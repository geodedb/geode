// SONNY-6528 (3): a create with a given node id (a Raft apply, a replayed
// committed entry) of a node that already exists is refused
// (NodeAlreadyExists), whether or not the node is resident in the node cache.
//
// `GraphStore.createNodeWithIdInternal` decided whether the id existed by
// asking the node cache (`nodes.contains`), and the cache is bounded
// (GEODE_NODE_CACHE_ENTRIES): an evicted node, or one a restart had not read
// back yet, was not found, and the create made a second engine record with
// the same public id. The replicated-create apply relies on that refusal to
// make a re-applied committed entry a no-op
// (`cluster_replication.applyNodeCreatePayload`).
//
// The case is built with a real store: a 16-entry node cache, 200 nodes
// applied from GNC1 payloads, and the same payloads applied again, once on
// the live store (most nodes evicted) and once after a clean restart (the
// replay a restarted cluster member does). The label count, the unlabeled
// count and the engine's live records must stay at 200 throughout.
//
// CANARY: REQ=REQ-SONNY-6528-EVICTED-NODE-CREATE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6528_evicted_node_create.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;
const cluster_replication = geode.distributed.cluster_replication;

const NODES: usize = 200;
const FIRST_INDEX: u64 = 1000;
const CACHE_CAP = "16";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn queryCount(allocator: std.mem.Allocator, q: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = try geode.parseGql(q, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog });
    defer result.deinit(allocator);
    if (result.rows.len != 1 or result.rows[0].len != 1) return error.UnexpectedRows;
    return switch (result.rows[0][0]) {
        .Int => |v| v,
        else => error.UnexpectedValue,
    };
}

/// Apply the NODES committed creates, one GNC1 payload each at raft index
/// FIRST_INDEX + i (the node id). Returns how many created a node (the
/// others found it and were no-ops).
fn applyAll(allocator: std.mem.Allocator, store: *graph_store.GraphStore) !usize {
    const labels = [_][]const u8{"R6528"};
    var created: usize = 0;
    for (0..NODES) |i| {
        const props = [_]cluster_replication.Prop{.{ .key = "i", .value = .{ .Int = @intCast(i) } }};
        const payload = try cluster_replication.serializeNodeCreate(allocator, "default", &labels, &props);
        defer allocator.free(payload);
        const before = store.countNodesByLabel("default", "R6528", null);
        _ = try cluster_replication.applyNodeCreatePayload(allocator, store, payload, FIRST_INDEX + i);
        if (store.countNodesByLabel("default", "R6528", null) != before) created += 1;
    }
    return created;
}

const Counts = struct { label: usize, unlabeled: i64, records: usize };

fn counts(allocator: std.mem.Allocator, store: *graph_store.GraphStore) !Counts {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const entries = try adapter.scanAllNodes("default", allocator);
    defer allocator.free(entries);
    return .{
        .label = store.countNodesByLabel("default", "R6528", null),
        .unlabeled = try queryCount(allocator, "MATCH (n) RETURN count(n) AS c"),
        .records = entries.len,
    };
}

fn check(what: []const u8, c: Counts, failures: *usize) void {
    std.debug.print("SONNY-6528 (3) {s}: label count {d}, count(n) {d}, engine records {d}; want {d}\n", .{ what, c.label, c.unlabeled, c.records, NODES });
    if (c.label != NODES or c.unlabeled != @as(i64, @intCast(NODES)) or c.records != NODES) failures.* += 1;
}

test "SONNY-6528 (3): re-applying a committed create of an evicted node does not create it twice" {
    const allocator = std.testing.allocator;
    if (setenv("GEODE_NODE_CACHE_ENTRIES", CACHE_CAP, 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var failures: usize = 0;
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        const first = try applyAll(allocator, store);
        try std.testing.expectEqual(NODES, first);
        // The cache holds at most a few of them: the first ids were evicted.
        var resident: usize = 0;
        for (0..NODES) |i| {
            if (store.nodes.contains(FIRST_INDEX + i)) resident += 1;
        }
        std.debug.print("SONNY-6528 (3) {d} of {d} nodes resident in the node cache\n", .{ resident, NODES });
        try std.testing.expect(resident < NODES);

        const again = try applyAll(allocator, store);
        if (again != 0) {
            std.debug.print("SONNY-6528 (3) the live replay created {d} node(s) again\n", .{again});
            failures += 1;
        }
        check("after the live replay", try counts(allocator, store), &failures);
    }

    // A clean restart, then the replay a restarted cluster member does.
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        const again = try applyAll(allocator, store);
        if (again != 0) {
            std.debug.print("SONNY-6528 (3) the replay after the restart created {d} node(s) again\n", .{again});
            failures += 1;
        }
        check("after the replay after the restart", try counts(allocator, store), &failures);
    }
    if (failures > 0) return error.EvictedNodeCreatedTwice;
}
