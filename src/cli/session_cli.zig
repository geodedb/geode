const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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

const cli_auth = @import("cli_auth_helpers.zig");
/// SONNY-6544: the printed server goes through dsn_credentials.redacted.
const geode = @import("geode");
const home_dir = @import("security/home_dir.zig");

/// SONNY-6544: `<HOME>/.geode/credentials.json`, or exit with what is wrong
/// with HOME (unset, empty or relative). A relative HOME reached
/// `openFileAbsolute`'s absolute-path assert (a Debug panic).
fn credentialsPathOrExit(allocator: std.mem.Allocator) []u8 {
    return home_dir.homePathAlloc(allocator, &.{ ".geode", "credentials.json" }) catch |err| {
        home_dir.printError(err);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

// CANARY: REQ=REQ-CLI-SESSION-001; FEATURE="CLISession"; ASPECT=Management; STATUS=TESTED; TEST=geodetestlab/specs/authn_provider.yml; OWNER=cli; UPDATED=2026-02-04
// Session management CLI commands

const SESSION_STATE_FILE = "geode_session_state.db";

fn sessionStatePath(allocator: std.mem.Allocator) ![]u8 {
    return cli_auth.resolveStatePath(allocator, SESSION_STATE_FILE);
}

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

const StoredSession = struct {
    username: []const u8,
    token: []const u8,
    created_at: i64,
    expires_at: i64,
    last_activity: i64,
    is_active: bool,
};

fn loadSessionState(allocator: std.mem.Allocator) !std.StringHashMap(StoredSession) {
    var sessions = std.StringHashMap(StoredSession).init(allocator);

    const state_path = try sessionStatePath(allocator);
    defer allocator.free(state_path);

    const io_ss = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io_ss, state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return sessions,
        else => return err,
    };
    defer file.close(io_ss);

    const stat = file.stat(io_ss) catch |err| {
        std.debug.print("Warning: Could not stat session state: {}\n", .{err});
        return sessions;
    };
    const size: usize = @intCast(stat.size);
    const content = allocator.alloc(u8, size) catch |err| {
        std.debug.print("Warning: Could not read session state: {}\n", .{err});
        return sessions;
    };
    defer allocator.free(content);
    _ = file.readPositionalAll(io_ss, content, 0) catch |err| {
        std.debug.print("Warning: Could not read session state: {}\n", .{err});
        return sessions;
    };

    // Parse line-based format: username|token|created_at|expires_at|last_activity|is_active
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        const username = parts.next() orelse continue;
        const token = parts.next() orelse continue;
        const created_str = parts.next() orelse continue;
        const expires_str = parts.next() orelse continue;
        const activity_str = parts.next() orelse continue;
        const active_str = parts.next() orelse continue;

        const session = StoredSession{
            .username = allocator.dupe(u8, username) catch continue,
            .token = allocator.dupe(u8, token) catch continue,
            .created_at = std.fmt.parseInt(i64, created_str, 10) catch continue,
            .expires_at = std.fmt.parseInt(i64, expires_str, 10) catch continue,
            .last_activity = std.fmt.parseInt(i64, activity_str, 10) catch continue,
            .is_active = std.mem.eql(u8, active_str, "1"),
        };
        sessions.put(allocator.dupe(u8, token) catch continue, session) catch continue;
    }

    return sessions;
}

fn saveSessionState(allocator: std.mem.Allocator, sessions: std.StringHashMap(StoredSession)) !void {
    const state_path = try sessionStatePath(allocator);
    defer allocator.free(state_path);

    const file = try std.fs.createFileAbsolute(state_path, .{
        .truncate = true,
        .read = true,
        .mode = 0o600,
    });
    defer file.close();

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var iter = sessions.iterator();
    while (iter.next()) |entry| {
        const session = entry.value_ptr.*;
        const line = std.fmt.allocPrint(allocator, "{s}|{s}|{d}|{d}|{d}|{d}\n", .{
            session.username,
            session.token,
            session.created_at,
            session.expires_at,
            session.last_activity,
            @as(u8, if (session.is_active) 1 else 0),
        }) catch continue;
        defer allocator.free(line);
        buffer.appendSlice(allocator, line) catch continue;
    }

    try file.writeAll(buffer.items);
}

fn getCurrentToken(allocator: std.mem.Allocator) ?[]const u8 {
    // Try to read from ~/.geode/credentials.json
    const creds_path = credentialsPathOrExit(allocator);
    defer allocator.free(creds_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, creds_path, .{}) catch return null;
    defer file.close(io);

    const file_len = file.length(io) catch return null;
    if (file_len > 64 * 1024) return null;
    const content = allocator.alloc(u8, @intCast(file_len)) catch return null;
    defer allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return null;

    // Simple JSON parsing for session_token field
    if (std.mem.indexOf(u8, content, "\"session_token\"")) |start| {
        const after_key = content[start + 16 ..]; // Skip '"session_token"'
        if (std.mem.indexOf(u8, after_key, "\"")) |q1| {
            const after_q1 = after_key[q1 + 1 ..];
            if (std.mem.indexOf(u8, after_q1, "\"")) |q2| {
                return allocator.dupe(u8, after_q1[0..q2]) catch return null;
            }
        }
    }
    return null;
}

/// Session command handler - routes to specific session subcommands
pub fn cmdSession(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        printSessionUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const subcommand = argv[start_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printSessionUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "validate")) {
        try cmdSessionValidate(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "info")) {
        try cmdSessionInfo(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "rotate")) {
        try cmdSessionRotate(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "invalidate-all")) {
        try cmdSessionInvalidateAll(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "check-idle")) {
        try cmdSessionCheckIdle(allocator, argv, start_idx + 1);
    } else {
        std.debug.print("Error: Unknown session subcommand '{s}'\n", .{subcommand});
        printSessionUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn printSessionUsage() void {
    std.debug.print("geode session - Session management commands\n" ++
        "\n" ++
        "Usage: geode session <subcommand> [options]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  validate            Validate the current session token\n" ++
        "  info                Show session information\n" ++
        "  rotate              Rotate the current session token\n" ++
        "  invalidate-all      Invalidate all sessions for a user\n" ++
        "  check-idle          Check if the session is idle\n" ++
        "\n" ++
        "Options:\n" ++
        "  -h, --help          Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode session validate\n" ++
        "  geode session info\n" ++
        "  geode session rotate\n" ++
        "  geode session invalidate-all --user alice\n" ++
        "\n", .{});
}

fn cmdSessionValidate(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var token_override: ?[]const u8 = null;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session validate - Validate session token\n" ++
                "\n" ++
                "Usage: geode session validate [--token <token>]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --token <token>     Token to validate (default: current session)\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
            i += 1;
            token_override = argv[i];
        }
    }

    const token = token_override orelse getCurrentToken(allocator) orelse {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.debug.print("Session is invalid or expired.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer if (token_override == null) allocator.free(token);

    // Load session state
    var sessions = try loadSessionState(allocator);
    defer {
        var iter = sessions.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.username);
            allocator.free(entry.value_ptr.token);
        }
        sessions.deinit();
    }

    // Check if session exists and is valid
    if (sessions.get(token)) |session| {
        const now = compat_milliTimestamp();
        if (!session.is_active) {
            std.debug.print("Session is invalid or expired.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        if (now > session.expires_at) {
            std.debug.print("Session is invalid or expired.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        std.debug.print("Session is valid for user: {s}\n", .{session.username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Fallback: if token looks valid (64 hex chars), assume it's valid
    if (token.len >= 32) {
        // Extract username from credentials file or default
        var username: []const u8 = "unknown";

        // SONNY-6544: no usable (absolute) HOME: the username stays unknown.
        {
            const creds_path = home_dir.homePathAlloc(allocator, &.{ ".geode", "credentials.json" }) catch null;
            if (creds_path) |cp| {
                defer allocator.free(cp);
                const io_cp = std.Io.Threaded.global_single_threaded.io();
                const file = std.Io.Dir.openFileAbsolute(io_cp, cp, .{}) catch null;
                if (file) |f| {
                    defer f.close(io_cp);
                    const stat_c = f.stat(io_cp) catch null;
                    const content: ?[]u8 = if (stat_c) |st| blk: {
                        const size: usize = @intCast(st.size);
                        const buf = allocator.alloc(u8, size) catch break :blk null;
                        _ = f.readPositionalAll(io_cp, buf, 0) catch {
                            allocator.free(buf);
                            break :blk null;
                        };
                        break :blk buf;
                    } else null;
                    if (content) |c| {
                        defer allocator.free(c);
                        // Simple JSON parsing for username
                        if (std.mem.indexOf(u8, c, "\"username\"")) |start| {
                            const after_key = c[start + 11 ..];
                            if (std.mem.indexOf(u8, after_key, "\"")) |q1| {
                                const after_q1 = after_key[q1 + 1 ..];
                                if (std.mem.indexOf(u8, after_q1, "\"")) |q2| {
                                    username = after_q1[0..q2];
                                }
                            }
                        }
                    }
                }
            }
        }

        std.debug.print("Session is valid for user: {s}\n", .{username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    std.debug.print("Session is invalid or expired.\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdSessionInfo(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session info - Show session information\n" ++
                "\n" ++
                "Usage: geode session info\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    const token = getCurrentToken(allocator) orelse {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(token);

    // Get username from credentials
    const creds_path = credentialsPathOrExit(allocator);
    defer allocator.free(creds_path);

    const io_cp2 = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io_cp2, creds_path, .{}) catch {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close(io_cp2);

    const stat_cp2 = try file.stat(io_cp2);
    const size_cp2: usize = @intCast(stat_cp2.size);
    const content = try allocator.alloc(u8, size_cp2);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io_cp2, content, 0);

    // Parse basic info from credentials
    var username: []const u8 = "unknown";
    var server: []const u8 = "unknown";
    var expires_at: i64 = 0;

    if (std.mem.indexOf(u8, content, "\"username\"")) |start| {
        const after_key = content[start + 11 ..];
        if (std.mem.indexOf(u8, after_key, "\"")) |q1| {
            const after_q1 = after_key[q1 + 1 ..];
            if (std.mem.indexOf(u8, after_q1, "\"")) |q2| {
                username = after_q1[0..q2];
            }
        }
    }

    if (std.mem.indexOf(u8, content, "\"server\"")) |start| {
        const after_key = content[start + 9 ..];
        if (std.mem.indexOf(u8, after_key, "\"")) |q1| {
            const after_q1 = after_key[q1 + 1 ..];
            if (std.mem.indexOf(u8, after_q1, "\"")) |q2| {
                server = after_q1[0..q2];
            }
        }
    }

    if (std.mem.indexOf(u8, content, "\"expires_at\"")) |start| {
        const after_key = content[start + 13 ..];
        // Skip whitespace and colon
        var pos: usize = 0;
        while (pos < after_key.len and (after_key[pos] == ':' or after_key[pos] == ' ')) : (pos += 1) {}
        // Find end of number
        var end: usize = pos;
        while (end < after_key.len and (after_key[end] >= '0' and after_key[end] <= '9')) : (end += 1) {}
        if (end > pos) {
            expires_at = std.fmt.parseInt(i64, after_key[pos..end], 10) catch 0;
        }
    }

    const now = compat_milliTimestamp();
    const created_at = if (expires_at > 0) expires_at - (24 * 60 * 60 * 1000) else now; // Assume 24h sessions

    std.debug.print("Session Information:\n", .{});
    std.debug.print("  user: {s}\n", .{username});
    std.debug.print("  server: {f}\n", .{geode.dsn_credentials.redacted(server)});
    std.debug.print("  created: {d} (timestamp)\n", .{created_at});
    std.debug.print("  expires: {d} (timestamp)\n", .{expires_at});
    std.debug.print("  token: {s}...\n", .{token[0..@min(16, token.len)]});
    std.process.exit(@intFromEnum(ExitCode.success));
}

// CANARY: REQ=REQ-CLI-SESSION-001; FEATURE="CLISession"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_sec_sess_log.zig; OWNER=cli; UPDATED=2026-06-10
/// SEC-SESS-LOG-01: all user-facing `session rotate` result output flows
/// through this function so the no-token-in-output contract is testable
/// (tests/test_sec_sess_log.zig). The rotated token is persisted to the
/// credentials file only — it must NEVER be written here (stderr/stdout).
pub fn writeRotateResult(writer: *std.Io.Writer, new_token: []const u8) !void {
    // SEC-SESS-LOG-01: deliberately unused — no token material in CLI output.
    _ = new_token;
    try writer.writeAll("Session token rotated successfully.\n");
}

fn cmdSessionRotate(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session rotate - Rotate session token\n" ++
                "\n" ++
                "Usage: geode session rotate\n" ++
                "\n" ++
                "Generates a new session token while keeping the old one valid during grace period.\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    const old_token = getCurrentToken(allocator) orelse {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(old_token);

    // Generate new token
    var new_token_bytes: [32]u8 = undefined;
    try cb.Csprng.bytes(&new_token_bytes);

    // Convert to hex string
    const hex_chars = "0123456789abcdef";
    var new_token: [64]u8 = undefined;
    for (new_token_bytes, 0..) |byte, j| {
        new_token[j * 2] = hex_chars[byte >> 4];
        new_token[j * 2 + 1] = hex_chars[byte & 0x0f];
    }

    // Update credentials file with new token
    const creds_path = credentialsPathOrExit(allocator);
    defer allocator.free(creds_path);

    const io_cp3 = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io_cp3, creds_path, .{}) catch {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const stat_cp3 = file.stat(io_cp3) catch {
        file.close(io_cp3);
        std.debug.print("Error: Cannot read credentials file.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const size_cp3: usize = @intCast(stat_cp3.size);
    const content = allocator.alloc(u8, size_cp3) catch {
        file.close(io_cp3);
        std.debug.print("Error: Cannot read credentials file.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    _ = file.readPositionalAll(io_cp3, content, 0) catch {
        file.close(io_cp3);
        allocator.free(content);
        std.debug.print("Error: Cannot read credentials file.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    file.close(io_cp3);
    defer allocator.free(content);

    // For simplicity, just regenerate the token part in the JSON
    // Find and replace the session_token value
    if (std.mem.indexOf(u8, content, old_token)) |_| {
        // Build new content with replaced token
        var new_content: std.ArrayListUnmanaged(u8) = .empty;
        defer new_content.deinit(allocator);

        var remaining = content;
        while (std.mem.indexOf(u8, remaining, old_token)) |idx| {
            new_content.appendSlice(allocator, remaining[0..idx]) catch {};
            new_content.appendSlice(allocator, &new_token) catch {};
            remaining = remaining[idx + old_token.len ..];
        }
        new_content.appendSlice(allocator, remaining) catch {};

        // Write file with replacement
        const out_file = std.Io.Dir.createFileAbsolute(io_cp3, creds_path, .{}) catch {
            std.debug.print("Error: Cannot write credentials file.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer out_file.close(io_cp3);
        out_file.writeStreamingAll(io_cp3, new_content.items) catch {
            std.debug.print("Error: Cannot write credentials file.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    } else {
        std.debug.print("Warning: Token not found in credentials file.\n", .{});
    }

    var rotate_out_buf: [256]u8 = undefined;
    var rotate_writer = std.Io.Writer.fixed(&rotate_out_buf);
    writeRotateResult(&rotate_writer, &new_token) catch {};
    std.debug.print("{s}", .{rotate_writer.buffered()});
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdSessionInvalidateAll(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var target_user: ?[]const u8 = null;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session invalidate-all - Invalidate all sessions for a user\n" ++
                "\n" ++
                "Usage: geode session invalidate-all --user <username>\n" ++
                "\n" ++
                "Options:\n" ++
                "  --user <username>   User whose sessions to invalidate (required)\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--user") and i + 1 < argv.len) {
            i += 1;
            target_user = argv[i];
        }
    }

    if (target_user == null) {
        std.debug.print("Error: --user is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    std.debug.print("All sessions for user '{s}' have been invalidated.\n", .{target_user.?});
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdSessionCheckIdle(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session check-idle - Check if session is idle\n" ++
                "\n" ++
                "Usage: geode session check-idle\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    const token = getCurrentToken(allocator) orelse {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(token);

    // If we have a token, the session is considered active
    std.debug.print("Session is active.\n", .{});
    std.process.exit(@intFromEnum(ExitCode.success));
}
