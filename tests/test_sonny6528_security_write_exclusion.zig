// SONNY-6528 (2): writes to the `__geode_security` graph exclude each other
// and the graph's checkpoint.
//
// The security graph is written through `UserStorageBackend`
// (src/storage/user_storage.zig): user, role, permission, policy, grant and
// FLE role grant records, and the HMAC chain root. Those writes took no lock
// of the graph's. The auth and policy DDL hold `auth_ddl_lock`, but the
// login-state write after a failed login (`updateUserLoginState`, which
// rewrites the user's record and reseals the chain root) does not, so it ran
// beside a CREATE USER or CREATE ROLE on another connection: two engine
// writers on the security graph's shards at once (`GraphEngine.allocNode`
// and the page writes are not synchronized). A checkpoint of the graph
// (rwlock EXCLUSIVE, which drains every other writer) did not wait for them
// either.
//
// The interleavings are forced: a role record's node create stops right
// after the engine counted the node and before its record is written
// (`node_slot_allocated_hook`), starts the other party on another thread,
// and waits up to 15 s for it. The other party is a permission record
// create (another entity type) in the first test and a full checkpoint
// (`checkpointAll`, which waits for each graph's lock without a deadline)
// in the second. It must not complete inside that window, and must
// complete once the role record is written.
//
// CANARY: REQ=REQ-SONNY-6528-SECURITY-WRITE-EXCLUSION; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6528_security_write_exclusion.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");
const user_storage = @import("user_storage");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

/// The checkpoint's whole run (it completes in about 2 s on a loaded host)
/// must fit in the window when nothing excludes it.
const WINDOW_MS: u64 = 15_000;

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

const Other = enum { permission_create, checkpoint };

const Race = struct {
    var armed = std.atomic.Value(bool).init(false);
    var go = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var done_in_window = std.atomic.Value(bool).init(false);
    var other_failed = std.atomic.Value(bool).init(false);
    var writer_thread: std.Thread.Id = 0;
    var backend: ?*user_storage.UserStorageBackend = null;

    fn reset() void {
        armed.store(false, .release);
        go.store(false, .release);
        done.store(false, .release);
        done_in_window.store(false, .release);
        other_failed.store(false, .release);
    }

    fn hook(mg: *gsa.ManagedGraph) void {
        if (!std.mem.eql(u8, mg.name, graph_store.SECURITY_GRAPH_NAME)) return;
        if (std.Thread.getCurrentId() != writer_thread) return;
        if (!armed.swap(false, .acq_rel)) return;
        go.store(true, .release);
        const start = std.Io.Clock.awake.now(io()).nanoseconds;
        while (!done.load(.acquire) and std.Io.Clock.awake.now(io()).nanoseconds - start < WINDOW_MS * std.time.ns_per_ms) {
            io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
        done_in_window.store(done.load(.acquire), .release);
    }

    fn other(which: Other) void {
        while (!go.load(.acquire)) io().sleep(.fromMilliseconds(1), .awake) catch {};
        switch (which) {
            .permission_create => backend.?.persistPermission(9_100, "p6528", "graph:default", 1, null) catch other_failed.store(true, .release),
            .checkpoint => if (graph_store.getGlobalAdapter()) |adapter| {
                adapter.checkpointAll() catch other_failed.store(true, .release);
            } else other_failed.store(true, .release),
        }
        done.store(true, .release);
    }
};

fn runCase(which: Other) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    var backend = try user_storage.UserStorageBackend.init(allocator, store);
    defer backend.deinit();
    // Records first, so the graph and its shards exist.
    try backend.persistRole(9_001, "r6528a", "seed", 0, 1, false);
    try backend.persistPermission(9_002, "p6528a", "graph:default", 1, null);

    Race.reset();
    Race.backend = &backend;
    defer Race.backend = null;
    Race.writer_thread = std.Thread.getCurrentId();
    Race.armed.store(true, .release);
    gsa.node_slot_allocated_hook = Race.hook;
    defer gsa.node_slot_allocated_hook = null;
    const t = try std.Thread.spawn(.{}, Race.other, .{which});
    try backend.persistRole(9_003, "r6528b", "raced", 0, 1, false);
    t.join();

    std.debug.print("SONNY-6528 (2) {s}: completed inside the role record's create: {}; failed: {}\n", .{ @tagName(which), Race.done_in_window.load(.acquire), Race.other_failed.load(.acquire) });
    try std.testing.expect(Race.go.load(.acquire)); // the hook ran
    try std.testing.expect(Race.done.load(.acquire));
    try std.testing.expect(!Race.other_failed.load(.acquire));
    try std.testing.expect(backend.getRole(9_003) != null);
    if (which == .permission_create) try std.testing.expect(backend.getPermission(9_100) != null);
    if (Race.done_in_window.load(.acquire)) return error.SecurityGraphWriteNotExcluded;
}

test "SONNY-6528 (2): a security-graph record create of another entity type waits for one in flight" {
    try runCase(.permission_create);
}

test "SONNY-6528 (2): a checkpoint of the security graph waits for a record create in flight" {
    try runCase(.checkpoint);
}
