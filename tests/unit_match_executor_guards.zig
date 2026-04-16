const std = @import("std");
const geode = @import("geode");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const execution = geode.execution;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=FrontierAndResultGuardTrips; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-24

const Harness = struct {
    allocator: std.mem.Allocator,
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
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

fn seedStarGraph(allocator: std.mem.Allocator, fanout: usize) !void {
    const store = graph_store.getGlobalStore(allocator);
    const center = try store.createNode(&.{});
    var i: usize = 0;
    while (i < fanout) : (i += 1) {
        const nid = try store.createNode(&.{});
        _ = try store.createEdge(center, nid, "KNOWS");
    }
}

fn hasFlag(flags: std.ArrayList([]const u8), name: []const u8) bool {
    for (flags.items) |flag| {
        if (std.mem.eql(u8, flag, name)) return true;
    }
    return false;
}

// Force frontier guard by setting max_frontier extremely low
test "TestCANARY_REQ_GQL_017_MatchGuardTrips frontier" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedStarGraph(allocator, 5);

    const query_txt = "MATCH (a)-[:KNOWS*1..2]->(b) RETURN a, b";
    var parsed = try geode.parseGql(query_txt, allocator);
    defer parsed.deinit();

    var ctx = h.ctx;
    ctx.match_max_frontier = 2;
    ctx.match_max_results = 100;

    var res = try execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
    defer res.deinit(allocator);

    try std.testing.expect(hasFlag(res.flags, "ExecutionGuardTrip"));
    try std.testing.expect(res.rows.len <= 2);
}

// Force result guard by setting max_results extremely low
test "TestCANARY_REQ_GQL_017_MatchGuardTrips results" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedStarGraph(allocator, 20);

    const query_txt = "MATCH (a)-[:KNOWS]->(b) RETURN a, b";
    var parsed = try geode.parseGql(query_txt, allocator);
    defer parsed.deinit();

    var ctx = h.ctx;
    ctx.match_max_frontier = 1_000;
    ctx.match_max_results = 3;

    var res = try execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
    defer res.deinit(allocator);

    try std.testing.expect(hasFlag(res.flags, "ExecutionGuardTrip"));
    try std.testing.expect(res.rows.len <= 3);
}
