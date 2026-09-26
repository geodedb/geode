// SONNY-2809: a second identical CREATE CONSTRAINT freed the catalog key
// twice.
//
// catalog.addConstraint freed its scoped key explicitly on the duplicate
// path and again in the errdefer, so any user allowed to run DDL could corrupt
// the allocator and abort the server (a segfault in a ReleaseSafe build) with
// the same statement run twice. GAP-0903 fixed the same bug in addIndex. The
// duplicate branch of the executor also returned a result whose one column
// and one row were uninitialized memory. A duplicate name is now refused with
// ConstraintAlreadyExists (42710), and IF NOT EXISTS is a no-op.
//
// The catalog here is allocated with the testing allocator, which reports a
// double free or a leak.
//
// CANARY: REQ=REQ-SONNY-2809-DUPLICATE-CONSTRAINT; FEATURE="ConstraintManagement"; ASPECT=DuplicateNameSingleFree; STATUS=TESTED; TEST=tests/test_sonny2809_duplicate_constraint.zig; OWNER=schema; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const catalog_mod = geode.catalog;

/// A session over a private catalog directory, in memory or persisted.
const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(persisted: bool) !Session {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        // The catalog lives in the temporary directory in both modes (with no
        // data directory it persists in /tmp, shared by every run).
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        if (!persisted) graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        try testing.expectEqual(@as(usize, 0), r.columns.len);
        try testing.expectEqual(@as(usize, 0), r.rows.len);
        r.deinit(self.arena.allocator());
    }
};

fn checkDuplicates(persisted: bool) !void {
    harness.silenceEngineLogs();
    var s = try Session.init(persisted);
    defer s.deinit();
    const create = "CREATE CONSTRAINT u_id FOR (n:Acct) REQUIRE n.id IS UNIQUE";
    try s.exec(create);
    // The same statement again: refused, with the key freed once.
    try testing.expectError(error.ConstraintAlreadyExists, s.run(create));
    try testing.expectError(error.ConstraintAlreadyExists, s.run(create));
    try s.exec("CREATE CONSTRAINT IF NOT EXISTS u_id FOR (n:Acct) REQUIRE n.id IS UNIQUE");
    try s.exec("CREATE CONSTRAINT u_email FOR (n:Acct) REQUIRE n.email IS UNIQUE");
    try testing.expectError(error.ConstraintAlreadyExists, s.run("CREATE CONSTRAINT u_email FOR (n:Acct) REQUIRE n.email IS UNIQUE"));
    // Both constraints are still in the catalog, each once.
    try testing.expectEqual(@as(u32, 2), s.ctx.catalog.constraints.count());
    try testing.expect((try s.ctx.catalog.getConstraint("Acct", "u_id")) != null);
    try testing.expect((try s.ctx.catalog.getConstraint("Acct", "u_email")) != null);
}

test "SONNY-2809: a duplicate CREATE CONSTRAINT is refused, in memory" {
    try checkDuplicates(false);
}

test "SONNY-2809: a duplicate CREATE CONSTRAINT is refused, persisted" {
    try checkDuplicates(true);
}

test "SONNY-2809: the catalog's add functions free a refused name once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try harness.tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);
    const cat = try catalog_mod.Catalog.init(testing.allocator, dir);
    defer {
        cat.deinit();
        testing.allocator.destroy(cat);
    }
    var props = [_][]const u8{"id"};
    const info: catalog_mod.ConstraintInfo = .{ .name = "u", .constraint_type = .unique, .label = "L", .properties = &props, .is_enforced = true };
    try cat.addConstraint(info);
    try testing.expectError(error.ConstraintAlreadyExists, cat.addConstraint(info));
    try cat.addSchema("s");
    try testing.expectError(error.DuplicateSchema, cat.addSchema("s"));
    var cols = [_][]const u8{"id"};
    const index: catalog_mod.IndexInfo = .{ .name = "i", .index_type = "btree", .table_name = "L", .columns = &cols };
    try cat.addIndex(index);
    try testing.expectError(error.DuplicateIndex, cat.addIndex(index));
    try cat.ensureAutoIdIndex("L");
    try cat.ensureAutoIdIndex("L");
}
