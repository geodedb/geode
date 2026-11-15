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

// CANARY: REQ=REQ-SONNY-6600-CLUSTER-TOKEN-FULL-COMPARE; FEATURE="ClusterAuth"; ASPECT=FullLengthConstantTimeCompare; STATUS=TESTED; TEST=tests/test_sonny6600_cluster_token.zig; OWNER=security; UPDATED=2026-11-15
/// SEC-07 / SONNY-6600: constant-time comparison of the whole token. Both
/// inputs are hashed with SHA-256 and the fixed-size digests compared with
/// `timing_safe.eql`, so every byte of both tokens counts and the time taken
/// depends only on the two lengths, never on where they differ. It used to
/// compare 256-byte zero-padded copies: two tokens equal in their first 256
/// bytes (or a long token and its first 256 bytes) compared equal.
fn tokenEqlConstantTime(password: []const u8, expected: []const u8) bool {
    if (expected.len == 0 or password.len == 0) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256; // fips-exempt: non-security (digest used only to compare two tokens in constant time; not key material)
    var d_pw: [Sha256.digest_length]u8 = undefined;
    var d_ex: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(password, &d_pw, .{});
    Sha256.hash(expected, &d_ex, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, d_pw, d_ex); // fips-exempt: non-security (timing-safe memcmp of the two digests)
}

/// SONNY-6600: the shortest GEODE_CLUSTER_TOKEN / GEODE_CLUSTER_TOKEN_PREVIOUS
/// `geode serve` starts with (16 bytes: 128 bits if random; generate one with
/// `openssl rand -hex 32`).
pub const min_token_len: usize = 16;

pub const TokenConfigError = error{ ClusterTokenTooShort, ClusterTokenPreviousTooShort };

// CANARY: REQ=REQ-SONNY-6600-CLUSTER-TOKEN-CONFIG; FEATURE="ClusterAuth"; ASPECT=StartupTokenCheck; STATUS=TESTED; TEST=tests/test_sonny6600_cluster_token.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6600: the startup check of the configured cluster tokens (null:
/// the variable is not set). A token that is set must be at least
/// `min_token_len` bytes: GEODE_CLUSTER_TOKEN=t turned cluster mode on with a
/// one-byte shared secret. Set but empty is refused too (it authenticated
/// nothing, silently).
pub fn validateTokenConfig(primary: ?[]const u8, previous: ?[]const u8) TokenConfigError!void {
    if (primary) |p| if (p.len < min_token_len) return error.ClusterTokenTooShort;
    if (previous) |p| if (p.len < min_token_len) return error.ClusterTokenPreviousTooShort;
}

/// `validateTokenConfig` on the process environment.
pub fn validateClusterTokenEnv() TokenConfigError!void {
    return validateTokenConfig(posixGetenv("GEODE_CLUSTER_TOKEN"), posixGetenv("GEODE_CLUSTER_TOKEN_PREVIOUS"));
}

/// SEC-INFRA-03: Dual-token validation for zero-downtime bearer rotation.
/// Accepts the password if it matches the primary token OR the optional
/// previous token (overlap window). A null/empty primary never authenticates
/// — the previous token cannot keep cluster auth alive on its own.
/// Both comparisons use the full-length constant-time compare; both are evaluated
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
/// Uses a full-length constant-time comparison (SHA-256 digests compared
/// with timing_safe.eql) to prevent timing side-channels. Returns true only
/// if the password matches the primary token or (when set) the previous
/// token.
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

/// SEC-D011 / SONNY-6453: dial a cluster peer (raft, the cluster coordinator,
/// 2PC) with THE cluster transport configuration. `qc` is a
/// `*transport/quic.QuicClient` (or raft's test-build stub). Does not wait for
/// the handshake.
///
/// 1. GEODE_CLUSTER_INSECURE=1, honoured in Debug builds only
///    (`isInsecureModeAllowed`): connect without verification, with a warning.
/// 2. GEODE_CLUSTER_CA_CERT set: verify the peer's chain against that CA
///    bundle and its name against `host` (`QuicClient.connectEx`; a bundle
///    that cannot be loaded is an error).
/// 3. Neither: error.ClusterCaRequired. No CA is loaded from anywhere else
///    (there is no system bundle), so dialling could only fail the handshake.
// CANARY: REQ=REQ-CLUSTER-PEER-DIAL-001; FEATURE="ClusterAuth"; ASPECT=PeerTls; STATUS=TESTED; TEST=tests/test_sonny6453_cluster_peer_tls.zig; OWNER=security; UPDATED=2026-11-13
pub fn dialClusterPeer(qc: anytype, host: []const u8, port: u16) !void {
    if (isInsecureModeAllowed()) {
        log.warn("cluster peer TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
        return qc.connectInsecure(host, port, true);
    }
    const ca_path = posixGetenv("GEODE_CLUSTER_CA_CERT") orelse {
        log.err("cluster peer TLS: GEODE_CLUSTER_CA_CERT is not set; refusing to dial a peer unverified", &.{
            logging.Attr.string("host", host),
            logging.Attr.int("port", port),
        });
        return error.ClusterCaRequired;
    };
    return qc.connectEx(host, port, ca_path, null, null);
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
