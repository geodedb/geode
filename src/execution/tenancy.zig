// CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=ProcessFlag; STATUS=IMPL; OWNER=security; UPDATED=2026-06-08
//
// GAP-0840: opt-in strict-tenancy mode (SCAFFOLD — failing-test commit).
//
// This is the failing-test scaffold for GAP-0840. The public surface
// (`setStrictTenancy`/`isStrictTenancy`/`resolveTenantFilter`) exists so the
// regression test in tests/test_gap0840_strict_tenancy.zig compiles, but
// `resolveTenantFilter` still reproduces the legacy footgun: an unscoped /
// empty / "default" tenant always resolves to `null` (all-tenants), and strict
// mode is NOT yet enforced. The next commit implements the real strict-mode
// rejection + rate-limited warning.

const std = @import("std");
const graph_store = @import("../graph_store.zig");

/// Returned when strict-tenancy mode is enabled and a tenant-scoped operation
/// is attempted without a concrete (non-"default", non-empty) tenant scope.
pub const TenancyError = error{TenantScopeRequired};

var g_strict_tenancy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setStrictTenancy(value: bool) void {
    g_strict_tenancy.store(value, .release);
}

pub fn isStrictTenancy() bool {
    return g_strict_tenancy.load(.acquire);
}

/// Test-only no-op for the not-yet-implemented warn rate-limiter.
pub fn resetWarnState() void {}

/// SCAFFOLD: still exhibits the GAP-0840 footgun — unscoped/"default" resolves
/// to null (all-tenants) regardless of strict mode. Implemented for real in the
/// follow-up commit.
pub fn resolveTenantFilter(maybe_tid: ?[]const u8) TenancyError!?[]const u8 {
    if (maybe_tid) |tid| {
        if (tid.len != 0 and !std.mem.eql(u8, tid, graph_store.DEFAULT_TENANT_ID)) return tid;
    }
    return null;
}
