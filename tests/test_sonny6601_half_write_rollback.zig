// SONNY-6601 (1): a node property write that fails half done (its property
// chain written in the transaction, the node record not) inside a
// statement's engine transaction does not commit.
//
// The failure is injected with the adapter's test-only seam
// (`property_write_midpoint_hook`), between `putPropertyTxn` and
// `putNodeTxn`: a real failure of the write at that point, not a mock of it.
// It fails the 16th of 32 property writes of one `SET`, on whichever shard
// that node lives (the statement's own engine transaction, or a write of its
// own on another shard). The statement fails; geode's statement undo and the
// engine's abort must leave every node at its old value: in memory, and on
// disk after the store is closed and reopened. Run as an auto-commit
// statement and inside an explicit transaction, which then commits a change
// of its own.
//
// CANARY: REQ=REQ-SONNY-6601-HALF-WRITE-SEAM; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6601_half_write_rollback.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;
const gsa = geode.graph_storage_adapter;

const G = "g6601hw";
const N: usize = 32;
const FAIL_AT: usize = 16;

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

var hook_calls: usize = 0;
var hook_fail_at: ?usize = null;
var hook_fired: bool = false;

fn midpointHook() gsa.PropertyWriteFault!void {
    hook_calls += 1;
    if (hook_fail_at) |k| {
        if (hook_calls == k) {
            hook_fired = true;
            return error.PropertyWriteFaultInjected;
        }
    }
}

const Outcome = union(enum) { count: i64, failed: anyerror };

fn ask(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) Outcome {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return .{ .failed = err };
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return .{ .failed = err };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    if (result.rows.len == 1 and result.rows[0].len == 1) switch (result.rows[0][0]) {
        .Int => |v| return .{ .count = v },
        else => {},
    };
    return .{ .count = -1 };
}

fn run(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !void {
    switch (ask(allocator, session, q)) {
        .count => {},
        .failed => |err| {
            std.debug.print("SONNY-6601 (1) '{s}' failed: {s}\n", .{ q, @errorName(err) });
            return err;
        },
    }
}

fn count(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !i64 {
    return switch (ask(allocator, session, q)) {
        .count => |c| c,
        .failed => |err| {
            std.debug.print("SONNY-6601 (1) '{s}' failed: {s}\n", .{ q, @errorName(err) });
            return err;
        },
    };
}

/// Every node still holds p = 0; `keep` nodes of the committed change.
fn expectState(allocator: std.mem.Allocator, session: *execution.SessionState, keep: i64, when: []const u8) !void {
    const set = try count(allocator, session, "USE GRAPH " ++ G ++ "; MATCH (n:H6601) WHERE n.p = 1 RETURN count(n) AS c");
    const old = try count(allocator, session, "USE GRAPH " ++ G ++ "; MATCH (n:H6601) WHERE n.p = 0 RETURN count(n) AS c");
    const kept = try count(allocator, session, "USE GRAPH " ++ G ++ "; MATCH (n:Keep6601) RETURN count(n) AS c");
    if (set != 0 or old != N or kept != keep) {
        std.debug.print("SONNY-6601 (1) {s}: {d} node(s) with the failed SET's value (want 0), {d} with the old value (want {d}), {d} committed node(s) (want {d})\n", .{ when, set, old, N, kept, keep });
        return error.HalfWriteCommitted;
    }
}

test "SONNY-6601 (1): a property write failing half done inside a statement transaction does not commit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    gsa.property_write_midpoint_hook = midpointHook;
    defer gsa.property_write_midpoint_hook = null;

    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        try store.createGraph(G);
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(allocator);
        try s.appendSlice(allocator, "USE GRAPH " ++ G ++ "; CREATE ");
        for (0..N) |i| {
            if (i > 0) try s.appendSlice(allocator, ", ");
            try s.print(allocator, "(:H6601 {{k: {d}, p: 0}})", .{i});
        }
        try run(allocator, &session, s.items);
        try expectState(allocator, &session, 0, "seeded");

        // An auto-commit statement.
        hook_calls = 0;
        hook_fired = false;
        hook_fail_at = FAIL_AT;
        const r1 = ask(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:H6601) SET n.p = 1");
        hook_fail_at = null;
        try std.testing.expect(hook_fired);
        try std.testing.expect(r1 == .failed);
        try expectState(allocator, &session, 0, "after the failed auto-commit SET");

        // Inside an explicit transaction, which then commits a change.
        try run(allocator, &session, "USE GRAPH " ++ G ++ "; START TRANSACTION");
        hook_calls = 0;
        hook_fired = false;
        hook_fail_at = FAIL_AT;
        const r2 = ask(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:H6601) SET n.p = 1");
        hook_fail_at = null;
        try std.testing.expect(hook_fired);
        try std.testing.expect(r2 == .failed);
        try run(allocator, &session, "USE GRAPH " ++ G ++ "; CREATE (:Keep6601)");
        try run(allocator, &session, "COMMIT");
        try expectState(allocator, &session, 1, "after the transaction committed");
    }

    // On disk: reopened, the half-done writes are not there.
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        try expectState(allocator, &session, 1, "after a reopen");
    }
}
