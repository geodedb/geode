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
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.REALTIME, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
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

    /// Which bucket denied a principal (ENG-3954 RC-3). Lets the denial log,
    /// the admin escape hatch, and any metric label tell "this account is being
    /// guessed" (`principal`) apart from "this NAT egress is spraying"
    /// (`ip_ceiling`) — the exact call field triage could not make.
    pub const DenialReason = enum { principal, ip_ceiling };

    /// Maximum failed attempts before an IP is locked out.
    max_attempts: u32,
    /// COARSE per-IP ceiling counted across ALL usernames (ENG-3954 RC-1c).
    /// Bounds a username-rotating password-spray without catching a bystander,
    /// so it MUST stay strictly above `max_attempts`; otherwise per-principal
    /// keying buys nothing (the ceiling would fire at the same count).
    ip_max_attempts: u32,
    /// Duration of the lockout window in nanoseconds.
    lockout_duration_ns: u64,
    /// Legacy IP-only buckets (keyed on the bare peer-IP string). Retained so
    /// the pre-existing `isLocked`/`recordFailure`/`recordSuccess` semantics are
    /// unchanged during the migration to the principal-keyed surface.
    entries: std.StringHashMap(Entry),
    /// Principal buckets keyed on the (ip, username) pair — the composite key is
    /// `ip ++ "\x00" ++ username`. Threshold is `max_attempts` (ENG-3954 RC-1).
    principal_entries: std.StringHashMap(Entry),
    /// Coarse per-IP ceiling buckets keyed on the bare peer-IP string. Threshold
    /// is `ip_max_attempts` (ENG-3954 RC-1c). Kept apart from `entries` so the
    /// two thresholds never collide on one shared entry.
    ip_ceiling_entries: std.StringHashMap(Entry),
    /// Keys that this map owns (heap-duped IP strings).
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Counter for periodic eviction of expired entries.
    record_count: u32 = 0,

    /// Default configuration constants.
    pub const default_max_attempts: u32 = 10;
    /// Default coarse per-IP ceiling. Strictly above `default_max_attempts` so
    /// the reproduced burst (10 failures for a single bogus username) locks that
    /// principal WITHOUT collaterally locking every other user on the IP.
    pub const default_ip_max_attempts: u32 = 50;
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
        // Same resolution the operator-facing flags use, with no CLI values
        // supplied — env > default. Keeping one resolver means the precedence
        // cannot drift between the bootstrap path and the flags.
        const cfg = resolveConfig(null, null);
        return initWithConfig(allocator, cfg.max_attempts, cfg.lockout_duration_ns);
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
            // Strictly above `max_attempts` for every configuration: 5x
            // (saturating) keeps the invariant even for an operator-raised
            // threshold, and the floor of `default_ip_max_attempts` keeps a
            // small threshold from producing a ceiling that catches a bystander.
            .ip_max_attempts = @max(default_ip_max_attempts, max_attempts *| 5),
            .lockout_duration_ns = lockout_duration_ns,
            .entries = std.StringHashMap(Entry).init(allocator),
            .principal_entries = std.StringHashMap(Entry).init(allocator),
            .ip_ceiling_entries = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *Self) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        freeAllKeys(&self.entries, self.allocator);
        freeAllKeys(&self.principal_entries, self.allocator);
        freeAllKeys(&self.ip_ceiling_entries, self.allocator);
        self.entries.deinit();
        self.principal_entries.deinit();
        self.ip_ceiling_entries.deinit();
    }

    /// Free every owned key in a bucket map (composite or IP), then leave it
    /// ready for `deinit`.
    fn freeAllKeys(map: *std.StringHashMap(Entry), allocator: std.mem.Allocator) void {
        var iter = map.iterator();
        while (iter.next()) |kv| {
            allocator.free(kv.key_ptr.*);
        }
    }

    /// Return true if the given IP is currently locked out.
    pub fn isLocked(self: *Self, ip: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.isLockedUnlocked(ip);
    }

    /// Internal lock-free check (caller must hold mutex).
    fn isLockedUnlocked(self: *Self, ip: []const u8) bool {
        return bucketLocked(&self.entries, ip, compat_nanoTimestamp());
    }

    /// Whether a single bucket in `map` under `key` is currently locked.
    fn bucketLocked(map: *std.StringHashMap(Entry), key: []const u8, now: i128) bool {
        const entry = map.get(key) orelse return false;
        if (entry.lockout_until_ns == 0) return false;
        return now < entry.lockout_until_ns;
    }

    /// Remaining lockout time for a bucket, or null when it is not locked.
    fn bucketRemainingNs(map: *std.StringHashMap(Entry), key: []const u8, now: i128) ?u64 {
        const entry = map.get(key) orelse return null;
        if (entry.lockout_until_ns == 0 or now >= entry.lockout_until_ns) return null;
        return @intCast(entry.lockout_until_ns - now);
    }

    /// Record a failure against one bucket, applying the ANCHORED lockout window
    /// (ENG-3954 RC-2): a failure that lands while the bucket is ALREADY locked
    /// still counts but must NEVER push `lockout_until_ns` forward, so sustained
    /// guessing cannot turn a fixed window into an indefinite one. The
    /// post-expiry reset-and-recount is preserved. `key` is duplicated on first
    /// insertion and owned by `map`.
    fn recordFailureInBucket(self: *Self, map: *std.StringHashMap(Entry), key: []const u8, threshold: u32, now: i128) void {
        if (map.getPtr(key)) |entry| {
            if (entry.lockout_until_ns != 0) {
                if (now >= entry.lockout_until_ns) {
                    // The window elapsed: reset and recount from scratch.
                    entry.* = .{};
                    entry.failed_attempts += 1;
                    entry.last_failure_ns = now;
                    if (entry.failed_attempts >= threshold) {
                        entry.lockout_until_ns = now + @as(i128, @intCast(self.lockout_duration_ns));
                    }
                } else {
                    // ANCHORED: still locked — count, but leave the deadline put.
                    entry.failed_attempts +|= 1;
                    entry.last_failure_ns = now;
                }
            } else {
                entry.failed_attempts += 1;
                entry.last_failure_ns = now;
                if (entry.failed_attempts >= threshold) {
                    entry.lockout_until_ns = now + @as(i128, @intCast(self.lockout_duration_ns));
                }
            }
        } else {
            // First failure for this key -- insert a new entry (never arms on the
            // first failure, matching the long-standing IP-only behaviour).
            const owned_key = self.allocator.dupe(u8, key) catch return;
            map.put(owned_key, .{
                .failed_attempts = 1,
                .last_failure_ns = now,
                .lockout_until_ns = 0,
            }) catch {
                self.allocator.free(owned_key);
            };
        }
    }

    /// Remove a bucket entry (freeing its owned key). Returns whether one was
    /// present.
    fn removeBucket(self: *Self, map: *std.StringHashMap(Entry), key: []const u8) bool {
        if (map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// Bump the periodic eviction counter and sweep every map at the interval.
    fn tickEviction(self: *Self) void {
        self.record_count +%= 1;
        if (self.record_count % 100 == 0) {
            self.evictExpiredLocked();
        }
    }

    /// Record a failed authentication attempt for the given IP.
    /// If the failure count reaches `max_attempts`, the IP is locked out.
    /// Periodically evicts expired entries to prevent unbounded memory growth.
    pub fn recordFailure(self: *Self, ip: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.tickEviction();
        self.recordFailureInBucket(&self.entries, ip, self.max_attempts, compat_nanoTimestamp());
    }

    /// Record a successful authentication, resetting the failure counter.
    pub fn recordSuccess(self: *Self, ip: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        _ = self.removeBucket(&self.entries, ip);
    }

    // ── Principal-keyed surface (ENG-3954 RC-1/RC-3) ───────────────────────
    // Keyed on the (ip, username) PAIR so a failure charged to one principal
    // never denies another principal from the same IP, while a coarse per-IP
    // ceiling (`ip_max_attempts`, counted across ALL usernames) still bounds a
    // username-rotating spray. Both HELLO gates use these entry points.

    /// Build the composite `ip ++ "\x00" ++ username` key into `buf`; returns the
    /// used slice, or null when it does not fit. The NUL separator keeps
    /// ("a", "bc") distinct from ("ab", "c").
    fn compositeKeyInto(buf: []u8, ip: []const u8, username: []const u8) ?[]const u8 {
        const need = ip.len + 1 + username.len;
        if (need > buf.len) return null;
        @memcpy(buf[0..ip.len], ip);
        buf[ip.len] = 0;
        @memcpy(buf[ip.len + 1 ..][0..username.len], username);
        return buf[0..need];
    }

    /// Record a failed attempt for the (ip, username) principal AND against the
    /// coarse per-IP ceiling. For a nonexistent username the caller still passes
    /// the ATTEMPTED name, so the victim's own bucket stays untouched while the
    /// ceiling still accrues the spray (ENG-3954 RC-1).
    pub fn recordFailureForPrincipal(self: *Self, ip: []const u8, username: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.tickEviction();
        const now = compat_nanoTimestamp();

        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            self.recordFailureInBucket(&self.principal_entries, key, self.max_attempts, now);
        }
        self.recordFailureInBucket(&self.ip_ceiling_entries, ip, self.ip_max_attempts, now);
    }

    /// True when the (ip, username) principal bucket is locked OR the coarse
    /// per-IP ceiling bucket is locked.
    pub fn isLockedForPrincipal(self: *Self, ip: []const u8, username: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const now = compat_nanoTimestamp();
        if (bucketLocked(&self.ip_ceiling_entries, ip, now)) return true;
        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            if (bucketLocked(&self.principal_entries, key, now)) return true;
        }
        return false;
    }

    /// Record a successful authentication for the (ip, username) principal,
    /// clearing that principal's bucket. A success for one principal is not an
    /// amnesty for another, so the coarse ceiling and other principals are left
    /// untouched.
    pub fn recordSuccessForPrincipal(self: *Self, ip: []const u8, username: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            _ = self.removeBucket(&self.principal_entries, key);
        }
    }

    /// Which bucket currently denies the (ip, username) principal, or null when
    /// it is admissible (ENG-3954 RC-3). A principal denial takes precedence so
    /// an operator sees "this account is being guessed" over the coarser signal.
    pub fn lockoutReason(self: *Self, ip: []const u8, username: []const u8) ?DenialReason {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const now = compat_nanoTimestamp();
        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            if (bucketLocked(&self.principal_entries, key, now)) return .principal;
        }
        if (bucketLocked(&self.ip_ceiling_entries, ip, now)) return .ip_ceiling;
        return null;
    }

    /// Remaining lockout time for the (ip, username) principal, or null when it
    /// is not locked. Mirrors `lockoutReason`: reports the principal window when
    /// that bucket is the reason, else the ceiling window.
    pub fn lockoutRemainingNs(self: *Self, ip: []const u8, username: []const u8) ?u64 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const now = compat_nanoTimestamp();
        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            if (bucketRemainingNs(&self.principal_entries, key, now)) |rem| return rem;
        }
        return bucketRemainingNs(&self.ip_ceiling_entries, ip, now);
    }

    /// Operator escape hatch (ENG-3954 RC-3): clear a lockout. A non-empty
    /// username clears that (ip, username) principal bucket; an EMPTY username
    /// clears the IP's coarse ceiling bucket. Returns whether anything was
    /// actually cleared, so an admin path can report "no such lockout" instead
    /// of a silent success.
    pub fn clearLockout(self: *Self, ip: []const u8, username: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (username.len == 0) {
            return self.removeBucket(&self.ip_ceiling_entries, ip);
        }
        var key_buf: [512]u8 = undefined;
        if (compositeKeyInto(&key_buf, ip, username)) |key| {
            return self.removeBucket(&self.principal_entries, key);
        }
        return false;
    }

    /// Evict entries whose lockout has expired.  Call periodically to
    /// prevent unbounded memory growth (e.g. from a maintenance timer).
    pub fn evictExpired(self: *Self) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.evictExpiredLocked();
    }

    /// Internal: evict expired entries while already holding the mutex. Sweeps
    /// every bucket map — legacy IP-only, principal, and the coarse per-IP
    /// ceiling — so none of the three grows unbounded (ENG-3954 RC-1).
    fn evictExpiredLocked(self: *Self) void {
        const now = compat_nanoTimestamp();
        self.evictMapLocked(&self.entries, now);
        self.evictMapLocked(&self.principal_entries, now);
        self.evictMapLocked(&self.ip_ceiling_entries, now);
    }

    /// Evict expired entries from a single bucket map (caller holds the mutex).
    fn evictMapLocked(self: *Self, map: *std.StringHashMap(Entry), now: i128) void {
        // Collect keys to remove (cannot mutate while iterating).
        var to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return;
        defer to_remove.deinit(self.allocator);

        const cutoff = now - @as(i128, @intCast(self.lockout_duration_ns));
        var iter = map.iterator();
        while (iter.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (entry.lockout_until_ns != 0 and now >= entry.lockout_until_ns) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch continue;
            } else if (entry.lockout_until_ns == 0 and entry.last_failure_ns < cutoff) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (map.fetchRemove(key)) |kv| {
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

// ── Auth-outcome classification (ENG-3954 / #874) ──────────────────────
// Both transports (QUIC HELLO, gRPC HELLO) previously fed the limiter from a
// bare `authenticate(...) catch { recordFailure(peer_ip); }`, so a server-side
// fault — an unhydrated/quarantined `__geode_security` graph, a store lock we
// could not take, an allocation failure — armed the same lockout as a real
// brute-force burst and, because the fault persisted, re-armed it on every
// retry. The policy lives here because this is the one module both transports
// already share, so it cannot drift between them.
//
// CANARY: REQ=REQ-SEC-RATE-LIMIT-007; FEATURE="AuthRateLimiting"; ASPECT=OutcomeClassification; STATUS=TESTED; TEST=auth_rate_limiter_tests; OWNER=security; UPDATED=2026-08-28

/// Whether a failed `authenticate()` outcome may count against the per-IP
/// brute-force lockout.
///
/// Only `error.Unauthenticated` — credentials that were actually checked and
/// rejected — counts. Every other error means "we could not check", including
/// `error.AuthUnavailable` (see `user_management.authenticate`) and
/// `error.OutOfMemory`. Unrecognised errors default to NOT counting: counting a
/// server-side fault is precisely what locks honest clients out, while failing
/// to count one only forgoes a single increment of an attacker's budget.
pub fn shouldCountFailedAttempt(err: anyerror) bool {
    return err == error.Unauthenticated;
}

// CANARY: REQ=REQ-SONNY-6598-HELLO-AUTH-ERROR-ANSWER; FEATURE="AuthOutcomeClassification"; ASPECT=HelloRefusalMessage; STATUS=TESTED; TEST=tests/test_sonny6598_kdf_error_hello.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6598: the HELLO error message for a failed `authenticate()`, the
/// same on both transports. Only a checked-and-rejected credential
/// (`error.Unauthenticated`, the one outcome `shouldCountFailedAttempt`
/// counts) is "Authentication failed". A stored hash the server cannot use
/// (`error.AuthCredentialInvalid`) is a server-side error on that account,
/// which a retry does not cure. Everything else (the store or the password
/// KDF could not run, e.g. out of memory under load) is the retryable
/// "temporarily unavailable".
pub const hello_failed_message = "Authentication failed";
pub const hello_unavailable_message = "Authentication temporarily unavailable";
pub const hello_credential_invalid_message = "Authentication unavailable: the stored credential of this account cannot be used (server-side error; contact the administrator)";

pub fn helloRefusalMessage(err: anyerror) []const u8 {
    if (err == error.Unauthenticated) return hello_failed_message;
    if (err == error.AuthCredentialInvalid) return hello_credential_invalid_message;
    return hello_unavailable_message;
}

/// Whether a HELLO carries both credential halves and is therefore eligible for
/// a credential check at all.
///
/// A truncated or half-open HELLO deserialises to proto3 defaults (`""` / `""`).
/// That is a malformed handshake, not a failed credential check, so it must
/// never reach the limiter.
pub fn credentialsPresent(username: []const u8, password: []const u8) bool {
    return username.len > 0 and password.len > 0;
}

// ── Lockout configuration resolution (ENG-3954 / #874) ─────────────────
// The threshold and window used to be reachable ONLY through process env
// vars, so an operator whose supervisor does not forward env (systemd without
// `Environment=`, a k8s command-only override, a wrapper shell script) had no
// way to widen a lockout that misfired on their network. Resolution lives in
// this module because it is the one file both transports and the server
// bootstrap already share, so precedence cannot drift.
//
// CANARY: REQ=REQ-SEC-RATE-LIMIT-008; FEATURE="AuthRateLimiting"; ASPECT=OperatorConfig; STATUS=TESTED; TEST=auth_rate_limiter_tests; OWNER=security; UPDATED=2026-08-29

/// Env var names for the two lockout knobs (also settable as CLI flags).
pub const max_attempts_env = "GEODE_AUTH_RATE_MAX_ATTEMPTS";
pub const lockout_secs_env = "GEODE_AUTH_RATE_LOCKOUT_SECS";

/// Upper bound on an accepted lockout window (1 day). Anything larger is an
/// operator typo, not a policy.
pub const max_lockout_secs: u64 = 86_400;

/// A fully resolved lockout configuration, ready for `initWithConfig`.
pub const LockoutConfig = struct {
    max_attempts: u32,
    lockout_duration_ns: u64,
};

fn validAttempts(v: u64) ?u32 {
    if (v == 0 or v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

fn validLockoutNs(secs: u64) ?u64 {
    if (secs == 0 or secs > max_lockout_secs) return null;
    return secs * std.time.ns_per_s;
}

/// Resolve the per-IP lockout thresholds with the geode-wide precedence
/// flags > env > default, each knob INDEPENDENTLY (supplying one flag never
/// resets the other to its default).
///
/// `cli_max_attempts` / `cli_lockout_secs` are the `--auth-lockout-attempts` /
/// `--auth-lockout-secs` values (null = operator said nothing). An
/// out-of-range value at any level is rejected and falls through to the next
/// source: a typo must never disable brute-force protection outright.
pub fn resolveConfig(cli_max_attempts: ?u32, cli_lockout_secs: ?u64) LockoutConfig {
    const cli_attempts: ?u32 = if (cli_max_attempts) |v| validAttempts(v) else null;
    const env_attempts: ?u32 = if (AuthRateLimiter.readEnvU64(max_attempts_env)) |v| validAttempts(v) else null;

    const cli_ns: ?u64 = if (cli_lockout_secs) |secs| validLockoutNs(secs) else null;
    const env_ns: ?u64 = if (AuthRateLimiter.readEnvU64(lockout_secs_env)) |secs| validLockoutNs(secs) else null;

    return .{
        .max_attempts = cli_attempts orelse env_attempts orelse AuthRateLimiter.default_max_attempts,
        .lockout_duration_ns = cli_ns orelse env_ns orelse AuthRateLimiter.default_lockout_duration_ns,
    };
}

/// Env var name for the coarse per-IP ceiling (also settable as a CLI flag).
pub const ip_max_attempts_env = "GEODE_AUTH_RATE_IP_MAX_ATTEMPTS";

/// A ceiling is only meaningful strictly ABOVE the per-principal threshold —
/// otherwise per-principal keying buys nothing (ENG-3954 RC-1c). A value at or
/// below `max_attempts`, zero, or beyond u32 is an operator typo and is
/// rejected so it falls through to the next source.
fn validIpCeiling(v: u64, max_attempts: u32) ?u32 {
    if (v == 0 or v > std.math.maxInt(u32)) return null;
    const c: u32 = @intCast(v);
    if (c <= max_attempts) return null;
    return c;
}

/// Resolve the coarse per-IP ceiling with the same geode-wide precedence as
/// `resolveConfig` — flags > env > default — but validated against the already
/// resolved `max_attempts` so the ceiling can never drop to/under the
/// per-principal threshold. Kept as a separate resolver (rather than a third
/// `resolveConfig` argument) so the pinned two-argument `resolveConfig` surface
/// is unchanged.
pub fn resolveIpMaxAttempts(cli_ip_max_attempts: ?u32, max_attempts: u32) u32 {
    const cli: ?u32 = if (cli_ip_max_attempts) |v| validIpCeiling(v, max_attempts) else null;
    const env: ?u32 = if (AuthRateLimiter.readEnvU64(ip_max_attempts_env)) |v| validIpCeiling(v, max_attempts) else null;
    // The default floor is `default_ip_max_attempts`, but never at/under an
    // operator-raised `max_attempts` — 5x (saturating) keeps the invariant.
    const dflt: u32 = @max(AuthRateLimiter.default_ip_max_attempts, max_attempts *| 5);
    return cli orelse env orelse dflt;
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
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
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

// ── ENG-3954 / #874 residual R1: the lockout thresholds are not configurable ──
//
// TRIAGE (current HEAD): the two knobs that decide when a client is locked out
// exist ONLY as process env vars, read in `initFromEnv` (auth_rate_limiter.zig
// :66-93) and consumed once at startup (src/server/main.zig:1927):
//
//     GEODE_AUTH_RATE_MAX_ATTEMPTS   failures before lockout   (default 10)
//     GEODE_AUTH_RATE_LOCKOUT_SECS   lockout window, seconds   (default 60)
//
// There is no `--auth-lockout-attempts` / `--auth-lockout-secs` CLI flag and no
// operator documentation, so ENG-3954 expectation C ("the threshold and window
// must be operator-configurable") is unmet: an operator running geode under a
// supervisor that does not forward env (systemd without `Environment=`, a
// k8s command-only override, `geode serve` from a shell script) has NO way to
// widen a 10-attempt / 60-second lockout that is misfiring on their network.
//
// CONTRACT THESE TESTS PIN (the fix must supply it in THIS module — the same
// argument as `shouldCountFailedAttempt`: this is the one file both transports
// and the server bootstrap already share, so precedence cannot drift):
//
//   pub fn resolveConfig(cli_max_attempts: ?u32, cli_lockout_secs: ?u64) <cfg>
//       Returns a value with `.max_attempts: u32` and `.lockout_duration_ns: u64`,
//       resolving each knob INDEPENDENTLY with the documented geode precedence
//       flags > env > default (the same order `--strict-tenancy` /
//       GEODE_STRICT_TENANCY uses in src/server/cli_args.zig:402-450).
//       Out-of-range values (0 attempts, a 0 or >86400 s window) are REJECTED
//       and fall through to the next source — a typo must never disable
//       brute-force protection outright.
//
// The companion CLI-surface test lives in tests/test_cli_args_cluster.zig
// (`--auth-lockout-attempts` / `--auth-lockout-secs` -> ServerConfig).
//
// RED at HEAD: `resolveConfig` does not exist, so these fail with
// error.MissingLockoutConfigResolver.

// Zig 0.16 removed std.process.setEnvVar; use libc directly (same pattern as
// tests/test_gap0061_crash_auth.zig). `readEnvU64` above already reads through
// std.c.getenv, so this test artifact links libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const MAX_ATTEMPTS_ENV = "GEODE_AUTH_RATE_MAX_ATTEMPTS";
const LOCKOUT_SECS_ENV = "GEODE_AUTH_RATE_LOCKOUT_SECS";

fn clearLockoutEnv() void {
    _ = unsetenv(MAX_ATTEMPTS_ENV);
    _ = unsetenv(LOCKOUT_SECS_ENV);
}

fn setLockoutEnv(attempts: [:0]const u8, secs: [:0]const u8) !void {
    if (setenv(MAX_ATTEMPTS_ENV, attempts.ptr, 1) != 0) return error.SetEnvFailed;
    if (setenv(LOCKOUT_SECS_ENV, secs.ptr, 1) != 0) return error.SetEnvFailed;
}

test "auth_rate_limiter: lockout config resolves flags > env > defaults (ENG-3954 R1)" {
    const M = @This();
    if (comptime !@hasDecl(M, "resolveConfig")) {
        return error.MissingLockoutConfigResolver;
    } else {
        clearLockoutEnv();
        defer clearLockoutEnv();

        // 1) Nothing supplied anywhere -> the documented defaults.
        {
            const cfg = M.resolveConfig(null, null);
            try std.testing.expectEqual(AuthRateLimiter.default_max_attempts, cfg.max_attempts);
            try std.testing.expectEqual(AuthRateLimiter.default_lockout_duration_ns, cfg.lockout_duration_ns);
        }

        // 2) Env only -> env beats the defaults (today's only knob; must keep working).
        try setLockoutEnv("7", "11");
        {
            const cfg = M.resolveConfig(null, null);
            try std.testing.expectEqual(@as(u32, 7), cfg.max_attempts);
            try std.testing.expectEqual(@as(u64, 11 * std.time.ns_per_s), cfg.lockout_duration_ns);
        }

        // 3) CLI supplied -> the flag beats the env (flags > env, geode-wide).
        {
            const cfg = M.resolveConfig(5, 3);
            try std.testing.expectEqual(@as(u32, 5), cfg.max_attempts);
            try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), cfg.lockout_duration_ns);
        }

        // 4) Each knob resolves independently: a flag for one does not silently
        //    reset the other to its default.
        {
            const cfg = M.resolveConfig(5, null);
            try std.testing.expectEqual(@as(u32, 5), cfg.max_attempts);
            try std.testing.expectEqual(@as(u64, 11 * std.time.ns_per_s), cfg.lockout_duration_ns);
        }
        {
            const cfg = M.resolveConfig(null, 3);
            try std.testing.expectEqual(@as(u32, 7), cfg.max_attempts);
            try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), cfg.lockout_duration_ns);
        }
    }
}

test "auth_rate_limiter: out-of-range lockout config never disables brute-force protection (ENG-3954 R1)" {
    const M = @This();
    if (comptime !@hasDecl(M, "resolveConfig")) {
        return error.MissingLockoutConfigResolver;
    } else {
        clearLockoutEnv();
        defer clearLockoutEnv();

        // `--auth-lockout-attempts 0` would mean "lock out on the zeroth
        // failure" / "never lock out" depending on the comparison — either way
        // it is an operator typo, not a policy. Same for a zero-length or
        // absurd (>1 day) window. All fall through to the next source, exactly
        // like the existing initFromEnv validation at :70-75.
        {
            const cfg = M.resolveConfig(0, 0);
            try std.testing.expectEqual(AuthRateLimiter.default_max_attempts, cfg.max_attempts);
            try std.testing.expectEqual(AuthRateLimiter.default_lockout_duration_ns, cfg.lockout_duration_ns);
        }
        {
            const cfg = M.resolveConfig(null, 86_401);
            try std.testing.expectEqual(AuthRateLimiter.default_lockout_duration_ns, cfg.lockout_duration_ns);
        }

        // A junk env value is ignored too (unchanged initFromEnv behaviour).
        try setLockoutEnv("not-a-number", "");
        {
            const cfg = M.resolveConfig(null, null);
            try std.testing.expectEqual(AuthRateLimiter.default_max_attempts, cfg.max_attempts);
            try std.testing.expectEqual(AuthRateLimiter.default_lockout_duration_ns, cfg.lockout_duration_ns);
        }
    }
}

test "auth_rate_limiter: the resolved config is what the limiter actually enforces (ENG-3954 R1)" {
    const M = @This();
    if (comptime !@hasDecl(M, "resolveConfig")) {
        return error.MissingLockoutConfigResolver;
    } else {
        clearLockoutEnv();
        defer clearLockoutEnv();

        // An operator who raises the threshold to 4 must survive 3 rejections.
        const cfg = M.resolveConfig(4, 60);
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, cfg.max_attempts, cfg.lockout_duration_ns);
        defer limiter.deinit();
        const ip = "203.0.113.42";

        var i: usize = 0;
        while (i < 3) : (i += 1) limiter.recordFailure(ip);
        try std.testing.expect(!limiter.isLocked(ip));

        limiter.recordFailure(ip); // the 4th reaches the configured threshold
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

// ── ENG-3954 round 2: cross-principal lockout + indefinite re-arm ──────────
//
// TRIAGE (reproduced on this HEAD, all four root causes):
//
//   RC-1 (primary) The limiter is keyed on the SOURCE IP ALONE.
//        src/transport/quic.zig:1329-1352 `getPeerAddressString` formats the
//        peer address with NO port and NO principal, and `entries` above
//        (auth_rate_limiter.zig:43) is a StringHashMap on exactly that string.
//        The gate at src/server/quic_connection_handler.zig:5905-5919 (gRPC
//        parity src/transport/grpc_server.zig:1427-1436) therefore refuses
//        EVERY principal from an IP as soon as ANY principal — including a
//        username that does not exist, which `user_management.authenticate`
//        rejects with error.Unauthenticated (user_management.zig:830-841) and
//        `shouldCountFailedAttempt` (:250-252) counts — fails ten times.
//        REPRODUCED: 10 bad logins as the NONEXISTENT user 'mallory' from
//        127.0.0.1 locked out BOTH the valid user 'alice' AND the admin
//        'geode'. One unauthenticated attacker can deny the whole database to
//        every operator sharing a NAT egress address.
//
//   RC-2 (severity multiplier) The lockout never ends under sustained failure
//        traffic. `recordFailure` (:141-150) only resets an entry AFTER the
//        deadline has passed and then counts afresh, so the deadline is pushed
//        to `now + lockout_duration_ns` by every failure that lands while the
//        entry is at/over threshold — a SLIDING window, not a fixed one.
//        REPRODUCED: 159 bad attempts over 75 s (window = 60 s) left a valid
//        login still refused. This contradicts docs/USER_AUTH.md:606-610,
//        which promises the lockout "simply expires on its own".
//
//   RC-3 (diagnosis/recovery) The denial log at quic_connection_handler.zig
//        :5907-5909 emits only `peer_ip` — not the attempted username, not
//        which bucket denied. There is no way for an operator to ask "who is
//        locked, why, and for how long", and no way to clear a misfire short
//        of restarting the server. This is why field triage of the incident
//        could not tell a brute-force burst from a collateral lockout.
//
// THE CONTRACT THESE TESTS PIN — the fix adds, to `AuthRateLimiter`:
//
//   ip_max_attempts: u32                            (NEW field)
//       The COARSE per-IP ceiling, counted across ALL usernames, that keeps a
//       username-rotating password-spray bounded (the DoS backstop the
//       IP-only key provides today and which the fix must NOT throw away).
//       It MUST default strictly above `max_attempts`, otherwise per-principal
//       keying buys nothing: the ceiling would fire at the same count.
//
//   pub fn recordFailureForPrincipal(self, ip, username) void
//   pub fn isLockedForPrincipal(self, ip, username) bool
//   pub fn recordSuccessForPrincipal(self, ip, username) void
//       Principal-aware entry points, keyed on the (ip, username) PAIR, that
//       both HELLO gates switch to. `isLockedForPrincipal` is true when the
//       (ip, username) bucket has reached `max_attempts` OR the IP-wide bucket
//       has reached `ip_max_attempts`. The existing IP-only methods keep their
//       current meaning (the tests above still pin them) so no call site is
//       silently left without ANY brute-force protection during the migration.
//
//   pub const DenialReason = enum { principal, ip_ceiling };
//   pub fn lockoutReason(self, ip, username) ?DenialReason
//   pub fn lockoutRemainingNs(self, ip, username) ?u64
//   pub fn clearLockout(self, ip, username) bool
//       RC-3 diagnosis/recovery surface: which bucket denied, for how long,
//       and an operator escape hatch. `clearLockout` clears the (ip, username)
//       bucket; an EMPTY username clears that IP's ceiling bucket. It returns
//       whether anything was actually cleared, so the admin path can report
//       "no such lockout" instead of a silent success.
//
// The check ORDER is deliberately NOT changed: `isLockedForPrincipal` must
// still run BEFORE any Argon2id verification (docs/USER_AUTH.md:606-610 — a
// locked client must not be able to force unbounded password hashing). None of
// these tests requires a credential to be verified before the lock is checked.
//
// RED at HEAD: none of these declarations exist, so the tests fail with
// error.MissingPrincipalKeyedRateLimit / error.MissingLockoutIntrospection.

/// Whether the fix's principal-keyed surface is present. Kept as one comptime
/// predicate so every ENG-3954 round-2 test reports the same named RED reason
/// instead of a compile error that would take the whole lane down with it.
const has_principal_keyed_api = @hasDecl(AuthRateLimiter, "recordFailureForPrincipal") and
    @hasDecl(AuthRateLimiter, "isLockedForPrincipal") and
    @hasDecl(AuthRateLimiter, "recordSuccessForPrincipal") and
    @hasField(AuthRateLimiter, "ip_max_attempts");

const has_lockout_introspection = @hasDecl(AuthRateLimiter, "lockoutRemainingNs") and
    @hasDecl(AuthRateLimiter, "clearLockout") and
    @hasDecl(AuthRateLimiter, "lockoutReason") and
    @hasDecl(AuthRateLimiter, "DenialReason");

test "auth_rate_limiter: a failed principal never locks a DIFFERENT principal from the same IP (ENG-3954 RC-1a)" {
    if (comptime !has_principal_keyed_api) {
        return error.MissingPrincipalKeyedRateLimit;
    } else {
        // Threshold 3 so the burst is small; the per-IP ceiling is raised well
        // clear of it so this test isolates the PRINCIPAL bucket. (RC-1c below
        // pins that the ceiling still exists and still fires.)
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
        defer limiter.deinit();
        limiter.ip_max_attempts = 1000;

        const ip = "127.0.0.1";

        // The reproduced incident: an attacker sprays a username that does not
        // even exist. Every one of these is a checked-and-rejected credential
        // (error.Unauthenticated), so it legitimately counts — against MALLORY.
        var i: usize = 0;
        while (i < 3) : (i += 1) limiter.recordFailureForPrincipal(ip, "mallory");

        // The attacked principal is locked — protection still works.
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "mallory"));

        // ...and NOBODY else from that IP is. This is the whole defect: at HEAD
        // both of these are locked out, which is how one unauthenticated
        // attacker denied the database to its own operators.
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "geode"));

        // A valid login for alice is therefore admissible, and recording her
        // success must not disturb the attacker's lockout (a success for one
        // principal is not an amnesty for another).
        limiter.recordSuccessForPrincipal(ip, "alice");
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "mallory"));

        // The same username from a different IP is a different principal too:
        // one compromised network must not lock a user out everywhere.
        try std.testing.expect(!limiter.isLockedForPrincipal("198.51.100.4", "mallory"));
    }
}

test "auth_rate_limiter: a single principal still locks after max_attempts (ENG-3954 RC-1b)" {
    if (comptime !has_principal_keyed_api) {
        return error.MissingPrincipalKeyedRateLimit;
    } else {
        // Regression guard on the protection the fix must NOT weaken: keying on
        // (ip, username) still has to stop a password-guessing run against ONE
        // account. Green today in IP-only form; must stay green afterwards.
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
        defer limiter.deinit();
        limiter.ip_max_attempts = 1000;

        const ip = "203.0.113.11";

        limiter.recordFailureForPrincipal(ip, "alice");
        limiter.recordFailureForPrincipal(ip, "alice");
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));

        limiter.recordFailureForPrincipal(ip, "alice"); // reaches max_attempts
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "alice"));

        // A correct password does NOT lift an active lockout: the gate runs
        // before Argon2id verification on purpose (CPU-amplification defense,
        // docs/USER_AUTH.md:606-610), so a locked principal stays locked until
        // the window elapses or an operator clears it.
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "alice"));

        // ...and a success recorded for the SAME principal does clear it, which
        // is the existing recordSuccess contract carried over to the pair key.
        limiter.recordSuccessForPrincipal(ip, "alice");
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
    }
}

test "auth_rate_limiter: a per-IP ceiling still stops a username-rotating spray (ENG-3954 RC-1c)" {
    if (comptime !has_principal_keyed_api) {
        return error.MissingPrincipalKeyedRateLimit;
    } else {
        // The DoS backstop. Per-principal keying must not become "one free
        // max_attempts budget per username an attacker can invent" — the coarse
        // per-IP counter that exists today has to survive the fix, just with a
        // HIGHER threshold so it stops a spray without catching a bystander.
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
        defer limiter.deinit();
        limiter.ip_max_attempts = 12;

        const ip = "198.51.100.77";

        // Twelve DISTINCT usernames, one failure each: no principal bucket ever
        // gets near max_attempts (3), so only the ceiling can fire here.
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 11) : (i += 1) {
            const user = try std.fmt.bufPrint(&buf, "sprayed_user_{d}", .{i});
            limiter.recordFailureForPrincipal(ip, user);
        }
        // Still under the ceiling: a bystander is untouched.
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "bystander"));

        const last = try std.fmt.bufPrint(&buf, "sprayed_user_{d}", .{11});
        limiter.recordFailureForPrincipal(ip, last); // 12th -> reaches the ceiling

        // Beyond the ceiling the IP is refused whatever username it presents,
        // including one that has never failed. The fixer MUST NOT "fix" RC-1 by
        // deleting all per-IP protection.
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "never_seen_before"));
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "sprayed_user_0"));

        // A different IP is unaffected by another IP's ceiling.
        try std.testing.expect(!limiter.isLockedForPrincipal("198.51.100.78", "never_seen_before"));
    }
}

test "auth_rate_limiter: the shipped default ceiling is above the per-principal threshold (ENG-3954 RC-1c)" {
    if (comptime !has_principal_keyed_api) {
        return error.MissingPrincipalKeyedRateLimit;
    } else {
        // Property, not a magic number — the fixer picks the constant. What
        // must hold is that the ceiling does not fire at the SAME count as the
        // per-principal threshold: if it did, ten failures for 'mallory' would
        // still lock 'alice' out and nothing about the incident would change.
        var limiter = AuthRateLimiter.init(std.testing.allocator);
        defer limiter.deinit();
        try std.testing.expect(limiter.ip_max_attempts > limiter.max_attempts);

        // The reproduced burst was exactly default_max_attempts failures for a
        // single bogus username. That burst alone must not trip the ceiling.
        const ip = "127.0.0.1";
        var i: usize = 0;
        while (i < AuthRateLimiter.default_max_attempts) : (i += 1) {
            limiter.recordFailureForPrincipal(ip, "mallory");
        }
        try std.testing.expect(limiter.isLockedForPrincipal(ip, "mallory"));
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
    }
}

test "auth_rate_limiter: failures during an active lockout never extend it (ENG-3954 RC-2)" {
    if (comptime !has_principal_keyed_api or !has_lockout_introspection) {
        return error.MissingLockoutIntrospection;
    } else {
        // RC-2, deterministically: the window must be anchored to the moment the
        // lockout ARMED, never re-based on the newest failure. At HEAD every
        // failure that lands at/over threshold rewrites lockout_until_ns to
        // `now + lockout_duration_ns` (:148-150), which is why 159 attempts over
        // 75 s kept a 60 s lockout alive indefinitely.
        const window_ns: u64 = 1500 * std.time.ns_per_ms;
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, window_ns);
        defer limiter.deinit();
        limiter.ip_max_attempts = 100_000;

        const ip = "198.51.100.31";

        var i: usize = 0;
        while (i < 3) : (i += 1) limiter.recordFailureForPrincipal(ip, "alice");
        const rem_at_arm = limiter.lockoutRemainingNs(ip, "alice") orelse return error.ExpectedActiveLockout;
        try std.testing.expect(rem_at_arm <= window_ns);

        // Time passes while the attacker keeps hammering the locked principal.
        const elapsed_ns: u64 = 500 * std.time.ns_per_ms;
        testSleepNs(elapsed_ns);
        i = 0;
        while (i < 200) : (i += 1) limiter.recordFailureForPrincipal(ip, "alice");

        const rem_after = limiter.lockoutRemainingNs(ip, "alice") orelse return error.ExpectedActiveLockout;

        // Still locked — sustained guessing is still refused.
        try std.testing.expect(rem_after > 0);

        // But the deadline did NOT move: at least the slept time must have been
        // burned off it. The 250 ms slack keeps this honest on a loaded runner
        // (a stall only makes MORE time elapse, never less), while HEAD's
        // sliding window reports a full fresh `window_ns` here and fails.
        const slack_ns: u64 = 250 * std.time.ns_per_ms;
        try std.testing.expect(rem_after + slack_ns <= rem_at_arm);

        // ...and once that anchored window elapses the lockout really is over,
        // which is what docs/USER_AUTH.md:606-610 promises operators.
        testSleepNs(rem_after + 150 * std.time.ns_per_ms);
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
        try std.testing.expect(limiter.lockoutRemainingNs(ip, "alice") == null);
    }
}

test "auth_rate_limiter: an operator can see and clear a lockout (ENG-3954 RC-3)" {
    if (comptime !has_principal_keyed_api or !has_lockout_introspection) {
        return error.MissingLockoutIntrospection;
    } else {
        // RC-3: the incident was un-triageable because the denial log names only
        // the peer IP (quic_connection_handler.zig:5907-5909) and nothing can
        // report WHICH bucket denied, for how long, or release it. These four
        // declarations are the seam the log line, the metric label, and the
        // admin procedure all read from.
        var limiter = AuthRateLimiter.initWithConfig(std.testing.allocator, 3, 60 * std.time.ns_per_s);
        defer limiter.deinit();
        limiter.ip_max_attempts = 10;

        const ip = "203.0.113.55";

        // Nothing has failed yet: no lockout, no reason, no remaining time.
        try std.testing.expect(limiter.lockoutReason(ip, "alice") == null);
        try std.testing.expect(limiter.lockoutRemainingNs(ip, "alice") == null);
        try std.testing.expect(!limiter.clearLockout(ip, "alice")); // nothing to clear

        var i: usize = 0;
        while (i < 3) : (i += 1) limiter.recordFailureForPrincipal(ip, "alice");

        // The denial is attributable to the PRINCIPAL, and time-bounded.
        try std.testing.expectEqual(AuthRateLimiter.DenialReason.principal, limiter.lockoutReason(ip, "alice").?);
        const rem = limiter.lockoutRemainingNs(ip, "alice") orelse return error.ExpectedActiveLockout;
        try std.testing.expect(rem > 0 and rem <= 60 * std.time.ns_per_s);
        // A bystander on the same IP is not denied and has no reason recorded.
        try std.testing.expect(limiter.lockoutReason(ip, "bob") == null);

        // The operator escape hatch: clear it, and it is really gone.
        try std.testing.expect(limiter.clearLockout(ip, "alice"));
        try std.testing.expect(!limiter.isLockedForPrincipal(ip, "alice"));
        try std.testing.expect(limiter.lockoutRemainingNs(ip, "alice") == null);
        try std.testing.expect(!limiter.clearLockout(ip, "alice")); // idempotent, reports "nothing there"

        // The IP-ceiling denial is distinguishable from a principal denial —
        // without that, an operator cannot tell "this account is being guessed"
        // from "this NAT egress is spraying", which is exactly the call field
        // triage could not make.
        const spray_ip = "203.0.113.56";
        var buf: [32]u8 = undefined;
        i = 0;
        while (i < 10) : (i += 1) {
            const user = try std.fmt.bufPrint(&buf, "spray_{d}", .{i});
            limiter.recordFailureForPrincipal(spray_ip, user);
        }
        try std.testing.expectEqual(
            AuthRateLimiter.DenialReason.ip_ceiling,
            limiter.lockoutReason(spray_ip, "innocent").?,
        );

        // An empty username addresses the IP-wide bucket, so an operator can
        // release a NATed office without restarting the server.
        try std.testing.expect(limiter.clearLockout(spray_ip, ""));
        try std.testing.expect(!limiter.isLockedForPrincipal(spray_ip, "innocent"));
    }
}

test "SONNY-6598: only a rejected credential is answered 'Authentication failed' and counted" {
    try std.testing.expectEqualStrings(hello_failed_message, helloRefusalMessage(error.Unauthenticated));
    try std.testing.expect(shouldCountFailedAttempt(error.Unauthenticated));
    for ([_]anyerror{ error.AuthUnavailable, error.OutOfMemory, error.FipsUnsupported }) |err| {
        try std.testing.expectEqualStrings(hello_unavailable_message, helloRefusalMessage(err));
        try std.testing.expect(!shouldCountFailedAttempt(err));
    }
    try std.testing.expectEqualStrings(hello_credential_invalid_message, helloRefusalMessage(error.AuthCredentialInvalid));
    try std.testing.expect(!shouldCountFailedAttempt(error.AuthCredentialInvalid));
}
