//! The rules of a per-graph grant, shared by the online
//! `GRANT <privilege> ON GRAPH <graph> TO <user>` / `geode.auth.grant`
//! (src/execution/auth_dispatch.zig) and the offline `geode grant` /
//! `geode revoke` (src/cli/auth_cli.zig), so the two cannot disagree
//! (SONNY-6586). docs/GQL_AUTH_DDL.md "Per-graph grant semantics".
//!
//!   - The privilege is READ, WRITE, SCHEMA or ALL (any case); ALL is the
//!     three. Nothing else is a privilege: `admin` is a role (GRANT ROLE
//!     admin TO <user>, geode user assign-role <user> admin).
//!   - The grant is on one named graph. There is no global per-privilege
//!     grant (global privilege is the user's role), and a grant on `*`
//!     would match no request. A revoke of `*` is allowed, to remove such a
//!     grant an older release stored.

// CANARY: REQ=REQ-SONNY-6586-GRANT-RULES-SHARED; FEATURE="GQL Auth DDL"; ASPECT=OneGrantRule; STATUS=TESTED; TEST=tests/test_sonny6586_offline_grant_rule.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");

/// The action codes of a privilege: 0 read, 1 write, 2 schema.
pub const read: u8 = 0;
pub const write: u8 = 1;
pub const schema: u8 = 2;

const all_actions = [_]u8{ read, write, schema };

/// The action codes `privilege` grants, or null when it is not one of
/// READ, WRITE, SCHEMA, ALL.
pub fn actionsOf(privilege: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(privilege, "READ")) return all_actions[0..1];
    if (std.ascii.eqlIgnoreCase(privilege, "WRITE")) return all_actions[1..2];
    if (std.ascii.eqlIgnoreCase(privilege, "SCHEMA")) return all_actions[2..3];
    if (std.ascii.eqlIgnoreCase(privilege, "ALL")) return all_actions[0..];
    return null;
}

/// The privilege's name as GRANT writes it.
pub fn canonicalName(privilege: []const u8) []const u8 {
    inline for (.{ "READ", "WRITE", "SCHEMA", "ALL" }) |name| {
        if (std.ascii.eqlIgnoreCase(privilege, name)) return name;
    }
    return privilege;
}

pub const GraphError = error{ GlobalPrivilegeNotSupported, GrantWildcardNotSupported };

/// Whether `graph` names a graph a grant (or, `is_grant` false, a revoke)
/// can be on.
pub fn checkGraph(graph: []const u8, is_grant: bool) GraphError!void {
    if (graph.len == 0) return error.GlobalPrivilegeNotSupported;
    if (is_grant and std.mem.eql(u8, graph, "*")) return error.GrantWildcardNotSupported;
}

test "privileges are READ, WRITE, SCHEMA and ALL only" {
    try std.testing.expectEqualSlices(u8, &.{read}, actionsOf("read").?);
    try std.testing.expectEqualSlices(u8, &.{write}, actionsOf("Write").?);
    try std.testing.expectEqualSlices(u8, &.{schema}, actionsOf("SCHEMA").?);
    try std.testing.expectEqualSlices(u8, &.{ read, write, schema }, actionsOf("all").?);
    for ([_][]const u8{ "admin", "read:users", "", "READS", "*" }) |p| try std.testing.expect(actionsOf(p) == null);
    try std.testing.expectEqualStrings("READ", canonicalName("read"));
}

test "a grant is on one named graph" {
    try std.testing.expectError(error.GlobalPrivilegeNotSupported, checkGraph("", true));
    try std.testing.expectError(error.GlobalPrivilegeNotSupported, checkGraph("", false));
    try std.testing.expectError(error.GrantWildcardNotSupported, checkGraph("*", true));
    try checkGraph("*", false);
    try checkGraph("g", true);
}
