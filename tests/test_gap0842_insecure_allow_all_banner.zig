// CANARY: REQ=REQ-GAP-0842-INSECURE-BANNER-001; FEATURE="InsecureAllowAllStartupBanner"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0842_insecure_allow_all_banner.zig:1; OWNER=security; UPDATED=2026-06-08
//
// Regression tests for GAP-0842: `--insecure-allow-all` short-circuits ALL
// authorization (tenant isolation, RLS, and FLE decrypt authz) before any
// tenant/RLS logic runs (see `gps.decide()`).
//
// The hardening here is documentation + a prominent startup banner (NOT an
// auto-refuse-to-start). Auto-refuse-on-multi-tenant-data was deliberately not
// added: a tenant is a per-record string tag (`graph_store.tenant_id`), not an
// on-disk directory (storage is per-GRAPH at `{data_dir}/graphs/{uuid}/...`),
// so distinct-tenant detection would require a full scan of every node/edge
// across every graph at startup — neither cheap nor safe.
//
// These tests pin the banner contract so it can never silently regress into a
// vague one-liner that omits one of the three disabled controls:
//   (a) the banner names tenant isolation, RLS, and FLE explicitly;
//   (b) the banner states it is NOT FOR PRODUCTION and points operators at the
//       hardening doc;
//   (c) the flag setter/getter round-trips (the value decide() reads).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gps = geode.security.gps;

test "GAP-0842 (a): banner names all three disabled controls" {
    const banner = gps.insecureAllowAllBanner();

    // Tenant isolation, RLS, and FLE must each be called out by name so the
    // operator cannot miss which protections are off.
    try testing.expect(std.mem.indexOf(u8, banner, "Tenant isolation") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "Row-level security") != null or
        std.mem.indexOf(u8, banner, "RLS") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "Field-level encryption") != null or
        std.mem.indexOf(u8, banner, "FLE") != null);
}

test "GAP-0842 (b): banner warns NOT FOR PRODUCTION and references the hardening doc" {
    const banner = gps.insecureAllowAllBanner();
    try testing.expect(std.mem.indexOf(u8, banner, "NOT FOR PRODUCTION") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "MULTI_TENANT_HARDENING.md") != null);
    // The flag name itself must appear so a log search for it lands here.
    try testing.expect(std.mem.indexOf(u8, banner, "--insecure-allow-all") != null);
}

test "GAP-0842 (c): setInsecureAllowAll round-trips through isInsecureAllowAll" {
    // Default is OFF (fail-closed).
    gps.setInsecureAllowAll(false);
    try testing.expect(!gps.isInsecureAllowAll());

    gps.setInsecureAllowAll(true);
    try testing.expect(gps.isInsecureAllowAll());

    // Reset so this test does not leak the bypass into any other test that
    // shares the process-wide flag.
    gps.setInsecureAllowAll(false);
    try testing.expect(!gps.isInsecureAllowAll());
}
