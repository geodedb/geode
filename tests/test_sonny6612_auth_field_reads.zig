// SONNY-6612 (1): an auth check that cannot read a record's field reports
// the read error; it never takes the field for absent.
//
// The auth stores read record fields (`hmac`, `user_id`, `graph_name`, the
// user and role fields) with `GraphStore.getNodeProperty`, which returns
// null both for an absent property and for a record whose body could not be
// rebuilt: `verifyChain` then reported a record with "no HMAC" (tampering)
// for a read error, and the record loaders took defaults.
//
// A real store with a data directory, a real AuthGraphManager, and
// `BodyFault.ioErrorFrom(k)`: the k-th body rebuild on fails with an engine
// read error, for every k up to the first run that needs none. Each
// `verifyChain` either succeeds or fails with that read error, never with a
// tamper verdict.
//
// CANARY: REQ=REQ-SONNY-6612-AUTH-FIELD-READS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6612_auth_field_reads.zig; OWNER=security; UPDATED=2026-11-15

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

test "SONNY-6612 (1): verifyChain whose record field cannot be read reports the read error, never tampering" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.agm.verifyChain(&HMAC_KEY);
    var wrong: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        try w.fault.evictAll();
        w.fault.ioErrorFrom(k);
        const got = w.agm.verifyChain(&HMAC_KEY);
        const induced = w.fault.off();
        if (got) |_| {} else |err| if (err != error.InputOutput) {
            wrong += 1;
            std.debug.print("SONNY-6612 (1) verifyChain, rebuild {d} on failing: {s}\n", .{ k, @errorName(err) });
        }
        if (!induced) break;
    }
    std.debug.print("SONNY-6612 (1) verifyChain: {d} runs, {d} wrong verdicts\n", .{ k + 1, wrong });
    try testing.expectEqual(@as(usize, 0), wrong);
}
