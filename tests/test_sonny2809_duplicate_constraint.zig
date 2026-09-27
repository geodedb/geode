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

// ---------------------------------------------------------------------------
// Round 7: the error paths. Each add function must free exactly what it still
// owns when an allocation or the save fails, and leave the catalog as it was.
// ---------------------------------------------------------------------------

const nonzero_uuid: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

/// A catalog in a fresh directory, and one of each add. Run by
/// checkAllAllocationFailures once per allocation, failing that allocation:
/// every run must return OutOfMemory and free every byte. ensureAutoIdIndex
/// is not here: it keeps an index whose save failed, by design (IF NOT
/// EXISTS semantics; it logs the failure).
fn addEachWith(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try harness.tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);
    const cat = try catalog_mod.Catalog.init(allocator, dir);
    defer {
        cat.deinit();
        allocator.destroy(cat);
    }
    var props = [_][]const u8{ "id", "email" };
    try cat.addConstraint(.{ .name = "u", .constraint_type = .unique, .label = "L", .properties = &props, .is_enforced = true });
    try cat.addSchema("s");
    try cat.addGraphWithUuid("g", nonzero_uuid);
    var cols = [_][]const u8{ "id", "name" };
    try cat.addIndex(.{ .name = "i", .index_type = "btree", .table_name = "L", .columns = &cols, .metric = "cosine" });
}

test "SONNY-2809: the catalog's add functions free what they own when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, addEachWith, .{});
}

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

fn expectFailure(result: anyerror!void) !void {
    if (result) |_| return error.SaveDidNotFail else |err| switch (err) {
        else => {},
    }
}

fn setMode(buf: []u8, comptime fmt: []const u8, args: anytype, mode: c_uint) !void {
    const path = try std.fmt.bufPrint(buf, fmt, args);
    buf[path.len] = 0;
    if (chmod(buf[0..path.len :0], mode) != 0) return error.ChmodFailed;
}

test "SONNY-2809: a failed catalog save leaves the catalog as it was" {
    // Root writes through a read-only mode: nothing to test.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try harness.tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);
    const cat = try catalog_mod.Catalog.init(testing.allocator, dir);
    defer {
        cat.deinit();
        testing.allocator.destroy(cat);
    }
    try cat.addSchema("kept");

    // The catalog file and its directory read-only: every save fails.
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    try setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o400);
    try setMode(&buf, "{s}", .{dir}, 0o500);
    var restored = false;
    defer if (!restored) {
        setMode(&buf, "{s}", .{dir}, 0o700) catch {};
        setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o600) catch {};
    };

    var props = [_][]const u8{ "id", "email" };
    const constraint: catalog_mod.ConstraintInfo = .{ .name = "u", .constraint_type = .unique, .label = "L", .properties = &props, .is_enforced = true };
    var cols = [_][]const u8{ "id", "name" };
    const index: catalog_mod.IndexInfo = .{ .name = "i", .index_type = "btree", .table_name = "L", .columns = &cols };
    try expectFailure(cat.addConstraint(constraint));
    try expectFailure(cat.addSchema("s"));
    try expectFailure(cat.addGraphWithUuid("g", nonzero_uuid));
    try expectFailure(cat.addIndex(index));
    // Nothing was added, and each refused entry was freed once (the testing
    // allocator reports a double free or a leak).
    try testing.expectEqual(@as(u32, 0), cat.constraints.count());
    try testing.expectEqual(@as(u32, 1), cat.schemas.count());
    try testing.expectEqual(@as(u32, 0), cat.graphs.count());
    try testing.expectEqual(@as(u32, 0), cat.indexes.count());

    // Writable again: the same adds succeed, and nothing is a duplicate.
    try setMode(&buf, "{s}", .{dir}, 0o700);
    try setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o600);
    restored = true;
    try cat.addConstraint(constraint);
    try cat.addSchema("s");
    try cat.addGraphWithUuid("g", nonzero_uuid);
    try cat.addIndex(index);
    try testing.expectEqual(@as(u32, 1), cat.constraints.count());
    try testing.expectEqual(@as(u32, 2), cat.schemas.count());
}
