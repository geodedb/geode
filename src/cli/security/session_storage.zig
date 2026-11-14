// CANARY: REQ=REQ-AUTH-SESSION-001; FEATURE="LocalSessionStorage"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14

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

/// SONNY-6551: one saved session (`~/.geode/credentials.json`), as written by
/// `geode auth login --save-session` and read by `geode query`.
pub const Credentials = struct {
    /// The `--server` address the session was obtained from.
    server: []const u8,
    username: []const u8,
    /// The session id the server returned in its HELLO.
    token: []const u8,
    /// Unix seconds.
    created_at: i64,
    /// Unix seconds; the session is not offered at or after this time.
    expires_at: i64,
    /// `getSystemFingerprint()` of the process that saved it.
    system_fingerprint: []const u8,
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

// CANARY: REQ=REQ-SONNY-6551-SAVED-SESSION-FILE; FEATURE="LocalSessionStorage"; ASPECT=OneWriterOneReaderSafeFile; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14
/// SONNY-6551: the one writer and the one reader of the saved session file
/// `<HOME>/.geode/credentials.json` (docs/SESSION_MANAGEMENT.md).
///
/// Format: one std.json object, `file_version` 1, exactly the fields of
/// `Credentials` plus `version`; every string is JSON-escaped. A file with a
/// missing, extra or mistyped field (an older geode's `session_token` file
/// included) is not read.
///
/// Writing: `~/.geode` is created mode 0700, opened without following a
/// symbolic link, and must belong to this user; group or other access on an
/// existing one is removed. The file is written to a new temporary file
/// (O_CREAT|O_EXCL, mode 0600) in that directory, synced and renamed over
/// `credentials.json`: a reader sees the old file or the new one, and a
/// symbolic link at the final path is replaced, never followed.
///
/// Reading creates nothing. The file is not read (`LoadResult.ignored`)
/// when `~/.geode` is a symbolic link, belongs to another user or is
/// writable by group or other, or when `credentials.json` is a symbolic
/// link, not a regular file, belongs to another user, has group or other
/// permissions (as ssh treats a private key), is larger than
/// `max_file_bytes` or is not the format above.
pub const CredentialStore = struct {
    /// `<HOME>/.geode`.
    dir_path: []u8,
    allocator: std.mem.Allocator,

    pub const file_name = "credentials.json";
    pub const file_version: i64 = 1;
    pub const max_file_bytes: u64 = 16 * 1024;

    /// The JSON object on disk.
    const FileV1 = struct {
        version: i64,
        server: []const u8,
        username: []const u8,
        token: []const u8,
        created_at: i64,
        expires_at: i64,
        system_fingerprint: []const u8,
    };

    pub const SaveError = error{
        /// `~/.geode` is a symbolic link or not a directory, or belongs to
        /// another user.
        CredentialsDirUnsafe,
    };

    /// Why a file that is there was not read.
    pub const Ignored = enum {
        directory_unsafe,
        symlink,
        not_regular_file,
        not_owned,
        permissions_too_open,
        too_large,
        unreadable,
        malformed,
    };

    pub const Loaded = struct {
        parsed: std.json.Parsed(FileV1),

        pub fn credentials(self: *const Loaded) Credentials {
            const v = self.parsed.value;
            return .{
                .server = v.server,
                .username = v.username,
                .token = v.token,
                .created_at = v.created_at,
                .expires_at = v.expires_at,
                .system_fingerprint = v.system_fingerprint,
            };
        }
    };

    pub const LoadResult = union(enum) {
        /// No `~/.geode` or no `credentials.json`.
        none,
        loaded: Loaded,
        ignored: Ignored,

        pub fn deinit(self: *LoadResult) void {
            switch (self.*) {
                .loaded => |*l| {
                    std.crypto.secureZero(u8, @constCast(l.parsed.value.token));
                    l.parsed.deinit();
                },
                else => {},
            }
            self.* = .none;
        }
    };

    /// Resolves `<HOME>/.geode` (`home_dir`: `error.HomeNotSet` /
    /// `error.HomeNotAbsolute` for an unusable HOME). Creates nothing.
    pub fn init(allocator: std.mem.Allocator) !CredentialStore {
        return .{
            .dir_path = try home_dir.homePathAlloc(allocator, &.{".geode"}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CredentialStore) void {
        self.allocator.free(self.dir_path);
    }

    /// The JSON text `save` writes (and `geode auth token` prints). The
    /// caller zeroes and frees it.
    pub fn encode(allocator: std.mem.Allocator, creds: Credentials) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, FileV1{
            .version = file_version,
            .server = creds.server,
            .username = creds.username,
            .token = creds.token,
            .created_at = creds.created_at,
            .expires_at = creds.expires_at,
            .system_fingerprint = creds.system_fingerprint,
        }, .{});
    }

    /// Decode `text`; `error.MalformedCredentials` for anything but the
    /// documented format. The caller deinits the result.
    pub fn decode(allocator: std.mem.Allocator, text: []const u8) error{ MalformedCredentials, OutOfMemory }!std.json.Parsed(FileV1) {
        const parsed = std.json.parseFromSlice(FileV1, allocator, text, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedCredentials,
        };
        const v = parsed.value;
        if (v.version != file_version or v.server.len == 0 or v.username.len == 0 or
            v.token.len == 0 or v.system_fingerprint.len == 0)
        {
            std.crypto.secureZero(u8, @constCast(v.token));
            parsed.deinit();
            return error.MalformedCredentials;
        }
        return parsed;
    }

    pub fn save(self: *CredentialStore, creds: Credentials) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-002; FEATURE="SaveSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.createDirAbsolute(io, self.dir_path, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var dir = std.Io.Dir.openDirAbsolute(io, self.dir_path, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.SymLinkLoop, error.NotDir => return error.CredentialsDirUnsafe,
            else => return err,
        };
        defer dir.close(io);
        const st = fdStat(dir.handle) orelse return error.CredentialsDirUnsafe;
        if (st.uid != currentUid()) return error.CredentialsDirUnsafe;
        if (st.mode & 0o077 != 0) try dir.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));

        const body = try encode(self.allocator, creds);
        defer {
            std.crypto.secureZero(u8, body);
            self.allocator.free(body);
        }

        var rnd: [8]u8 = undefined;
        try cb.Csprng.bytes(&rnd);
        var tmp_buf: [64]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, file_name ++ ".tmp-{x}", .{&rnd});
        const file = try dir.createFile(io, tmp_name, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        var renamed = false;
        defer if (!renamed) dir.deleteFile(io, tmp_name) catch {};
        {
            defer file.close(io);
            try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
            try file.writeStreamingAll(io, body);
            try file.sync(io);
        }
        try std.Io.Dir.rename(dir, tmp_name, dir, file_name, io);
        renamed = true;
    }

    pub fn load(self: *CredentialStore) !LoadResult {
        // CANARY: REQ=REQ-AUTH-SESSION-003; FEATURE="LoadSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.openDirAbsolute(io, self.dir_path, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .none,
            error.SymLinkLoop, error.NotDir => return .{ .ignored = .directory_unsafe },
            else => return .{ .ignored = .unreadable },
        };
        defer dir.close(io);
        const dst = fdStat(dir.handle) orelse return .{ .ignored = .unreadable };
        if (dst.uid != currentUid() or dst.mode & 0o022 != 0) return .{ .ignored = .directory_unsafe };

        const file = dir.openFile(io, file_name, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return .none,
            error.SymLinkLoop => return .{ .ignored = .symlink },
            error.IsDir => return .{ .ignored = .not_regular_file },
            else => return .{ .ignored = .unreadable },
        };
        defer file.close(io);
        const st = fdStat(file.handle) orelse return .{ .ignored = .unreadable };
        if (st.mode & S_IFMT != S_IFREG) return .{ .ignored = .not_regular_file };
        if (st.uid != currentUid()) return .{ .ignored = .not_owned };
        if (st.mode & 0o077 != 0) return .{ .ignored = .permissions_too_open };

        const len = file.length(io) catch return .{ .ignored = .unreadable };
        if (len > max_file_bytes) return .{ .ignored = .too_large };
        const content = try self.allocator.alloc(u8, @intCast(len));
        defer {
            std.crypto.secureZero(u8, content);
            self.allocator.free(content);
        }
        const n = file.readPositionalAll(io, content, 0) catch return .{ .ignored = .unreadable };
        const parsed = decode(self.allocator, content[0..n]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedCredentials => return .{ .ignored = .malformed },
        };
        return .{ .loaded = .{ .parsed = parsed } };
    }

    /// Remove `credentials.json` (a symbolic link there is removed, not its
    /// target). Creates nothing.
    pub fn delete(self: *CredentialStore) !void {
        // CANARY: REQ=REQ-AUTH-SESSION-004; FEATURE="DeleteSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.openDirAbsolute(io, self.dir_path, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        dir.deleteFile(io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

/// What `geode query` may do with a saved session.
pub const Applies = enum {
    /// Saved by this OS user on this host, for `server`, not expired.
    usable,
    /// `system_fingerprint` differs: another OS user or another host saved it.
    foreign,
    other_server,
    expired,
};

/// SONNY-6551: `system_fingerprint` (hostname:user:uid) binds the file to the
/// OS account and host that saved it, so a file that travelled (a copied or
/// restored home directory, an NFS home shared between hosts) is not
/// offered. It is not a secret and not authentication: a mismatch guard.
pub fn applies(creds: Credentials, server: []const u8, now: i64, current_fingerprint: []const u8) Applies {
    if (!std.mem.eql(u8, creds.system_fingerprint, current_fingerprint)) return .foreign;
    if (!std.mem.eql(u8, creds.server, server)) return .other_server;
    if (now >= creds.expires_at or creds.created_at > now + 300) return .expired;
    return .usable;
}

/// The reason printed after `Warning: saved session ignored: `.
pub fn ignoredMessage(why: CredentialStore.Ignored) []const u8 {
    return switch (why) {
        .directory_unsafe => "~/.geode is a symbolic link, not a directory, not owned by you, or writable by other users (it must be your own directory, mode 0700)",
        .symlink => "~/.geode/credentials.json is a symbolic link",
        .not_regular_file => "~/.geode/credentials.json is not a regular file",
        .not_owned => "~/.geode/credentials.json is not owned by you",
        .permissions_too_open => "~/.geode/credentials.json is accessible by other users (chmod 600 it, or log in again)",
        .too_large => "~/.geode/credentials.json is too large to be a saved session",
        .unreadable => "~/.geode/credentials.json cannot be read",
        .malformed => "~/.geode/credentials.json is not a saved session this geode can read (damaged, or written by an older geode); run 'geode auth login --save-session' again",
    };
}

/// What is wrong when `save` fails, for an `Error: ...` line.
pub fn saveErrorMessage(err: anyerror) ?[]const u8 {
    if (home_dir.errorMessage(err)) |why| return why;
    return switch (err) {
        error.CredentialsDirUnsafe => "~/.geode is a symbolic link, not a directory, or not owned by you; the session token is not written there",
        else => null,
    };
}

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;

const FdStat = struct { uid: u32, mode: u32 };

/// Owner and mode of an open descriptor; null when fstat fails.
fn fdStat(fd: std.posix.fd_t) ?FdStat {
    switch (comptime builtin.os.tag) {
        .windows => return null,
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &stx);
            if (linux.errno(rc) != .SUCCESS) return null;
            return .{ .uid = stx.uid, .mode = stx.mode };
        },
        else => {
            var st: std.c.Stat = undefined;
            if (std.c.fstat(fd, &st) != 0) return null;
            return .{ .uid = @intCast(st.uid), .mode = @intCast(st.mode) };
        },
    }
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
        // CANARY: REQ=REQ-AUTH-SESSION-005; FEATURE="RegisterSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=src/cli/security/session_storage.zig; OWNER=security; UPDATED=2026-11-14

        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const key = try self.allocator.dupe(u8, token_hex);
        try self.sessions.put(key, session);
    }

    pub fn getSession(self: *SessionRegistry, token_hex: []const u8) ?*SessionToken {
        // CANARY: REQ=REQ-AUTH-SESSION-006; FEATURE="ValidateSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=src/cli/security/session_storage.zig; OWNER=security; UPDATED=2026-11-14

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
        // CANARY: REQ=REQ-AUTH-SESSION-007; FEATURE="CleanupExpiredSessions"; ASPECT=IMPL; STATUS=TESTED; TEST=src/cli/security/session_storage.zig; OWNER=security; UPDATED=2026-11-14

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

fn expectSameCredentials(want: Credentials, got: Credentials) !void {
    try std.testing.expectEqualStrings(want.server, got.server);
    try std.testing.expectEqualStrings(want.username, got.username);
    try std.testing.expectEqualStrings(want.token, got.token);
    try std.testing.expectEqual(want.created_at, got.created_at);
    try std.testing.expectEqual(want.expires_at, got.expires_at);
    try std.testing.expectEqualStrings(want.system_fingerprint, got.system_fingerprint);
}

test "SONNY-6551: CredentialStore.save and load round-trip every field, escaped" {
    const allocator = std.testing.allocator;
    var home = try TestHome.enter();
    defer home.leave();

    var store = try CredentialStore.init(allocator);
    defer store.deinit();

    // Quotes, backslashes and control characters must be JSON-escaped.
    const creds = Credentials{
        .token = "tok\"en\\with\nnewline",
        .username = "test \"alice\" \\ o'brien",
        .server = "127.0.0.1:3141",
        .created_at = 1234567890,
        .expires_at = 1234567890 + 86400,
        .system_fingerprint = "testhost:testuser:1000",
    };
    try store.save(creds);

    var result = try store.load();
    defer result.deinit();
    switch (result) {
        .loaded => |*l| try expectSameCredentials(creds, l.credentials()),
        else => return error.NotLoaded,
    }

    try store.delete();
    var gone = try store.load();
    defer gone.deinit();
    try std.testing.expect(gone == .none);
}

test "SONNY-6551: CredentialStore.decode refuses anything but the documented format" {
    const allocator = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "{",
        "[]",
        // An older geode's file.
        "{\"server\":\"h:1\",\"username\":\"u\",\"session_token\":\"t\",\"expires_at\":1}",
        // A missing field.
        "{\"version\":1,\"server\":\"h:1\",\"username\":\"u\",\"token\":\"t\",\"created_at\":1,\"expires_at\":2}",
        // An unknown field.
        "{\"version\":1,\"server\":\"h:1\",\"username\":\"u\",\"token\":\"t\",\"created_at\":1,\"expires_at\":2,\"system_fingerprint\":\"f\",\"x\":1}",
        // Another version.
        "{\"version\":2,\"server\":\"h:1\",\"username\":\"u\",\"token\":\"t\",\"created_at\":1,\"expires_at\":2,\"system_fingerprint\":\"f\"}",
        // An empty token.
        "{\"version\":1,\"server\":\"h:1\",\"username\":\"u\",\"token\":\"\",\"created_at\":1,\"expires_at\":2,\"system_fingerprint\":\"f\"}",
        // A mistyped field.
        "{\"version\":1,\"server\":7,\"username\":\"u\",\"token\":\"t\",\"created_at\":1,\"expires_at\":2,\"system_fingerprint\":\"f\"}",
    };
    for (bad) |text| {
        try std.testing.expectError(error.MalformedCredentials, CredentialStore.decode(allocator, text));
    }
    const good = "{\"version\":1,\"server\":\"h:1\",\"username\":\"u\",\"token\":\"t\",\"created_at\":1,\"expires_at\":2,\"system_fingerprint\":\"f\"}";
    const parsed = try CredentialStore.decode(allocator, good);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("t", parsed.value.token);
}

test "SONNY-6551: a load creates no ~/.geode, and a missing file is none" {
    const allocator = std.testing.allocator;
    var home = try TestHome.enter();
    defer home.leave();

    var store = try CredentialStore.init(allocator);
    defer store.deinit();
    var result = try store.load();
    defer result.deinit();
    try std.testing.expect(result == .none);
    try store.delete();
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.FileNotFound, home.tmp.dir.statFile(io, ".geode", .{}));
}

test "SONNY-6551: applies() checks fingerprint, then server, then expiry" {
    const creds = Credentials{
        .token = "t",
        .username = "u",
        .server = "h:1",
        .created_at = 100,
        .expires_at = 200,
        .system_fingerprint = "fp",
    };
    try std.testing.expectEqual(Applies.usable, applies(creds, "h:1", 150, "fp"));
    try std.testing.expectEqual(Applies.foreign, applies(creds, "h:1", 150, "other"));
    try std.testing.expectEqual(Applies.other_server, applies(creds, "h:2", 150, "fp"));
    try std.testing.expectEqual(Applies.expired, applies(creds, "h:1", 200, "fp"));
    // Created in the future (a clock moved back, or a forged file).
    try std.testing.expectEqual(Applies.expired, applies(creds, "h:1", -400, "fp"));
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
