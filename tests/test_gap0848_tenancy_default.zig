// CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=ConfigResolution; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
//
// GAP-0848: default tenancy treated unset/empty/"default" tenant as unscoped
// (all-tenants) even in a multi-tenant deployment. GAP-0840 left strict tenancy
// purely opt-in, so an operator who provisioned real tenants but forgot
// `--strict-tenancy` still leaked across tenants silently.
//
// Detection signal (documented choice): a deployment is "multi-tenant" when the
// durable tenant registry contains >= 1 tenant whose id is NOT the implicit
// `"default"` sentinel. The registry is the only place a tenant record lands
// (via `CALL geode.tenant.create`), so a registered non-default tenant is the
// most truthful signal that an operator has actually provisioned tenants. We
// lock that in with `tenant_registry.hasNonDefaultTenant`.
//
// This regression pins TWO pure functions:
//   1. tenant_registry.hasNonDefaultTenant — the multi-tenant signal.
//   2. tenancy.resolveEffectiveStrictTenancy — the auto-strict resolution with
//      the GEODE_PERMISSIVE_TENANCY break-glass opt-out.

const std = @import("std");
const geode = @import("geode");
const tenancy = geode.tenancy;
const tenant_registry = geode.tenant_registry;

const testing = std.testing;

// ── Multi-tenant detection signal ──────────────────────────────────────────

test "hasNonDefaultTenant: empty registry is single-tenant" {
    var reg = tenant_registry.TenantRegistry.init(testing.allocator);
    defer reg.deinit();
    try testing.expect(!reg.hasNonDefaultTenant());
}

test "hasNonDefaultTenant: only \"default\" registered is still single-tenant" {
    var reg = tenant_registry.TenantRegistry.init(testing.allocator);
    defer reg.deinit();
    try reg.create("default", null);
    try testing.expect(!reg.hasNonDefaultTenant());
}

test "hasNonDefaultTenant: a real tenant flips the signal" {
    var reg = tenant_registry.TenantRegistry.init(testing.allocator);
    defer reg.deinit();
    try reg.create("acme", null);
    try testing.expect(reg.hasNonDefaultTenant());
}

test "hasNonDefaultTenant: default + real tenant is multi-tenant" {
    var reg = tenant_registry.TenantRegistry.init(testing.allocator);
    defer reg.deinit();
    try reg.create("default", null);
    try reg.create("acme", null);
    try testing.expect(reg.hasNonDefaultTenant());
}

// ── Effective strict-tenancy resolution ─────────────────────────────────────

test "resolve: explicit strict always wins (both signals)" {
    const r1 = tenancy.resolveEffectiveStrictTenancy(true, true, false);
    try testing.expect(r1.strict);
    try testing.expectEqual(tenancy.StrictResolution.explicit_strict, r1.reason);

    // Explicit strict even overrides a permissive override request.
    const r2 = tenancy.resolveEffectiveStrictTenancy(true, true, true);
    try testing.expect(r2.strict);
    try testing.expectEqual(tenancy.StrictResolution.explicit_strict, r2.reason);

    // Explicit strict in a single-tenant deployment stays strict.
    const r3 = tenancy.resolveEffectiveStrictTenancy(true, false, false);
    try testing.expect(r3.strict);
}

test "resolve: single-tenant deployment stays permissive (legacy default unchanged)" {
    const r = tenancy.resolveEffectiveStrictTenancy(false, false, false);
    try testing.expect(!r.strict);
    try testing.expectEqual(tenancy.StrictResolution.single_tenant_permissive, r.reason);

    // Permissive override has no effect when single-tenant (no surprise flip).
    const r2 = tenancy.resolveEffectiveStrictTenancy(false, false, true);
    try testing.expect(!r2.strict);
    try testing.expectEqual(tenancy.StrictResolution.single_tenant_permissive, r2.reason);
}

test "resolve: multi-tenant without explicit config AUTO-ENABLES strict (the GAP-0848 fix)" {
    const r = tenancy.resolveEffectiveStrictTenancy(false, true, false);
    try testing.expect(r.strict);
    try testing.expectEqual(tenancy.StrictResolution.auto_strict_multi_tenant, r.reason);
}

test "resolve: multi-tenant + GEODE_PERMISSIVE_TENANCY keeps permissive (loud opt-out)" {
    const r = tenancy.resolveEffectiveStrictTenancy(false, true, true);
    try testing.expect(!r.strict);
    try testing.expectEqual(tenancy.StrictResolution.explicit_permissive_override, r.reason);
}
