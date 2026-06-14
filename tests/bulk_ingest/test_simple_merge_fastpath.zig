// Simple-MERGE fast-path parity + correctness tests.
//
// Extends the Task 11/12/16 bulk-ingest fast path with the msft-graph
// nodes_*.jsonl hot pattern:
//
//     MERGE (n:L {merge_key: v}) ON CREATE SET n.a = ..., n.b = ..., ...
//
// Exercised cases (all run directly against `bulkMergeNode` — the
// QUIC handler integration is covered by the msft-graph ingest workload):
//
//   1. MERGE hits an existing node — second call returns the same id and
//      does not duplicate the label-index posting entry.
//   2. MERGE creates when missing — first call inserts with label +
//      merge key + ON CREATE SET properties.
//   3. Parity — executor path and bulk path produce semantically identical
//      final GraphStore state.
//   4. Concurrent-MERGE race — 16 threads racing on the SAME merge id
//      result in exactly one node (label-index posting length == 1).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const fle_integration = geode.fle_integration;

// libc env shims: the FLE key manager reads GEODE_MASTER_KEY (and the FLE
// catalog persistence reads GEODE_DATA_DIR) via std.c.getenv. The test module
// links libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// 32-byte secret (hex) for the FLE master key — test-only, never a real secret.
// This bulk-MERGE suite does NOT configure any FLE field, but the storage
// adapter's defense-in-depth FLE hook reads the key manager (which refuses to
// operate without a master key) the moment ANY encrypted field is configured
// in the process-global catalog. The pre-push test shards run WITHOUT
// GEODE_MASTER_KEY in the environment, so we install a deterministic one here
// to make this suite self-sufficient and order-independent.
const TEST_MASTER_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

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
        // Make this suite self-sufficient w.r.t. FLE: install a deterministic
        // master key (the pre-push shards run without GEODE_MASTER_KEY set) and
        // isolate the persisted FLE catalog so a SIBLING test that configured an
        // encrypted field (e.g. test_gap0854_fle_chain's ('User','email'))
        // cannot leak its config into this process via the shared
        // {GEODE_DATA_DIR or /tmp}/geode_fle_catalog.dat file. Point
        // GEODE_DATA_DIR at this harness's own tmp dir and reset the in-memory
        // global catalog so it reloads from there (empty).
        _ = setenv("GEODE_MASTER_KEY", TEST_MASTER_KEY_HEX, 1);

        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        // Isolate the FLE catalog persistence to this data dir (it reads the
        // GEODE_DATA_DIR env at load/save time) and clear any catalog the
        // process already loaded from a prior /tmp path.
        const data_dir_z = try allocator.dupeZ(u8, data_dir);
        defer allocator.free(data_dir_z);
        _ = setenv("GEODE_DATA_DIR", data_dir_z.ptr, 1);
        fle_integration.catalog_mod.resetGlobalCatalog(allocator);
        fle_integration.setHasEncryptedFields(false);

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
        // Drop the FLE catalog isolation so we leave no global state (or env
        // override pointing at a now-deleted tmp dir) behind for sibling tests.
        fle_integration.catalog_mod.resetGlobalCatalog(self.allocator);
        fle_integration.setHasEncryptedFields(false);
        _ = unsetenv("GEODE_DATA_DIR");
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

fn findNodeByProperty(
    store: *graph_store.GraphStore,
    key: []const u8,
    expected: []const u8,
) ?*graph_store.Node {
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.properties.get(key)) |pv| {
            switch (pv) {
                .String => |s| if (std.mem.eql(u8, s, expected)) return node,
                else => {},
            }
        }
    }
    return null;
}

fn labelPostingLen(store: *graph_store.GraphStore, graph_name: []const u8, label: []const u8) usize {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, label }) catch return 0;
    const posting = store.label_index.getPtr(key) orelse return 0;
    posting.lock();
    defer posting.unlock();
    return posting.list.items.len;
}

// ----------------------------------------------------------------------
// 1. MERGE hits an existing node.
// ----------------------------------------------------------------------

test "bulkMergeNode returns existing id + does not duplicate posting" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;

    // First call: fresh insert.
    const first_id = try adapter.bulkMergeNode(
        "default",
        "Widget",
        "node_id",
        .{ .String = "alpha" },
        &.{
            .{ .key = "name", .value = .{ .String = "alpha" } },
        },
        null,
        false,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "Widget"));

    // Second call with the same merge key: MUST return the same id and
    // must NOT grow the label-posting list.
    const second_id = try adapter.bulkMergeNode(
        "default",
        "Widget",
        "node_id",
        .{ .String = "alpha" },
        &.{
            // Even with new on-create props, a hit should be a no-op.
            .{ .key = "name", .value = .{ .String = "Bob" } },
        },
        null,
        false,
    );
    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "Widget"));

    // On-match is a no-op: the name stays as it was on first insert.
    const node = store.nodes.getPtr(first_id) orelse return error.NodeMissing;
    const name_pv = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("alpha", name_pv.String);
}

// ----------------------------------------------------------------------
// 2. MERGE creates missing node + writes ON CREATE SET props.
// ----------------------------------------------------------------------

test "bulkMergeNode inserts label + merge key + all ON CREATE props" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const node_id = try adapter.bulkMergeNode(
        "default",
        "Widget",
        "node_id",
        .{ .String = "beta" },
        &.{
            .{ .key = "name", .value = .{ .String = "alpha" } },
            .{ .key = "email", .value = .{ .String = "a@b.c" } },
            .{ .key = "age", .value = .{ .Int = 30 } },
        },
        null,
        false,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.getPtr(node_id) orelse return error.NodeMissing;

    // Label exists.
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("Widget", node.labels[0]);

    // Merge key was written as a node property.
    const node_id_prop = node.properties.get("node_id") orelse return error.MissingNodeId;
    try testing.expectEqualStrings("beta", node_id_prop.String);

    // All ON CREATE SET values landed.
    const name_prop = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("alpha", name_prop.String);
    const email_prop = node.properties.get("email") orelse return error.MissingEmail;
    try testing.expectEqualStrings("a@b.c", email_prop.String);
    const age_prop = node.properties.get("age") orelse return error.MissingAge;
    try testing.expectEqual(@as(i64, 30), age_prop.Int);

    // Store marked dirty.
    try testing.expect(store.isDirty());

    // Label posting has exactly one entry.
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "Widget"));
}

// ----------------------------------------------------------------------
// 3. Parity: executor path + bulk path produce semantically identical
//    final GraphStore state.
// ----------------------------------------------------------------------

test "bulkMergeNode parity with executor path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Path A: executor path.
    var r = try h.runQuery(
        "MERGE (n:Widget {node_id: 'exec-abc'}) ON CREATE SET n.name = 'alpha', n.age = 30",
    );
    r.deinit(testing.allocator);

    // Path B: bulk path.
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.bulkMergeNode(
        "default",
        "Widget",
        "node_id",
        .{ .String = "bulk-xyz" },
        &.{
            .{ .key = "name", .value = .{ .String = "alpha" } },
            .{ .key = "age", .value = .{ .Int = 30 } },
        },
        null,
        false,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    const exec_node = findNodeByProperty(store, "node_id", "exec-abc") orelse
        return error.ExecutorNodeMissing;
    const bulk_node = findNodeByProperty(store, "node_id", "bulk-xyz") orelse
        return error.BulkNodeMissing;

    // Labels identical.
    try testing.expectEqual(@as(usize, 1), exec_node.labels.len);
    try testing.expectEqual(@as(usize, 1), bulk_node.labels.len);
    try testing.expectEqualStrings("Widget", exec_node.labels[0]);
    try testing.expectEqualStrings("Widget", bulk_node.labels[0]);

    // Properties identical.
    const exec_name = exec_node.properties.get("name") orelse return error.MissingExecName;
    const bulk_name = bulk_node.properties.get("name") orelse return error.MissingBulkName;
    try testing.expectEqualStrings(exec_name.String, bulk_name.String);

    const exec_age = exec_node.properties.get("age") orelse return error.MissingExecAge;
    const bulk_age = bulk_node.properties.get("age") orelse return error.MissingBulkAge;
    try testing.expectEqual(exec_age.Int, bulk_age.Int);

    // Both nodes are indexed under the "Widget" label.
    try testing.expectEqual(@as(usize, 2), labelPostingLen(store, "default", "Widget"));
}

// ----------------------------------------------------------------------
// 4. Concurrent MERGE race — 16 threads racing on the SAME id yield
//    exactly one node.
// ----------------------------------------------------------------------

const race_thread_count: usize = 16;

const RaceWorkerCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    ids: [race_thread_count]u64 = [_]u64{0} ** race_thread_count,
    tid: usize = 0,
    errored: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    barrier: *std.atomic.Value(u32),
    ready_count: *std.atomic.Value(u32),
};

fn concurrentMergeWorker(ctx: *RaceWorkerCtx) void {
    // Signal ready, then busy-wait for the go signal so all 16 threads
    // enter `bulkMergeNode` within a narrow window.
    _ = ctx.ready_count.fetchAdd(1, .acq_rel);
    while (ctx.barrier.load(.acquire) == 0) std.Thread.yield() catch {};

    // Take the per-graph write lock for the insert phase: this mirrors
    // what the QUIC handler does for the MERGE fast path (Phase 2 of
    // the two-phase split).  Under the write lock the lookupMergeCandidate
    // probe + insert is atomic from the caller's perspective, so the
    // 15 losing threads see the winning insert on their re-probe.
    //
    // Deadline is intentionally generous (180s). The actual lock-hold work is
    // tiny, but the local pre-push gate runs all 4 test shards in parallel
    // (`.pre-commit-config.yaml` zig-test), oversubscribing the box far past its
    // cores; a waiting thread can then be descheduled for many seconds between
    // lock-handoffs. The old 30s deadline made ~14/16 threads time out and report
    // a spurious error under that oversubscription (the dedup invariants below
    // were never the problem — they pass cleanly when run un-oversubscribed). A
    // large deadline lets every thread acquire so the test measures correctness,
    // not scheduler latency.
    const deadline = monoNanosNow() + 180 * std.time.ns_per_s;
    const handle = graph_store.acquireGraphWriteLockCancelable("default", deadline) catch {
        _ = ctx.errored.fetchAdd(1, .monotonic);
        return;
    };
    defer graph_store.releaseGraphLock(handle);

    const id = ctx.adapter.bulkMergeNode(
        "default",
        "U",
        "id",
        .{ .String = "X" },
        &.{},
        null,
        false,
    ) catch {
        _ = ctx.errored.fetchAdd(1, .monotonic);
        return;
    };
    ctx.ids[ctx.tid] = id;
}

fn monoNanosNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    const sec = @as(u64, @intCast(ts.sec));
    const nsec = @as(u64, @intCast(ts.nsec));
    return sec * std.time.ns_per_s + nsec;
}

test "concurrent MERGE on same key inserts exactly one node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    var ctxs: [race_thread_count]RaceWorkerCtx = undefined;
    var barrier = std.atomic.Value(u32).init(0);
    var ready_count = std.atomic.Value(u32).init(0);

    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .adapter = adapter,
            .tid = i,
            .barrier = &barrier,
            .ready_count = &ready_count,
        };
    }

    var threads: [race_thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, concurrentMergeWorker, .{&ctxs[i]});
    }

    // Wait for all threads to reach the barrier, then release them.
    while (ready_count.load(.acquire) < race_thread_count) std.Thread.yield() catch {};
    barrier.store(1, .release);

    for (threads) |t| t.join();

    // Invariants:
    //   * No thread errored (every call completed cleanly).
    //   * Exactly one posting-list entry under (default, U).
    //   * All 16 returned ids are identical.
    var error_total: u32 = 0;
    for (ctxs) |c| error_total += c.errored.load(.monotonic);
    try testing.expectEqual(@as(u32, 0), error_total);

    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "U"));

    const first_id = ctxs[0].ids[0];
    try testing.expect(first_id != 0);
    for (ctxs) |c| {
        try testing.expectEqual(first_id, c.ids[c.tid]);
    }

    // The single inserted node is the one we resolve via the merge index.
    var verify_id: u64 = undefined;
    const res = store.lookupMergeCandidate(
        "default",
        "U",
        "id",
        .{ .String = "X" },
        &verify_id,
    );
    try testing.expect(res == .found);
    try testing.expectEqual(first_id, verify_id);
}

// ----------------------------------------------------------------------
// 5. Bare-SET MERGE upsert via apply_on_match=true.
//
// Covers the GAP #59 case where the user wrote `MERGE (...) SET ...`
// (no ON CREATE / ON MATCH qualifier).  The parser duplicates the SET
// clauses into both `on_create` and `on_match` and sets
// `set_is_bare = true`; the bulk fast-path detector forwards that to
// the spec as `apply_on_match = true`, and the executor calls
// bulkMergeNode with the new flag so existing nodes are upserted
// instead of treated as no-ops on the match branch.
// ----------------------------------------------------------------------

test "bulkMergeNode apply_on_match creates missing node with props" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;

    const node_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "u1" },
        &.{
            .{ .key = "name", .value = .{ .String = "alice" } },
            .{ .key = "age", .value = .{ .Int = 30 } },
        },
        null,
        true, // apply_on_match
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.getPtr(node_id) orelse return error.NodeMissing;

    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("User", node.labels[0]);

    const node_id_prop = node.properties.get("node_id") orelse return error.MissingNodeId;
    try testing.expectEqualStrings("u1", node_id_prop.String);
    const name_prop = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("alice", name_prop.String);
    const age_prop = node.properties.get("age") orelse return error.MissingAge;
    try testing.expectEqual(@as(i64, 30), age_prop.Int);

    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "User"));
}

test "bulkMergeNode apply_on_match updates existing node (true upsert)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    // First call: create the node with name=alice.
    const first_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "u1" },
        &.{
            .{ .key = "name", .value = .{ .String = "alice" } },
        },
        null,
        true,
    );

    // Second call with the same merge key but different name — apply_on_match
    // must overwrite the existing prop instead of returning early like the
    // ON-CREATE-SET-only path does.
    const second_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "u1" },
        &.{
            .{ .key = "name", .value = .{ .String = "bob" } },
            .{ .key = "email", .value = .{ .String = "bob@example.com" } },
        },
        null,
        true,
    );

    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "User"));

    const node = store.nodes.getPtr(first_id) orelse return error.NodeMissing;

    // Property MUST have been updated (this is the bug we are fixing —
    // bulkMergeNode without apply_on_match would still report 'alice').
    const name_prop = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("bob", name_prop.String);

    // New prop added on the upsert is also present.
    const email_prop = node.properties.get("email") orelse return error.MissingEmail;
    try testing.expectEqualStrings("bob@example.com", email_prop.String);
}

test "bulkMergeNode apply_on_match=false preserves ON CREATE SET no-op semantics" {
    // Regression guard — the new apply_on_match parameter MUST default to
    // create-or-no-op on `false` so explicit ON CREATE SET clients are
    // unaffected by this fix.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    const first_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "u2" },
        &.{
            .{ .key = "name", .value = .{ .String = "alice" } },
        },
        null,
        false, // ON CREATE SET-only semantics
    );

    const second_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "u2" },
        &.{
            // These would be applied on match ONLY if apply_on_match=true.
            .{ .key = "name", .value = .{ .String = "bob" } },
        },
        null,
        false,
    );

    try testing.expectEqual(first_id, second_id);
    const node = store.nodes.getPtr(first_id) orelse return error.NodeMissing;
    const name_prop = node.properties.get("name") orelse return error.MissingName;
    // On-match is a no-op: original "alice" must remain.
    try testing.expectEqualStrings("alice", name_prop.String);
}

// ----------------------------------------------------------------------
// 6. End-to-end: bare SET MERGE through the parser → detector path.
//
// Verifies that the parser flags `set_is_bare = true` for a bare SET,
// the detector accepts it (vs. rejecting on `on_match.len != 0`), and
// the resulting spec carries `apply_on_match = true`.  This is the
// regression test for the msft-graph seed-stall — it locks in the
// classification at the AST/spec layer so any future detector change
// that skips the bare-SET case fails fast here, before silently
// dropping seeds back to the slow path.
// ----------------------------------------------------------------------

test "parser marks bare SET MERGE with set_is_bare=true" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try geode.parseGql(
        "MERGE (n:User {node_id: 'u1'}) SET n.name = 'alice', n.age = 30",
        arena.allocator(),
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.program.statements.len);
    const merge = switch (parsed.program.statements[0]) {
        .Merge => |m| m,
        else => return error.WrongStatementKind,
    };

    try testing.expect(merge.set_is_bare);
    // Parser duplicated the bare SET into both clauses.
    try testing.expectEqual(@as(usize, 2), merge.on_create.len);
    try testing.expectEqual(@as(usize, 2), merge.on_match.len);
}

test "parser leaves set_is_bare=false for explicit ON CREATE SET" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try geode.parseGql(
        "MERGE (n:User {node_id: 'u1'}) ON CREATE SET n.name = 'alice'",
        arena.allocator(),
    );
    defer parsed.deinit();

    const merge = switch (parsed.program.statements[0]) {
        .Merge => |m| m,
        else => return error.WrongStatementKind,
    };
    try testing.expect(!merge.set_is_bare);
    try testing.expectEqual(@as(usize, 1), merge.on_create.len);
    try testing.expectEqual(@as(usize, 0), merge.on_match.len);
}

test "bulk fast-path detector accepts bare SET, sets apply_on_match=true" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try geode.parseGql(
        "MERGE (n:User {node_id: 'u1'}) SET n.name = 'alice'",
        arena.allocator(),
    );
    defer parsed.deinit();

    const spec_opt = geode.bulk_ingest.matchSimpleNodeMergeSpec(&parsed.program);
    const spec = spec_opt orelse return error.DetectorRejectedBareSet;
    try testing.expect(spec.apply_on_match);
    try testing.expectEqualStrings("User", spec.label);
    try testing.expectEqualStrings("node_id", spec.merge_key);
    try testing.expectEqual(@as(usize, 1), spec.on_create_props.len);
    try testing.expectEqualStrings("name", spec.on_create_props[0].key);
}

test "bulk fast-path detector rejects explicit ON MATCH SET" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try geode.parseGql(
        "MERGE (n:User {node_id: 'u1'}) ON CREATE SET n.a = 1 ON MATCH SET n.a = 2",
        arena.allocator(),
    );
    defer parsed.deinit();

    // Explicit ON MATCH SET (where on_match.len != 0 AND set_is_bare=false)
    // has divergent payloads; fast path can't currently express that, so
    // the detector must continue to reject it and fall back to the slow
    // executor.
    const spec_opt = geode.bulk_ingest.matchSimpleNodeMergeSpec(&parsed.program);
    try testing.expect(spec_opt == null);
}
