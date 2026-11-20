// SONNY-6708, end to end: a real `geode serve` started on a data directory
// whose first start was interrupted before it sealed the auth chain must start
// (as a first boot) and let the seeded admin log in; it used to exit 1 with
// AUTH TAMPER DETECTED / MissingChainRoot / AuthChainTampered, on every start,
// forever.
//
// The artifact is made the way a crash makes it: a real server completes a
// first boot (its own HMAC key, admin, role, sealed chain) and is stopped; the
// data directory is then opened in process and the AuthChainRoot node - the last
// thing the first boot writes - is deleted, which is exactly the on-disk state
// of a first start killed one step before its seal. The in-process variant of
// this contract, with the guard cases (a missing root over real auth state stays
// the tamper verdict), is tests/test_sonny6708_interrupted_first_boot.zig.
//
// CANARY: REQ=REQ-SONNY-6708-INTERRUPTED-FIRST-BOOT; FEATURE="AuthGraphManager Bootstrap"; ASPECT=RealServerRecoversInterruptedFirstBoot; STATUS=TESTED; TEST=tests/test_sonny6708_real_server_restart.zig; OWNER=security; UPDATED=2026-11-17

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;

fn startServer(allocator: std.mem.Allocator, data_dir: []const u8, ready_ms: u64) !struct { handle: proto_util.ServerHandle, addr: []u8 } {
    const addr = try proto_util.formatAddr(allocator, try proto_util.getRandomPort());
    errdefer allocator.free(addr);
    var handle = try proto_util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_LSP_PORT=0"});
    errdefer handle.deinit();
    try proto_util.waitForServerReady(allocator, addr, ready_ms);
    return .{ .handle = handle, .addr = addr };
}

test "SONNY-6708: a real server starts on a data directory whose first start was interrupted before the seal, and the admin logs in" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try scratch.ScratchDir.create("sonny6708-real");
    defer root.remove();
    const data_dir = try std.fs.path.join(allocator, &.{ root.path(), "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir);

    // 1. A real first boot, completed, then stopped.
    {
        var first = try startServer(allocator, data_dir, 90_000);
        defer {
            first.handle.deinit();
            allocator.free(first.addr);
        }
        var c = try proto_util.QuicProtoClient.connect(allocator, first.addr);
        defer c.deinit();
        var h = try c.hello(allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }

    // 2. The crash artifact: the last thing the first boot wrote is gone.
    {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        const roots = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, "AuthChainRoot") orelse return error.NoChainRoot;
        const owned = try allocator.dupe(u64, roots);
        defer allocator.free(owned);
        try testing.expect(owned.len > 0);
        for (owned) |id| store.deleteNode(id);
    }

    // 3. The next start. PRE-FIX it exits with AuthChainTampered and never
    //    listens (the readiness wait times out).
    var second = try startServer(allocator, data_dir, 60_000);
    defer {
        second.handle.deinit();
        allocator.free(second.addr);
    }
    var c = try proto_util.QuicProtoClient.connect(allocator, second.addr);
    defer c.deinit();
    var h = try c.hello(allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) std.debug.print("SONNY-6708: HELLO after the recovered first boot failed: {s}\n", .{h.error_message});
    try testing.expect(h.success);
    var r = try c.executeAndCollect(allocator, "RETURN 6708 AS recovered", proto_util.emptyParams(), 10);
    defer r.deinit(allocator);
    try testing.expect(r.error_code == null);
}
