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

test "TestCANARY_REQ_GQL_087_MigrationLedgerSchema_and_Apply" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMigration(tmp.dir, "002_create_person.gql", "CREATE (:Person {name: 'Alice'})");
    try writeMigration(tmp.dir, "003_add_index.gql", "CREATE INDEX IF NOT EXISTS person_name_idx ON :Person(name)");

    var exec = ExecRecorder.init(alloc);
    defer exec.deinit();

    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };
    try migrate.applyUpMigrations(&alloc, cfg, &.{ "002_create_person.gql", "003_add_index.gql" }, exec.executor());

    const rows = try migrate.statusReport(&alloc, cfg);
    defer migrate.freeStatusRows(alloc, rows);
    try std.testing.expect(rows.len == 3); // seed + 2 applied
    try std.testing.expect(exec.calls.items.len == 2);
}

test "TestCANARY_REQ_GQL_087_DownReversalSafety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMigration(tmp.dir, "002_create_person.gql", "CREATE (:Person {name: 'Bob'})");
    try writeMigration(tmp.dir, "002_create_person.gql.down.gql", "MATCH (n:Person {name: 'Bob'}) DETACH DELETE n");

    var exec = ExecRecorder.init(alloc);
    defer exec.deinit();
    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };

    try migrate.applyUpMigrations(&alloc, cfg, &.{ "002_create_person.gql" }, exec.executor());
    try migrate.applyDownMigrations(&alloc, cfg, &.{}, exec.executor());

    const rows = try migrate.statusReport(&alloc, cfg);
    defer migrate.freeStatusRows(alloc, rows);
    var applied_gt1: usize = 0;
    for (rows) |r| {
        if (r.applied and r.version > 1) applied_gt1 += 1;
    }
    try std.testing.expect(applied_gt1 == 0);
    try std.testing.expect(exec.calls.items.len == 2); // up + down executed
}

test "TestCANARY_REQ_GQL_087_ChecksumValidation_and_PlanDryRun" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMigration(tmp.dir, "002_second.gql", "RETURN 1");

    var exec = ExecRecorder.init(alloc);
    defer exec.deinit();
    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };
    try migrate.applyUpMigrations(&alloc, cfg, &.{ "002_second.gql" }, exec.executor());

    const rows = try migrate.statusReport(&alloc, cfg);
    defer migrate.freeStatusRows(alloc, rows);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    for (rows) |r| {
        if (!r.applied) continue;
        try w.print("{d} {s}\n", .{ r.version, r.checksum_prefix });
    }
    const manifest = fbs.getWritten();
    const ok = try migrate.checksumValidate(&alloc, cfg, manifest);
    try std.testing.expect(ok);

    const plan = try migrate.planDryRun(&alloc, cfg, &.{ "003_third.gql" });
    defer {
        alloc.free(plan.up);
        alloc.free(plan.down);
    }
    try std.testing.expect(plan.up.len == 1);
    try std.testing.expect(std.mem.eql(u8, plan.up[0], "003_third.gql"));
}

test "TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cfg = migrate.MigrationConfig{ .migrations_dir = tmp.path };

    try migrate.enforcePolicy("STRICT");
    const before = try migrate.driftCheck(&alloc, cfg);
    try std.testing.expect(before);
    migrate.testSimulateDrift();
    const after = try migrate.driftCheck(&alloc, cfg);
    try std.testing.expect(!after);
    try migrate.enforcePolicy("LENIENT");
}

test "TestCANARY_REQ_GQL_087_LockAcquisitionTTLHeartbeat" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();
    var lh = try migrate.acquireLock(&alloc, 200);
    try std.testing.expectError(error.AlreadyLocked, migrate.acquireLock(&alloc, 200));
    try migrate.heartbeatLock(&lh);
    std.Thread.sleep(300 * std.time.ns_per_ms);
    var lh2 = try migrate.acquireLock(&alloc, 200);
    try migrate.releaseLock(&lh2);
    try std.testing.expectError(error.NoLockHeld, migrate.releaseLock(&lh2));
}

test "TestCANARY_REQ_GQL_087_ResumeTokenDataMigration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();
    const token = "resumetoken";
    var last_state = try migrate.resumeDataMigration(&alloc, token);
    try std.testing.expect(!last_state.done);
    const total = last_state.total_batches;
    var i: usize = 1;
    while (i < total) : (i += 1) {
        last_state = try migrate.resumeDataMigration(&alloc, token);
    }
    try std.testing.expect(last_state.done);
}
