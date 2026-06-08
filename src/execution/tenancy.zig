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

const logging = @import("logging");
const log = logging.scoped("tenancy");

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
fn isConcreteScope(tid: []const u8) bool {
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
