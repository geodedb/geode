// SONNY-6594 (6): a tenant scan that cannot read a row's tenant tag (or its
// body) fails; the row is never handed to the wrong tenant, nor dropped.
//
// With a bounded node cache, `getAllNodesForTenant` resolves an evicted
// node's tenant from the persisted `__tenant_id` property
// (`nodeMatchesTenant`) and took a read that FAILED for an absent tag, that
// is, for the default tenant: another tenant's nodes were listed as the
// default tenant's. `getAllEdgesForTenant` (and the typed edge scan) skipped
// an edge whose body could not be read: the edge silently left the tenant's
// listing (the DROP TENANT cascade's input among others).
//
// A real store with a data directory and bounded caches. The tag read is
// made to fail by wrapping the store's allocator (the one the engine
// property read copies the tag with) in a `FailingAllocator`; the edge body
// read with `BodyFault` (`sonny6594_body_fault.zig`).
//
// CANARY: REQ=REQ-SONNY-6594-TENANT-SCAN-READ-FAILURE; FEATURE="PerTenantIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_tenant_scan_read_failure.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;

const T = "t6594a";
const D = graph_store.DEFAULT_TENANT_ID;
const G = graph_store.DEFAULT_GRAPH_NAME;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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
    fault: BodyFault,

    fn init(self: *World) !void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "4", 1) != 0) return error.SetEnvFailed;
        if (setenv("GEODE_EDGE_CACHE_ENTRIES", "4", 1) != 0) return error.SetEnvFailed;
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        self.st = graph_store.getGlobalStore(testing.allocator);
        self.st.installNodeCacheHydrate();
        self.st.installEdgeCacheHydrate();
        self.fault.init(self.st);
        const labels = [_][]const u8{"N6594"};
        var prev: ?u64 = null;
        for (0..3) |_| {
            const id = try self.st.createNodeWithGraphAndTenant(&labels, G, T);
            if (prev) |p| _ = try self.st.createEdgeWithGraphAndTenant(p, id, "E6594", G, T);
            prev = id;
        }
        for (0..3) |_| _ = try self.st.createNodeWithGraphAndTenant(&labels, G, D);
    }

    fn deinit(self: *World) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        _ = unsetenv("GEODE_EDGE_CACHE_ENTRIES");
    }
};

test "SONNY-6594 (6): a node whose tenant tag cannot be read is never listed as the default tenant's" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const healthy = try w.st.getAllNodesForTenant(testing.allocator, D);
    defer testing.allocator.free(healthy);
    try w.fault.evictAll();

    var failing = std.testing.FailingAllocator.init(w.st.allocator, .{ .fail_index = 0 });
    const real = w.st.allocator;
    w.st.allocator = failing.allocator();
    const got = w.st.getAllNodesForTenant(testing.allocator, D);
    w.st.allocator = real;
    if (got) |ids| {
        defer testing.allocator.free(ids);
        std.debug.print("SONNY-6594 (6) default tenant's nodes, tags unreadable: {d} listed (healthy {d}; tag read failed: {})\n", .{ ids.len, healthy.len, failing.has_induced_failure });
        try testing.expectEqual(healthy.len, ids.len);
    } else |err| {
        std.debug.print("SONNY-6594 (6) default tenant's nodes, tags unreadable: failed {s}\n", .{@errorName(err)});
    }
}

test "SONNY-6594 (6): an edge whose body cannot be read is never dropped from its tenant's listing" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const healthy = try w.st.getAllEdgesForTenant(testing.allocator, T);
    defer testing.allocator.free(healthy);
    try testing.expectEqual(@as(usize, 2), healthy.len);
    try w.fault.evictAll();
    w.fault.on();
    const got = w.st.getAllEdgesForTenant(testing.allocator, T);
    const induced = w.fault.off();
    if (got) |ids| {
        defer testing.allocator.free(ids);
        std.debug.print("SONNY-6594 (6) tenant's edges, bodies unreadable: {d} listed (healthy {d}; body read failed: {})\n", .{ ids.len, healthy.len, induced });
        try testing.expectEqual(healthy.len, ids.len);
    } else |err| {
        std.debug.print("SONNY-6594 (6) tenant's edges, bodies unreadable: failed {s}\n", .{@errorName(err)});
    }
}
