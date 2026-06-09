// GAP-0839: `geode tenant` CLI subcommand — pure query-string construction.
//
// The CLI connects to a running server and issues `CALL geode.tenant.<op>(...)`,
// reusing the existing dispatch (tenant_dispatch.zig), durable registry, and the
// admin_tenant authz gate (server-side). A full e2e test needs a live server, so
// here we unit-test the deterministic, server-free layer: `buildTenantCallQuery`,
// which maps argv → the exact CALL string the server's geode.tenant.* dispatch
// expects (arg shapes + ordering per tenant_dispatch.zig).
const std = @import("std");
const tenant_cli = @import("tenant_cli");

test "tenant create builds CALL geode.tenant.create with id + parent" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "create", "acme", "--parent", "root" });
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "CALL geode.tenant.create(") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "'acme'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "'root'") != null);
}

test "tenant create without parent omits the second arg" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "create", "acme" });
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.create('acme')", q);
}

test "tenant list builds CALL geode.tenant.list()" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{"list"});
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.list()", q);
}

test "tenant show builds CALL geode.tenant.show(id)" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "show", "acme" });
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.show('acme')", q);
}

test "tenant drop builds CALL geode.tenant.drop(id)" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "drop", "acme" });
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.drop('acme')", q);
}

test "tenant set-quota maps flags to positional args in dispatch order" {
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "set-quota", "acme", "--max-connections", "10", "--max-concurrent-queries", "4" });
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "CALL geode.tenant.set_quota('acme'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "4") != null);
}

test "tenant set-quota supplies dispatch-required defaults for omitted quotas" {
    // tenant_dispatch.handleSetQuota requires exactly 5 args; unspecified quota
    // dimensions default to the registry/quota defaults so the CALL is valid.
    const a = std.testing.allocator;
    const q = try tenant_cli.buildTenantCallQuery(a, &.{ "set-quota", "acme" });
    defer a.free(q);
    // tenant_id + 4 integer positionals.
    try std.testing.expect(std.mem.startsWith(u8, q, "CALL geode.tenant.set_quota('acme', "));
    // 4 commas inside the arg list (between the 5 positional args).
    var commas: usize = 0;
    for (q) |c| {
        if (c == ',') commas += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), commas);
}

test "unknown subcommand is an error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownTenantSubcommand, tenant_cli.buildTenantCallQuery(a, &.{"frobnicate"}));
}

test "empty argv is an error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownTenantSubcommand, tenant_cli.buildTenantCallQuery(a, &.{}));
}

test "single-quote in tenant id is rejected (injection defense)" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidTenantId, tenant_cli.buildTenantCallQuery(a, &.{ "create", "ac'me" }));
    try std.testing.expectError(error.InvalidTenantId, tenant_cli.buildTenantCallQuery(a, &.{ "show", "x'); DROP" }));
}

test "create requires a tenant id" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingTenantId, tenant_cli.buildTenantCallQuery(a, &.{"create"}));
}
