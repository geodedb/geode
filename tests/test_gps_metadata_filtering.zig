// GPS Phase 3 — Metadata Filtering Unit Tests
//
// Verifies that db.labels(), db.relationshipTypes(), and db.propertyKeys()
// honour ctx.tenant_id and do NOT leak metadata across tenant boundaries.
//
// Strategy: spin up a single shared GraphStore, insert nodes/edges under two
// tenant IDs, then call executeDb* with a context bound to one tenant and
// assert the other tenant's metadata is absent.
//
// These tests call the internal `executeDb*` helpers directly (not via the
// full GQL execution path) so they work without a network stack, avoid the
// catalog singleton contention present in the meta_procedures suite, and
// isolate exactly the filtering logic being changed in tasks 3-4/3-5/3-6.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

// ---------------------------------------------------------------------------
// Minimal test harness
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

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

    /// Build an ExecutionContext pinned to the given tenant.
    pub fn ctxForTenant(self: *const Harness, tenant_id: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant_id;
        return c;
    }
};

// ===========================================================================
// Task 3-4 — db.labels() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabelsTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.labels() returns only tenant_a labels, not tenant_b labels" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    // tenant_a gets Employee + Department
    const emp_labels = [_][]const u8{"Employee"};
    const dep_labels = [_][]const u8{"Department"};
    const cust_labels = [_][]const u8{"Customer"};
    _ = try store.createNodeWithGraphAndTenant(&emp_labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&dep_labels, "default", "tenant_a");
    // tenant_b gets Customer
    _ = try store.createNodeWithGraphAndTenant(&cust_labels, "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbLabelsForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see Employee + Department
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    // Rows are sorted ascending
    try std.testing.expectEqualStrings("Department", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("Employee", res.rows[1][0].Str);
}

test "db.labels() with null tenant sees all labels (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const emp_labels = [_][]const u8{"Employee"};
    const cust_labels = [_][]const u8{"Customer"};
    _ = try store.createNodeWithGraphAndTenant(&emp_labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&cust_labels, "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbLabelsForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin (null tenant) must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

// ===========================================================================
// Task 3-5 — db.relationshipTypes() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=DbRelationshipTypesTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.relationshipTypes() returns only tenant_a edge types, not tenant_b" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");
    const nb2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    _ = try store.createEdgeWithGraphAndTenant(na1, na2, "KNOWS", "default", "tenant_a");
    _ = try store.createEdgeWithGraphAndTenant(nb1, nb2, "FOLLOWS", "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbRelationshipTypesForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see KNOWS only, not FOLLOWS
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("KNOWS", res.rows[0][0].Str);
}

test "db.relationshipTypes() with null tenant sees all edge types (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");
    const nb2 = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    _ = try store.createEdgeWithGraphAndTenant(na1, na2, "KNOWS", "default", "tenant_a");
    _ = try store.createEdgeWithGraphAndTenant(nb1, nb2, "FOLLOWS", "default", "tenant_b");

    var res = try geode.meta_dispatch.executeDbRelationshipTypesForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

// ===========================================================================
// Task 3-6 — db.propertyKeys() must filter by tenant
// CANARY: REQ=REQ-GPS-METADATA-003; FEATURE="GPS Metadata Isolation"; ASPECT=DbPropertyKeysTenantFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "db.propertyKeys() returns only tenant_a property keys, not tenant_b" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    // tenant_a has "name" and "age"
    try store.setNodeProperty(na, "name", .{ .String = "Alice" });
    try store.setNodeProperty(na, "age", .{ .Int = 30 });

    // tenant_b has "secret_key" — must NOT appear for tenant_a
    try store.setNodeProperty(nb, "secret_key", .{ .String = "hidden" });

    var res = try geode.meta_dispatch.executeDbPropertyKeysForTest(
        allocator,
        store,
        h.ctxForTenant("tenant_a"),
    );
    defer res.deinit(allocator);

    // Must see "age" + "name" only (sorted), not "secret_key"
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try std.testing.expectEqualStrings("age", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("name", res.rows[1][0].Str);
}

test "db.propertyKeys() with null tenant sees all property keys (admin path)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);

    const person_labels = [_][]const u8{"Person"};
    const na = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_a");
    const nb = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant_b");

    try store.setNodeProperty(na, "name", .{ .String = "Alice" });
    try store.setNodeProperty(nb, "secret_key", .{ .String = "hidden" });

    var res = try geode.meta_dispatch.executeDbPropertyKeysForTest(
        allocator,
        store,
        h.ctxForTenant(null),
    );
    defer res.deinit(allocator);

    // Admin must see both
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}
