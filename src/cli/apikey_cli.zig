const std = @import("std");
const geode = @import("geode");
const api_keys = geode.api_keys;
const auth_state = geode.auth_state;

// CANARY: REQ=REQ-AUTH-APIKEYS-CLI-001; FEATURE="ApiKeyCLI"; ASPECT=CLI; STATUS=IMPL; TEST=geodetestlab/specs/api_key_auth.yml; OWNER=cli; UPDATED=2026-02-04
// API Key CLI commands for managing API keys from the command line

/// Persistent file path for API keys (matches auth_state pattern)
const APIKEY_STATE_FILE = "geode_apikey_state.db";

fn apiKeyStatePath(allocator: std.mem.Allocator) ![]u8 {
    return auth_state.resolveStatePath(allocator, APIKEY_STATE_FILE);
}

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

fn printOut(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Persistent API key entry stored in the state file
const StoredApiKey = struct {
    username: []const u8,
    name: []const u8,
    scopes: []const u8, // comma-separated
    created_at: i64,
    expires_at: ?i64,
    is_active: bool,
    key_string: []const u8, // full key string (gk1.xxx.xxx)
};

/// Load API keys from persistent storage
fn loadApiKeyState(allocator: std.mem.Allocator) !std.StringHashMap(StoredApiKey) {
    var keys = std.StringHashMap(StoredApiKey).init(allocator);
    errdefer {
        var it = keys.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.username);
            allocator.free(entry.value_ptr.name);
            allocator.free(entry.value_ptr.scopes);
            allocator.free(entry.value_ptr.key_string);
        }
        keys.deinit();
    }

    const state_path = try apiKeyStatePath(allocator);
    defer allocator.free(state_path);

    const file = std.fs.openFileAbsolute(state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return keys,
        else => return err,
    };
    defer file.close();

    // Read entire file (simpler for small state files)
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Format: username|name|scopes|created_at|expires_at|is_active|key_string
        var parts = std.mem.splitScalar(u8, line, '|');
        const username = parts.next() orelse continue;
        const name = parts.next() orelse continue;
        const scopes = parts.next() orelse continue;
        const created_str = parts.next() orelse continue;
        const expires_str = parts.next() orelse continue;
        const active_str = parts.next() orelse continue;
        const key_string = parts.next() orelse continue;

        const created_at = std.fmt.parseInt(i64, created_str, 10) catch continue;
        const expires_at: ?i64 = if (std.mem.eql(u8, expires_str, "null"))
            null
        else
            std.fmt.parseInt(i64, expires_str, 10) catch continue;
        const is_active = std.mem.eql(u8, active_str, "true");

        // Key is username:name
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, name });
        errdefer allocator.free(key);

        try keys.put(key, .{
            .username = try allocator.dupe(u8, username),
            .name = try allocator.dupe(u8, name),
            .scopes = try allocator.dupe(u8, scopes),
            .created_at = created_at,
            .expires_at = expires_at,
            .is_active = is_active,
            .key_string = try allocator.dupe(u8, key_string),
        });
    }

    return keys;
}

/// Save API keys to persistent storage
fn saveApiKeyState(keys: *std.StringHashMap(StoredApiKey)) !void {
    const state_path = try apiKeyStatePath(keys.allocator);
    defer keys.allocator.free(state_path);

    const file = try std.fs.createFileAbsolute(state_path, .{
        .truncate = true,
        .read = true,
        .mode = 0o600,
    });
    defer file.close();

    var it = keys.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        var expires_buf: [20]u8 = undefined;
        const expires_str = if (v.expires_at) |e|
            std.fmt.bufPrint(&expires_buf, "{d}", .{e}) catch "null"
        else
            "null";

        var line_buf: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}|{s}|{s}|{d}|{s}|{s}|{s}\n", .{
            v.username,
            v.name,
            v.scopes,
            v.created_at,
            expires_str,
            if (v.is_active) "true" else "false",
            v.key_string,
        }) catch continue;
        _ = file.writeAll(line) catch continue;
    }
}

/// Free API key state map
fn freeApiKeyState(allocator: std.mem.Allocator, keys: *std.StringHashMap(StoredApiKey)) void {
    var it = keys.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.username);
        allocator.free(entry.value_ptr.name);
        allocator.free(entry.value_ptr.scopes);
        allocator.free(entry.value_ptr.key_string);
    }
    keys.deinit();
}

fn printUsage() void {
    printOut("geode apikey - API Key management commands\n", .{});
    printOut("Usage: geode apikey <command> [options]\n", .{});
    printOut("Commands:\n", .{});
    printOut("  create --user <username> --name <keyname> --scope <scopes> [--expires-in <seconds>]\n", .{});
    printOut("  list --user <username>\n", .{});
    printOut("  revoke --user <username> --name <keyname>\n", .{});
    printOut("  revoke-all --user <username> [--yes]\n", .{});
    printOut("  validate <api_key>\n", .{});
    printOut("  check-scope --user <username> --name <keyname> --scope <scope>\n", .{});
    printOut("\nScopes can be comma-separated: metrics:read,health:read,query:execute\n", .{});
    printOut("Use '*' for wildcard scope (grants all scopes)\n", .{});
}

fn hasHelpFlag(argv: [][:0]u8, start_idx: usize) bool {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) return true;
    }
    return false;
}

fn findSubcommandStart(argv: [][:0]u8, start_idx: usize) usize {
    var idx = start_idx + 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--audit")) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--server") or
            std.mem.eql(u8, arg, "--audit-file") or
            std.mem.eql(u8, arg, "--audit-syslog"))
        {
            idx += 1;
            continue;
        }
        break;
    }
    return idx;
}

/// Parse a comma-separated scope string into individual scopes
fn parseScopes(allocator: std.mem.Allocator, scope_str: []const u8) ![][]const u8 {
    var scopes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (scopes.items) |s| allocator.free(s);
        scopes.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, scope_str, ',');
    while (it.next()) |scope| {
        const trimmed = std.mem.trim(u8, scope, " \t");
        if (trimmed.len > 0) {
            try scopes.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return scopes.toOwnedSlice(allocator);
}

/// API Key management command handler
pub fn cmdApiKey(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Load auth state for user lookup
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    // Initialize API key manager
    var manager = api_keys.ApiKeyManager.init(allocator);
    defer manager.deinit();

    const subcmd_idx = findSubcommandStart(argv, start_idx);
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing apikey subcommand\n", .{});
        printUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[subcmd_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        var username: ?[]const u8 = null;
        var keyname: ?[]const u8 = null;
        var scope_str: ?[]const u8 = null;
        var expires_in: ?i64 = null;

        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--user")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --user requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                username = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--name")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --name requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                keyname = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--scope")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --scope requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                scope_str = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--expires-in")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --expires-in requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                expires_in = std.fmt.parseInt(i64, argv[i + 1], 10) catch {
                    std.debug.print("Error: invalid expires-in value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                i += 1;
            }
        }

        if (username == null) {
            std.debug.print("Error: --user is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (keyname == null) {
            std.debug.print("Error: --name is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (scope_str == null or scope_str.?.len == 0) {
            std.debug.print("Error: --scope is required and cannot be empty\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Validate key name length
        if (keyname.?.len > 64) {
            std.debug.print("Error: key name too long (max 64 characters)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        // Lookup user to get user_id
        try state.ensureDefaults();
        const user = state.getUser(username.?) orelse {
            std.debug.print("Error: user '{s}' does not exist\n", .{username.?});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Parse scopes
        const scopes = try parseScopes(allocator, scope_str.?);
        defer {
            for (scopes) |s| allocator.free(s);
            allocator.free(scopes);
        }

        // Load existing API keys
        var api_key_state = try loadApiKeyState(allocator);
        defer freeApiKeyState(allocator, &api_key_state);

        // Check for duplicate name
        const lookup_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username.?, keyname.? });
        defer allocator.free(lookup_key);

        if (api_key_state.contains(lookup_key)) {
            std.debug.print("Error: key '{s}' already exists for user '{s}'\n", .{ keyname.?, username.? });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        // Create the key using the manager
        const key_string = try manager.createKey(
            @intCast(@intFromPtr(user)),
            keyname.?,
            scopes,
            expires_in,
        );
        defer allocator.free(key_string);

        // Calculate expiration
        const now = std.time.timestamp();
        const expires_at: ?i64 = if (expires_in) |exp| now + exp else null;

        // Save to persistent storage
        const state_key = try allocator.dupe(u8, lookup_key);
        errdefer allocator.free(state_key);

        try api_key_state.put(state_key, .{
            .username = try allocator.dupe(u8, username.?),
            .name = try allocator.dupe(u8, keyname.?),
            .scopes = try allocator.dupe(u8, scope_str.?),
            .created_at = now,
            .expires_at = expires_at,
            .is_active = true,
            .key_string = try allocator.dupe(u8, key_string),
        });

        try saveApiKeyState(&api_key_state);

        // Output the key (use printOut to match other CLI commands)
        printOut("{s}\n", .{key_string});

        if (expires_in) |exp| {
            printOut("API key created (expires in {d} seconds)\n", .{exp});
        } else {
            printOut("API key created (no expiration)\n", .{});
        }

        return;
    }

    if (std.mem.eql(u8, subcommand, "list")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode apikey list --user <username>\nLists all API keys for a user\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        var username: ?[]const u8 = null;
        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--user")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --user requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                username = argv[i + 1];
                i += 1;
            }
        }

        if (username == null) {
            std.debug.print("Error: --user is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Lookup user
        try state.ensureDefaults();
        _ = state.getUser(username.?) orelse {
            std.debug.print("Error: user '{s}' does not exist\n", .{username.?});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Load from persistent storage
        var api_key_state = try loadApiKeyState(allocator);
        defer freeApiKeyState(allocator, &api_key_state);

        // Find keys for this user
        var found_keys = false;
        printOut("API keys for user '{s}':\n", .{username.?});
        var it = api_key_state.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username.?)) {
                found_keys = true;
                printOut("  - {s}", .{entry.value_ptr.name});
                if (entry.value_ptr.is_active) {
                    printOut(" (active)", .{});
                } else {
                    printOut(" (revoked)", .{});
                }
                printOut("\n", .{});
            }
        }

        if (!found_keys) {
            printOut("  (no keys found)\n", .{});
        }

        return;
    }

    if (std.mem.eql(u8, subcommand, "revoke")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode apikey revoke --user <username> --name <keyname>\nRevokes an API key\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        var username: ?[]const u8 = null;
        var keyname: ?[]const u8 = null;
        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--user")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --user requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                username = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--name")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --name requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                keyname = argv[i + 1];
                i += 1;
            }
        }

        if (username == null) {
            std.debug.print("Error: --user is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (keyname == null) {
            std.debug.print("Error: --name is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Lookup user
        try state.ensureDefaults();
        _ = state.getUser(username.?) orelse {
            std.debug.print("Error: user '{s}' does not exist\n", .{username.?});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Load from persistent storage
        var api_key_state = try loadApiKeyState(allocator);
        defer freeApiKeyState(allocator, &api_key_state);

        // Find and revoke the key
        const lookup_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username.?, keyname.? });
        defer allocator.free(lookup_key);

        if (api_key_state.getPtr(lookup_key)) |entry| {
            entry.is_active = false;
            try saveApiKeyState(&api_key_state);
            printOut("API key '{s}' revoked\n", .{keyname.?});
            return;
        }

        std.debug.print("Error: key '{s}' not found for user '{s}'\n", .{ keyname.?, username.? });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    if (std.mem.eql(u8, subcommand, "revoke-all")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode apikey revoke-all --user <username> [--yes]\nRevokes all API keys for a user\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        var username: ?[]const u8 = null;
        var yes_flag = false;
        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--user")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --user requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                username = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--yes") or std.mem.eql(u8, argv[i], "-y")) {
                yes_flag = true;
            }
        }

        if (username == null) {
            std.debug.print("Error: --user is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        if (!yes_flag) {
            std.debug.print("Error: --yes flag required to confirm revocation\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Lookup user
        try state.ensureDefaults();
        _ = state.getUser(username.?) orelse {
            std.debug.print("Error: user '{s}' does not exist\n", .{username.?});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Load from persistent storage
        var api_key_state = try loadApiKeyState(allocator);
        defer freeApiKeyState(allocator, &api_key_state);

        // Revoke all keys for the user
        var count: usize = 0;
        var it = api_key_state.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username.?) and entry.value_ptr.is_active) {
                entry.value_ptr.is_active = false;
                count += 1;
            }
        }

        try saveApiKeyState(&api_key_state);
        printOut("Revoked {d} API key(s) for user '{s}'\n", .{ count, username.? });

        return;
    }

    if (std.mem.eql(u8, subcommand, "validate")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode apikey validate <api_key>\nValidates an API key format\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: API key is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        const key_string = argv[subcmd_idx + 1];

        // Parse and validate format
        _ = api_keys.parseApiKey(key_string) catch |err| {
            switch (err) {
                error.UnsupportedApiKeyVersion => {
                    std.debug.print("Error: unsupported API key version\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                },
                error.InvalidApiKeyFormat => {
                    std.debug.print("Error: invalid API key format\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                },
            }
        };

        printOut("API key format is valid\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "check-scope")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode apikey check-scope --user <username> --name <keyname> --scope <scope>\nChecks if a key has a specific scope\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        var username: ?[]const u8 = null;
        var keyname: ?[]const u8 = null;
        var scope: ?[]const u8 = null;
        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--user")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --user requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                username = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--name")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --name requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                keyname = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--scope")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --scope requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                scope = argv[i + 1];
                i += 1;
            }
        }

        if (username == null) {
            std.debug.print("Error: --user is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (keyname == null) {
            std.debug.print("Error: --name is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (scope == null) {
            std.debug.print("Error: --scope is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Lookup user
        try state.ensureDefaults();
        _ = state.getUser(username.?) orelse {
            std.debug.print("Error: user '{s}' does not exist\n", .{username.?});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Load from persistent storage
        var api_key_state = try loadApiKeyState(allocator);
        defer freeApiKeyState(allocator, &api_key_state);

        // Find the key
        const lookup_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username.?, keyname.? });
        defer allocator.free(lookup_key);

        const entry = api_key_state.get(lookup_key) orelse {
            std.debug.print("Error: key '{s}' not found for user '{s}'\n", .{ keyname.?, username.? });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Check if scope is granted (comma-separated scopes or wildcard)
        var scope_it = std.mem.splitScalar(u8, entry.scopes, ',');
        while (scope_it.next()) |s| {
            const trimmed = std.mem.trim(u8, s, " \t");
            if (std.mem.eql(u8, trimmed, scope.?) or std.mem.eql(u8, trimmed, "*")) {
                printOut("scope granted for key '{s}': {s}\n", .{ keyname.?, scope.? });
                return;
            }
        }

        printOut("scope denied for key '{s}': {s}\n", .{ keyname.?, scope.? });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    std.debug.print("Error: unknown apikey subcommand '{s}'\n", .{subcommand});
    printUsage();
    std.process.exit(@intFromEnum(ExitCode.usage_error));
}
