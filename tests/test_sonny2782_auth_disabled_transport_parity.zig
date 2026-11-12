// SONNY-2782: with authentication disabled the QUIC and gRPC handlers must
// gate a request the same way.
//
// The QUIC handler ran its write gate and its read gate only for a session
// with a role (`state.authenticated_role != null`), so with authentication
// disabled nothing was gated. The gRPC handler skipped its read gate the same
// way, but ran its write gate for every session: with authentication disabled
// the session has no user, `gps.decide` answers `unauthenticated`, and every
// change was refused (42501) unless `--insecure-allow-all` was set, while the
// same gRPC session ran reads and every admin procedure (`authorizeAdminSession`
// and the executor's admin gates allow everything with authentication off).
//
// The contract (docs/security/gps-decide.md, "Authentication disabled"):
// authentication disabled is the in-process, single-user mode (embedders and
// tests: `geode serve` always enables authentication, and its `--no-auth` is
// refused outside Debug builds). No request is authenticated and none is
// authorized per user: on every transport every request runs as if by an
// administrator, and GPS policies, grants and roles are not consulted.
// `--insecure-allow-all` changes nothing there. With authentication enabled
// both handlers gate every session, whatever its role. One function decides
// for both handlers (`session_graph.requestChangePermitted`,
// `requestReadPermitted`), so they cannot drift again.
//
// The gRPC handler is driven in process (the SONNY-1560 shim). The QUIC
// handler cannot run with authentication disabled outside the process (the
// server enables it at startup) and has no in-process harness, so its side is
// held by the shared gate, which both handlers call and which is tested here
// directly, and by a source check that neither handler gates on its own.
//
// CANARY: REQ=REQ-SONNY-2782-AUTH-DISABLED-PARITY; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2782_auth_disabled_transport_parity.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const wd = @import("sonny2753_gps_world.zig");

const gps = wd.gps;
const user_mgmt = wd.user_mgmt;
const World = wd.World;
const io = std.Io.Threaded.global_single_threaded.io();

/// One of each statement class: a read, a data change, graph DDL, index
/// DDL, the security DDL and a procedure that changes data (every graph:
/// the self-locking backfill, gated by `gps.writePermitted`).
const statements = [_][]const u8{
    "MATCH (n:C) RETURN count(n) AS c",
    "CREATE (:W {v: 1})",
    "MATCH (n:C) SET n.v = 2",
    "CREATE GRAPH g_off",
    "CREATE INDEX i2782 FOR (n:C) ON (n.v)",
    "CREATE POLICY p2782 ON GRAPH * FOR READ",
    "CALL geode.tenant.backfill_edge_tags()",
};

/// An unauthenticated gRPC session (no user, no role), as a client gets one
/// with authentication disabled.
fn anonymous(w: *World) ![]const u8 {
    return w.sessions.createSession("", "", null, null, null, false, 0);
}

fn runAllAnonymous(w: *World) !void {
    var refused: usize = 0;
    for (statements) |q| {
        if (try wd.outcome(w.ga(), try anonymous(w), q)) |e| {
            std.debug.print("auth off, insecure_allow_all={}: `{s}` refused {s} '{s}'\n", .{ gps.isInsecureAllowAll(), q, e.code, e.message });
            refused += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), refused);
}

test "SONNY-2782: with authentication disabled a gRPC session runs every statement class, as QUIC does" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    user_mgmt.setAuthEnabled(false);
    try runAllAnonymous(&w);
}

test "SONNY-2782: with authentication disabled --insecure-allow-all changes nothing on gRPC" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    user_mgmt.setAuthEnabled(false);
    gps.setInsecureAllowAll(true);
    try runAllAnonymous(&w);
}

test "SONNY-2782: with authentication enabled the gRPC gates are unchanged" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    // ReadOnly: reads, but no change and no DDL.
    try wd.expectRuns(ga, try w.session("otto", .ReadOnly, null), statements[0]);
    for (statements[1..]) |q| try wd.expectDenied(ga, try w.session("otto", .ReadOnly, null), q);
    // No stored role: not even a read of the default graph without a grant.
    try wd.expectDenied(ga, try w.session("nora", .None, null), statements[0]);
    try wd.expectDenied(ga, try w.session("nora", .None, null), statements[1]);
    // ReadWrite: reads and changes data, no DDL.
    try wd.expectRuns(ga, try w.session("rita", .ReadWrite, null), statements[0]);
    try wd.expectRuns(ga, try w.session("rita", .ReadWrite, null), statements[1]);
    try wd.expectDenied(ga, try w.session("rita", .ReadWrite, null), "CREATE INDEX i2782rw FOR (n:C) ON (n.v)");
    // A DENY WRITE still refuses an Admin's change.
    try w.policy("no_writes", "*", &.{.write}, .deny);
    try wd.expectDenied(ga, try w.session("ada", .Admin, null), statements[1]);
}

fn readSource(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

test "SONNY-2782: the QUIC and gRPC handlers gate through the one shared request gate, never on their own" {
    const a = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "src/server/quic_connection_handler.zig", "src/transport/grpc_server.zig" }) |path| {
        const src = try readSource(a, path);
        defer a.free(src);
        for ([_][]const u8{ "session_graph.requestChangePermitted(", "session_graph.requestReadPermitted(" }) |needed| {
            if (std.mem.indexOf(u8, src, needed) == null) {
                std.debug.print("{s} does not call {s}\n", .{ path, needed });
                bad += 1;
            }
        }
        for ([_][]const u8{ "gps.changePermittedOn(", "gps.writePermitted(", "session_graph.programReadPermitted(" }) |own| {
            if (std.mem.indexOf(u8, src, own) != null) {
                std.debug.print("{s} gates on its own: {s}\n", .{ path, own });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-2782: the shared request gate both handlers call: no principal with authentication disabled, every session gated with it enabled" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const session_graph = geode.execution.session_graph;
    const write_walk = geode.execution.write_walk;
    const create: write_walk.Actions = .{ .create = true };
    const schema_change: write_walk.Actions = .{ .schema = true };
    const a = testing.allocator;

    // What each handler derives for an anonymous session: no user, no role.
    const anon = wd.principal("", &.{}, 0);
    var anon_no_user = anon;
    anon_no_user.username = null;
    const readonly = wd.principal("otto", &.{"ReadOnly"}, 0);

    for ([_]bool{ false, true }) |allow_all| {
        gps.setInsecureAllowAll(allow_all);
        user_mgmt.setAuthEnabled(false);
        const p = session_graph.requestPrincipal(&anon_no_user);
        try testing.expect(p == null);
        try testing.expect(session_graph.requestChangePermitted(a, p, false, "default", create));
        try testing.expect(session_graph.requestChangePermitted(a, p, false, "default", schema_change));
        try testing.expect(session_graph.requestChangePermitted(a, p, true, "default", .{ .write = true }));
        // Even a ReadOnly session's principal is not consulted.
        try testing.expect(session_graph.requestPrincipal(&readonly) == null);
    }

    gps.setInsecureAllowAll(false);
    user_mgmt.setAuthEnabled(true);
    // With authentication enabled the principal is always used: a session
    // with no user and no role is refused, and so is ReadOnly's change.
    const p_anon = session_graph.requestPrincipal(&anon_no_user) orelse return error.ExpectedPrincipal;
    try testing.expect(!session_graph.requestChangePermitted(a, p_anon, false, "default", create));
    try testing.expect(!session_graph.requestChangePermitted(a, p_anon, true, "default", .{ .write = true }));
    const p_ro = session_graph.requestPrincipal(&readonly) orelse return error.ExpectedPrincipal;
    try testing.expect(!session_graph.requestChangePermitted(a, p_ro, false, "default", create));
    const rita = wd.principal("rita", &.{"ReadWrite"}, 0);
    const p_rw = session_graph.requestPrincipal(&rita) orelse return error.ExpectedPrincipal;
    try testing.expect(session_graph.requestChangePermitted(a, p_rw, false, "default", create));
    try testing.expect(!session_graph.requestChangePermitted(a, p_rw, false, "default", schema_change));
}
