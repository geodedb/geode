// CANARY: REQ=REQ-GAP-0850-INSECURE-GUARD-001; FEATURE="InsecureAllowAllProductionGuard"; ASPECT=StartupGuard; STATUS=TESTED; TEST=tests/test_gap0850_insecure_guard.zig; OWNER=security; UPDATED=2026-06-09
//
// GAP-0850: refuse-to-start guard for --insecure-allow-all in production.
//
// GAP-0842 added a startup banner + docs but nothing actually PREVENTED
// --insecure-allow-all from being enabled on a production deployment. This
// regression locks in the pure config-validation function `validateInsecureMode`
// (src/security/gps.zig): the flag must refuse-to-start under production
// conditions (release build OR GEODE_ENV=production) unless the explicit
// break-glass override GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND=1 is set.
//
// The function takes build mode and env as PARAMETERS so the production path is
// exercisable from a Debug test binary without faking the real optimize mode or
// mutating process env.

const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;

const testing = std.testing;

test "flag off: always permitted regardless of production conditions" {
    // insecure_allow_all = false short-circuits before any production check.
    try gps.validateInsecureMode(false, true, true, false); // release + prod, no override
    try gps.validateInsecureMode(false, false, false, false);
}

test "flag on + debug build + non-production env: permitted (dev/test)" {
    try gps.validateInsecureMode(true, false, false, false);
}

test "flag on + release build: REFUSED without override" {
    try testing.expectError(
        error.InsecureAllowAllRefusedInProduction,
        gps.validateInsecureMode(true, true, false, false),
    );
}

test "flag on + GEODE_ENV=production: REFUSED without override (even in debug build)" {
    try testing.expectError(
        error.InsecureAllowAllRefusedInProduction,
        gps.validateInsecureMode(true, false, true, false),
    );
}

test "flag on + release + production: REFUSED without override" {
    try testing.expectError(
        error.InsecureAllowAllRefusedInProduction,
        gps.validateInsecureMode(true, true, true, false),
    );
}

test "break-glass override permits startup under all production conditions" {
    try gps.validateInsecureMode(true, true, false, true); // release
    try gps.validateInsecureMode(true, false, true, true); // GEODE_ENV=production
    try gps.validateInsecureMode(true, true, true, true); // both
}

test "override has no effect when flag is off (no surprising side effects)" {
    try gps.validateInsecureMode(false, true, true, true);
}

test "exported override env var name is the verbose, unmistakable string" {
    try testing.expectEqualStrings(
        "GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND",
        gps.insecure_override_env,
    );
}
