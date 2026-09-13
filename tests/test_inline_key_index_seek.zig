// KNOWN BUG #1 (read-stress) reproduction / regression.
//
// Triage: inline-property EQUALITY reads — `MATCH (n:Taxon {source_id:'X'})`
// and `MATCH (n:Taxon {source:'col'})` — routed through
// `node_scan_stream.collectMatchingSlotIds`, which (when the pattern carries a
// label) FULL-SCANNED the label posting list via `iterateNodesByLabel` and
// called `nodeMatchesPattern` (a full `getAllNodeProperties` fetch + per-prop
// compare) on EVERY node — O(graph) — even when the equality property is the
// indexed unique MERGE key. At 14.27M nodes a single point-read took ~30s and
// hogged CPU.
//
// The storage adapter already exposes an O(matching) exact-property index
// (`getCandidateNodesByLabelAndProperty`, also used by the MERGE dedup path).
// The fix wires `collectMatchingSlotIds` to SEEK that index for any inline
// equality on an INDEXED property (gated by `graph_store.shouldIndexProperty`,
// the same predicate the write path uses), then re-verifies each candidate via
// the UNCHANGED `nodeMatchesPattern` so results are byte-for-byte identical to
// the full-scan path. An authoritative index miss returns empty immediately
// (no full scan).
//
// These tests are wall-clock-INDEPENDENT. They assert:
//   1. Correct results: present key -> exactly 1 row; absent key -> 0 rows.
//   2. The seek path is actually taken (the exact-property index lookup counter
//      increments for the indexed inline read).
//   3. The streamed rows are IDENTICAL to a full-scan baseline (the WHERE-clause
//      form, which is not inline-property and still scans), proving the fast
//      path changes only HOW candidates are gathered, never WHICH rows match.
//   4. Multi-property inline equality stays correct (the most-selective indexed
//      prop seeds the seek; the rest are verified per-candidate).
//
// CANARY: REQ=REQ-PERF-INLINE-KEY-INDEX-SEEK; FEATURE="InlineKeyIndexSeek"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_inline_key_index_seek.zig; OWNER=performance; UPDATED=2026-06-20

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const graph_storage_adapter = geode.graph_storage_adapter;

const N_NODES: usize = 1500;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    // Seed via MERGE so `source_id` is registered as a merge key (keeping the
    // exact index populated even under GEODE_INDEX_MERGE_KEYS_ONLY). `source`
    // is a low-selectivity grouping prop; `kingdom` is a third prop. In the
    // default (non-lean) test process every prop is indexed regardless.
    fn seed(self: *Harness, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source_id: 'sid{d}'}}) ON CREATE SET n.source = 'col', n.name = 'name{d}', n.rank = {d}",
                .{ i, i, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

// Run a streamable query fully (all pages) and return the materialized rows
// count. Caller owns the arena; rows live in `qa`.
fn streamRowCount(
    aa: std.mem.Allocator,
    q: *const geode.gql.ast.Query,
    ctx: execution.ExecutionContext,
) !usize {
    var stream = (try node_scan_stream.prepare(aa, q, ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();

    var total: usize = 0;
    while (true) {
        var page = try stream.buildNextPage(aa, 256);
        defer page.result.deinit(aa);
        total += page.result.rows.len;
        if (page.final) break;
    }
    return total;
}

// -------------------------------------------------------------------
// Test 1 — present indexed key: exactly 1 row, and the exact-property
// index was actually consulted (seek path taken, not a full scan).
// -------------------------------------------------------------------
test "inline-key index seek: present source_id returns 1 row via index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid42'}) RETURN n");
    // SONNY-1229: `isEligible` takes the session's tenant scope (the same value
    // the caller passes to `prepare` via the ExecutionContext). These harnesses
    // are unscoped single-tenant (`ctx.tenant_id == null`) with strict tenancy
    // off, so `null` is the scope under test and the fast path stays engaged.
    try testing.expect(node_scan_stream.isEligible(q, null));

    graph_storage_adapter.resetLookupCounters();
    const rows = try streamRowCount(aa, q, h.ctx);

    try testing.expectEqual(@as(usize, 1), rows);
    // The seek path consulted the exact-property index at least once. Before
    // the fix this counter stayed 0 (the read full-scanned the label instead).
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
}

// -------------------------------------------------------------------
// Test 2 — absent indexed key: empty fast (authoritative index miss),
// NOT a silent full scan that drops rows.
// -------------------------------------------------------------------
test "inline-key index seek: absent source_id returns empty via index miss" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid-does-not-exist'}) RETURN n");
    graph_storage_adapter.resetLookupCounters();
    const rows = try streamRowCount(aa, q, h.ctx);

    try testing.expectEqual(@as(usize, 0), rows);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
}

// -------------------------------------------------------------------
// Test 3 — RESULT PARITY: the index-seek inline read returns EXACTLY the
// same rows as the equivalent WHERE-clause scan (which does not use the
// inline-property seek). Correctness is paramount: the fast path must not
// change which rows match.
// -------------------------------------------------------------------
test "inline-key index seek: results identical to scan baseline" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    // Indexed-seek form (inline equality on the unique key).
    const inline_q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid7'}) RETURN n");
    const inline_rows = try streamRowCount(aa, inline_q, h.ctx);

    // Scan baseline: WHERE form on the same key. This is also streamable but
    // collects slots by full label scan + per-node predicate, never the inline
    // seek — so it is an independent ground truth.
    const scan_q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source_id = 'sid7' RETURN n");
    const scan_rows = try streamRowCount(aa, scan_q, h.ctx);

    try testing.expectEqual(scan_rows, inline_rows);
    try testing.expectEqual(@as(usize, 1), inline_rows);

    // Low-selectivity grouping prop: every node shares source='col'. The inline
    // seek must return ALL N (re-verified per candidate), identical to the WHERE
    // scan over the same predicate.
    const inline_all = try parseQuery(&qa, "MATCH (n:Taxon {source: 'col'}) RETURN n");
    const inline_all_rows = try streamRowCount(aa, inline_all, h.ctx);
    const scan_all = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source = 'col' RETURN n");
    const scan_all_rows = try streamRowCount(aa, scan_all, h.ctx);

    try testing.expectEqual(scan_all_rows, inline_all_rows);
    try testing.expectEqual(@as(usize, N_NODES), inline_all_rows);
}

// -------------------------------------------------------------------
// Test 4 — multi-property inline equality stays correct. The most-selective
// indexed prop (unique source_id) seeds the seek; the second prop (source)
// is verified per-candidate. A matching combo returns 1; a mismatched combo
// returns 0.
// -------------------------------------------------------------------
test "inline-key index seek: multi-property equality is correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    // Both props match the same node -> 1 row.
    const match_q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid9', source: 'col'}) RETURN n");
    try testing.expectEqual(@as(usize, 1), try streamRowCount(aa, match_q, h.ctx));

    // source_id exists but the second prop contradicts -> 0 rows (the seek
    // narrows to the unique node, the per-candidate verify rejects it).
    const mismatch_q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid9', source: 'nope'}) RETURN n");
    try testing.expectEqual(@as(usize, 0), try streamRowCount(aa, mismatch_q, h.ctx));
}

// -------------------------------------------------------------------
// Test 5 — count(n) over an inline indexed equality is correct and uses
// the seek (filtered count tallies seeked+verified candidates, no clone).
// -------------------------------------------------------------------
test "inline-key index seek: filtered count is correct via index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid100'}) RETURN count(n)");
    try testing.expect(node_scan_stream.isEligible(q, null));

    var stream = (try node_scan_stream.prepare(aa, q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();

    var page = try stream.buildNextPage(aa, 256);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    // The single count row must equal 1 (exactly one node has source_id sid100).
    const count_val = page.result.rows[0][0];
    const got: i64 = switch (count_val) {
        .Int => |v| v,
        .BigInt => |v| v,
        .SmallInt => |v| v,
        else => return error.UnexpectedCountType,
    };
    try testing.expectEqual(@as(i64, 1), got);
}

// ===================================================================
// GAP-ENT-0019: a WHERE-clause equality on an indexed scalar property must
// use the SAME exact-index SEEK the inline `{prop:val}` form uses — O(matching)
// not O(n). RED (pre-fix): `MATCH (n:L) WHERE n.key = 'v'` full-scanned the
// label (getLabelScanLookupCount > 0, getExactNodePropertyLookupCount == 0).
// GREEN (post-fix): it seeks (getExactNodePropertyLookupCount > 0,
// getLabelScanLookupCount == 0). Soundness: only a pure-ASCII, non-bool,
// non-numeric string literal on an indexed key seeks (identical gate to
// match_operations.seekableAsciiStringEq); numeric/non-ASCII literals fall back
// to the exact full scan. Every candidate is re-verified + the full WHERE is
// re-applied downstream, so results are byte-identical to the scan.
// ===================================================================

fn countOfStream(
    aa: std.mem.Allocator,
    q: *const geode.gql.ast.Query,
    ctx: execution.ExecutionContext,
) !i64 {
    var stream = (try node_scan_stream.prepare(aa, q, ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();
    var page = try stream.buildNextPage(aa, 256);
    defer page.result.deinit(aa);
    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    return switch (page.result.rows[0][0]) {
        .Int => |v| v,
        .BigInt => |v| v,
        .SmallInt => |v| v,
        else => error.UnexpectedCountType,
    };
}

// Test 6 — selective WHERE equality on the unique indexed key: exactly 1, and
// the SEEK path is taken (exact-property lookup > 0, NO full label scan).
test "where-clause index seek: selective WHERE equality uses seek, count == 1" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source_id = 'sid5' RETURN count(n)");
    try testing.expect(node_scan_stream.isEligible(q, null));

    graph_storage_adapter.resetLookupCounters();
    const got = try countOfStream(aa, q, h.ctx);

    try testing.expectEqual(@as(i64, 1), got);
    // GREEN: seek engaged. RED (pre-fix) left exact==0 and label-scan>0.
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
}

// Test 7 — RETURN n (node shape, not count) also seeks: the fix helps ALL read
// shapes routed through collectMatchingSlotIds, not just count.
test "where-clause index seek: RETURN n via WHERE uses seek" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source_id = 'sid3' RETURN n");
    graph_storage_adapter.resetLookupCounters();
    const rows = try streamRowCount(aa, q, h.ctx);

    try testing.expectEqual(@as(usize, 1), rows);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
}

// Test 8 — low-selectivity WHERE equality (every node shares source='col')
// returns ALL N, and STILL seeks (candidates re-verified per node). Byte-parity
// with a full-scan oracle (an ORDERING predicate that has no seekable Eq
// conjunct and therefore scans).
test "where-clause index seek: all-match equality returns N, parity with scan oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    // Seek path: WHERE source = 'col' (all N match).
    const seek_q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source = 'col' RETURN count(n)");
    graph_storage_adapter.resetLookupCounters();
    const seek_count = try countOfStream(aa, seek_q, h.ctx);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());

    // Oracle: an ORDERING predicate (no Eq conjunct) forces the full label scan
    // — an independent ground truth for the same result set (rank = 0..N-1 ≥ 0).
    const oracle_q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.rank >= 0 RETURN count(n)");
    graph_storage_adapter.resetLookupCounters();
    const oracle_count = try countOfStream(aa, oracle_q, h.ctx);
    try testing.expect(graph_storage_adapter.getLabelScanLookupCount() > 0);

    try testing.expectEqual(@as(i64, @intCast(N_NODES)), seek_count);
    try testing.expectEqual(oracle_count, seek_count);
}

// Test 9 — SOUNDNESS: a NUMERIC WHERE equality literal must NOT seek (eval `=`
// cross-type coerces, broader than the raw-hash index) — it falls back to the
// exact full scan and still returns the correct count. sid5 was seeded with
// rank = 5, so exactly one node matches.
test "where-clause index seek: numeric equality falls back to scan, correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.rank = 5 RETURN count(n)");
    graph_storage_adapter.resetLookupCounters();
    const got = try countOfStream(aa, q, h.ctx);

    try testing.expectEqual(@as(i64, 1), got);
    // Numeric literal is NOT seekable → the label was full-scanned.
    try testing.expect(graph_storage_adapter.getLabelScanLookupCount() > 0);
}

// Test 10 — SOUNDNESS: a NON-ASCII WHERE equality literal must NOT seek (NFC
// normalization makes eval string-eq broader than the raw-byte hash index) — it
// falls back to the full scan and still finds the matching node.
test "where-clause index seek: non-ascii equality falls back to scan, correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    // A node whose source_id contains a non-ASCII byte (é = 0xC3 0xA9).
    {
        var r = try h.runQuery("CREATE (n:Taxon {source_id: 'caf\u{00e9}', source: 'col', rank: 424242})");
        r.deinit(h.arena.allocator());
    }

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.source_id = 'caf\u{00e9}' RETURN count(n)");
    graph_storage_adapter.resetLookupCounters();
    const got = try countOfStream(aa, q, h.ctx);

    try testing.expectEqual(@as(i64, 1), got);
    // Non-ASCII literal is NOT seekable → the label was full-scanned.
    try testing.expect(graph_storage_adapter.getLabelScanLookupCount() > 0);
}

// Test 11 — INLINE path unchanged (no regression): the inline `{source_id:'v'}`
// form still seeks and returns 1 (guards against the merge accidentally breaking
// the original path).
test "where-clause index seek: inline path still seeks (no regression)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    const q = try parseQuery(&qa, "MATCH (n:Taxon {source_id: 'sid8'}) RETURN n");
    graph_storage_adapter.resetLookupCounters();
    const rows = try streamRowCount(aa, q, h.ctx);

    try testing.expectEqual(@as(usize, 1), rows);
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() > 0);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
}
