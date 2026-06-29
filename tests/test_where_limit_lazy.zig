// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// H1 (where-limit-lazy): `MATCH (n:Label) WHERE <pred> RETURN ... LIMIT m` must
// STOP enumerating the label's live slots once `offset + m` predicate-matching
// rows are found — instead of enumerating ALL live slots up front and only THEN
// applying LIMIT during paging.
//
// Root cause (pre-fix): `node_scan_stream.prepare`'s `where_expr` arm calls
// `collectMatchingSlotIds(.., required_rows = null, ..)`, so the label branch
// runs `getNodesByLabelCapped(graph, label, cap = null)` which materializes
// EVERY live slot for the label (`appendLiveNodesForLabelShard`) before the
// per-row predicate + LIMIT ever apply in `buildNextPage`. The LIMIT never
// bounds the scan (the ~6-8K slots/s floor at scale).
//
// This test seeds a label with N live nodes whose predicate property matches on
// ALL of them (mirrors the bench `WHERE source='col'` shape), resets the
// live-slots-enumerated counter, then drives the REAL streaming path the
// transport handler uses for `... WHERE n.k='hit' RETURN n.k LIMIT 10`. It
// asserts BOTH:
//   (a) exactly 10 correct rows (each == 'hit'), and
//   (b) `getLabelSlotsEnumerated()` is BOUNDED (<< N) — enough shards to find
//       10 matches, not the whole label.
//
// RED (pre-fix): (a) passes but (b) FAILS — the counter equals N (all slots
// enumerated). GREEN (post-fix): the chunked, match-bounded enumeration stops
// after the first shard(s) yielding 10 matches, so the counter is ~one shard's
// worth (<< N).
//
// Wall-clock-independent (asserts a slot-enumeration COUNT, not a duration),
// tmpDir-isolated, CI-safe.
//
// CANARY: REQ=REQ-PERF-WHERE-LIMIT-LAZY; FEATURE="WhereLimitLazyEnumeration"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_where_limit_lazy.zig; OWNER=engine; UPDATED=2026-06-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const node_scan_stream = geode.node_scan_stream;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "T";
const PROP = "k";
const HIT = "hit";
const SEED_NODES: usize = 2000;
const LIMIT: usize = 10;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

// Seed N :T nodes spread naturally across shards (plain reserveNodeId), every
// node carrying k='hit' so the predicate matches all of them (the all-match
// shape). Returns once all N are applied.
fn seedGraph(adapter: *adapter_mod.StorageAdapter, store: *graph_store.GraphStore, n: usize) !void {
    const labels = [_][]const u8{LABEL};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const reserved = store.reserveNodeId();
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = PROP, .value = .{ .String = HIT } },
        };
        _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props);
    }
}

// Drive the WHERE+LIMIT scan EXACTLY as the transport handler does: prepare the
// stream, then materialize pages (buildNextPage acquires/releases the per-graph
// SHARED read lock internally). Returns the number of matched rows AND records
// whether every returned k value was 'hit'.
fn runWhereLimitScan(allocator: std.mem.Allocator, ctx: execution.ExecutionContext, all_hit: *bool) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try parseQuery(&arena, "MATCH (n:T) WHERE n.k = 'hit' RETURN n.k LIMIT 10");
    const prepared = (try node_scan_stream.prepare(aa, q, ctx, &.{}, &.{}, &.{})) orelse
        return error.NotStreamable;
    var stream = prepared;
    defer stream.deinit();

    var matched: usize = 0;
    all_hit.* = true;
    while (stream.hasRemaining()) {
        var page = try stream.buildNextPage(aa, LIMIT);
        for (page.result.rows) |row| {
            matched += 1;
            // RETURN n.k → single column; value must be the string 'hit'.
            if (row.len != 1 or row[0] != .Str or !std.mem.eql(u8, row[0].Str, HIT)) {
                all_hit.* = false;
            }
        }
        page.result.deinit(aa);
        if (page.final) break;
    }
    return matched;
}

test "WHERE+LIMIT bounds label-slot enumeration by matches, not full scan (H1)" {
    const allocator = testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);

    try seedGraph(adapter, store, SEED_NODES);

    // Reset the enumeration counter immediately before the query so it measures
    // ONLY the WHERE+LIMIT scan's slot enumeration (seeding uses writes, not the
    // label-scan enumeration path).
    adapter_mod.resetLabelSlotsEnumerated();

    var all_hit: bool = true;
    const matched = try runWhereLimitScan(allocator, ctx, &all_hit);
    const enumerated = adapter_mod.getLabelSlotsEnumerated();

    std.debug.print(
        "where-limit-lazy: matched={d} all_hit={} slots_enumerated={d} (N={d})\n",
        .{ matched, all_hit, enumerated, SEED_NODES },
    );

    // (a) Correctness: exactly LIMIT rows, every one a real 'hit'.
    try testing.expectEqual(LIMIT, matched);
    try testing.expect(all_hit);

    // (b) Bounded enumeration: finding 10 matches must NOT enumerate the whole
    // label. With SHARD_COUNT=16 and all-match, the first shard(s) holding >= 10
    // live slots suffice (~N/16 enumerated). Pre-fix this equals N (all slots);
    // post-fix it is far below. A generous bound (N/4) cleanly separates the two
    // while tolerating shard-distribution skew.
    try testing.expect(enumerated < SEED_NODES);
    try testing.expect(enumerated <= SEED_NODES / 4);
}
