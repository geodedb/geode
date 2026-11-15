// SONNY-6594 (5): an auth decision that cannot read a security record
// reports the read failure; it never answers as if the record were absent.
//
// The auth store read its records' bodies with the hydrated getters and took
// a body that could not be READ (an engine read error, out of memory while
// rebuilding an evicted body) for an absent one:
//   - `canUserAccessGraph` skipped the grant and answered "no access": a
//     silent deny an operator cannot tell from a missing grant;
//   - `verifyChain` read the chain root as missing and failed with
//     `MissingChainRoot`, the "POSSIBLE TAMPERING" alarm, for a read error;
//   - loading the auth store at start skipped the user, which then did not
//     exist for the rest of the run.
// Each stays fail closed (no access is granted, no chain is accepted) and
// now fails with the read's own error.
//
// A real store with a data directory, a real AuthGraphManager, and
// `BodyFault` (the caches' body rebuilds fail on demand;
// `sonny6594_body_fault.zig`).
//
// CANARY: REQ=REQ-SONNY-6594-AUTH-READ-FAILURE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_auth_read_failure.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth_graph_manager = @import("auth_graph_manager");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const user_mgmt = geode.user_management;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

const HMAC_KEY = [_]u8{0x94} ** 32;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const World = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    st: *graph_store.GraphStore,
    agm: AuthGraphManager,
    auth_was: bool,
    fault: BodyFault,

    fn init(self: *World) !void {
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        self.st = graph_store.getGlobalStore(testing.allocator);
        self.st.installNodeCacheHydrate();
        self.st.installEdgeCacheHydrate();
        self.agm = try AuthGraphManager.init(testing.allocator, self.st);
        const ida = try self.agm.createUser(&HMAC_KEY, "ida6594", "ida@example.com", "not_a_real_hash", false);
        try self.agm.grantUserGraphPermission(&HMAC_KEY, ida, "g6594", 1);
        self.fault.init(self.st);
    }

    fn deinit(self: *World) void {
        self.agm.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        user_mgmt.setAuthEnabled(self.auth_was);
    }
};

/// `canUserAccessGraph`, whether it answers a bool or an error union.
fn canAccess(agm: *AuthGraphManager, user: []const u8, graph: []const u8) anyerror!bool {
    const R = @typeInfo(@TypeOf(AuthGraphManager.canUserAccessGraph)).@"fn".return_type.?;
    if (@typeInfo(R) == .error_union) return try agm.canUserAccessGraph(user, graph);
    return agm.canUserAccessGraph(user, graph);
}

test "SONNY-6594 (5): canUserAccessGraph with an unreadable grant fails with the read's error, never a silent deny" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try testing.expect(try canAccess(&w.agm, "ida6594", "g6594"));
    try w.fault.evictAll();
    w.fault.on();
    const got = canAccess(&w.agm, "ida6594", "g6594");
    const induced = w.fault.off();
    std.debug.print("SONNY-6594 (5) canUserAccessGraph, grant unreadable: {any} (body read failed: {})\n", .{ got, induced });
    try testing.expect(induced);
    // Fail closed either way; the defect is answering "no grant".
    try testing.expectError(error.OutOfMemory, got);
}

test "SONNY-6594 (5): verifyChain with an unreadable chain root reports the read error, not MissingChainRoot (tampering)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.agm.verifyChain(&HMAC_KEY);
    try w.fault.evictAll();
    w.fault.on();
    const got = w.agm.verifyChain(&HMAC_KEY);
    const induced = w.fault.off();
    std.debug.print("SONNY-6594 (5) verifyChain, chain root unreadable: {any} (body read failed: {})\n", .{ got, induced });
    try testing.expect(induced);
    try testing.expectError(error.OutOfMemory, got);
}

test "SONNY-6594 (5): loading the auth store with an unreadable user fails, never loads without the user" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.fault.evictAll();
    w.fault.on();
    var second = AuthGraphManager.init(testing.allocator, w.st);
    const induced = w.fault.off();
    if (second) |*agm| {
        defer agm.deinit();
        const found = agm.storage.getUserByUsername("ida6594") != null;
        std.debug.print("SONNY-6594 (5) auth store load, user unreadable: loaded, ida6594 {s} (body read failed: {})\n", .{ if (found) "present" else "MISSING", induced });
        try testing.expect(found);
    } else |err| {
        std.debug.print("SONNY-6594 (5) auth store load, user unreadable: failed {s} (body read failed: {})\n", .{ @errorName(err), induced });
    }
}
