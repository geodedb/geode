const std = @import("std");
const builtin = @import("builtin");

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const schema = @import("schema");

const logging = @import("logging");
const log = logging.scoped("cluster_auth");

// CANARY: REQ=REQ-CLUSTER-AUTH-001; FEATURE="ClusterAuth"; ASPECT=SharedModule; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01

/// SEC-07: Constant-time token comparison with 256-byte padded buffers.
/// No early length check — pad both to 256 bytes and compare in constant time.
/// Different lengths produce different zero-padded buffers, caught by
/// timing_safe.eql without leaking which input was shorter. Bytes beyond the
/// 256-byte pad window are not compared (documented; pinned by the
/// SEC-INFRA-03 regression test).
fn tokenEqlConstantTime(password: []const u8, expected: []const u8) bool {
    if (expected.len == 0 or password.len == 0) return false;
    var buf_a: [256]u8 = [_]u8{0} ** 256;
    var buf_b: [256]u8 = [_]u8{0} ** 256;
    const n_pw = @min(password.len, 256);
    const n_ex = @min(expected.len, 256);
    @memcpy(buf_a[0..n_pw], password[0..n_pw]);
    @memcpy(buf_b[0..n_ex], expected[0..n_ex]);
    return std.crypto.timing_safe.eql([256]u8, buf_a, buf_b);
}

/// SEC-INFRA-03: Dual-token validation for zero-downtime bearer rotation.
/// Accepts the password if it matches the primary token OR the optional
/// previous token (overlap window). A null/empty primary never authenticates
/// — the previous token cannot keep cluster auth alive on its own.
/// Both comparisons use the constant-time padded compare; both are evaluated
/// unconditionally so timing does not reveal which token matched.
// CANARY: REQ=REQ-SEC-INFRA-03-TOKEN-ROTATION; FEATURE="ClusterTokenRotation"; ASPECT=DualTokenValidation; STATUS=TESTED; OWNER=security; UPDATED=2026-06-10
pub fn validateTokenWithRotation(password: []const u8, primary: ?[]const u8, previous: ?[]const u8) bool {
    const primary_tok = primary orelse return false;
    if (primary_tok.len == 0) return false;
    const matches_primary = tokenEqlConstantTime(password, primary_tok);
    const matches_previous = if (previous) |prev| tokenEqlConstantTime(password, prev) else false;
    return matches_primary or matches_previous;
}

/// Validate a cluster token password against the GEODE_CLUSTER_TOKEN
/// environment variable, with SEC-INFRA-03 rotation support: during a
/// rotation overlap window, GEODE_CLUSTER_TOKEN_PREVIOUS (the pre-rotation
/// token) is also accepted on inbound validation. Outbound paths
/// (buildClusterHelloRequest, Raft/2PC envelopes) always send the primary.
///
/// Zero-downtime rotation procedure — 3 phases (see src/distributed/README.md).
/// A node only picks up new env values on restart, so the accept-both phase
/// must complete on every node BEFORE any node starts sending the new token:
///   A. GEODE_CLUSTER_TOKEN=<old>, GEODE_CLUSTER_TOKEN_PREVIOUS=<new>;
///      rolling restart (everyone accepts both, still sends old).
///   B. GEODE_CLUSTER_TOKEN=<new>, GEODE_CLUSTER_TOKEN_PREVIOUS=<old>;
///      rolling restart (senders switch to new; old still accepted).
///   C. Drop GEODE_CLUSTER_TOKEN_PREVIOUS; rolling restart.
///
/// Uses constant-time comparison with 256-byte padded buffers to prevent
/// timing side-channels. Returns true only if the password matches the
/// primary token or (when set) the previous token.
pub fn validateClusterToken(password: []const u8) bool {
    const primary = posixGetenv("GEODE_CLUSTER_TOKEN");
    const previous: ?[]const u8 = if (posixGetenv("GEODE_CLUSTER_TOKEN_PREVIOUS")) |p| p else null;
    return validateTokenWithRotation(password, primary, previous);
}

/// Build a HELLO request for inter-node cluster authentication.
/// Reads GEODE_CLUSTER_TOKEN from environment and sends as the "geode-cluster" user.
/// Falls back to empty credentials if the token is not set (with warning).
pub fn buildClusterHelloRequest(allocator: std.mem.Allocator) !schema.HelloRequest {
    const token = posixGetenv("GEODE_CLUSTER_TOKEN") orelse {
        log.warn("GEODE_CLUSTER_TOKEN not set — inter-node connections may be rejected by auth-enabled nodes", &.{});
        return schema.HelloRequest{
            .username = "",
            .password = "",
            .tenant_id = null,
            .client_name = "geode-cluster",
            .client_version = "",
            .wanted_conformance = "",
        };
    };
    const password_copy = try allocator.dupe(u8, token);
    return schema.HelloRequest{
        .username = "geode-cluster",
        .password = password_copy,
        .tenant_id = null,
        .client_name = "geode-cluster",
        .client_version = "",
        .wanted_conformance = "",
    };
}

/// Check whether insecure mode (no TLS verification) is explicitly allowed.
///
/// GAP-0737 / SEC-INFRA-01 (2026-04-16):
///   - In a Debug build, returns true iff GEODE_CLUSTER_INSECURE=1.
///   - In ReleaseSafe / ReleaseFast / ReleaseSmall, ALWAYS returns false.
///     Even if the env var is set, the release build ignores it AND logs
///     a one-shot warning + increments `geode_cluster_insecure_total` so
///     operators can detect misconfiguration attempts.
///
/// The previous behaviour allowed anyone who could set an environment
/// variable on the server host to turn off TLS verification on a
/// production node — and because the check happened in six different
/// modules (federation, raft, 2pc, query-transport, cluster, cluster_auth),
/// it was easy to miss.  This single gate is the chokepoint; the caller
/// modules MUST go through here.
pub fn isInsecureModeAllowed() bool {
    const val = posixGetenv("GEODE_CLUSTER_INSECURE") orelse return false;
    const requested = std.mem.eql(u8, val, "1");
    if (!requested) return false;

    if (builtin.mode != .Debug) {
        // Release path: refuse, but emit a one-shot warning so the
        // misconfiguration is observable in logs / audit / metrics.
        logInsecureRefusalOnce();
        return false;
    }
    // Debug path: allow.
    return true;
}

/// Monotonic counter of refused insecure-cluster attempts (exposed via
/// metrics).  A Prometheus scrape or admin CLI can expose this so ops
/// alerts fire when someone tries to flip the bit in release.
///
/// CANARY: REQ=REQ-SEC-INFRA-01-METRIC; FEATURE="InsecureRefusalMetric"; ASPECT=Metrics; STATUS=IMPL; OWNER=security; UPDATED=2026-04-16
pub var geode_cluster_insecure_refused_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var insecure_warn_logged: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn logInsecureRefusalOnce() void {
    _ = geode_cluster_insecure_refused_total.fetchAdd(1, .monotonic);
    // Emit the stderr warning at most once per process.
    if (insecure_warn_logged.swap(true, .monotonic)) return;
    log.warn(
        "GAP-0737 SEC-INFRA-01: refusing GEODE_CLUSTER_INSECURE=1 in release build — use a Debug build if you really need insecure cluster transport",
        &.{},
    );
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "validateClusterToken rejects empty password" {
    // With no GEODE_CLUSTER_TOKEN set (default in test environment), should return false
    const result = validateClusterToken("");
    try std.testing.expect(!result);
}

test "validateClusterToken rejects arbitrary password when no token set" {
    const result = validateClusterToken("some-random-token-value");
    try std.testing.expect(!result);
}

test "isInsecureModeAllowed returns false when env not set" {
    // In test environment GEODE_CLUSTER_INSECURE is not set
    const result = isInsecureModeAllowed();
    try std.testing.expect(!result);
}

test "buildClusterHelloRequest returns empty credentials when no token set" {
    const req = try buildClusterHelloRequest(std.testing.allocator);
    // No allocation to free since token was not set — password is ""
    try std.testing.expectEqualStrings("", req.username);
    try std.testing.expectEqualStrings("", req.password);
    try std.testing.expectEqualStrings("geode-cluster", req.client_name);
}
