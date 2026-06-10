// GAP-0852: FLE enforcement must derive role AND tenant from the request
// ExecutionContext (the authoritative source), not solely from the per-thread
// fallback, and an absent tenant on a live context must NOT silently collapse
// to the "default" namespace.
//
// Background / call-site enumeration (sites that previously read the per-thread
// role/tenant accessors WITHOUT preferring the active ExecutionContext, now
// migrated to context-preferring helpers):
//
//   role (getCurrentUserRole -> *PreferringContext):
//     - src/graph_store.zig:applyFleEncryption / setNodeProperty /
//       getNodeProperty / setEdgeProperty (5 sites) -> fleRolePreferringContext
//     - src/planner/rewrite.zig predicate rewrite (1 site) -> fleRolePreferringContext
//     - src/fle_integration.zig checkPropertyAccess (1 site) -> active-context blk
//     (fle_hooks.zig + value_utilities.zig already used the role helper.)
//
//   tenant (getCurrentTenantId -> *PreferringContext):
//     - src/execution/fle_hooks.zig encrypt/encryptEdge/decrypt (3 sites)
//       -> currentTenantIdPreferringContext
//     - src/execution/value_utilities.zig node/edge JSON projection (2 sites)
//       -> currentTenantIdPreferringContext
//     - src/fle_integration.zig checkPropertyAccess (1 site) -> active-context blk
//     (graph_store.zig encrypt/decrypt uses the store-instance self.tenant_id,
//      which is set per GraphStore and is NOT the per-thread "default" fallback;
//      node-create auto-tenant via createNodeWithGraph is a write-tagging path,
//      out of scope for decryption-authorization correctness.)
//
// The authoritative resolvers are fle_integration.getCurrentUserRoleCtx and
// fle_integration.getCurrentTenantIdCtx; every migrated site funnels through
// them. This test pins their semantics directly (deterministic, no I/O) plus a
// bounded two-thread concurrency regression with explicit joins (no sleeps).
const std = @import("std");
const geode = @import("geode");
const fle = geode.fle_integration;
const exec = geode.execution;

test "GAP-0852: context role B wins over per-thread role A" {
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();

    // Per-thread (legacy bridge) says role A.
    fle.setCurrentUserRole("role_A");
    defer fle.clearCurrentThreadState();

    // Request context carries role B — B must win.
    var ctx: exec.ExecutionContext = .{ .catalog = catalog, .fle_role = "role_B" };
    try std.testing.expectEqualStrings("role_B", fle.getCurrentUserRoleCtx(&ctx).?);

    // The per-thread reader itself is unchanged (still A).
    try std.testing.expectEqualStrings("role_A", fle.getCurrentUserRole().?);
}

test "GAP-0852: absent tenant with a request context does NOT become default" {
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();

    // No per-thread tenant set -> getCurrentTenantId() would yield "default".
    fle.clearCurrentThreadState();
    try std.testing.expectEqualStrings("default", fle.getCurrentTenantId());

    // A live request context carrying tenant "acme" must make "acme" the FLE
    // namespace — NOT the per-thread "default" fallback.
    var ctx: exec.ExecutionContext = .{ .catalog = catalog, .tenant_id = "acme" };
    try std.testing.expectEqualStrings("acme", fle.getCurrentTenantIdCtx(&ctx));

    // Even when the per-thread map holds a *different* tenant, the context wins.
    fle.setCurrentTenantId("stale_thread_tenant");
    defer fle.clearCurrentThreadState();
    try std.testing.expectEqualStrings("acme", fle.getCurrentTenantIdCtx(&ctx));

    // And a context whose tenant_id is null legitimately falls back to the
    // per-thread map (documented contextless-internal-caller bridge).
    var ctx_empty: exec.ExecutionContext = .{ .catalog = catalog };
    try std.testing.expectEqualStrings("stale_thread_tenant", fle.getCurrentTenantIdCtx(&ctx_empty));
}

test "GAP-0852: a null-tenant context with empty per-thread map falls back to default" {
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();
    fle.clearCurrentThreadState();
    defer fle.clearCurrentThreadState();

    // Genuinely contextless: no context tenant, no per-thread tenant. This is
    // the ONLY path where "default" is reached — startup hydration / internal.
    var ctx_empty: exec.ExecutionContext = .{ .catalog = catalog };
    try std.testing.expectEqualStrings("default", fle.getCurrentTenantIdCtx(&ctx_empty));
}

// GAP-0852 follow-up: pin the thread-local active-context wiring that the
// migrated sites depend on. The four duplicated `*PreferringContext` helpers
// were consolidated into `fle_integration.rolePreferringActiveContext` /
// `.tenantPreferringActiveContext`, which read `execution.getActiveContext()`.
// Every production site that previously had its own copy now funnels through
// these two. This test exercises the REAL push/pop plumbing (not a hand-rolled
// `getActiveContext`) and asserts the consolidated helpers resolve role+tenant
// from the pushed context, then revert to the per-thread bridge after pop.
test "GAP-0852 follow-up: consolidated helpers resolve role+tenant from pushed active context" {
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();

    // Per-thread (legacy bridge) holds DIFFERENT values; the pushed context must win.
    fle.setCurrentUserRole("thread_role");
    fle.setCurrentTenantId("thread_tenant");
    defer fle.clearCurrentThreadState();

    // With no active context, the consolidated helpers fall back to the bridge.
    try std.testing.expect(exec.getActiveContext() == null);
    try std.testing.expectEqualStrings("thread_role", fle.rolePreferringActiveContext().?);
    try std.testing.expectEqualStrings("thread_tenant", fle.tenantPreferringActiveContext());

    // Push a real request context via the production push API, scoped to a block
    // so the matching pop runs deterministically before the post-pop assertions.
    {
        var ctx: exec.ExecutionContext = .{ .catalog = catalog, .fle_role = "ctx_role", .tenant_id = "ctx_tenant" };
        const prev = exec.pushActiveContext(&ctx);
        defer exec.popActiveContext(prev);

        // The consolidated helpers must now resolve from the pushed context, NOT
        // the per-thread map — this is the wiring the migrated graph_store /
        // fle_hooks / value_utilities / planner sites rely on.
        try std.testing.expectEqualStrings("ctx_role", fle.rolePreferringActiveContext().?);
        try std.testing.expectEqualStrings("ctx_tenant", fle.tenantPreferringActiveContext());

        // checkPropertyAccess (the pub entry that already used the active-context
        // block) observes the same pushed context: for a NON-encrypted field it
        // returns the value verbatim, proving it ran under the context cleanly.
        const out = try fle.checkPropertyAccess(std.testing.allocator, "UnregisteredType", "plain_field", "plaintext", 1);
        try std.testing.expectEqualStrings("plaintext", out);
    }

    // After pop, the helpers revert to the per-thread bridge.
    try std.testing.expect(exec.getActiveContext() == null);
    try std.testing.expectEqualStrings("thread_role", fle.rolePreferringActiveContext().?);
    try std.testing.expectEqualStrings("thread_tenant", fle.tenantPreferringActiveContext());
}

// Worker for the concurrency regression. Each thread sets its OWN per-thread
// role/tenant to a *wrong* value, then resolves through the context-preferring
// helpers with its OWN request context — and must observe its own context
// values, never the other thread's. Result is written through an out-pointer so
// the joiner can assert deterministically.
const Outcome = struct {
    role: [32]u8 = std.mem.zeroes([32]u8),
    role_len: usize = 0,
    tenant: [32]u8 = std.mem.zeroes([32]u8),
    tenant_len: usize = 0,
};

fn concurrentWorker(
    catalog: anytype,
    ctx_role: []const u8,
    ctx_tenant: []const u8,
    wrong_thread_role: []const u8,
    wrong_thread_tenant: []const u8,
    out: *Outcome,
) void {
    // Poison the per-thread (legacy) state for THIS thread with the OTHER
    // request's values, to prove the context — not the thread — is authoritative.
    fle.setCurrentUserRole(wrong_thread_role);
    fle.setCurrentTenantId(wrong_thread_tenant);
    defer fle.clearCurrentThreadState();

    var ctx: exec.ExecutionContext = .{ .catalog = catalog, .fle_role = ctx_role, .tenant_id = ctx_tenant };

    const resolved_role = fle.getCurrentUserRoleCtx(&ctx) orelse "";
    const resolved_tenant = fle.getCurrentTenantIdCtx(&ctx);

    @memcpy(out.role[0..resolved_role.len], resolved_role);
    out.role_len = resolved_role.len;
    @memcpy(out.tenant[0..resolved_tenant.len], resolved_tenant);
    out.tenant_len = resolved_tenant.len;
}

test "GAP-0852: concurrent requests each see their own context role/tenant" {
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();

    var out1: Outcome = .{};
    var out2: Outcome = .{};

    // Thread 1's request: role=admin, tenant=tenant_one; its per-thread legacy
    // state is poisoned with thread 2's values (and vice versa).
    const t1 = try std.Thread.spawn(.{}, concurrentWorker, .{
        catalog, "admin", "tenant_one", "user", "tenant_two", &out1,
    });
    const t2 = try std.Thread.spawn(.{}, concurrentWorker, .{
        catalog, "user", "tenant_two", "admin", "tenant_one", &out2,
    });

    // Deterministic joins — no sleeps.
    t1.join();
    t2.join();

    try std.testing.expectEqualStrings("admin", out1.role[0..out1.role_len]);
    try std.testing.expectEqualStrings("tenant_one", out1.tenant[0..out1.tenant_len]);

    try std.testing.expectEqualStrings("user", out2.role[0..out2.role_len]);
    try std.testing.expectEqualStrings("tenant_two", out2.tenant[0..out2.tenant_len]);
}
