//! SONNY-2775: the one gate for a change of a session's graph.
//!
//! A session's graph decides what its statements read and write, and binding
//! a graph (`bind_graph`) is the permission that guards it. Every way a
//! session's graph changes goes through here:
//!
//! - the statements: USE GRAPH, SESSION SET [PROPERTY] GRAPH, SESSION RESET
//!   and SESSION CLOSE (`change`);
//! - the QUIC and gRPC HELLO, which bind the graph a connection names
//!   (`mayBind`, `set`).
//!
//! Before SESSION SET [PROPERTY] GRAPH took any name as given: no permission
//! check, no existence check, a DSN-bound session could leave its graph, and
//! it created the test graphs G1 and G2 in production. It also stored the name
//! with the request's allocator, which is not the session's.

const std = @import("std");
const execution = @import("../execution.zig");
const graph_store = @import("../graph_store.zig");
const catalog_mod = @import("../schema/catalog.zig");
const query_traits = @import("../query/query_traits.zig");
const gps = @import("../security/gps.zig");
const principal_mod = @import("../security/principal.zig");

pub const GraphTarget = query_traits.GraphTarget;

// CANARY: REQ=REQ-SONNY-2791-INTERNAL-GRAPHS; FEATURE="GraphRBACEnforcement"; ASPECT=RefuseInternal; STATUS=TESTED; TEST=tests/test_sonny2791_internal_graphs_reseal.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2791: the engine's own graphs (`__geode_security`, and every
/// `__geode_*` name) are never a session's graph, and no statement creates or
/// drops one: `error.InternalGraph` (42501), for every user, Admin included.
/// They are written only through their owners (the auth and policy DDL, the
/// security manager). `USE GRAPH __geode_security; CREATE (:Policy ...)`
/// planted records, and `DROP GRAPH __geode_security` removed the security
/// graph.
pub fn refuseInternal(graph: []const u8) error{InternalGraph}!void {
    if (graph_store.isInternalGraphName(graph)) return error.InternalGraph;
}

/// Does `graph` exist? The default graph always does: every session starts
/// on it, whether or not anything has been stored in it yet.
pub fn exists(catalog: *catalog_mod.Catalog, graph: []const u8) bool {
    if (std.mem.eql(u8, graph, graph_store.DEFAULT_GRAPH_NAME)) return true;
    if (catalog.hasGraph(graph)) return true;
    const store = graph_store.getCurrentGlobalStore() orelse return false;
    return store.graphExists(graph);
}

// CANARY: REQ=REQ-SONNY-2775-SESSION-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=MayBind; STATUS=TESTED; TEST=tests/test_sonny2775_session_graph_gate.zig; OWNER=security; UPDATED=2026-09-26
/// May `principal` bind `graph`?
///
/// - No principal: yes. That is an in-process caller, or a HELLO on a server
///   with authentication off (the HELLO passes null then).
/// - The default graph: yes. Every session starts on it, and HELLO has
///   always let any authenticated user bind it by name.
/// - Otherwise `gps.decide(bind_graph, graph)`: Admin, a grant on the graph,
///   or ReadWrite in a single-tenant deployment. A decision error is a no.
pub fn mayBind(principal: ?*const principal_mod.Principal, graph: []const u8) bool {
    const p = principal orelse return true;
    if (std.mem.eql(u8, graph, graph_store.DEFAULT_GRAPH_NAME)) return true;
    const req = gps.DecisionRequest{
        .principal = p,
        .action = .bind_graph,
        .resource = .{ .graph = graph },
    };
    // smp_allocator: the governance-approved global allocator in src/.
    const decision = gps.decide(std.heap.smp_allocator, &req) catch return false;
    return decision.kind == .allow;
}

// CANARY: REQ=REQ-SONNY-2803-GRAPH-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=MaySchema; STATUS=TESTED; TEST=tests/test_sonny2803_graph_ddl_gate.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2803: may `principal` change `graph`'s schema: CREATE or DROP GRAPH
/// on it, or index or constraint DDL on it? `gps.decide(schema, graph)` must
/// allow, and so must binding it (`mayBind`), the permission USE GRAPH needs.
/// Schema is Admin's builtin permission, or a GPS policy's (`FOR SCHEMA` on
/// the graph or on `*`). No principal: yes, as for `mayBind` (an in-process
/// caller).
///
/// The handlers' only gate for DDL was `gps.writePermitted`, write on the
/// database, so a ReadWrite user refused `USE GRAPH g1` could `DROP GRAPH g1`,
/// and ReadWrite, which has no Schema permission, could create and drop any
/// graph, index or constraint.
pub fn maySchema(principal: ?*const principal_mod.Principal, graph: []const u8) bool {
    const p = principal orelse return true;
    const req = gps.DecisionRequest{
        .principal = p,
        .action = .schema,
        .resource = .{ .graph = graph },
    };
    // smp_allocator: the governance-approved global allocator in src/.
    const decision = gps.decide(std.heap.smp_allocator, &req) catch return false;
    if (decision.kind != .allow) return false;
    return mayBind(p, graph);
}

/// SONNY-2803: refuse DDL on `graph` (`Unauthorized`, 42501) unless
/// `maySchema`. The DDL arms call it before they look at whether the graph,
/// index or constraint exists, so a caller refused learns nothing about what
/// exists.
pub fn authorizeSchemaChange(context: execution.ExecutionContext, graph: []const u8) error{Unauthorized}!void {
    if (!maySchema(context.principal, graph)) return error.Unauthorized;
}

/// Store `graph` as `session`'s graph: null is the default graph. The name is
/// owned by the session's allocator, as `SessionState.deinit` and `reset`
/// expect. On an allocation failure the session keeps its graph.
pub fn set(session: *execution.SessionState, graph: ?[]const u8) std.mem.Allocator.Error!void {
    const copy: ?[]const u8 = if (graph) |g| try session.allocator.dupe(u8, g) else null;
    if (session.graph) |old| session.allocator.free(old);
    session.graph = copy;
}

/// The graph `context`'s session is on.
pub fn current(context: execution.ExecutionContext) []const u8 {
    const session = context.session_state orelse return graph_store.DEFAULT_GRAPH_NAME;
    return session.graph orelse graph_store.DEFAULT_GRAPH_NAME;
}

// CANARY: REQ=REQ-SONNY-2775-SESSION-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Change; STATUS=TESTED; TEST=tests/test_sonny2775_session_graph_gate.zig; OWNER=security; UPDATED=2026-09-26
/// Move `context`'s session to `target`, for USE GRAPH, SESSION SET
/// [PROPERTY] GRAPH, SESSION RESET and SESSION CLOSE. On an error the
/// session's graph is unchanged.
///
/// - `.current` (CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH): no change.
/// - `.home` (HOME_GRAPH, HOME_PROPERTY_GRAPH, and what SESSION RESET and
///   SESSION CLOSE return to): the session's DSN-bound graph if it has one,
///   else the default graph.
/// - `.named`: that graph.
///
/// A DSN-bound session stays on its graph: naming another is `GraphBound`,
/// naming its own is a no-op. Otherwise the permission check comes first
/// (`Unauthorized`), so a caller who may not bind a graph does not learn
/// whether it exists, and then the existence check (`GraphNotFound`, 3F000).
pub fn change(context: execution.ExecutionContext, target: GraphTarget) !void {
    const now = current(context);
    const wanted: ?[]const u8 = switch (target) {
        .current => return,
        .home => if (context.graph_bound) now else null,
        .named => |name| blk: {
            try refuseInternal(name);
            break :blk name;
        },
    };
    if (context.graph_bound) {
        if (std.mem.eql(u8, wanted orelse graph_store.DEFAULT_GRAPH_NAME, now)) return;
        return error.GraphBound;
    }
    const graph = wanted orelse graph_store.DEFAULT_GRAPH_NAME;
    if (!mayBind(context.principal, graph)) return error.Unauthorized;
    if (!exists(context.catalog, graph)) return error.GraphNotFound;
    if (context.session_state) |session| try set(session, wanted);
}
