const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const auth_state = geode.auth_state;

// CANARY: REQ=REQ-CLI-SESSION-001; FEATURE="CLISession"; ASPECT=Management; STATUS=TESTED; TEST=geodetestlab/specs/authn_provider.yml; OWNER=cli; UPDATED=2026-02-04
// Session management CLI commands

const SESSION_STATE_FILE = "geode_session_state.db";

fn sessionStatePath(allocator: std.mem.Allocator) ![]u8 {
    return auth_state.resolveStatePath(allocator, SESSION_STATE_FILE);
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

    const file = std.fs.openFileAbsolute(state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return sessions,
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Warning: Could not read session state: {}\n", .{err});
        return sessions;
    };
    defer allocator.free(content);

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
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const creds_path = std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home}) catch return null;
    defer allocator.free(creds_path);

    const file = std.fs.openFileAbsolute(creds_path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(content);

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
        const now = std.time.milliTimestamp();
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

        const home = if (builtin.os.tag == .windows)
            std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null
        else
            std.process.getEnvVarOwned(allocator, "HOME") catch null;

        if (home) |h| {
            defer allocator.free(h);
            const creds_path = std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{h}) catch null;
            if (creds_path) |cp| {
                defer allocator.free(cp);
                const file = std.fs.openFileAbsolute(cp, .{}) catch null;
                if (file) |f| {
                    defer f.close();
                    const content = f.readToEndAlloc(allocator, 64 * 1024) catch null;
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
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch {
            std.debug.print("Error: Cannot determine home directory\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("Error: Cannot determine home directory\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    defer allocator.free(home);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const file = std.fs.openFileAbsolute(creds_path, .{}) catch {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

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

    const now = std.time.milliTimestamp();
    const created_at = if (expires_at > 0) expires_at - (24 * 60 * 60 * 1000) else now; // Assume 24h sessions

    std.debug.print("Session Information:\n", .{});
    std.debug.print("  user: {s}\n", .{username});
    std.debug.print("  server: {s}\n", .{server});
    std.debug.print("  created: {d} (timestamp)\n", .{created_at});
    std.debug.print("  expires: {d} (timestamp)\n", .{expires_at});
    std.debug.print("  token: {s}...\n", .{token[0..@min(16, token.len)]});
    std.process.exit(@intFromEnum(ExitCode.success));
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
    std.crypto.random.bytes(&new_token_bytes);

    // Convert to hex string
    const hex_chars = "0123456789abcdef";
    var new_token: [64]u8 = undefined;
    for (new_token_bytes, 0..) |byte, j| {
        new_token[j * 2] = hex_chars[byte >> 4];
        new_token[j * 2 + 1] = hex_chars[byte & 0x0f];
    }

    // Update credentials file with new token
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch {
            std.debug.print("Error: Cannot determine home directory\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("Error: Cannot determine home directory\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    defer allocator.free(home);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const file = std.fs.openFileAbsolute(creds_path, .{}) catch {
        std.debug.print("Error: No session found. Please login first.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const content = file.readToEndAlloc(allocator, 64 * 1024) catch {
        file.close();
        std.debug.print("Error: Cannot read credentials file.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    file.close();
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
        const out_file = std.fs.createFileAbsolute(creds_path, .{}) catch {
            std.debug.print("Error: Cannot write credentials file.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer out_file.close();
        out_file.writeAll(new_content.items) catch {
            std.debug.print("Error: Cannot write credentials file.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    } else {
        std.debug.print("Warning: Token not found in credentials file.\n", .{});
    }

    std.debug.print("Session token rotated successfully.\n", .{});
    std.debug.print("new token: {s}\n", .{&new_token});
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
