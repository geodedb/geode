// CANARY: REQ=REQ-AUTH-SESSION-001; FEATURE="LocalSessionStorage"; ASPECT=SECURITY; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_001; OWNER=security; UPDATED=2025-10-14

const std = @import("std");
const crypto = std.crypto;

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
        crypto.random.bytes(&token);

        const now = std.time.timestamp();
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
        const now = std.time.timestamp();
        const time_remaining = self.expires_at - now;
        return time_remaining < RENEWAL_THRESHOLD_SECS;
    }

    pub fn renew(self: *SessionToken) void {
        const now = std.time.timestamp();
        self.last_renewed_at = now;
        self.expires_at = now + TOKEN_LIFETIME_SECS;
    }

    pub fn isExpired(self: *const SessionToken) bool {
        return std.time.timestamp() >= self.expires_at;
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
    // Get hostname
    var hostname_buf: [64]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "unknown";

    // Get system username
    const uid = std.posix.getuid();
    const username = std.posix.getenv("USER") orelse std.posix.getenv("USERNAME") orelse "unknown";

    // Combine: hostname:username:uid
    return std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ hostname, username, uid });
}

/// Credential storage manager
pub const CredentialStore = struct {
    file_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CredentialStore {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const geode_dir = try std.fmt.allocPrint(allocator, "{s}/.geode", .{home});
        defer allocator.free(geode_dir);

        // Create ~/.geode directory if it doesn't exist
        std.fs.makeDirAbsolute(geode_dir) catch |err| {
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
        // CANARY: REQ=REQ-AUTH-SESSION-002; FEATURE="SaveSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_002; OWNER=security; UPDATED=2025-10-14

        const file = try std.fs.createFileAbsolute(self.file_path, .{ .truncate = true });
        defer file.close();

        // Set restrictive permissions (600 - owner read/write only)
        try file.chmod(0o600);

        // Write JSON
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 256) catch unreachable;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);
        try writer.print("{{\n", .{});
        try writer.print("  \"token\": \"{s}\",\n", .{creds.token});
        try writer.print("  \"username\": \"{s}\",\n", .{creds.username});
        try writer.print("  \"server\": \"{s}\",\n", .{creds.server});
        try writer.print("  \"created_at\": {d},\n", .{creds.created_at});
        try writer.print("  \"system_fingerprint\": \"{s}\"\n", .{creds.system_fingerprint});
        try writer.print("}}\n", .{});

        try file.writeAll(buf.items);
    }

    pub fn loadCredentials(self: *CredentialStore) !?Credentials {
        // CANARY: REQ=REQ-AUTH-SESSION-003; FEATURE="LoadSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_003; OWNER=security; UPDATED=2025-10-14

        const file = std.fs.openFileAbsolute(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 4096);
        defer self.allocator.free(content);

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
        // CANARY: REQ=REQ-AUTH-SESSION-004; FEATURE="DeleteSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_004; OWNER=security; UPDATED=2025-10-14
        std.fs.deleteFileAbsolute(self.file_path) catch |err| {
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
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionRegistry {
        return SessionRegistry{
            .sessions = std.StringHashMap(SessionToken).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.username);
            self.allocator.free(entry.value_ptr.system_fingerprint);
        }
        self.sessions.deinit();
    }

    pub fn addSession(self: *SessionRegistry, token_hex: []const u8, session: SessionToken) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-005; FEATURE="RegisterSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_005; OWNER=security; UPDATED=2025-10-14

        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, token_hex);
        try self.sessions.put(key, session);
    }

    pub fn getSession(self: *SessionRegistry, token_hex: []const u8) ?*SessionToken {
        // CANARY: REQ=REQ-AUTH-SESSION-006; FEATURE="ValidateSessionToken"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_006; OWNER=security; UPDATED=2025-10-14

        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.getPtr(token_hex);
    }

    pub fn removeSession(self: *SessionRegistry, token_hex: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(token_hex)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.username);
            self.allocator.free(kv.value.system_fingerprint);
        }
    }

    pub fn cleanupExpired(self: *SessionRegistry) void {
        // CANARY: REQ=REQ-AUTH-SESSION-007; FEATURE="CleanupExpiredSessions"; ASPECT=IMPL; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_SESSION_007; OWNER=security; UPDATED=2025-10-14

        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                to_remove.append(entry.key_ptr.*) catch continue;
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
