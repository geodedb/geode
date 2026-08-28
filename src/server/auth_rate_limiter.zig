// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2025 CodePros

//! Per-IP authentication rate limiter for QUIC HELLO handler.
//!
//! Tracks failed authentication attempts per source IP address and enforces
//! a lockout period after too many failures.  This prevents brute-force
//! password attacks even when an attacker rotates usernames.
//!
//! Thread-safe: all public methods acquire the internal mutex.
//!
//! CANARY: REQ=REQ-SEC-RATE-LIMIT-001; FEATURE="AuthRateLimiting"; ASPECT=PerIPRateLimit; STATUS=TESTED; TEST=auth_rate_limiter_tests; OWNER=security; UPDATED=2026-03-26

const std = @import("std");

// Zig 0.16 compat: std.time.nanoTimestamp removed.
fn compat_nanoTimestamp() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Per-IP authentication rate limiter.
///
/// Enforces a configurable maximum number of failed authentication attempts
/// per source IP address.  Once the threshold is exceeded the IP is locked
/// out for `lockout_duration_ns` nanoseconds.  A successful authentication
/// resets the counter for that IP.
pub const AuthRateLimiter = struct {
    const Self = @This();

    /// Per-IP tracking entry.
    pub const Entry = struct {
        failed_attempts: u32 = 0,
        last_failure_ns: i128 = 0,
        lockout_until_ns: i128 = 0,
    };

    /// Maximum failed attempts before an IP is locked out.
    max_attempts: u32,
    /// Duration of the lockout window in nanoseconds.
    lockout_duration_ns: u64,
    entries: std.StringHashMap(Entry),
    /// Keys that this map owns (heap-duped IP strings).
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Counter for periodic eviction of expired entries.
    record_count: u32 = 0,

    /// Default configuration constants.
    pub const default_max_attempts: u32 = 10;
    pub const default_lockout_duration_ns: u64 = 60 * std.time.ns_per_s; // 60 seconds

    /// Create a rate limiter with default thresholds.
    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithConfig(allocator, default_max_attempts, default_lockout_duration_ns);
    }

    /// Create a rate limiter, honoring two optional env overrides:
    ///   GEODE_AUTH_RATE_LOCKOUT_SECS  — lockout window in whole seconds
    ///   GEODE_AUTH_RATE_MAX_ATTEMPTS  — failures before lockout
    /// Both fall back to the defaults when unset or unparseable. The lockout
    /// override exists so the harness can exercise the expiry path with a
    /// 1-second window instead of waiting the production 60 s.
    /// CANARY: REQ=REQ-AUTH-RATE-ENV-001; FEATURE="AuthRateLimiterEnvConfig"; ASPECT=LockoutOverride; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-05-22
    pub fn initFromEnv(allocator: std.mem.Allocator) Self {
        var max_attempts = default_max_attempts;
        var lockout_ns = default_lockout_duration_ns;

        if (readEnvU64("GEODE_AUTH_RATE_MAX_ATTEMPTS")) |v| {
            if (v > 0 and v <= std.math.maxInt(u32)) max_attempts = @intCast(v);
        }
        if (readEnvU64("GEODE_AUTH_RATE_LOCKOUT_SECS")) |secs| {
            if (secs > 0 and secs <= 86_400) lockout_ns = secs * std.time.ns_per_s;
        }
        return initWithConfig(allocator, max_attempts, lockout_ns);
    }

    /// Parse a positive integer from a process env var. Returns null when the
    /// var is unset or not a clean decimal integer. Uses the libc getenv
    /// (Zig 0.16 removed std.process.getEnvVarOwned / std.posix.getenv) with a
    /// NUL-terminated name — the var names here are comptime string literals.
    fn readEnvU64(name: []const u8) ?u64 {
        var name_buf: [64]u8 = undefined;
        if (name.len >= name_buf.len) return null;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const ptr = std.c.getenv(name_buf[0..name.len :0]) orelse return null;
        const raw = std.mem.span(ptr);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }

    /// Create a rate limiter with custom thresholds (useful for testing).
    pub fn initWithConfig(allocator: std.mem.Allocator, max_attempts: u32, lockout_duration_ns: u64) Self {
        return .{
            .max_attempts = max_attempts,
            .lockout_duration_ns = lockout_duration_ns,
            .entries = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *Self) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// Return true if the given IP is currently locked out.
    pub fn isLocked(self: *Self, ip: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.isLockedUnlocked(ip);
    }

    /// Internal lock-free check (caller must hold mutex).
    fn isLockedUnlocked(self: *Self, ip: []const u8) bool {
        const entry = self.entries.get(ip) orelse return false;
        if (entry.lockout_until_ns == 0) return false;
        const now = compat_nanoTimestamp();
        return now < entry.lockout_until_ns;
    }

    /// Record a failed authentication attempt for the given IP.
    /// If the failure count reaches `max_attempts`, the IP is locked out.
    /// Periodically evicts expired entries to prevent unbounded memory growth.
    pub fn recordFailure(self: *Self, ip: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Evict expired entries every 100 failures to bound memory growth
        self.record_count +%= 1;
        if (self.record_count % 100 == 0) {
            self.evictExpiredLocked();
        }

        const now = compat_nanoTimestamp();

        if (self.entries.getPtr(ip)) |entry| {
            // If an existing lockout has expired, reset before counting.
            if (entry.lockout_until_ns != 0 and now >= entry.lockout_until_ns) {
                entry.* = .{};
            }
            entry.failed_attempts += 1;
            entry.last_failure_ns = now;
            if (entry.failed_attempts >= self.max_attempts) {
                entry.lockout_until_ns = now + @as(i128, self.lockout_duration_ns);
            }
        } else {
            // First failure for this IP -- insert a new entry.
            const owned_key = self.allocator.dupe(u8, ip) catch return;
            self.entries.put(owned_key, .{
                .failed_attempts = 1,
                .last_failure_ns = now,
                .lockout_until_ns = 0,
            }) catch {
                self.allocator.free(owned_key);
            };
        }
    }

    /// Record a successful authentication, resetting the failure counter.
    pub fn recordSuccess(self: *Self, ip: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.entries.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Evict entries whose lockout has expired.  Call periodically to
    /// prevent unbounded memory growth (e.g. from a maintenance timer).
    pub fn evictExpired(self: *Self) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.evictExpiredLocked();
    }

    /// Internal: evict expired entries while already holding the mutex.
    fn evictExpiredLocked(self: *Self) void {
        const now = compat_nanoTimestamp();
        // Collect keys to remove (cannot mutate while iterating).
        var to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return;
        defer to_remove.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            const entry = kv.value_ptr.*;
            const cutoff = now - @as(i128, self.lockout_duration_ns);
            if (entry.lockout_until_ns != 0 and now >= entry.lockout_until_ns) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch continue;
            } else if (entry.lockout_until_ns == 0 and entry.last_failure_ns < cutoff) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    /// Return the number of tracked IPs (for diagnostics / tests).
    pub fn count(self: *Self) usize {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.entries.count();
    }
};

// ── Global singleton accessor ──────────────────────────────────────────
// Allows multiple transports (QUIC, gRPC) to share the same rate limiter.

var g_global_rate_limiter: ?*AuthRateLimiter = null;

/// Set the global authentication rate limiter (called during server startup).
pub fn setGlobalRateLimiter(limiter: ?*AuthRateLimiter) void {
    g_global_rate_limiter = limiter;
}

/// Get the global authentication rate limiter (used by all transports).
pub fn getGlobalRateLimiter() ?*AuthRateLimiter {
    return g_global_rate_limiter;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "auth_rate_limiter: new IP is not locked" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 1 * std.time.ns_per_s);
    defer limiter.deinit();
    try std.testing.expect(!limiter.isLocked("192.168.1.1"));
}

test "auth_rate_limiter: failures below threshold do not lock" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 1 * std.time.ns_per_s);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.1");
    limiter.recordFailure("10.0.0.1");
    try std.testing.expect(!limiter.isLocked("10.0.0.1"));
}

test "auth_rate_limiter: reaching threshold locks IP" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.2");
    limiter.recordFailure("10.0.0.2");
    limiter.recordFailure("10.0.0.2");
    try std.testing.expect(limiter.isLocked("10.0.0.2"));
}

test "auth_rate_limiter: success resets counter" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.3");
    limiter.recordFailure("10.0.0.3");
    limiter.recordSuccess("10.0.0.3");
    // After reset the IP should not be locked, and we can fail again
    try std.testing.expect(!limiter.isLocked("10.0.0.3"));
    limiter.recordFailure("10.0.0.3");
    limiter.recordFailure("10.0.0.3");
    try std.testing.expect(!limiter.isLocked("10.0.0.3"));
}

test "auth_rate_limiter: different IPs are independent" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 2, 60 * std.time.ns_per_s);
    defer limiter.deinit();
    limiter.recordFailure("1.1.1.1");
    limiter.recordFailure("1.1.1.1");
    try std.testing.expect(limiter.isLocked("1.1.1.1"));
    try std.testing.expect(!limiter.isLocked("2.2.2.2"));
}

// Zig 0.16: std.Thread.sleep was removed — linux nanosleep compat shim
// (test-only; mirrors the shape used by repl_dispatch.zig / proto_test_util.zig).
fn testSleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

test "auth_rate_limiter: lockout expires after duration" {
    // Use a very short lockout (1 nanosecond) so it expires immediately.
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 1, 1);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.4");
    // The lockout is 1ns; by the time we check it should have expired.
    testSleepNs(1000); // sleep 1 microsecond to be safe
    try std.testing.expect(!limiter.isLocked("10.0.0.4"));
}

test "auth_rate_limiter: evictExpired removes stale entries" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 1, 1);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.5");
    testSleepNs(1000);
    limiter.evictExpired();
    try std.testing.expectEqual(@as(usize, 0), limiter.count());
}

test "auth_rate_limiter: count tracks entries" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 5, 60 * std.time.ns_per_s);
    defer limiter.deinit();
    try std.testing.expectEqual(@as(usize, 0), limiter.count());
    limiter.recordFailure("a");
    try std.testing.expectEqual(@as(usize, 1), limiter.count());
    limiter.recordFailure("b");
    try std.testing.expectEqual(@as(usize, 2), limiter.count());
    limiter.recordSuccess("a");
    try std.testing.expectEqual(@as(usize, 1), limiter.count());
}

// ── ENG-3954 / #874: auth-lockout misclassification regression ─────────
//
// TRIAGE (current main): the per-IP limiter is fed by TWO handler sites that
// cannot tell a checked-and-rejected credential from a "we could not check"
// outcome, so an unreachable / not-yet-hydrated security store locks legitimate
// clients out of their own server:
//
//   src/server/quic_connection_handler.zig:5753  authenticate(...) catch {
//                                                    limiter.recordFailure(ip); }
//   src/transport/grpc_server.zig:1469           (exact parity)
//     A bare catch-all: error.OutOfMemory, a store-lock miss, a quarantined
//     `__geode_security` graph — every one of them increments the counter.
//
//   src/server/quic_connection_handler.zig:5740  empty username OR password
//   src/transport/grpc_server.zig:1455           (exact parity)
//     A truncated / half-open HELLO deserializes to proto3 defaults ("" / "")
//     and calls recordFailure with NO credential check at all.
//
//   src/security/user_management.zig:739-750 authenticate() returns
//   error.Unauthenticated for BOTH "wrong password" and "the persistent
//   resolver could not answer" (null flows :1117 ensureUserCached -> :1223
//   getAuthSnapshot -> Unauthenticated), because
//   src/storage/user_storage.zig:517 findUserByUsernameInGraph returns
//   ?UserRecord and collapses every failure mode to null.
//
// Ten of those non-credential events (default_max_attempts = 10, keyed on
// peer_ip alone) lock the IP for 60 s, and because the infrastructure fault
// persists the lock is re-armed on every retry.
//
// THE CONTRACT THESE TESTS PIN (the fix must supply the two pure predicates
// below in THIS module — it is the one place both transports already share, so
// the policy is not duplicated into two handlers that can drift):
//
//   pub fn shouldCountFailedAttempt(err: anyerror) bool
//       true ONLY when the credentials were actually checked and rejected
//       (error.Unauthenticated). false for every "could not check" outcome:
//       error.AuthUnavailable (the new distinguishable error authenticate()
//       must return when the security store cannot answer), error.OutOfMemory,
//       and any other infrastructure error — default-deny on COUNTING, because
//       counting a server-side fault is what locks out honest users.
//
//   pub fn credentialsPresent(username: []const u8, password: []const u8) bool
//       false when either side is empty. An empty-credential HELLO is
//       MALFORMED, not a failed credential check, and must never reach the
//       limiter.
//
// RED at HEAD: neither declaration exists, so these tests fail with
// error.MissingAuthOutcomeClassifier / error.MissingCredentialPresencePredicate.

test "auth_rate_limiter: only a checked-and-rejected credential counts as a failed attempt (ENG-3954)" {
    const M = @This();
    if (comptime !@hasDecl(M, "shouldCountFailedAttempt")) {
        return error.MissingAuthOutcomeClassifier;
    } else {
        // Checked and rejected -> counts.
        try std.testing.expect(M.shouldCountFailedAttempt(error.Unauthenticated));

        // "Could not check" -> must NOT count.
        try std.testing.expect(!M.shouldCountFailedAttempt(error.AuthUnavailable));
        try std.testing.expect(!M.shouldCountFailedAttempt(error.OutOfMemory));

        // Any other infrastructure error is also "could not check": the
        // classifier must default to NOT counting rather than counting
        // everything it does not recognise (the bare-catch bug).
        try std.testing.expect(!M.shouldCountFailedAttempt(error.Unexpected));
        try std.testing.expect(!M.shouldCountFailedAttempt(error.BrokenPipe));
        try std.testing.expect(!M.shouldCountFailedAttempt(error.AccessDenied));
    }
}

test "auth_rate_limiter: empty HELLO credentials are malformed, not a failed attempt (ENG-3954)" {
    const M = @This();
    if (comptime !@hasDecl(M, "credentialsPresent")) {
        return error.MissingCredentialPresencePredicate;
    } else {
        // proto3 defaults from a truncated / half-open HELLO.
        try std.testing.expect(!M.credentialsPresent("", ""));
        try std.testing.expect(!M.credentialsPresent("alice", ""));
        try std.testing.expect(!M.credentialsPresent("", "hunter2"));

        // A well-formed HELLO carries both sides and IS eligible for a check.
        try std.testing.expect(M.credentialsPresent("alice", "hunter2"));
    }
}

test "auth_rate_limiter: non-credential outcomes never lock an IP, real rejections still do (ENG-3954)" {
    const M = @This();
    if (comptime !@hasDecl(M, "shouldCountFailedAttempt") or !@hasDecl(M, "credentialsPresent")) {
        return error.MissingAuthOutcomeClassifier;
    } else {
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
        defer limiter.deinit();
        const ip = "203.0.113.7";

        // 1) The security store is down / not hydrated. authenticate() returns
        //    error.AuthUnavailable. Far more than max_attempts of these must
        //    leave the IP untouched — this is the exact loop that bricks a
        //    client today.
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            if (M.shouldCountFailedAttempt(error.AuthUnavailable)) limiter.recordFailure(ip);
        }
        try std.testing.expect(!limiter.isLocked(ip));
        try std.testing.expectEqual(@as(usize, 0), limiter.count());

        // 2) Truncated HELLOs (proto3 defaults) — never even reach authenticate.
        i = 0;
        while (i < 30) : (i += 1) {
            if (M.credentialsPresent("", "")) {
                if (M.shouldCountFailedAttempt(error.Unauthenticated)) limiter.recordFailure(ip);
            }
        }
        try std.testing.expect(!limiter.isLocked(ip));
        try std.testing.expectEqual(@as(usize, 0), limiter.count());

        // 3) Allocation failure inside the auth path is a server problem.
        i = 0;
        while (i < 30) : (i += 1) {
            if (M.shouldCountFailedAttempt(error.OutOfMemory)) limiter.recordFailure(ip);
        }
        try std.testing.expect(!limiter.isLocked(ip));

        // 4) Brute force is STILL stopped: real checked-and-rejected
        //    credentials reach the threshold and lock the IP.
        i = 0;
        while (i < 3) : (i += 1) {
            if (M.credentialsPresent("alice", "wrong")) {
                if (M.shouldCountFailedAttempt(error.Unauthenticated)) limiter.recordFailure(ip);
            }
        }
        try std.testing.expect(limiter.isLocked(ip));
    }
}

test "auth_rate_limiter: a persistent store outage does not re-arm the lockout forever (ENG-3954)" {
    const M = @This();
    if (comptime !@hasDecl(M, "shouldCountFailedAttempt")) {
        return error.MissingAuthOutcomeClassifier;
    } else {
        // 1 ns lockout so the window expires immediately; the point is that a
        // sustained outage must never RE-arm it, which is what turns a 60 s
        // lockout into a permanent one for a client whose credentials are fine.
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 2, 1);
        defer limiter.deinit();
        const ip = "198.51.100.9";

        // A real brute-force burst locks the IP...
        limiter.recordFailure(ip);
        limiter.recordFailure(ip);
        testSleepNs(1000);
        try std.testing.expect(!limiter.isLocked(ip)); // ...and expires.

        // ...but a stream of store-unavailable outcomes must not re-lock it,
        // so the client is free to retry the moment the store recovers.
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (M.shouldCountFailedAttempt(error.AuthUnavailable)) limiter.recordFailure(ip);
        }
        try std.testing.expect(!limiter.isLocked(ip));

        // And a successful authentication always clears the counter outright.
        limiter.recordSuccess(ip);
        try std.testing.expect(!limiter.isLocked(ip));
        try std.testing.expectEqual(@as(usize, 0), limiter.count());
    }
}
