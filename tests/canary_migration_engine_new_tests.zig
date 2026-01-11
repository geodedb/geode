const std = @import("std");
const migrate = @import("/home/benji/src/gl/devnw/geode/geode/src/migration/mod.zig");

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
        const self = @as(*ExecRecorder, @ptrCast(@alignCast(ctx_ptr.?)));
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

test "TestCANARY_REQ_GQL_087_ObservabilityMetrics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMigration(tmp.dir, "002_more.gql", "RETURN 1");

    var exec = ExecRecorder.init(alloc);
    defer exec.deinit();
    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };

    const m0 = try migrate.metricsSnapshot(&alloc, cfg);
    try migrate.applyUpMigrations(&alloc, cfg, &.{ "002_more.gql" }, exec.executor());
    const m1 = try migrate.metricsSnapshot(&alloc, cfg);
    try std.testing.expect(m1.applied_total >= m0.applied_total);
}

test "TestCANARY_REQ_GQL_087_CliParityStatusCommand" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };

    var exec = ExecRecorder.init(alloc);
    defer exec.deinit();
    try migrate.applyUpMigrations(&alloc, cfg, &.{ "002_status.gql" }, exec.executor());

    const before = try migrate.statusReport(&alloc, cfg);
    defer migrate.freeStatusRows(alloc, before);
    try std.testing.expect(before.len >= 2);

    const plan = try migrate.planDryRun(&alloc, cfg, &.{});
    defer {
        alloc.free(plan.up);
        alloc.free(plan.down);
    }
    try std.testing.expect(plan.up.len == 0);
}
