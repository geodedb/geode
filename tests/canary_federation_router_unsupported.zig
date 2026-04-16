const std = @import("std");
const router_mod = @import("../src/federation/router.zig");

// CANARY: REQ=REQ-GQL-052; FEATURE="Federation"; ASPECT=FederationRouterUnsupported; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationRouterUnsupported; OWNER=dist; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_052_FederationRouterUnsupported" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    _ = alloc; // silence unused
    var r = router_mod.FederationRouter.init(std.testing.allocator, false);
    const st = try r.route("RETURN 1");
    try std.testing.expect(st == .unsupported);
}
