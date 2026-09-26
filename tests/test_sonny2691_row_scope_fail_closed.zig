// SONNY-2691 / SONNY-2692 (item 5 of the SONNY-2686 security review): the
// evaluator's row scope fails closed when it is not installed.
//
// indegree()/outdegree() and knn() read rows from the store themselves, so
// they apply the session's RLS through `RowScope`, which
// `execution.initEvaluator` installs (eval.setExecutionCallbacks). In a
// process that never called it, `beginRowScope` returned null and those
// functions applied the graph and the tenant only: a session with a user and
// an RLS policy got the degree and knn() answers of rows its policy hides.
// Pattern comprehensions, COUNT {}, EXISTS {} and shortestPath() panicked in
// the same state ("Execution callbacks not initialized!"), aborting the
// process. Every production entry point calls `initEvaluator`, so this
// mattered for tests and embedded use.
//
// Now, with no scope installed, a statement whose active context carries a
// user or a principal is refused with `EvaluatorNotInitialized`, and so is
// every pattern predicate (they cannot run without the execution layer),
// instead of panicking. A context with neither keeps the graph and tenant
// scoping, as before.
//
// THIS TEST BINARY MUST NEVER CALL `execution.initEvaluator`: the callbacks
// are published once per process and never unset. So it has its own step,
// and uses the harness's `initWithoutEvaluator`.
//
// CANARY: REQ=REQ-SONNY-2691-ROW-SCOPE-FAIL-CLOSED; FEATURE="NodeDegreeFunctions"; ASPECT=RowScopeFailsClosed; STATUS=TESTED; TEST=tests/test_sonny2691_row_scope_fail_closed.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;
const principal_mod = geode.security.principal;

/// g1 -R-> ok, g1 -R-> leak, where the label-deny policy hides `:Hidden` leak;
/// `ok` and `leak` carry a vector.
fn seed(s: *h.Session) !void {
    try s.execAs(null, "CREATE (:G {s: 'g1'})");
    try s.execAs(null, "CREATE (:Doc {s: 'ok', cls: 'public', emb: vectorf32([1.0, 0.0])})");
    try s.execAs(null, "CREATE (:Hidden {s: 'leak', cls: 'secret', emb: vectorf32([0.0, 1.0])})");
    const store = graph_store.getGlobalStore(testing.allocator);
    const g1 = try s.idOf("g1");
    _ = try store.createEdgeWithGraphAndTenant(g1, try s.idOf("ok"), "R", graph_store.DEFAULT_GRAPH_NAME, graph_store.DEFAULT_TENANT_ID);
    _ = try store.createEdgeWithGraphAndTenant(g1, try s.idOf("leak"), "R", graph_store.DEFAULT_GRAPH_NAME, graph_store.DEFAULT_TENANT_ID);
    try s.restrict("Hidden");
}

/// The statements that read rows through the evaluator's row scope.
fn checkRefused(s: *h.Session, f: *h.Failures) !void {
    const aa = s.arena.allocator();
    const g1 = try s.idOf("g1");
    try h.expectError(s, f, try std.fmt.allocPrint(aa, "RETURN outdegree({d})", .{g1}), error.EvaluatorNotInitialized);
    try h.expectError(s, f, "MATCH (g:G) RETURN indegree(g), outdegree(g)", error.EvaluatorNotInitialized);
    try h.expectError(s, f, "RETURN knn('emb', vectorf32([0.0, 1.0]), 5, 'l2') AS ids", error.EvaluatorNotInitialized);
}

/// The pattern predicates, which cannot run at all without the execution
/// layer. Before the fix each one PANICKED, so this runs last in every test.
fn checkPatternPredicates(s: *h.Session, f: *h.Failures) !void {
    try h.expectError(s, f, "MATCH (g:G) RETURN [(g)-[:R]->(h) | h.s] AS xs", error.EvaluatorNotInitialized);
    try h.expectError(s, f, "MATCH (g:G) RETURN COUNT { (g)-[:R]->(h) } AS c", error.EvaluatorNotInitialized);
    try h.expectError(s, f, "MATCH (g:G) RETURN EXISTS { (g)-[:R]->(h) } AS e", error.EvaluatorNotInitialized);
}

test "SONNY-2691 (item 5): with no row scope installed, a user's statement is refused, not answered without RLS" {
    var s = try h.Session.initWithoutEvaluator(.label_policy);
    defer s.deinit();
    try seed(&s);
    var f: h.Failures = .{};
    try checkRefused(&s, &f);
    try checkPatternPredicates(&s, &f);
    try f.finish("user, no evaluator");
}

test "SONNY-2691 (item 5): with no row scope installed, a principal's statement is refused, not answered without RLS" {
    var s = try h.Session.initWithoutEvaluator(.label_policy);
    defer s.deinit();
    try seed(&s);
    var f: h.Failures = .{};
    // The GPS principal alone (RLS evaluates under its username).
    const principal = principal_mod.Principal{
        .user_id = 2691,
        .username = h.session_user,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
    s.ctx.user = null;
    s.ctx.principal = &principal;
    try checkRefused(&s, &f);
    try checkPatternPredicates(&s, &f);
    try f.finish("principal, no evaluator");
}

test "SONNY-2691 (item 5): with no row scope installed, a session with no identity keeps the graph and tenant scoping" {
    var s = try h.Session.initWithoutEvaluator(.label_policy);
    defer s.deinit();
    try seed(&s);
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    // No user and no principal: no RLS policy can apply to the session.
    s.ctx.user = null;
    const g1 = try s.idOf("g1");
    try h.expectRows(&s, &f, try std.fmt.allocPrint(aa, "RETURN outdegree({d})", .{g1}), &.{"2"});
    try h.expectRows(&s, &f, "RETURN size(knn('emb', vectorf32([0.0, 1.0]), 5, 'l2')) AS n", &.{"2"});
    // A pattern predicate still cannot run: refused, never a panic.
    try checkPatternPredicates(&s, &f);
    try f.finish("no identity, no evaluator");
}
