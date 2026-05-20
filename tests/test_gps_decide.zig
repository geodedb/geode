const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DecisionTypes; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "PolicyDecision kinds are distinct" {
    try std.testing.expect(gps.PolicyDecisionKind.allow != gps.PolicyDecisionKind.deny);
    try std.testing.expect(gps.PolicyDecisionKind.unauthenticated != gps.PolicyDecisionKind.unauthorized);
}

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DefaultDeny; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() with an empty Principal returns unauthenticated" {
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, decision.kind);
}
