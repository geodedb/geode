const std = @import("std");
const geode = @import("geode");
const auth_state = geode.auth_state;

// CANARY: REQ=REQ-GAP-0258-MTLS-CLI-001; FEATURE="mTLS CLI"; ASPECT=CertificateMapping; STATUS=IMPL; TEST=geodetestlab/specs/gap_0258_mtls_cli.yml; OWNER=cli; UPDATED=2026-02-09
// mTLS CLI commands for managing mutual TLS certificate-to-user mappings

/// Persistent file path for mTLS state (matches apikey_cli pattern)
const MTLS_STATE_FILE = "geode_mtls_state.db";

fn mtlsStatePath(allocator: std.mem.Allocator) ![]u8 {
    return auth_state.resolveStatePath(allocator, MTLS_STATE_FILE);
}

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

fn printOut(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Valid mTLS mapping methods
const VALID_METHODS = [_][]const u8{
    "fingerprint",
    "san_email",
    "san_dns",
    "san_uri",
    "subject_cn",
    "subject_dn",
};

fn isValidMethod(method: []const u8) bool {
    for (VALID_METHODS) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

/// Persistent mTLS mapping entry stored in state file
const StoredMapping = struct {
    method: []const u8,
    pattern: []const u8,
    username: []const u8,
    roles: []const u8, // comma-separated
    enabled: bool,
    description: []const u8,
};

/// mTLS configuration stored in state file
const MtlsConfig = struct {
    strict_mode: bool = false,
    default_method: []const u8 = "fingerprint",
    _allocated_method: bool = false,
};

/// Load mTLS mappings from persistent storage
fn loadMtlsState(allocator: std.mem.Allocator) !struct { mappings: std.StringHashMap(StoredMapping), config: MtlsConfig } {
    var mappings = std.StringHashMap(StoredMapping).init(allocator);
    var config = MtlsConfig{};
    errdefer {
        var it = mappings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.method);
            allocator.free(entry.value_ptr.pattern);
            allocator.free(entry.value_ptr.username);
            allocator.free(entry.value_ptr.roles);
            allocator.free(entry.value_ptr.description);
        }
        mappings.deinit();
    }

    const state_path = try mtlsStatePath(allocator);
    defer allocator.free(state_path);

    const file = std.fs.openFileAbsolute(state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .mappings = mappings, .config = config },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Config lines start with "CONFIG|"
        if (std.mem.startsWith(u8, line, "CONFIG|")) {
            var parts = std.mem.splitScalar(u8, line, '|');
            _ = parts.next(); // skip "CONFIG"
            const key = parts.next() orelse continue;
            const value = parts.next() orelse continue;
            if (std.mem.eql(u8, key, "strict_mode")) {
                config.strict_mode = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "default_method")) {
                config.default_method = try allocator.dupe(u8, value);
                config._allocated_method = true;
            }
            continue;
        }

        // Format: method|pattern|username|roles|enabled|description
        var parts = std.mem.splitScalar(u8, line, '|');
        const method = parts.next() orelse continue;
        const pattern = parts.next() orelse continue;
        const username = parts.next() orelse continue;
        const roles = parts.next() orelse continue;
        const enabled_str = parts.next() orelse continue;
        const description = parts.next() orelse "";

        const enabled = std.mem.eql(u8, enabled_str, "true");

        const key = try allocator.dupe(u8, pattern);
        errdefer allocator.free(key);

        try mappings.put(key, .{
            .method = try allocator.dupe(u8, method),
            .pattern = try allocator.dupe(u8, pattern),
            .username = try allocator.dupe(u8, username),
            .roles = try allocator.dupe(u8, roles),
            .enabled = enabled,
            .description = try allocator.dupe(u8, description),
        });
    }

    return .{ .mappings = mappings, .config = config };
}

/// Save mTLS state to persistent storage
fn saveMtlsState(mappings: *std.StringHashMap(StoredMapping), config: MtlsConfig) !void {
    const state_path = try mtlsStatePath(mappings.allocator);
    defer mappings.allocator.free(state_path);

    const file = try std.fs.createFileAbsolute(state_path, .{
        .truncate = true,
        .read = true,
        .mode = 0o600,
    });
    defer file.close();

    // Write config lines first
    var config_buf: [256]u8 = undefined;
    const strict_line = std.fmt.bufPrint(&config_buf, "CONFIG|strict_mode|{s}\n", .{
        if (config.strict_mode) "true" else "false",
    }) catch return;
    _ = file.writeAll(strict_line) catch {};

    var method_buf: [256]u8 = undefined;
    const method_line = std.fmt.bufPrint(&method_buf, "CONFIG|default_method|{s}\n", .{
        config.default_method,
    }) catch return;
    _ = file.writeAll(method_line) catch {};

    // Write mapping lines
    var it = mappings.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        var line_buf: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}|{s}|{s}|{s}|{s}|{s}\n", .{
            v.method,
            v.pattern,
            v.username,
            v.roles,
            if (v.enabled) "true" else "false",
            v.description,
        }) catch continue;
        _ = file.writeAll(line) catch continue;
    }
}

/// Free mTLS state (mappings + config)
fn freeMtlsState(allocator: std.mem.Allocator, mappings: *std.StringHashMap(StoredMapping), config: *MtlsConfig) void {
    var it = mappings.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.method);
        allocator.free(entry.value_ptr.pattern);
        allocator.free(entry.value_ptr.username);
        allocator.free(entry.value_ptr.roles);
        allocator.free(entry.value_ptr.description);
    }
    mappings.deinit();
    if (config._allocated_method) {
        allocator.free(config.default_method);
        config._allocated_method = false;
    }
}

fn printMtlsUsage() void {
    printOut("geode mtls - Mutual TLS certificate mapping management\n", .{});
    printOut("Usage: geode mtls <command> [options]\n\n", .{});
    printOut("Commands:\n", .{});
    printOut("  map create   --method <method> --pattern <pattern> --user <username> [--roles <roles>] [--description <desc>]\n", .{});
    printOut("  map list     List all certificate mappings\n", .{});
    printOut("  map delete   --pattern <pattern>\n", .{});
    printOut("  config       --strict-mode <true|false> --default-method <method>\n", .{});
    printOut("  status       Show mTLS configuration status\n", .{});
    printOut("\nValid methods: fingerprint, san_email, san_dns, san_uri, subject_cn, subject_dn\n", .{});
    printOut("Roles can be comma-separated: admin,read_only,graph_writer\n", .{});
}

/// mTLS CLI command handler
pub fn cmdMtls(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Find subcommand after global flags
    var sub_idx = start_idx;
    while (sub_idx < argv.len) : (sub_idx += 1) {
        const a = argv[sub_idx];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printMtlsUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (!std.mem.startsWith(u8, a, "--")) break;
        // Skip flags with values
        if (std.mem.eql(u8, a, "--server") or
            std.mem.eql(u8, a, "--audit-file") or
            std.mem.eql(u8, a, "--audit-syslog"))
        {
            sub_idx += 1;
            continue;
        }
    }

    if (sub_idx >= argv.len) {
        printMtlsUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[sub_idx];

    if (std.mem.eql(u8, subcmd, "map")) {
        if (sub_idx + 1 >= argv.len) {
            printMtlsUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const map_cmd = argv[sub_idx + 1];
        if (std.mem.eql(u8, map_cmd, "create")) {
            try handleMapCreate(allocator, argv, sub_idx + 2);
        } else if (std.mem.eql(u8, map_cmd, "list")) {
            try handleMapList(allocator);
        } else if (std.mem.eql(u8, map_cmd, "delete")) {
            try handleMapDelete(allocator, argv, sub_idx + 2);
        } else {
            printOut("Error: Unknown map subcommand '{s}'\n", .{map_cmd});
            printMtlsUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    } else if (std.mem.eql(u8, subcmd, "config")) {
        try handleConfig(allocator, argv, sub_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try handleStatus(allocator);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printMtlsUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        printOut("Error: Unknown mtls subcommand '{s}'\n", .{subcmd});
        printMtlsUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn handleMapCreate(allocator: std.mem.Allocator, argv: [][:0]u8, start: usize) !void {
    var method: ?[]const u8 = null;
    var pattern: ?[]const u8 = null;
    var username: ?[]const u8 = null;
    var roles: []const u8 = "";
    var description: []const u8 = "";

    var i = start;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--method") and i + 1 < argv.len) {
            i += 1;
            method = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--pattern") and i + 1 < argv.len) {
            i += 1;
            pattern = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--user") and i + 1 < argv.len) {
            i += 1;
            username = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--roles") and i + 1 < argv.len) {
            i += 1;
            roles = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--description") and i + 1 < argv.len) {
            i += 1;
            description = argv[i];
        }
    }

    const m = method orelse {
        printOut("Error: --method is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    const p = pattern orelse {
        printOut("Error: --pattern is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    const u = username orelse {
        printOut("Error: --user is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };

    if (!isValidMethod(m)) {
        printOut("Error: Invalid method '{s}'. Valid methods: fingerprint, san_email, san_dns, san_uri, subject_cn, subject_dn\n", .{m});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var state = try loadMtlsState(allocator);
    defer freeMtlsState(allocator, &state.mappings, &state.config);

    const key = try allocator.dupe(u8, p);
    errdefer allocator.free(key);

    try state.mappings.put(key, .{
        .method = try allocator.dupe(u8, m),
        .pattern = try allocator.dupe(u8, p),
        .username = try allocator.dupe(u8, u),
        .roles = try allocator.dupe(u8, roles),
        .enabled = true,
        .description = try allocator.dupe(u8, description),
    });

    try saveMtlsState(&state.mappings, state.config);
    printOut("Created mTLS mapping: method={s}, pattern={s}, user={s}\n", .{ m, p, u });
}

fn handleMapList(allocator: std.mem.Allocator) !void {
    var state = try loadMtlsState(allocator);
    defer freeMtlsState(allocator, &state.mappings, &state.config);

    if (state.mappings.count() == 0) {
        printOut("No mTLS mappings configured.\n", .{});
        return;
    }

    printOut("{s:<14} {s:<30} {s:<16} {s:<20} {s:<8} {s}\n", .{ "METHOD", "PATTERN", "USERNAME", "ROLES", "ENABLED", "DESCRIPTION" });
    printOut("{s}\n", .{"-" ** 100});

    var it = state.mappings.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        printOut("{s:<14} {s:<30} {s:<16} {s:<20} {s:<8} {s}\n", .{
            v.method,
            v.pattern,
            v.username,
            if (v.roles.len > 0) v.roles else "(none)",
            if (v.enabled) "true" else "false",
            v.description,
        });
    }
}

fn handleMapDelete(allocator: std.mem.Allocator, argv: [][:0]u8, start: usize) !void {
    var pattern: ?[]const u8 = null;

    var i = start;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--pattern") and i + 1 < argv.len) {
            i += 1;
            pattern = argv[i];
        }
    }

    const p = pattern orelse {
        printOut("Error: --pattern is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };

    var state = try loadMtlsState(allocator);
    defer freeMtlsState(allocator, &state.mappings, &state.config);

    if (state.mappings.fetchRemove(p)) |removed| {
        allocator.free(removed.key);
        allocator.free(removed.value.method);
        allocator.free(removed.value.pattern);
        allocator.free(removed.value.username);
        allocator.free(removed.value.roles);
        allocator.free(removed.value.description);
        try saveMtlsState(&state.mappings, state.config);
        printOut("Deleted mTLS mapping for pattern '{s}'\n", .{p});
    } else {
        printOut("Error: No mapping found for pattern '{s}'\n", .{p});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn handleConfig(allocator: std.mem.Allocator, argv: [][:0]u8, start: usize) !void {
    var state = try loadMtlsState(allocator);
    defer freeMtlsState(allocator, &state.mappings, &state.config);

    var changed = false;

    var i = start;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--strict-mode") and i + 1 < argv.len) {
            i += 1;
            state.config.strict_mode = std.mem.eql(u8, argv[i], "true");
            changed = true;
        } else if (std.mem.eql(u8, argv[i], "--default-method") and i + 1 < argv.len) {
            i += 1;
            if (!isValidMethod(argv[i])) {
                printOut("Error: Invalid method '{s}'. Valid methods: fingerprint, san_email, san_dns, san_uri, subject_cn, subject_dn\n", .{argv[i]});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Free previously allocated method before replacing
            if (state.config._allocated_method) {
                allocator.free(state.config.default_method);
                state.config._allocated_method = false;
            }
            state.config.default_method = argv[i];
            changed = true;
        }
    }

    if (!changed) {
        printOut("Error: Provide --strict-mode or --default-method\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    try saveMtlsState(&state.mappings, state.config);
    printOut("mTLS configuration updated: strict_mode={s}, default_method={s}\n", .{
        if (state.config.strict_mode) "true" else "false",
        state.config.default_method,
    });
}

fn handleStatus(allocator: std.mem.Allocator) !void {
    var state = try loadMtlsState(allocator);
    defer freeMtlsState(allocator, &state.mappings, &state.config);

    printOut("mTLS Configuration Status\n", .{});
    printOut("========================\n", .{});
    printOut("Strict mode:    {s}\n", .{if (state.config.strict_mode) "enabled" else "disabled"});
    printOut("Default method: {s}\n", .{state.config.default_method});
    printOut("Mappings:       {d}\n", .{state.mappings.count()});

    if (state.mappings.count() > 0) {
        var enabled: usize = 0;
        var it = state.mappings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.enabled) enabled += 1;
        }
        printOut("Active:         {d}\n", .{enabled});
    }
}
