// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LazyFetchTest; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig:1; OWNER=lsp; UPDATED=2026-05-14
//
// Regression tests for src/cli/lsp/schema_provider.zig — the LSP's
// lazy-fetch wrapper over schema_introspection.zig. Task 6 only covers
// the unconditional-cache-on-first-call behaviour; TTL expiry, mutex,
// and DDL invalidation hooks land in Tasks 7-9.
//
// The "returns labels accessible to the user" case mirrors Task 5's
// test_schema_introspection.zig "filters by tenant" case so the
// SchemaProvider's first-fetch path is exercised against a real
// GraphStore + a permissive (auth_mgr = null) IntrospectionContext.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const intro = @import("schema_introspection");
const SchemaProvider = @import("schema_provider").SchemaProvider;
// Task 9: notifier is accessed via the `geode` named module (re-exported
// from lib.zig:715). Registering schema_change_notifier as its own build
// module would trigger Zig 0.16's "file exists in modules X and X0"
// diamond — execution.zig + auth_dispatch.zig already pull it via
// relative @import.
const notifier = geode.schema_change_notifier;
const graph_store = geode.graph_store;
const user_management = geode.user_management;

test "SchemaProvider returns labels accessible to the user" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    // createNode(&.{"Person"}, .{}, "tenant-a") doesn't exist on
    // GraphStore — Tasks 1-5's tests use the explicit graph+tenant
    // variant, so do the same here.
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();

    const labels = try sp.getLabels();
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Person", labels[0]);
}

test "SchemaProvider re-fetches labels after TTL expiry" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Person"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();
    sp.ttl_ns = 1;

    _ = try sp.getLabels();
    _ = try store.createNodeWithGraphAndTenant(&.{"Product"}, default_graph, "tenant-a");
    // Zig 0.16 compat: std.Thread.sleep was removed. Use raw nanosleep
    // (same pattern as src/cli/main.zig:compat_sleepNs). 2ns is enough
    // because the TTL is 1ns and the monotonic clock has ns granularity.
    sleepNs(2);
    const labels = try sp.getLabels();
    try testing.expectEqual(@as(usize, 2), labels.len);
}

fn sleepNs(ns: i64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    }
}

test "SchemaProvider.invalidate() drops cached data" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"X"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();
    _ = try sp.getLabels();
    sp.invalidate();
    try testing.expect(sp.labels == null);
}

test "SchemaProvider is safe under concurrent access" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"P"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();

    const Run = struct {
        fn go(p: *SchemaProvider) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) _ = p.getLabels() catch {};
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Run.go, .{&sp});
    for (threads) |t| t.join();
}

test "SchemaProvider invalidates on DDL notification" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"A"}, default_graph, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();
    try sp.registerInvalidation();
    defer sp.unregisterInvalidation();

    _ = try sp.getLabels();
    try testing.expect(sp.labels != null);
    notifier.notify();
    try testing.expect(sp.labels == null);
}
