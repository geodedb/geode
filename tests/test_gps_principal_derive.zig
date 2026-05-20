const std = @import("std");
const geode = @import("geode");
const derive = geode.security.principal_derive;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-DERIVE-001; FEATURE="GPS Principal Derivation"; ASPECT=QuicArgs; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "derivePrincipal from QUIC-shaped args yields source=.quic_handler" {
    const role_names = [_][]const u8{"User"};
    const p = derive.derivePrincipal(.{
        .username = "alice",
        .role_names = &role_names,
        .tenant_id = "t1",
        .active_graph = "hr",
        .auth_version = 7,
        .auth_method = .password,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(principal_mod.PrincipalSource.quic_handler, p.source);
    try std.testing.expectEqualStrings("alice", p.username.?);
    try std.testing.expectEqual(@as(u64, 7), p.auth_version);
    try std.testing.expectEqualStrings("t1", p.tenant_id.?);
    try std.testing.expectEqualStrings("hr", p.active_graph.?);
}

// CANARY: REQ=REQ-GPS-DERIVE-001; FEATURE="GPS Principal Derivation"; ASPECT=EmptyArgs; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "derivePrincipal with null username returns source-tagged empty principal" {
    const p = derive.derivePrincipal(.{
        .username = null,
        .role_names = &.{},
        .tenant_id = null,
        .active_graph = null,
        .auth_version = 0,
        .auth_method = .anonymous,
        .source = .grpc_handler,
    });
    try std.testing.expectEqual(principal_mod.PrincipalSource.grpc_handler, p.source);
    try std.testing.expect(p.username == null);
    try std.testing.expectEqual(@as(usize, 0), p.roles.len);
}
