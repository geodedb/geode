// Task #34: bulk-edge ingest stalls on edges_app_role_assignment.jsonl.
// Level 1 regression — adapter-level contract tests for the future
// `StorageAdapter.setEdgePropertiesBatch` helper.
//
// Root cause (see docs/performance/2026-04-24-sharding/TASK-34-TRIAGE.md):
// `bulkInsertEdgeWithIds` in src/storage/graph_storage_adapter.zig runs a
// per-property loop where each property re-acquires the adapter mutex,
// performs 2× linear `updateEdgePropHead` scans, and an O(K)
// `refreshPropertyChainIndex` — yielding O(K²) per-edge cost for K props.
// The fix mirrors Task #33's `setNodePropertiesBatch` pattern but for
// edges: one adapter-mutex acquisition, one adjacency update per direction,
// one property-chain refresh, all under a single statement txn.
//
// These tests pin the behavioural contract.  Pre-fix: compile error —
// `setEdgePropertiesBatch` does not exist on `StorageAdapter`.  Post-fix:
// all three tests pass.
//
// Modelled after tests/bulk_ingest/test_two_phase_edge_lock.zig (which
// exercises `bulkInsertEdgeWithIds` end-to-end through the adapter) and
// tests/test_gap0815_batch_create.zig (harness pattern: real store, real
// parser, real executor, no mocks).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

// ----------------------------------------------------------------------
// Harness — identical shape to test_gap0815_batch_create.zig.
// ----------------------------------------------------------------------

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
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

// Seed two nodes (Widget{id:"A"} and Gadget{id:"B"}) + one edge Widget->Gadget
// of label LINKS_TO, and return (from_id, to_id, edge_id).
fn seedEdgePair(h: *Harness) !struct { from: u64, to: u64, edge: u64 } {
    var r1 = try h.runQuery("MERGE (n:Widget {node_id: 'A'})");
    r1.deinit(testing.allocator);
    var r2 = try h.runQuery("MERGE (n:Gadget {node_id: 'B'})");
    r2.deinit(testing.allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    // Resolve endpoints.
    var from_id: u64 = 0;
    var to_id: u64 = 0;
    {
        var it = store.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;
            if (node.properties.get("node_id")) |pv| switch (pv) {
                .String => |s| {
                    if (std.mem.eql(u8, s, "A")) from_id = node.id;
                    if (std.mem.eql(u8, s, "B")) to_id = node.id;
                },
                else => {},
            };
        }
    }
    try testing.expect(from_id != 0);
    try testing.expect(to_id != 0);

    // Create the edge (no initial properties).
    const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
    const write_handle = try graph_store.acquireGraphWriteLockCancelable("default", deadline);
    defer graph_store.releaseGraphLock(write_handle);
    const empty_props = [_]adapter_mod.StorageAdapter.PropKV{};
    const edge_id = try adapter.bulkInsertEdgeWithIds(
        "default",
        from_id,
        to_id,
        "LINKS_TO",
        &empty_props,
        null,
    );
    return .{ .from = from_id, .to = to_id, .edge = edge_id };
}

fn monoNanosNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    const sec = @as(u64, @intCast(ts.sec));
    const nsec = @as(u64, @intCast(ts.nsec));
    return sec * std.time.ns_per_s + nsec;
}

// ----------------------------------------------------------------------
// Test 1 (regression/unit): API exists and round-trips 5 properties in
// ONE batch call.  Pre-fix: compile error
// `error: no field or member function named 'setEdgePropertiesBatch' in 'StorageAdapter'`.
// Post-fix: five getEdgeProperty calls each return the set value.
// ----------------------------------------------------------------------
test "task34_regression: setEdgePropertiesBatch round-trips 5 properties in one call" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const ids = try seedEdgePair(&h);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    // Five heterogeneous entries — strings, ints, bools — to cover the
    // cases edges_app_role_assignment.jsonl actually writes.
    // Uses the public graph_store.GraphStore.BatchPropertyEntry type
    // (uppercase `PropertyValue` variants); `store.setEdgePropertiesBatch`
    // performs slot resolution and FLE encryption before dispatching to
    // the adapter-level batch helper.
    const entries = [_]graph_store.GraphStore.BatchPropertyEntry{
        .{ .key = "role", .value = .{ .String = "admin" } },
        .{ .key = "scope", .value = .{ .String = "tenant-1" } },
        .{ .key = "granted_at", .value = .{ .String = "2026-04-24T00:00:00Z" } },
        .{ .key = "seq", .value = .{ .Int = 42 } },
        .{ .key = "active", .value = .{ .Bool = true } },
    };

    // Take the per-graph write lock for the batch — mirrors the contract
    // `bulkInsertEdgeWithIds` requires from its callers.
    const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
    const write_handle = try graph_store.acquireGraphWriteLockCancelable("default", deadline);
    defer graph_store.releaseGraphLock(write_handle);

    try store.setEdgePropertiesBatch(ids.edge, &entries);

    // Verify each property round-tripped via the in-memory store, which
    // the batch must update in lock-step with the adapter engine writes.
    // `store.edges.getPtr(public_id).properties` is keyed by `graph_store
    // .PropertyValue` (uppercase tags).  Also assert via the adapter's
    // engine-space `getEdgeProperty` (slot-id space) to prove both layers
    // agree.
    const aa = h.arena.allocator();
    const edge = store.edges.get(ids.edge) orelse return error.EdgeMissing;
    for (entries) |entry| {
        const mem_prop = edge.properties.get(entry.key) orelse return error.PropertyMissing;
        switch (entry.value.?) {
            .String => |expected| try testing.expectEqualStrings(expected, mem_prop.String),
            .Int => |expected| try testing.expectEqual(expected, mem_prop.Int),
            .Bool => |expected| try testing.expectEqual(expected, mem_prop.Bool),
            else => unreachable,
        }
    }

    // Engine layer agreement — resolve slot ids via the same helpers
    // `store.setEdgeProperty` uses (lines 3375 / 3363 in graph_store.zig)
    // so we exercise the real slot-mapping path.
    const id_map = try store.getOrCreateIdMap("default");
    const slot_from = id_map.nodeSlot(@as(u128, ids.from)) orelse return error.SlotMissing;
    const slot_edge = id_map.edgeSlot(@as(u128, ids.edge)) orelse return error.SlotMissing;
    for (entries) |entry| {
        const got = try adapter.getEdgeProperty("default", slot_from, slot_edge, entry.key, aa);
        try testing.expect(got != null);
        switch (entry.value.?) {
            .String => |expected| try testing.expectEqualStrings(expected, got.?.string),
            .Int => |expected| try testing.expectEqual(expected, got.?.int),
            .Bool => |expected| try testing.expectEqual(expected, got.?.bool),
            else => unreachable,
        }
    }
}

// ----------------------------------------------------------------------
// Test 2 (regression/unit): When a StatementTxn is already active on this
// thread's graph, `setEdgePropertiesBatch` MUST join it rather than
// opening + committing its own engine txn.  Task #33's analogous invariant
// for `setNodePropertiesBatch` is at graph_storage_adapter.zig:2056.
//
// Pre-fix: compile error.
// Post-fix: observable as — after calling setEdgePropertiesBatch with a
// stmt_txn open, the values are visible immediately (statement txn has
// its own uncommitted view), and the stmt_txn.commit() is what flushes
// them durably.  If the batch opened + committed its own nested txn it
// would (a) conflict with NestedStatementTxn or (b) cause a double fsync
// — the very regression the fix eliminates.
// ----------------------------------------------------------------------
test "task34_regression: setEdgePropertiesBatch joins active StatementTxn instead of auto-committing" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const ids = try seedEdgePair(&h);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
    const write_handle = try graph_store.acquireGraphWriteLockCancelable("default", deadline);
    defer graph_store.releaseGraphLock(write_handle);

    // Open a per-statement engine txn BEFORE calling the batch.
    var stmt_txn: adapter_mod.StatementTxn = undefined;
    try adapter.beginStatementTxn("default", &stmt_txn);
    var committed = false;
    errdefer if (!committed) stmt_txn.abort();

    const entries = [_]graph_store.GraphStore.BatchPropertyEntry{
        .{ .key = "k1", .value = .{ .String = "v1" } },
        .{ .key = "k2", .value = .{ .String = "v2" } },
        .{ .key = "k3", .value = .{ .Int = 7 } },
    };

    // If the batch implementation tries to open its OWN statement txn
    // while one is already active, `beginStatementTxn` will return
    // `error.NestedStatementTxn` — the whole batch call will bubble up
    // that error and this test will fail with it.  The CORRECT post-fix
    // behaviour is to reuse the active stmt_txn (as `setNodePropertiesBatch`
    // does via `currentStatementTxnForGraph`) and return success.
    try store.setEdgePropertiesBatch(ids.edge, &entries);

    // Properties must be visible under the live statement txn — we can
    // read them back through the adapter (slot-space) and the in-memory
    // store simultaneously.  Engine-space `PropertyValue` uses lowercase
    // tags; `store.edges.get(...).properties` uses uppercase.
    const aa = h.arena.allocator();
    const id_map = try store.getOrCreateIdMap("default");
    const slot_from = id_map.nodeSlot(@as(u128, ids.from)) orelse return error.SlotMissing;
    const slot_edge = id_map.edgeSlot(@as(u128, ids.edge)) orelse return error.SlotMissing;

    const got_k1 = try adapter.getEdgeProperty("default", slot_from, slot_edge, "k1", aa);
    try testing.expect(got_k1 != null);
    try testing.expectEqualStrings("v1", got_k1.?.string);

    // Now commit the caller's statement txn.  This is the ONE fsync that
    // the batch optimisation guarantees — if the batch had auto-committed
    // its own txn, the engine would already have fsynced before we got
    // here, but commit() would still succeed (empty txn).  Either way,
    // committing must not error.
    try stmt_txn.commit();
    committed = true;

    // Post-commit: values still readable (now durably persisted).
    const got_k2 = try adapter.getEdgeProperty("default", slot_from, slot_edge, "k2", aa);
    try testing.expect(got_k2 != null);
    try testing.expectEqualStrings("v2", got_k2.?.string);

    const got_k3 = try adapter.getEdgeProperty("default", slot_from, slot_edge, "k3", aa);
    try testing.expect(got_k3 != null);
    try testing.expectEqual(@as(i64, 7), got_k3.?.int);
}

// ----------------------------------------------------------------------
// Test 3 (unit): parity — batching N properties through
// setEdgePropertiesBatch produces the same final edge state as setting
// them one at a time through the slow `setEdgeProperty` path.
//
// Covers correctness regressions where the batch path might skip / reorder
// adjacency-chain updates or miss a property-chain refresh.
// Pre-fix: compile error.  Post-fix: passes.
// ----------------------------------------------------------------------
test "task34_unit: setEdgePropertiesBatch parity with per-property setEdgeProperty loop" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed two edge pairs: one to receive the batch, one to receive the
    // per-property loop.  Compare final property sets.
    var r1 = try h.runQuery("MERGE (n:Widget {node_id: 'batchA'})");
    r1.deinit(testing.allocator);
    var r2 = try h.runQuery("MERGE (n:Gadget {node_id: 'batchB'})");
    r2.deinit(testing.allocator);
    var r3 = try h.runQuery("MERGE (n:Widget {node_id: 'loopA'})");
    r3.deinit(testing.allocator);
    var r4 = try h.runQuery("MERGE (n:Gadget {node_id: 'loopB'})");
    r4.deinit(testing.allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    var batch_from: u64 = 0;
    var batch_to: u64 = 0;
    var loop_from: u64 = 0;
    var loop_to: u64 = 0;
    {
        var it = store.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;
            if (node.properties.get("node_id")) |pv| switch (pv) {
                .String => |s| {
                    if (std.mem.eql(u8, s, "batchA")) batch_from = node.id;
                    if (std.mem.eql(u8, s, "batchB")) batch_to = node.id;
                    if (std.mem.eql(u8, s, "loopA")) loop_from = node.id;
                    if (std.mem.eql(u8, s, "loopB")) loop_to = node.id;
                },
                else => {},
            };
        }
    }
    try testing.expect(batch_from != 0 and batch_to != 0 and loop_from != 0 and loop_to != 0);

    const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
    const write_handle = try graph_store.acquireGraphWriteLockCancelable("default", deadline);
    defer graph_store.releaseGraphLock(write_handle);

    const empty_props = [_]adapter_mod.StorageAdapter.PropKV{};
    const batch_edge = try adapter.bulkInsertEdgeWithIds(
        "default",
        batch_from,
        batch_to,
        "LINKS_TO",
        &empty_props,
        null,
    );
    const loop_edge = try adapter.bulkInsertEdgeWithIds(
        "default",
        loop_from,
        loop_to,
        "LINKS_TO",
        &empty_props,
        null,
    );

    // Batch path.
    const entries = [_]graph_store.GraphStore.BatchPropertyEntry{
        .{ .key = "role", .value = .{ .String = "admin" } },
        .{ .key = "scope", .value = .{ .String = "t1" } },
        .{ .key = "weight", .value = .{ .Int = 5 } },
    };
    try store.setEdgePropertiesBatch(batch_edge, &entries);

    // Loop path — mirror the slow per-property flow through
    // GraphStore.setEdgeProperty (what today's `bulkInsertEdgeWithIds`
    // uses).  This exercises the *reference* code path so any divergence
    // is attributable to the new batch helper.
    try store.setEdgeProperty(loop_edge, "role", .{ .String = "admin" });
    try store.setEdgeProperty(loop_edge, "scope", .{ .String = "t1" });
    try store.setEdgeProperty(loop_edge, "weight", .{ .Int = 5 });

    // Parity assertions — engine-space PropertyValue (lowercase tags).
    // Resolve slot ids for both edges via the id_map, same as the real
    // per-property code path at graph_store.zig:3375.
    const aa = h.arena.allocator();
    const id_map = try store.getOrCreateIdMap("default");
    const batch_from_slot = id_map.nodeSlot(@as(u128, batch_from)) orelse return error.SlotMissing;
    const batch_edge_slot = id_map.edgeSlot(@as(u128, batch_edge)) orelse return error.SlotMissing;
    const loop_from_slot = id_map.nodeSlot(@as(u128, loop_from)) orelse return error.SlotMissing;
    const loop_edge_slot = id_map.edgeSlot(@as(u128, loop_edge)) orelse return error.SlotMissing;
    inline for (.{ "role", "scope" }) |key| {
        const b = try adapter.getEdgeProperty("default", batch_from_slot, batch_edge_slot, key, aa);
        const l = try adapter.getEdgeProperty("default", loop_from_slot, loop_edge_slot, key, aa);
        try testing.expect(b != null);
        try testing.expect(l != null);
        try testing.expectEqualStrings(l.?.string, b.?.string);
    }
    const b_w = try adapter.getEdgeProperty("default", batch_from_slot, batch_edge_slot, "weight", aa);
    const l_w = try adapter.getEdgeProperty("default", loop_from_slot, loop_edge_slot, "weight", aa);
    try testing.expect(b_w != null);
    try testing.expect(l_w != null);
    try testing.expectEqual(l_w.?.int, b_w.?.int);
}
