// CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=AtomicCounter; STATUS=TESTED; TEST=tests/test_gps_policy_version.zig; OWNER=security; UPDATED=2026-05-20
//
// policy_version.zig — global monotonic policy version counter.
//
// Incremented on every addPolicy / removePolicy call so that downstream caches
// (e.g. distributed decision caches introduced in GPS Phase 6) can detect
// stale entries without holding a lock on the PolicyCatalog itself.
//
// Usage:
//   - Read:      getPolicyVersion()      → u64, acquire-ordered
//   - Increment: incrementPolicyVersion() → new value (post-increment + 1)
//   - Reset:     resetPolicyVersionForTesting(v) — ONLY in test code
//
// Thread-safety: all operations use std.atomic.Value(u64).
// The version starts at 0 and wraps at u64 max (effectively never in practice).

const std = @import("std");

var g_policy_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Return the current policy version.  Acquire-ordered so that code observing
/// a version bump also sees all writes that preceded it.
pub fn getPolicyVersion() u64 {
    return g_policy_version.load(.acquire);
}

/// Atomically increment the version and return the NEW value.
/// Uses acq_rel ordering so the increment is a full memory barrier.
pub fn incrementPolicyVersion() u64 {
    return g_policy_version.fetchAdd(1, .acq_rel) + 1;
}

/// Reset the counter to `v`.  FOR TESTING ONLY — do not call in production
/// code.  Uses release ordering to make the store visible to subsequent
/// acquire-ordered loads.
pub fn resetPolicyVersionForTesting(v: u64) void {
    g_policy_version.store(v, .release);
}
