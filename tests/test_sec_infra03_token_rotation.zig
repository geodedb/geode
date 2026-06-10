// SEC-INFRA-03 regression: cluster bearer token rotation.
//
// The cluster token was a single shared bearer secret with no rotation
// story — rotating it required a flag-day restart of every node at once.
// The fix adds an optional secondary token (GEODE_CLUSTER_TOKEN_PREVIOUS):
// inbound validation accepts EITHER token during the overlap window, while
// outbound HELLO/Raft/2PC frames always send the primary. Zero-downtime
// rotation procedure: on every node set PREVIOUS=<old> TOKEN=<new>, rolling
// restart, then drop PREVIOUS and rolling restart again.
//
// CANARY: REQ=REQ-SEC-INFRA-03-TOKEN-ROTATION; FEATURE="ClusterTokenRotation"; ASPECT=Regression; STATUS=TESTED; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const cluster_auth = @import("cluster_auth");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ---------------------------------------------------------------------------
// Pure validator (no environment) — validateTokenWithRotation
// ---------------------------------------------------------------------------

test "rotation: validator with primary+previous accepts both tokens" {
    try std.testing.expect(cluster_auth.validateTokenWithRotation("new-token", "new-token", "old-token"));
    try std.testing.expect(cluster_auth.validateTokenWithRotation("old-token", "new-token", "old-token"));
}

test "rotation: validator with primary+previous rejects a third value" {
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("third-token", "new-token", "old-token"));
}

test "rotation: validator with only primary rejects the previous value" {
    try std.testing.expect(cluster_auth.validateTokenWithRotation("new-token", "new-token", null));
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("old-token", "new-token", null));
}

test "rotation: empty password is always rejected" {
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("", "new-token", "old-token"));
}

test "rotation: empty primary never authenticates (even with previous set)" {
    // An empty primary means "no cluster auth configured" — the previous
    // token must NOT keep the door open on its own.
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("old-token", null, "old-token"));
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("old-token", "", "old-token"));
}

test "rotation: empty previous token never matches an empty password" {
    try std.testing.expect(!cluster_auth.validateTokenWithRotation("", "new-token", ""));
}

test "rotation: tokens longer than the 256-byte pad still compare correctly" {
    const long_a = "x" ** 300;
    const long_b = "x" ** 299 ++ "y";
    // Same token matches itself.
    try std.testing.expect(cluster_auth.validateTokenWithRotation(long_a, long_a, null));
    // NOTE: bytes beyond the 256-byte constant-time pad window are not
    // compared (documented SEC-07 behavior) — both inputs differ only at
    // byte 299, so they compare equal within the window. Pin that behavior
    // so a future pad-size change is a conscious decision.
    try std.testing.expect(cluster_auth.validateTokenWithRotation(long_b, long_a, null));
}

// ---------------------------------------------------------------------------
// Environment-backed validator — validateClusterToken
// ---------------------------------------------------------------------------

test "env: overlap window accepts both primary and previous, rejects others" {
    _ = setenv("GEODE_CLUSTER_TOKEN", "rot-new-token", 1);
    _ = setenv("GEODE_CLUSTER_TOKEN_PREVIOUS", "rot-old-token", 1);
    defer {
        _ = unsetenv("GEODE_CLUSTER_TOKEN");
        _ = unsetenv("GEODE_CLUSTER_TOKEN_PREVIOUS");
    }

    try std.testing.expect(cluster_auth.validateClusterToken("rot-new-token"));
    try std.testing.expect(cluster_auth.validateClusterToken("rot-old-token"));
    try std.testing.expect(!cluster_auth.validateClusterToken("rot-other-token"));
    try std.testing.expect(!cluster_auth.validateClusterToken(""));
}

test "env: after dropping PREVIOUS the old token is rejected" {
    _ = setenv("GEODE_CLUSTER_TOKEN", "rot-new-token", 1);
    _ = unsetenv("GEODE_CLUSTER_TOKEN_PREVIOUS");
    defer _ = unsetenv("GEODE_CLUSTER_TOKEN");

    try std.testing.expect(cluster_auth.validateClusterToken("rot-new-token"));
    try std.testing.expect(!cluster_auth.validateClusterToken("rot-old-token"));
}

test "env: PREVIOUS alone (no primary) does not activate auth" {
    _ = unsetenv("GEODE_CLUSTER_TOKEN");
    _ = setenv("GEODE_CLUSTER_TOKEN_PREVIOUS", "rot-old-token", 1);
    defer _ = unsetenv("GEODE_CLUSTER_TOKEN_PREVIOUS");

    // GEODE_CLUSTER_TOKEN absent == standalone mode; the previous token
    // must not authenticate anything on its own.
    try std.testing.expect(!cluster_auth.validateClusterToken("rot-old-token"));
}

test "env: outbound HELLO always sends the primary token" {
    _ = setenv("GEODE_CLUSTER_TOKEN", "rot-new-token", 1);
    _ = setenv("GEODE_CLUSTER_TOKEN_PREVIOUS", "rot-old-token", 1);
    defer {
        _ = unsetenv("GEODE_CLUSTER_TOKEN");
        _ = unsetenv("GEODE_CLUSTER_TOKEN_PREVIOUS");
    }

    const req = try cluster_auth.buildClusterHelloRequest(std.testing.allocator);
    defer std.testing.allocator.free(req.password);
    try std.testing.expectEqualStrings("geode-cluster", req.username);
    try std.testing.expectEqualStrings("rot-new-token", req.password);
}
