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
    mutex: std.Thread.Mutex = .{},
    /// Counter for periodic eviction of expired entries.
    record_count: u32 = 0,

    /// Default configuration constants.
    pub const default_max_attempts: u32 = 10;
    pub const default_lockout_duration_ns: u64 = 60 * std.time.ns_per_s; // 60 seconds

    /// Create a rate limiter with default thresholds.
    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithConfig(allocator, default_max_attempts, default_lockout_duration_ns);
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
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// Return true if the given IP is currently locked out.
    pub fn isLocked(self: *Self, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.isLockedUnlocked(ip);
    }

    /// Internal lock-free check (caller must hold mutex).
    fn isLockedUnlocked(self: *Self, ip: []const u8) bool {
        const entry = self.entries.get(ip) orelse return false;
        if (entry.lockout_until_ns == 0) return false;
        const now = std.time.nanoTimestamp();
        return now < entry.lockout_until_ns;
    }

    /// Record a failed authentication attempt for the given IP.
    /// If the failure count reaches `max_attempts`, the IP is locked out.
    /// Periodically evicts expired entries to prevent unbounded memory growth.
    pub fn recordFailure(self: *Self, ip: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Evict expired entries every 100 failures to bound memory growth
        self.record_count +%= 1;
        if (self.record_count % 100 == 0) {
            self.evictExpiredLocked();
        }

        const now = std.time.nanoTimestamp();

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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Evict entries whose lockout has expired.  Call periodically to
    /// prevent unbounded memory growth (e.g. from a maintenance timer).
    pub fn evictExpired(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.evictExpiredLocked();
    }

    /// Internal: evict expired entries while already holding the mutex.
    fn evictExpiredLocked(self: *Self) void {
        const now = std.time.nanoTimestamp();
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
        self.mutex.lock();
        defer self.mutex.unlock();
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

test "auth_rate_limiter: lockout expires after duration" {
    // Use a very short lockout (1 nanosecond) so it expires immediately.
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 1, 1);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.4");
    // The lockout is 1ns; by the time we check it should have expired.
    std.Thread.sleep(1000); // sleep 1 microsecond to be safe
    try std.testing.expect(!limiter.isLocked("10.0.0.4"));
}

test "auth_rate_limiter: evictExpired removes stale entries" {
    var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 1, 1);
    defer limiter.deinit();
    limiter.recordFailure("10.0.0.5");
    std.Thread.sleep(1000);
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
