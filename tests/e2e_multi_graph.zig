const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const execution = geode.execution;
const graph_store = geode.graph_store;

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
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
        var session = execution.SessionState.init(allocator);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .session = session,
            .ctx = execution.ExecutionContext{
                .catalog = catalog,
                .session_state = &session,
            },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

test "E2E: CREATE GRAPH and USE GRAPH" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.exec("CREATE GRAPH social_network");
    res.deinit(allocator);
    res = try h.exec("CREATE GRAPH analytics");
    res.deinit(allocator);

    res = try h.exec("USE GRAPH social_network");
    res.deinit(allocator);

    try testing.expect(h.session.graph != null);
    try testing.expectEqualStrings("social_network", h.session.graph.?);

    const store = graph_store.getGlobalStore(allocator);
    try testing.expect(store.graphExists("social_network"));
    try testing.expect(store.graphExists("analytics"));
}

test "E2E: DROP GRAPH removes catalog and store entries" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.exec("CREATE GRAPH temp_graph_1");
    res.deinit(allocator);
    res = try h.exec("CREATE GRAPH temp_graph_2");
    res.deinit(allocator);

    res = try h.exec("DROP GRAPH temp_graph_1");
    res.deinit(allocator);

    const store = graph_store.getGlobalStore(allocator);
    try testing.expect(!store.graphExists("temp_graph_1"));
    try testing.expect(store.graphExists("temp_graph_2"));
    try testing.expect(!h.ctx.catalog.hasGraph("temp_graph_1"));
}

test "E2E: USE GRAPH fails for missing graph" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const result = h.exec("USE GRAPH missing_graph");
    try testing.expectError(error.GraphNotFound, result);
}

test "E2E: SHOW GRAPHS reflects catalog state" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.exec("CREATE GRAPH customers");
    res.deinit(allocator);
    res = try h.exec("CREATE GRAPH products");
    res.deinit(allocator);
    res = try h.exec("CREATE GRAPH orders");
    res.deinit(allocator);

    const graphs = try h.ctx.catalog.listGraphs(allocator);
    defer {
        for (graphs) |name| allocator.free(name);
        allocator.free(graphs);
    }

    try testing.expectEqual(@as(usize, 3), graphs.len);
}
