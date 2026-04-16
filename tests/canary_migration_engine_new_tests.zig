const std = @import("std");
const migrate = @import("migration");

const ExecRecorder = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged([]const u8),

    fn init(alloc: std.mem.Allocator) ExecRecorder {
        return .{ .allocator = alloc, .calls = .{} };
    }

    fn deinit(self: *ExecRecorder) void {
        for (self.calls.items) |c| self.allocator.free(c);
        self.calls.deinit(self.allocator);
    }

    fn exec(ctx_ptr: ?*anyopaque, script: []const u8) !void {
        const self: *ExecRecorder = @ptrCast(@alignCast(ctx_ptr.?));
        const copy = try self.allocator.dupe(u8, script);
        try self.calls.append(self.allocator, copy);
    }

    fn executor(self: *ExecRecorder) migrate.QueryExecutor {
        return .{ .context = self, .execFn = ExecRecorder.exec };
    }
};

fn writeMigration(dir: std.fs.Dir, name: []const u8, body: []const u8) !void {
    var file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
}

fn tmpDirPath(alloc: std.mem.Allocator, tmp: anytype) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "TestCANARY_REQ_GQL_087_ObservabilityMetrics" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(alloc, tmp);
    defer alloc.free(dir_path);

    try writeMigration(tmp.dir, "002_more.gql", "RETURN 1");

    var exec_recorder = ExecRecorder.init(alloc);
    defer exec_recorder.deinit();
    const cfg = migrate.MigrationConfig{ .migrations_dir = dir_path };

    const m0 = try migrate.metricsSnapshot(alloc, cfg);
    try migrate.applyUpMigrations(alloc, cfg, &.{"002_more.gql"}, exec_recorder.executor());
    const m1 = try migrate.metricsSnapshot(alloc, cfg);
    try std.testing.expect(m1.applied_total >= m0.applied_total + 1);
}

test "TestCANARY_REQ_GQL_087_CliParityStatusCommand" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(alloc, tmp);
    defer alloc.free(dir_path);
    const cfg = migrate.MigrationConfig{ .migrations_dir = dir_path };

    // Create the migration file before applying
    try writeMigration(tmp.dir, "002_status.gql", "RETURN 'status test'");

    var exec_recorder = ExecRecorder.init(alloc);
    defer exec_recorder.deinit();
    try migrate.applyUpMigrations(alloc, cfg, &.{"002_status.gql"}, exec_recorder.executor());

    const rows = try migrate.statusReport(alloc, cfg);
    defer migrate.freeStatusRows(alloc, rows);
    try std.testing.expect(rows.len >= 1);

    const plan = try migrate.planDryRun(alloc, cfg, &.{});
    defer migrate.freePlan(alloc, &plan);
    try std.testing.expectEqual(@as(usize, 0), plan.up.len);
}
