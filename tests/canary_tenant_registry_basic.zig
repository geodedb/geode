const std = @import("std");
const registry_mod = @import("../src/multitenancy/registry.zig");

// CANARY: REQ=REQ-GQL-050; FEATURE="Multi-Tenancy"; ASPECT=TenantRegistryBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_050_TenantRegistryBasic; OWNER=dist; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_050_TenantRegistryBasic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();

    const t1 = try reg.createTenant("alpha");
    const t2 = try reg.createTenant("beta");
    try std.testing.expect(t1.id != t2.id);

    const fetched = reg.get(t1.id) orelse return error.MissingTenant;
    try std.testing.expect(std.mem.eql(u8, fetched.name, "alpha"));

    const listed = try reg.list(alloc);
    defer alloc.free(listed);
    try std.testing.expect(listed.len == 2);
}
