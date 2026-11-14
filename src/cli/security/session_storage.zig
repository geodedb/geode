// CANARY: REQ=REQ-AUTH-SESSION-001; FEATURE="LocalSessionStorage"; ASPECT=SECURITY; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");
const cb = @import("crypto_backend");
const home_dir = @import("home_dir.zig");

/// Credential storage for local session management
pub const Credentials = struct {
    token: []const u8, // Cryptographically random token (64 hex chars)
    username: []const u8,
    server: []const u8,
    created_at: i64,
    system_fingerprint: []const u8, // hostname + system_username
};

/// Session token with expiration and renewal
pub const SessionToken = struct {
    token: [32]u8, // 32 bytes = 64 hex chars
    username: []const u8,
    system_fingerprint: []const u8,
    created_at: i64,
    expires_at: i64,
    last_renewed_at: i64,

    const TOKEN_LIFETIME_SECS: i64 = 3600; // 1 hour
    const RENEWAL_THRESHOLD_SECS: i64 = 300; // Renew if < 5 minutes remaining

    pub fn generate(allocator: std.mem.Allocator, username: []const u8) !SessionToken {
        var token: [32]u8 = undefined;
        try cb.Csprng.bytes(&token);

        const now = compat_timestamp();
        const fingerprint = try getSystemFingerprint(allocator);

        return SessionToken{
            .token = token,
            .username = try allocator.dupe(u8, username),
            .system_fingerprint = fingerprint,
            .created_at = now,
            .expires_at = now + TOKEN_LIFETIME_SECS,
            .last_renewed_at = now,
        };
    }

    pub fn needsRenewal(self: *const SessionToken) bool {
        const now = compat_timestamp();
        const time_remaining = self.expires_at - now;
        return time_remaining < RENEWAL_THRESHOLD_SECS;
    }

    pub fn renew(self: *SessionToken) void {
        const now = compat_timestamp();
        self.last_renewed_at = now;
        self.expires_at = now + TOKEN_LIFETIME_SECS;
    }

    pub fn isExpired(self: *const SessionToken) bool {
        return compat_timestamp() >= self.expires_at;
    }

    pub fn isValid(self: *const SessionToken, system_fp: []const u8) bool {
        if (self.isExpired()) return false;
        return std.mem.eql(u8, self.system_fingerprint, system_fp);
    }

    pub fn toHexString(self: *const SessionToken, allocator: std.mem.Allocator) ![]u8 {
        const hex_array = std.fmt.bytesToHex(self.token, .lower);
        return allocator.dupe(u8, &hex_array);
    }
};

/// Get system fingerprint (hostname + username)
pub fn getSystemFingerprint(allocator: std.mem.Allocator) ![]u8 {
    // Get hostname with platform-specific buffer sizes
    // Windows: MAX_COMPUTERNAME_LENGTH is 15, but we use 256 for safety
    // Unix: HOST_NAME_MAX varies (64 on Linux, 72 on macOS)
    const hostname_buf_size = if (builtin.os.tag == .windows) 256 else std.posix.HOST_NAME_MAX;
    var hostname_buf: [hostname_buf_size]u8 = undefined;

    // SONNY-6463: the environment copies are freed (they leaked on every call).
    const hostname_owned: ?[]u8 = if (builtin.os.tag == .windows)
        getEnvVarOwned(allocator, "COMPUTERNAME") catch null
    else
        null;
    defer if (hostname_owned) |h| allocator.free(h);
    const hostname: []const u8 = if (builtin.os.tag == .windows)
        hostname_owned orelse "unknown"
    else
        std.posix.gethostname(&hostname_buf) catch "unknown";

    // Get system username - use std.process for cross-platform compatibility
    const username_owned: ?[]u8 = getEnvVarOwned(allocator, "USER") catch
        getEnvVarOwned(allocator, "USERNAME") catch null;
    defer if (username_owned) |u| allocator.free(u);
    const username: []const u8 = username_owned orelse "unknown";

    // Get user ID (0 on Windows since it doesn't have Unix-style UIDs).
    // SONNY-6476: the Linux syscall only on Linux; macOS and the BSDs ask
    // libc (`std.os.linux.getuid` there issued a Linux syscall number).
    const uid: u32 = currentUid();

    // Combine: hostname:username:uid
    return std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ hostname, username, uid });
}

/// SONNY-6476: the calling process's real user id, per platform: the Linux
/// syscall on Linux, libc's `getuid` on the other POSIX systems (macOS, the
/// BSDs), 0 on Windows (no Unix-style uid).
fn currentUid() u32 {
    return switch (builtin.os.tag) {
        .windows => 0,
        .linux => std.os.linux.getuid(),
        else => @intCast(std.c.getuid()),
    };
}

/// Credential storage manager
pub const CredentialStore = struct {
    file_path: []const u8,
    allocator: std.mem.Allocator,

    /// SONNY-6544: `error.HomeNotSet` / `error.HomeNotAbsolute`
    /// (`home_dir.errorMessage`) for a missing, empty or relative HOME;
    /// `createDirAbsolute` below asserts an absolute path (a relative HOME
    /// panicked `geode query` in Debug).
    pub fn init(allocator: std.mem.Allocator) !CredentialStore {
        const home = try home_dir.homeDirAlloc(allocator);
        defer allocator.free(home);

        const geode_dir = try std.fmt.allocPrint(allocator, "{s}/.geode", .{home});
        defer allocator.free(geode_dir);

        // Create ~/.geode directory if it doesn't exist
        std.Io.Dir.createDirAbsolute(std.Io.Threaded.global_single_threaded.io(), geode_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});

        return CredentialStore{
            .file_path = file_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CredentialStore) void {
        self.allocator.free(self.file_path);
    }

    pub fn saveCredentials(self: *CredentialStore, creds: Credentials) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-002; FEATURE="SaveSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

        // SONNY-6463: Zig 0.16 file API (std.fs.createFileAbsolute and
        // ArrayList.writer are gone; this did not compile, and no step built it).
        const body = try std.fmt.allocPrint(self.allocator, "{{\n  \"token\": \"{s}\",\n  \"username\": \"{s}\",\n  \"server\": \"{s}\",\n  \"created_at\": {d},\n  \"system_fingerprint\": \"{s}\"\n}}\n", .{ creds.token, creds.username, creds.server, creds.created_at, creds.system_fingerprint });
        defer self.allocator.free(body);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.createFileAbsolute(io, self.file_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, body);
    }

    pub fn loadCredentials(self: *CredentialStore) !?Credentials {
        // CANARY: REQ=REQ-AUTH-SESSION-003; FEATURE="LoadSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.openFileAbsolute(io, self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        const file_len = try file.length(io);
        if (file_len > 4096) return error.FileTooBig;
        const content = try self.allocator.alloc(u8, @intCast(file_len));
        defer self.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        // Simple JSON parsing (for basic structure)
        var token: ?[]const u8 = null;
        var username: ?[]const u8 = null;
        var server: ?[]const u8 = null;
        var created_at: i64 = 0;
        var system_fingerprint: ?[]const u8 = null;

        var lines = std.mem.tokenizeAny(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t,");

            if (std.mem.indexOf(u8, trimmed, "\"token\"")) |_| {
                if (extractJsonString(trimmed)) |value| {
                    token = try self.allocator.dupe(u8, value);
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"username\"")) |_| {
                if (extractJsonString(trimmed)) |value| {
                    username = try self.allocator.dupe(u8, value);
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"server\"")) |_| {
                if (extractJsonString(trimmed)) |value| {
                    server = try self.allocator.dupe(u8, value);
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"created_at\"")) |_| {
                if (extractJsonNumber(trimmed)) |value| {
                    created_at = value;
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"system_fingerprint\"")) |_| {
                if (extractJsonString(trimmed)) |value| {
                    system_fingerprint = try self.allocator.dupe(u8, value);
                }
            }
        }

        if (token == null or username == null or server == null or system_fingerprint == null) {
            return null;
        }

        return Credentials{
            .token = token.?,
            .username = username.?,
            .server = server.?,
            .created_at = created_at,
            .system_fingerprint = system_fingerprint.?,
        };
    }

    pub fn deleteCredentials(self: *CredentialStore) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-004; FEATURE="DeleteSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14
        std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), self.file_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
};

fn extractJsonString(line: []const u8) ?[]const u8 {
    // Extract value from: "key": "value"
    const start_quote = std.mem.lastIndexOf(u8, line, "\"") orelse return null;
    const before_end = line[0..start_quote];
    const end_quote = std.mem.lastIndexOf(u8, before_end, "\"") orelse return null;
    return before_end[end_quote + 1 ..];
}

fn extractJsonNumber(line: []const u8) ?i64 {
    // Extract value from: "key": 123
    const colon = std.mem.lastIndexOf(u8, line, ":") orelse return null;
    const after_colon = std.mem.trim(u8, line[colon + 1 ..], " \t,");
    return std.fmt.parseInt(i64, after_colon, 10) catch null;
}

// Session token registry (server-side storage)
pub const SessionRegistry = struct {
    sessions: std.StringHashMap(SessionToken),
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionRegistry {
        return SessionRegistry{
            .sessions = std.StringHashMap(SessionToken).init(allocator),
            .mutex = std.Io.Mutex.init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionRegistry) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.username);
            self.allocator.free(entry.value_ptr.system_fingerprint);
        }
        self.sessions.deinit();
    }

    pub fn addSession(self: *SessionRegistry, token_hex: []const u8, session: SessionToken) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-005; FEATURE="RegisterSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const key = try self.allocator.dupe(u8, token_hex);
        try self.sessions.put(key, session);
    }

    pub fn getSession(self: *SessionRegistry, token_hex: []const u8) ?*SessionToken {
        // CANARY: REQ=REQ-AUTH-SESSION-006; FEATURE="ValidateSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return self.sessions.getPtr(token_hex);
    }

    pub fn removeSession(self: *SessionRegistry, token_hex: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.sessions.fetchRemove(token_hex)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.username);
            self.allocator.free(kv.value.system_fingerprint);
        }
    }

    pub fn cleanupExpired(self: *SessionRegistry) void {
        // CANARY: REQ=REQ-AUTH-SESSION-007; FEATURE="CleanupExpiredSessions"; ASPECT=IMPL; STATUS=IMPL; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-11-14

        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.username);
                self.allocator.free(kv.value.system_fingerprint);
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

// CANARY: REQ=REQ-SONNY-6476-FINGERPRINT-UID; FEATURE="CliSessionStorage"; ASPECT=PortableUid; STATUS=TESTED; TEST=src/cli/security/session_storage.zig; OWNER=cli; UPDATED=2026-11-13
test "SONNY-6476: the system fingerprint ends with this process's real uid, read the platform's way" {
    const fp = try getSystemFingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fp);
    const colon = std.mem.lastIndexOfScalar(u8, fp, ':') orelse return error.NoUid;
    const uid = try std.fmt.parseInt(u32, fp[colon + 1 ..], 10);
    const want: u32 = if (builtin.os.tag == .windows) 0 else @intCast(std.c.getuid());
    try std.testing.expectEqual(want, uid);
    try std.testing.expectEqual(want, currentUid());
}

test "SessionToken.generate creates valid token" {
    const allocator = std.testing.allocator;

    const token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    // Token should be 32 bytes
    try std.testing.expectEqual(@as(usize, 32), token.token.len);

    // Username should match
    try std.testing.expectEqualStrings("testuser", token.username);

    // System fingerprint should be non-empty
    try std.testing.expect(token.system_fingerprint.len > 0);

    // Timestamps should be valid
    try std.testing.expect(token.created_at > 0);
    try std.testing.expect(token.expires_at > token.created_at);
    try std.testing.expectEqual(token.created_at, token.last_renewed_at);
}

test "SessionToken.toHexString produces 64 character hex" {
    const allocator = std.testing.allocator;

    const token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    const hex = try token.toHexString(allocator);
    defer allocator.free(hex);

    // Should be 64 hex characters (32 bytes * 2)
    try std.testing.expectEqual(@as(usize, 64), hex.len);

    // Should only contain valid hex characters
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "SessionToken.isExpired detects expired tokens" {
    const allocator = std.testing.allocator;

    var token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    // Fresh token should not be expired
    try std.testing.expect(!token.isExpired());

    // Manually expire the token
    token.expires_at = compat_timestamp() - 1;
    try std.testing.expect(token.isExpired());
}

test "SessionToken.needsRenewal detects renewal threshold" {
    const allocator = std.testing.allocator;

    var token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    // Fresh token should not need renewal (1 hour until expiry)
    try std.testing.expect(!token.needsRenewal());

    // Set expiry to 4 minutes from now (< 5 minute threshold)
    token.expires_at = compat_timestamp() + 240;
    try std.testing.expect(token.needsRenewal());
}

test "SessionToken.renew extends expiration" {
    const allocator = std.testing.allocator;

    var token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    const original_expires = token.expires_at;

    token.renew();

    // Expiration should be extended (renew adds TOKEN_LIFETIME_SECS from current time)
    // Since time has passed, new expiry should be at least as far in future
    try std.testing.expect(token.expires_at >= original_expires);

    // Last renewed should be updated to current time
    try std.testing.expect(token.last_renewed_at >= token.created_at);
}

test "SessionToken.isValid checks fingerprint and expiry" {
    const allocator = std.testing.allocator;

    var token = try SessionToken.generate(allocator, "testuser");
    defer allocator.free(token.username);
    defer allocator.free(token.system_fingerprint);

    const current_fp = try getSystemFingerprint(allocator);
    defer allocator.free(current_fp);

    // Valid with correct fingerprint
    try std.testing.expect(token.isValid(current_fp));

    // Invalid with wrong fingerprint
    try std.testing.expect(!token.isValid("wrong:fingerprint:123"));

    // Invalid when expired (even with correct fingerprint)
    token.expires_at = compat_timestamp() - 1;
    try std.testing.expect(!token.isValid(current_fp));
}

/// SONNY-6463: the CredentialStore tests run against a private HOME (a test
/// temporary directory). They used to write the real ~/.geode/credentials.json
/// and "restore" it best-effort, and did not compile under Zig 0.16
/// (std.fs.copyFileAbsolute is gone), so no step ran them.
const TestHome = struct {
    tmp: std.testing.TmpDir,
    old_home: ?[:0]u8,

    fn enter() !TestHome {
        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(std.Io.Threaded.global_single_threaded.io(), &buf);
        const old = if (std.c.getenv("HOME")) |h| try std.testing.allocator.dupeZ(u8, std.mem.span(h)) else null;
        errdefer if (old) |o| std.testing.allocator.free(o);
        const path_z = try std.testing.allocator.dupeZ(u8, buf[0..n]);
        defer std.testing.allocator.free(path_z);
        if (setenv("HOME", path_z, 1) != 0) return error.SetEnvFailed;
        return .{ .tmp = tmp, .old_home = old };
    }

    fn leave(self: *TestHome) void {
        if (self.old_home) |o| {
            _ = setenv("HOME", o, 1);
            std.testing.allocator.free(o);
        } else {
            _ = unsetenv("HOME");
        }
        self.tmp.cleanup();
    }

    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

test "CredentialStore.saveCredentials and loadCredentials roundtrip" {
    const allocator = std.testing.allocator;
    var home = try TestHome.enter();
    defer home.leave();

    var store = try CredentialStore.init(allocator);
    defer store.deinit();

    // Create test credentials
    const creds = Credentials{
        .token = "test-session-token-aaaaaaaa-bbbbbbbb-cccccccc-dddddddd",
        .username = "test_alice",
        .server = "127.0.0.1:3141",
        .created_at = 1234567890,
        .system_fingerprint = "testhost:testuser:1000",
    };

    // Save credentials
    try store.saveCredentials(creds);

    // Load credentials
    const loaded = try store.loadCredentials();
    try std.testing.expect(loaded != null);

    if (loaded) |l| {
        defer allocator.free(l.token);
        defer allocator.free(l.username);
        defer allocator.free(l.server);
        defer allocator.free(l.system_fingerprint);

        try std.testing.expectEqualStrings(creds.token, l.token);
        try std.testing.expectEqualStrings(creds.username, l.username);
        try std.testing.expectEqualStrings(creds.server, l.server);
        try std.testing.expectEqual(creds.created_at, l.created_at);
        try std.testing.expectEqualStrings(creds.system_fingerprint, l.system_fingerprint);
    }

    // Cleanup test file
    try store.deleteCredentials();
}

test "CredentialStore.deleteCredentials removes file" {
    const allocator = std.testing.allocator;

    var home = try TestHome.enter();
    defer home.leave();

    var store = try CredentialStore.init(allocator);
    defer store.deinit();

    const creds = Credentials{
        .token = "testtoken_delete",
        .username = "test_bob",
        .server = "127.0.0.1:3141",
        .created_at = 1234567890,
        .system_fingerprint = "test:fp:123",
    };

    try store.saveCredentials(creds);

    // Verify file exists
    var loaded = try store.loadCredentials();
    try std.testing.expect(loaded != null);
    if (loaded) |l| {
        allocator.free(l.token);
        allocator.free(l.username);
        allocator.free(l.server);
        allocator.free(l.system_fingerprint);
    }

    // Delete credentials
    try store.deleteCredentials();

    // Verify file is gone
    loaded = try store.loadCredentials();
    try std.testing.expect(loaded == null);
}

test "SessionRegistry.addSession and getSession" {
    const allocator = std.testing.allocator;

    var registry = SessionRegistry.init(allocator);
    defer registry.deinit();

    var token = try SessionToken.generate(allocator, "testuser");
    const token_hex = try token.toHexString(allocator);
    defer allocator.free(token_hex);

    // Add session
    try registry.addSession(token_hex, token);

    // Retrieve session
    const retrieved = registry.getSession(token_hex);
    try std.testing.expect(retrieved != null);

    if (retrieved) |r| {
        try std.testing.expectEqualStrings("testuser", r.username);
        try std.testing.expectEqual(token.created_at, r.created_at);
    }
}

test "SessionRegistry.removeSession deletes session" {
    const allocator = std.testing.allocator;

    var registry = SessionRegistry.init(allocator);
    defer registry.deinit();

    var token = try SessionToken.generate(allocator, "testuser");
    const token_hex = try token.toHexString(allocator);
    defer allocator.free(token_hex);

    try registry.addSession(token_hex, token);

    // Verify session exists
    var retrieved = registry.getSession(token_hex);
    try std.testing.expect(retrieved != null);

    // Remove session
    registry.removeSession(token_hex);

    // Verify session is gone
    retrieved = registry.getSession(token_hex);
    try std.testing.expect(retrieved == null);
}

test "SessionRegistry.cleanupExpired removes only expired sessions" {
    const allocator = std.testing.allocator;

    var registry = SessionRegistry.init(allocator);
    defer registry.deinit();

    // Create valid token
    var valid_token = try SessionToken.generate(allocator, "valid_user");
    const valid_hex = try valid_token.toHexString(allocator);
    defer allocator.free(valid_hex);
    try registry.addSession(valid_hex, valid_token);

    // Create expired token
    var expired_token = try SessionToken.generate(allocator, "expired_user");
    expired_token.expires_at = compat_timestamp() - 1;
    const expired_hex = try expired_token.toHexString(allocator);
    defer allocator.free(expired_hex);
    try registry.addSession(expired_hex, expired_token);

    // Cleanup expired sessions
    registry.cleanupExpired();

    // Valid session should still exist
    try std.testing.expect(registry.getSession(valid_hex) != null);

    // Expired session should be removed
    try std.testing.expect(registry.getSession(expired_hex) == null);
}

test "getSystemFingerprint returns valid format" {
    const allocator = std.testing.allocator;

    const fp = try getSystemFingerprint(allocator);
    defer allocator.free(fp);

    // Should contain at least one colon (hostname:username:uid)
    try std.testing.expect(std.mem.indexOf(u8, fp, ":") != null);

    // Should be non-empty
    try std.testing.expect(fp.len > 0);
}

test "extractJsonString parses JSON value" {
    const line = "  \"token\": \"abc123\",";
    const value = extractJsonString(line);

    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings("abc123", v);
    }
}

test "extractJsonNumber parses integer value" {
    const line = "  \"created_at\": 1234567890,";
    const value = extractJsonNumber(line);

    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqual(@as(i64, 1234567890), v);
    }
}
