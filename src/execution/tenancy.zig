// CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=ProcessFlag; STATUS=TESTED; TEST=tests/test_gap0840_strict_tenancy.zig; OWNER=security; UPDATED=2026-06-08
//
// GAP-0840: opt-in strict-tenancy mode.
//
// Background: `tenant_id == "default"` or an unset session tenant historically
// resolved to a *null* tenant filter, which the storage/match layers interpret
// as "match ALL tenants". A session that authenticates without a tenant scope
// (or with the literal "default") therefore silently sees every tenant's data —
// a latent cross-tenant data leak (the failure is silent: no error, just broader
// results, which is the worst kind for an isolation control).
//
// This module centralises the tenant-filter decision used by BOTH tenant-filter
// entry points (`crud_operations.tenantFilterFromContext` and
// `match_operations.getSessionTenantFilter`) so the footgun is closed in one
// place:
//
//   * Strict mode OFF (default, unchanged behaviour): an unscoped / "default"
//     tenant resolves to `null` (all-tenants) exactly as before, but a
//     rate-limited WARN is emitted the first time so operators notice that
//     tenant isolation is disabled for that request.
//
//   * Strict mode ON (opt-in via `--strict-tenancy` / `GEODE_STRICT_TENANCY=1`):
//     an unscoped / "default" tenant-scoped operation is REJECTED with
//     `error.TenantScopeRequired` rather than silently widened to all tenants.
//
// The flag mirrors the `--insecure-allow-all` wiring in `src/security/gps.zig`:
// a process-wide `std.atomic.Value(bool)` written once at startup by CLI/env
// parsing and read on every tenant-filter resolution.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const tenant_registry = @import("../security/tenant_registry.zig");

const logging = @import("logging");
const log = logging.scoped("tenancy");

// GAP-0848 follow-up: keep the multi-tenant signal and the strict-tenancy
// resolver in lock-step. `tenant_registry.hasNonDefaultTenant()` decides "is
// this multi-tenant?" by excluding `tenant_registry.DEFAULT_TENANT_ID`, while
// `isConcreteScope` (below) decides "does this request have a concrete scope?"
// by comparing against `graph_store.DEFAULT_TENANT_ID`. Those two ideas of "the
// default tenant" MUST be the same string or the auto-strict default could trip
// on a scope the resolver still treats as concrete (or vice versa). The
// tenant_registry leaf module intentionally does not import the heavy graph_store
// module, so this is the single place that has both in scope — assert equality
// at comptime here so any future drift is a build error, not a silent leak.
comptime {
    if (!std.mem.eql(u8, tenant_registry.DEFAULT_TENANT_ID, graph_store.DEFAULT_TENANT_ID)) {
        @compileError("tenant_registry.DEFAULT_TENANT_ID must equal graph_store.DEFAULT_TENANT_ID (GAP-0848 multi-tenant signal / strict-tenancy resolver must share the default-tenant sentinel)");
    }
}

/// Returned when strict-tenancy mode is enabled and a tenant-scoped operation
/// is attempted without a concrete (non-"default", non-empty) tenant scope.
/// Surfaced to the client as a query error (via `@errorName`).
pub const TenancyError = error{TenantScopeRequired};

// Process-wide strict-tenancy flag. Written once at startup by CLI/env parsing
// (see `src/server/cli_args.zig` + `src/server/main.zig`); read on every
// tenant-filter resolution. Same `std.atomic.Value(bool)` pattern as
// `gps.g_insecure_allow_all`.
var g_strict_tenancy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setStrictTenancy(value: bool) void {
    g_strict_tenancy.store(value, .release);
}

pub fn isStrictTenancy() bool {
    return g_strict_tenancy.load(.acquire);
}

// CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=ConfigResolution; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
//
// GAP-0848: make strict tenancy the DEFAULT in a multi-tenant deployment.
//
// GAP-0840 made strict tenancy purely opt-in, which left the dangerous default:
// a multi-tenant deployment that forgot `--strict-tenancy` still treated an
// unset/empty/"default" tenant as "all tenants" — a silent cross-tenant leak.
//
// This resolver flips that. When the deployment is detected as multi-tenant
// (see `tenant_registry.hasNonDefaultTenant`) and strict tenancy was NOT
// explicitly configured, the effective mode resolves to STRICT. Operators who
// genuinely want the legacy permissive behaviour in a multi-tenant deployment
// must opt back in loudly via `GEODE_PERMISSIVE_TENANCY=1`. Explicitly-set
// strict always stays strict, and single-tenant deployments are completely
// unaffected (effective == explicit).
//
// Decision table (explicit_strict, multi_tenant, permissive_override) -> effective:
//   (true,  *,     *    ) -> strict      (operator asked for strict)
//   (false, false, *    ) -> permissive  (single-tenant: unchanged legacy)
//   (false, true,  false) -> strict      (AUTO-STRICT: the GAP-0848 fix)
//   (false, true,  true ) -> permissive  (explicit break-glass opt-out)
//
// Pure function: every input is a parameter so it is unit-testable in a Debug
// binary with no global/registry/env state. The startup call site in
// `src/server/main.zig` supplies the live values and then calls
// `setStrictTenancy(effective)`.

/// The reason an effective strict-tenancy decision was reached, for honest
/// startup logging.
pub const StrictResolution = enum {
    /// Strict because the operator explicitly configured it.
    explicit_strict,
    /// Permissive in a single-tenant deployment (legacy default, unchanged).
    single_tenant_permissive,
    /// Strict auto-enabled because a multi-tenant deployment was detected and
    /// strict was not explicitly configured (the GAP-0848 fix).
    auto_strict_multi_tenant,
    /// Permissive in a multi-tenant deployment because the operator explicitly
    /// opted out via GEODE_PERMISSIVE_TENANCY (loud warning at the call site).
    explicit_permissive_override,
};

/// Resolve the effective strict-tenancy mode at startup.
///
///   * `explicit_strict`     — `--strict-tenancy` / `GEODE_STRICT_TENANCY=1` was set.
///   * `multi_tenant`        — `tenant_registry.hasNonDefaultTenant()`.
///   * `permissive_override` — `GEODE_PERMISSIVE_TENANCY` is truthy.
///
/// Returns the effective strict boolean plus the reason for logging.
pub fn resolveEffectiveStrictTenancy(
    explicit_strict: bool,
    multi_tenant: bool,
    permissive_override: bool,
) struct { strict: bool, reason: StrictResolution } {
    if (explicit_strict) {
        return .{ .strict = true, .reason = .explicit_strict };
    }
    if (!multi_tenant) {
        return .{ .strict = false, .reason = .single_tenant_permissive };
    }
    // Multi-tenant, strict not explicitly configured.
    if (permissive_override) {
        return .{ .strict = false, .reason = .explicit_permissive_override };
    }
    return .{ .strict = true, .reason = .auto_strict_multi_tenant };
}

// Rate-limiter for the non-strict "tenant isolation disabled" warning so we log
// it once-ish instead of per request/row. We only need a coarse "have we warned
// recently" gate; an atomic bool flipped on first warn is sufficient and never
// spams. One warning per process lifetime is the right signal-to-noise for a
// configuration footgun.
var g_warned_unscoped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Reset the rate-limiter (test-only).
pub fn resetWarnState() void {
    g_warned_unscoped.store(false, .release);
}

/// Returns true if `tid` represents a concrete tenant scope (i.e. NOT the empty
/// string and NOT the wildcard "default" sentinel).
pub fn isConcreteScope(tid: []const u8) bool {
    if (tid.len == 0) return false;
    return !std.mem.eql(u8, tid, graph_store.DEFAULT_TENANT_ID);
}

/// Resolve the tenant filter for a tenant-scoped operation.
///
/// `maybe_tid` is the session's resolved `tenant_id` (`context.tenant_id`).
///
///   * A concrete scope returns that tenant id (`?[]const u8` = the id).
///   * An unscoped / empty / "default" scope:
///       - strict mode ON  -> `error.TenantScopeRequired`
///       - strict mode OFF -> `null` (all-tenants, unchanged) + a one-time WARN.
///
/// Both `crud_operations.tenantFilterFromContext` and
/// `match_operations.getSessionTenantFilter` delegate here so the
/// null=all-tenants footgun is closed in exactly one place.
pub fn resolveTenantFilter(maybe_tid: ?[]const u8) TenancyError!?[]const u8 {
    if (maybe_tid) |tid| {
        if (isConcreteScope(tid)) return tid;
    }

    // Unscoped / empty / "default".
    if (isStrictTenancy()) {
        log.warn(
            "GAP-0840: strict tenancy enabled — rejecting tenant-scoped operation with no concrete tenant scope (unset/empty/\"default\")",
            &.{},
        );
        return error.TenantScopeRequired;
    }

    // Non-strict (default): preserve the legacy all-tenants behaviour but emit a
    // rate-limited warning that tenant isolation is disabled for this request.
    if (!g_warned_unscoped.swap(true, .acq_rel)) {
        log.warn(
            "tenant isolation DISABLED for a tenant-scoped request: session tenant is unset/empty/\"default\", so it can read ALL tenants' data. " ++
                "Set a concrete tenant scope, or enable --strict-tenancy / GEODE_STRICT_TENANCY=1 to reject unscoped access. " ++
                "(This warning is rate-limited to once per process.)",
            &.{},
        );
    }
    return null;
}

const testing = std.testing;

test "resolveTenantFilter: concrete scope returns the tenant id (both modes)" {
    setStrictTenancy(false);
    defer setStrictTenancy(false);
    resetWarnState();

    const r1 = try resolveTenantFilter("tenant_alpha");
    try testing.expect(r1 != null);
    try testing.expectEqualStrings("tenant_alpha", r1.?);

    setStrictTenancy(true);
    const r2 = try resolveTenantFilter("tenant_alpha");
    try testing.expect(r2 != null);
    try testing.expectEqualStrings("tenant_alpha", r2.?);
}

test "resolveTenantFilter: non-strict mode returns null for unscoped/default" {
    setStrictTenancy(false);
    defer setStrictTenancy(false);
    resetWarnState();

    try testing.expect((try resolveTenantFilter(null)) == null);
    try testing.expect((try resolveTenantFilter("")) == null);
    try testing.expect((try resolveTenantFilter(graph_store.DEFAULT_TENANT_ID)) == null);
}

test "resolveTenantFilter: strict mode rejects unscoped/empty/default" {
    setStrictTenancy(true);
    defer setStrictTenancy(false);
    resetWarnState();

    try testing.expectError(error.TenantScopeRequired, resolveTenantFilter(null));
    try testing.expectError(error.TenantScopeRequired, resolveTenantFilter(""));
    try testing.expectError(error.TenantScopeRequired, resolveTenantFilter(graph_store.DEFAULT_TENANT_ID));
}
