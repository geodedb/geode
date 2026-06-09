// GAP-0844 (secondary): the FLE role should flow through ExecutionContext, not
// just the OS thread, so FLE isolation stays correct under a future async /
// work-stealing executor that moves a request across threads mid-flight.
//
// This test asserts the context-preferring reader `getCurrentUserRoleCtx`:
//   - prefers `ctx.fle_role` when set,
//   - falls back to the per-thread map when `ctx.fle_role` is null,
// while the legacy per-thread `getCurrentUserRole()` is unchanged.
const std = @import("std");
const geode = @import("geode");
const fle = geode.fle_integration;
const exec = geode.execution;

test "GAP-0844: getCurrentUserRoleCtx prefers ExecutionContext fle_role over per-thread" {
    // ExecutionContext requires a catalog; build a real one.
    const catalog = try exec.ensureCatalogInstance(std.testing.allocator);
    defer exec.cleanupCatalogInstance();

    // Per-thread says "thread_role"; the context says "ctx_role"; context wins.
    fle.setCurrentUserRole("thread_role");
    defer fle.clearCurrentThreadState();

    var ctx: exec.ExecutionContext = .{ .catalog = catalog, .fle_role = "ctx_role" };
    try std.testing.expectEqualStrings("ctx_role", fle.getCurrentUserRoleCtx(&ctx).?);

    // With no context (null), the per-thread map is the source (unchanged behavior).
    try std.testing.expectEqualStrings("thread_role", fle.getCurrentUserRole().?);

    // A context whose fle_role is null also falls back to the per-thread map.
    var ctx_empty: exec.ExecutionContext = .{ .catalog = catalog };
    try std.testing.expectEqualStrings("thread_role", fle.getCurrentUserRoleCtx(&ctx_empty).?);

    // And with NO per-thread role AND a null-fle_role context, it returns null
    // (fail-secure: no role = deny). The context never resurrects a role.
    fle.clearCurrentThreadState();
    try std.testing.expect(fle.getCurrentUserRoleCtx(&ctx_empty) == null);
    // A context WITH an fle_role still wins even when the per-thread map is empty.
    try std.testing.expectEqualStrings("ctx_role", fle.getCurrentUserRoleCtx(&ctx).?);
}
