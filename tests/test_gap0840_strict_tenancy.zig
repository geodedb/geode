// CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0840_strict_tenancy.zig:1; OWNER=security; UPDATED=2026-06-08
//
// Regression tests for GAP-0840: `tenant_id="default"`/empty disabling tenant
// isolation (cross-tenant data-leak footgun).
//
// The fix adds an opt-in strict-tenancy mode. Both tenant-filter entry points
// (`crud_operations.tenantFilterFromContext` and
// `match_operations.getSessionTenantFilter`) delegate to
// `tenancy.resolveTenantFilter`, so testing that shared decision covers both
// the CRUD (CREATE/MERGE/DELETE) and MATCH read paths.
//
// Asserts:
//   (a) strict mode ON  -> an unscoped/"default"/empty tenant-scoped op is
//       REJECTED with error.TenantScopeRequired (NOT widened to all-tenants);
//   (b) strict mode ON  -> a properly-scoped op still resolves to that tenant;
//   (c) strict mode OFF (default) -> unscoped/"default"/empty still returns the
//       no-filter (null = all-tenants) path, i.e. unchanged behaviour.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const tenancy = geode.tenancy;
const graph_store = geode.graph_store;

// Ensure the process-wide flag is reset to the default (OFF) after each test so
// these tests are order-independent and don't leak strict mode into others.
fn resetTenancyFlag() void {
    tenancy.setStrictTenancy(false);
    tenancy.resetWarnState();
}

test "GAP-0840 (a): strict mode rejects unset tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(error.TenantScopeRequired, tenancy.resolveTenantFilter(null));
}

test "GAP-0840 (a): strict mode rejects empty tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(error.TenantScopeRequired, tenancy.resolveTenantFilter(""));
}

test "GAP-0840 (a): strict mode rejects the \"default\" wildcard tenant scope" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    try testing.expectError(
        error.TenantScopeRequired,
        tenancy.resolveTenantFilter(graph_store.DEFAULT_TENANT_ID),
    );
}

test "GAP-0840 (b): strict mode allows a properly-scoped tenant" {
    defer resetTenancyFlag();
    tenancy.setStrictTenancy(true);

    const filter = try tenancy.resolveTenantFilter("tenant_alpha");
    try testing.expect(filter != null);
    try testing.expectEqualStrings("tenant_alpha", filter.?);
}

test "GAP-0840 (c): non-strict (default) mode is unchanged — unscoped returns null" {
    defer resetTenancyFlag();
    resetTenancyFlag(); // explicitly OFF for this case

    // No filter (all-tenants) is the legacy behaviour; must NOT regress.
    try testing.expect((try tenancy.resolveTenantFilter(null)) == null);
    try testing.expect((try tenancy.resolveTenantFilter("")) == null);
    try testing.expect((try tenancy.resolveTenantFilter(graph_store.DEFAULT_TENANT_ID)) == null);

    // A concrete scope still filters even in non-strict mode.
    const filter = try tenancy.resolveTenantFilter("tenant_beta");
    try testing.expect(filter != null);
    try testing.expectEqualStrings("tenant_beta", filter.?);
}
