// CANARY: REQ=REQ-DIST-CLI-001; FEATURE="DistributedClusterCLI"; ASPECT=ArgParsing; STATUS=TESTED; TEST=tests/test_cli_args_cluster.zig; OWNER=core; UPDATED=2026-05-25
// Unit tests for the --cluster-port and --peers CLI flags introduced by
// the distributed cluster testing plan (Task A1). These exercise the new
// `parseArgsFromSlice` entry point so the parser body can be tested
// without invoking `/proc/self/cmdline` / argv recovery.

const std = @import("std");
const cli_args = @import("cli_args");

test "--cluster-port parses to u16" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--cluster-port", "4242" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, 4242), cfg.cluster_port);
}

test "--peers splits on comma and owns each entry" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--peers", "127.0.0.1:4242,127.0.0.1:4243" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
    try std.testing.expectEqualStrings("127.0.0.1:4242", cfg.peers[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4243", cfg.peers[1]);
}

test "--peers with empty entries skips them" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--peers", "127.0.0.1:4242,,127.0.0.1:4243," };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
}

test "cluster_port defaults to null and peers defaults to empty slice" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{"geode"};
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, null), cfg.cluster_port);
    try std.testing.expectEqual(@as(usize, 0), cfg.peers.len);
}

test "--cluster-port with malformed value yields null" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--cluster-port", "not-a-number" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, null), cfg.cluster_port);
}

// ── ENG-3954 / #874 residual R1: brute-force lockout CLI flags ───────────────
//
// The per-IP lockout threshold and window (src/server/auth_rate_limiter.zig
// :66-93 `initFromEnv`, consumed at src/server/main.zig:1927) are reachable
// ONLY through GEODE_AUTH_RATE_MAX_ATTEMPTS / GEODE_AUTH_RATE_LOCKOUT_SECS.
// ENG-3954 expectation C requires them to be operator-configurable on the
// command line, following the `--strict-tenancy` precedent
// (src/server/cli_args.zig:57 field, :228 usage line, :402-404 parse arm,
// :440-450 env fallback).
//
// CONTRACT PINNED HERE:
//   ServerConfig gains two OPTIONAL integer fields, null = "operator said
//   nothing, fall through to env then default" (so
//   auth_rate_limiter.resolveConfig can apply flags > env > default):
//       auth_lockout_attempts : ?u32  <- --auth-lockout-attempts <n>
//       auth_lockout_secs     : ?u64  <- --auth-lockout-secs <n>
//   A malformed value parses to null rather than aborting startup, matching
//   the existing --cluster-port arm.
//
// RED at HEAD: neither field exists, so these fail with
// error.MissingAuthLockoutCliFlags. (@hasField-guarded rather than a direct
// field access on purpose: a compile error here would also break every other
// artifact that pulls this file in through all_tests.zig.)

fn hasAuthLockoutFlags() bool {
    return @hasField(cli_args.ServerConfig, "auth_lockout_attempts") and
        @hasField(cli_args.ServerConfig, "auth_lockout_secs");
}

test "--auth-lockout-attempts and --auth-lockout-secs parse into ServerConfig (ENG-3954)" {
    if (comptime !hasAuthLockoutFlags()) {
        return error.MissingAuthLockoutCliFlags;
    } else {
        const a = std.testing.allocator;
        const argv = [_][]const u8{ "geode", "--auth-lockout-attempts", "4", "--auth-lockout-secs", "30" };
        const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
        try std.testing.expect(maybe_cfg != null);
        var cfg = maybe_cfg.?;
        defer cfg.deinit(a);

        try std.testing.expect(cfg.auth_lockout_attempts != null);
        try std.testing.expectEqual(@as(u64, 4), @as(u64, cfg.auth_lockout_attempts.?));
        try std.testing.expect(cfg.auth_lockout_secs != null);
        try std.testing.expectEqual(@as(u64, 30), @as(u64, cfg.auth_lockout_secs.?));
    }
}

test "auth lockout flags default to null so env/defaults still apply (ENG-3954)" {
    if (comptime !hasAuthLockoutFlags()) {
        return error.MissingAuthLockoutCliFlags;
    } else {
        const a = std.testing.allocator;
        const argv = [_][]const u8{"geode"};
        const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
        try std.testing.expect(maybe_cfg != null);
        var cfg = maybe_cfg.?;
        defer cfg.deinit(a);

        try std.testing.expect(cfg.auth_lockout_attempts == null);
        try std.testing.expect(cfg.auth_lockout_secs == null);
    }
}

test "malformed auth lockout flag values yield null, not a startup abort (ENG-3954)" {
    if (comptime !hasAuthLockoutFlags()) {
        return error.MissingAuthLockoutCliFlags;
    } else {
        const a = std.testing.allocator;
        const argv = [_][]const u8{ "geode", "--auth-lockout-attempts", "not-a-number", "--auth-lockout-secs", "-5" };
        const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
        try std.testing.expect(maybe_cfg != null);
        var cfg = maybe_cfg.?;
        defer cfg.deinit(a);

        try std.testing.expect(cfg.auth_lockout_attempts == null);
        try std.testing.expect(cfg.auth_lockout_secs == null);
    }
}
