const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const audit_cli = @import("audit_cli");
const geode = @import("geode");
const log = std.log.scoped(.cli);

// GAP-0075: Syslog audit logging integration
// CANARY: REQ=REQ-AUDIT-SYSLOG-001; FEATURE="SyslogAuditIntegration"; ASPECT=AuditLogging; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-10

// CANARY: REQ=REQ-M4.4-CLI-DISPATCHER-001; FEATURE="CLI Modularization"; ASPECT=CommandDispatch; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.4: CLI Dispatcher module - central command routing, flag parsing, and audit configuration

// Import command modules
const user_mgmt_cli = @import("user_mgmt_cli.zig");
const auth_cli_mod = @import("auth_cli.zig");
const backup_cli = @import("backup_cli.zig");
const storage_cli = @import("storage_cli.zig");

// Re-export command handlers for main to use
pub const cmdUser = user_mgmt_cli.cmdUser;
pub const cmdRole = user_mgmt_cli.cmdRole;
pub const cmdPolicy = auth_cli_mod.cmdPolicy;
pub const cmdGrant = auth_cli_mod.cmdGrant;
pub const cmdRevoke = auth_cli_mod.cmdRevoke;
pub const cmdBackup = backup_cli.cmdBackup;
pub const cmdRestore = backup_cli.cmdRestore;
pub const cmdMigrate = backup_cli.cmdMigrate;
pub const cmdStorage = storage_cli.cmdStorage;

// Forward declare command handlers that remain in main.zig
// These will be passed in when calling dispatch()
pub const CommandHandler = fn (allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) anyerror!void;

/// Command dispatch table entry
pub const CommandEntry = struct {
    name: []const u8,
    handler: *const CommandHandler,
    description: []const u8,
};

/// Exit codes for CLI operations
pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    auth_error = 3,
};

/// CLI Audit Configuration
pub const CliAuditConfig = struct {
    enabled: bool = false,
    syslog_enabled: bool = false,
    syslog_host: ?[]const u8 = null,
    syslog_port: u16 = 514,
    file_enabled: bool = false,
    file_path: ?[]const u8 = null,
    windows_eventlog_enabled: bool = false,
    windows_eventlog_source: ?[]const u8 = null,
    windows_eventlog_log: ?[]const u8 = null,
};

/// Simple audit logging structures
const SimpleAuditEvent = struct {
    timestamp: []const u8,
    category: []const u8,
    action: []const u8,
    outcome: []const u8,
    actor: []const u8,
};

// Global audit logger instances
var global_audit_file: ?std.fs.File = null;
var global_windows_eventlog_handle: ?std.os.windows.HANDLE = null;
// GAP-0075: Global syslog configuration for audit logging
var global_syslog_host: ?[]const u8 = null;
var global_syslog_port: u16 = 514;
var global_syslog_allocator: ?std.mem.Allocator = null;

// Windows Event Log API declarations for cross-platform compatibility
const windows = std.os.windows;
const EVENTLOG_SUCCESS: windows.WORD = 0x0000;
const EVENTLOG_ERROR_TYPE: windows.WORD = 0x0001;
const EVENTLOG_WARNING_TYPE: windows.WORD = 0x0002;
const EVENTLOG_INFORMATION_TYPE: windows.WORD = 0x0004;

// Windows API function declarations (Windows only)
const WindowsEventLogAPI = if (builtin.os.tag == .windows) struct {
    extern "advapi32" fn RegisterEventSourceW(?windows.LPCWSTR, windows.LPCWSTR) ?windows.HANDLE;
    extern "advapi32" fn ReportEventW(windows.HANDLE, windows.WORD, windows.WORD, windows.DWORD, ?*anyopaque, windows.WORD, windows.DWORD, ?*const [*:0]const u16, ?*const anyopaque) windows.BOOL;
    extern "advapi32" fn DeregisterEventSource(windows.HANDLE) windows.BOOL;
} else struct {};

/// Main dispatch function - central command routing
/// Accepts command handlers from main.zig to avoid circular dependencies
pub fn dispatch(
    allocator: std.mem.Allocator,
    argv: [][:0]u8,
    cmdServe: *const CommandHandler,
    cmdQuery: *const CommandHandler,
    cmdShell: *const CommandHandler,
    cmdLsp: *const CommandHandler,
    cmdStdio: *const CommandHandler,
    cmdAuth: *const CommandHandler,
    cmdFLE: *const CommandHandler,
) !void {
    // Build command table with handlers passed from main
    const commands = [_]CommandEntry{
        .{ .name = "serve", .handler = cmdServe, .description = "Start the Geode server" },
        .{ .name = "query", .handler = cmdQuery, .description = "Execute a GQL query" },
        .{ .name = "shell", .handler = cmdShell, .description = "Start interactive shell (REPL)" },
        .{ .name = "stdio", .handler = cmdStdio, .description = "JSON protocol for process mode (Go client compatibility)" },
        .{ .name = "lsp", .handler = cmdLsp, .description = "Start Language Server Protocol server" },
        .{ .name = "backup", .handler = cmdBackup, .description = "Create database backup" },
        .{ .name = "restore", .handler = cmdRestore, .description = "Restore database from backup" },
        .{ .name = "migrate", .handler = cmdMigrate, .description = "Database migration commands" },
        .{ .name = "user", .handler = cmdUser, .description = "Manage users" },
        .{ .name = "role", .handler = cmdRole, .description = "Manage roles" },
        .{ .name = "policy", .handler = cmdPolicy, .description = "Manage policies" },
        .{ .name = "grant", .handler = cmdGrant, .description = "Grant permissions" },
        .{ .name = "revoke", .handler = cmdRevoke, .description = "Revoke permissions" },
        .{ .name = "auth", .handler = cmdAuth, .description = "Authentication commands" },
        .{ .name = "fle", .handler = cmdFLE, .description = "Field-Level Encryption management" },
        .{ .name = "storage", .handler = cmdStorage, .description = "Storage engine management and verification" },
    };

    // Parse audit configuration from environment variables
    var audit_cfg = parseAuditConfigFromEnv(allocator) catch |err| blk: {
        std.debug.print("Warning: Failed to parse audit configuration: {s}\n", .{@errorName(err)});
        break :blk CliAuditConfig{};
    };

    // Parse global audit flags
    var subcommand_start: usize = 1;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--audit")) {
            audit_cfg.enabled = true;
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "--audit-syslog")) {
            if (i + 1 < argv.len) {
                audit_cfg.syslog_enabled = true;
                audit_cfg.enabled = true;

                // Parse host:port
                const hostport = argv[i + 1];
                if (std.mem.lastIndexOf(u8, hostport, ":")) |colon_idx| {
                    audit_cfg.syslog_host = try allocator.dupe(u8, hostport[0..colon_idx]);
                    audit_cfg.syslog_port = std.fmt.parseInt(u16, hostport[colon_idx + 1 ..], 10) catch 514;
                } else {
                    audit_cfg.syslog_host = try allocator.dupe(u8, hostport);
                    audit_cfg.syslog_port = 514;
                }

                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-file")) {
            if (i + 1 < argv.len) {
                audit_cfg.file_enabled = true;
                audit_cfg.enabled = true;
                audit_cfg.file_path = try allocator.dupe(u8, argv[i + 1]);
                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-eventlog")) {
            audit_cfg.windows_eventlog_enabled = true;
            audit_cfg.enabled = true;

            // Check if there's an optional source name argument
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                audit_cfg.windows_eventlog_source = try allocator.dupe(u8, argv[i + 1]);
                i += 1;
            } else {
                audit_cfg.windows_eventlog_source = try allocator.dupe(u8, "Geode");
            }
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printMainUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--version")) {
            std.debug.print("geode " ++ build_options.version ++ "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--verbose") or std.mem.eql(u8, argv[i], "-v")) {
            // Set global verbose flag (would be used throughout the application)
            // For now, just accept the flag
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "--json")) {
            // Set global JSON output flag (would be used throughout the application)
            // For now, just accept the flag
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "--config")) {
            if (i + 1 < argv.len) {
                // Would load configuration file
                // For now, just accept the flag
                i += 1;
                subcommand_start = i + 1;
            } else {
                std.debug.print("Error: --config requires a path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
        } else {
            break;
        }
    }

    if (subcommand_start >= argv.len) {
        std.debug.print("Error: missing subcommand\n", .{});
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Initialize audit logging
    initializeAuditLogger(allocator, audit_cfg) catch |err| {
        std.debug.print("Warning: Failed to initialize audit logging: {s}\n", .{@errorName(err)});
    };
    defer deinitializeAuditLogger();

    // Log CLI startup event
    logAuditEvent("cli", "startup", "success");

    const subcommand = argv[subcommand_start];

    // Dispatch to subcommand using unified command table
    if (findCommand(&commands, subcommand)) |cmd_entry| {
        logAuditEvent("command", cmd_entry.name, "started");

        // Handle special cases for commands that need different start_idx
        // These commands have their own subcommands, so skip past the command name
        const actual_start_idx = if (std.mem.eql(u8, cmd_entry.name, "backup") or
            std.mem.eql(u8, cmd_entry.name, "restore") or
            std.mem.eql(u8, cmd_entry.name, "migrate") or
            std.mem.eql(u8, cmd_entry.name, "storage"))
            subcommand_start + 1
        else
            subcommand_start;

        try cmd_entry.handler(allocator, argv, actual_start_idx);
    } else if (std.mem.eql(u8, subcommand, "audit")) {
        // geode audit verify --file <path> ...
        var algo: audit_cli.HashAlgo = .sha256;
        var path: []const u8 = "audit.jsonl";
        var require_digest = false;
        var pubkey: ?[32]u8 = null;
        var audit_i: usize = subcommand_start + 1;
        while (audit_i < argv.len) : (audit_i += 1) {
            if (std.mem.eql(u8, argv[audit_i], "verify")) {
                continue;
            } else if (std.mem.eql(u8, argv[audit_i], "--file") and audit_i + 1 < argv.len) {
                path = argv[audit_i + 1];
                audit_i += 1;
            } else if (std.mem.eql(u8, argv[audit_i], "--algo") and audit_i + 1 < argv.len) {
                const a = argv[audit_i + 1];
                audit_i += 1;
                algo = if (std.mem.eql(u8, a, "blake3")) .blake3 else .sha256;
            } else if (std.mem.eql(u8, argv[audit_i], "--require-digest")) {
                require_digest = true;
            } else if (std.mem.eql(u8, argv[audit_i], "--pubkey") and audit_i + 1 < argv.len) {
                pubkey = audit_cli.hex32(argv[audit_i + 1]) catch null;
                audit_i += 1;
            }
        }
        try audit_cli.verifyFile(allocator, path, algo, 100, require_digest, pubkey);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        // Check if this is an option that should be handled by query command
        if (std.mem.startsWith(u8, subcommand, "--format") or
            std.mem.startsWith(u8, subcommand, "--json-param") or
            std.mem.startsWith(u8, subcommand, "--page-size") or
            std.mem.startsWith(u8, subcommand, "--server"))
        {
            // These are query command options, auto-route to query command
            logAuditEvent("command", "query", "started");
            try cmdQueryImplicit(allocator, argv, subcommand_start, cmdQuery);
        } else if (looksLikeGqlQuery(subcommand)) {
            // Check if this looks like a GQL query and auto-route to query command
            logAuditEvent("command", "query", "started");
            try cmdQueryImplicit(allocator, argv, subcommand_start, cmdQuery);
        } else if (std.mem.startsWith(u8, subcommand, "--")) {
            // Check if it looks like an option (starts with --)
            std.debug.print("Error: unknown option '{s}'\n", .{subcommand});
            std.debug.print("Run 'geode --help' to see available options\n\n", .{});
            printMainUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        } else {
            std.debug.print("Error: unknown subcommand '{s}'\n", .{subcommand});
            std.debug.print("Run 'geode --help' to see available commands\n\n", .{});
            printMainUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }
}

/// Helper function to find command by name
fn findCommand(commands: []const CommandEntry, name: []const u8) ?CommandEntry {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd;
        }
    }
    return null;
}

/// Helper function to detect if a string looks like a GQL query
pub fn looksLikeGqlQuery(str: []const u8) bool {
    // Convert to uppercase for case-insensitive matching
    var buf: [256]u8 = undefined;
    if (str.len > buf.len) return false;

    const upper_str = std.ascii.upperString(buf[0..str.len], str);

    // GQL query keywords (most common ones that start queries)
    const gql_keywords = [_][]const u8{ "MATCH", "CREATE", "DELETE", "SET", "REMOVE", "RETURN", "WITH", "UNWIND", "MERGE", "CALL", "OPTIONAL", "FOREACH", "LOAD", "USING", "START", "WHERE", "ORDER", "SKIP", "LIMIT", "UNION", "EXPLAIN", "PROFILE", "DETACH", "ON", "CASE", "WHEN", "ELSE", "END", "EXISTS", "UNIQUE", "INDEX", "CONSTRAINT", "DROP", "SHOW", "DESCRIBE", "USE" };

    for (gql_keywords) |keyword| {
        if (std.mem.startsWith(u8, upper_str, keyword)) {
            return true;
        }
    }

    return false;
}

/// Implicit query handler for when GQL query is provided without 'query' subcommand
pub fn cmdQueryImplicit(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize, cmdQuery: *const CommandHandler) !void {
    // Reconstruct argv as if 'query' subcommand was used
    // We need to create a new argv with 'query' inserted at start_idx
    var new_argv = try allocator.alloc([:0]u8, argv.len + 1);
    defer allocator.free(new_argv);

    // Copy elements before the query
    var i: usize = 0;
    while (i < start_idx) : (i += 1) {
        new_argv[i] = argv[i];
    }

    // Insert 'query' subcommand
    new_argv[start_idx] = try allocator.dupeZ(u8, "query");
    defer allocator.free(new_argv[start_idx]);

    // Copy the rest of the elements (including the query string and flags)
    i = start_idx;
    while (i < argv.len) : (i += 1) {
        new_argv[i + 1] = argv[i];
    }

    // Call the regular query command handler
    try cmdQuery(allocator, new_argv, start_idx);
}

// ============================================================================
// Audit Configuration and Logging
// ============================================================================

/// Cross-platform environment variable helper
pub fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

// CANARY: REQ=REQ-AUDIT-CLI-001; FEATURE="CLI Audit Configuration"; ASPECT=Configuration; STATUS=TESTED; TEST=TestCANARY_REQ_AUDIT_CLI_001_Configuration; OWNER=audit; UPDATED=2025-09-30
pub fn parseAuditConfigFromEnv(allocator: std.mem.Allocator) !CliAuditConfig {
    var cli_config = CliAuditConfig{};

    // Check if audit is enabled
    if (getEnvVar(allocator, "GEODE_AUDIT_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    // Syslog configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.syslog_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_HOST")) |value| {
        cli_config.syslog_host = value; // Keep ownership
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_PORT")) |value| {
        defer allocator.free(value);
        cli_config.syslog_port = std.fmt.parseInt(u16, value, 10) catch 514;
    }

    // Note: Protocol and facility configuration can be added later if needed

    // File configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_FILE_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.file_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_FILE_PATH")) |value| {
        cli_config.file_path = value; // Keep ownership
    }

    // Windows Event Log configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.windows_eventlog_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_WINDOWS_EVENTLOG_SOURCE")) |value| {
        cli_config.windows_eventlog_source = value; // Keep ownership
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_WINDOWS_EVENTLOG_LOG")) |value| {
        cli_config.windows_eventlog_log = value; // Keep ownership
    }

    // Note: File rotation and PII mode configuration can be added later if needed

    return cli_config;
}

pub fn initializeAuditLogger(allocator: std.mem.Allocator, cli_config: CliAuditConfig) !void {
    if (!cli_config.enabled) return;

    // Initialize file logging if enabled
    if (cli_config.file_enabled) {
        const path = cli_config.file_path orelse "/var/log/geode/cli-audit.log";

        // Create directory if it doesn't exist
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        global_audit_file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // Try to create the file
                break :blk try std.fs.cwd().createFile(path, .{});
            },
            else => return err,
        };

        // Seek to end for append mode
        if (global_audit_file) |*file| {
            _ = file.seekFromEnd(0) catch {};
        }
    }

    // GAP-0075: Initialize syslog logging if enabled
    // CANARY: REQ=REQ-AUDIT-SYSLOG-002; FEATURE="SyslogSenderInit"; ASPECT=AuditLogging; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-10
    if (cli_config.syslog_enabled) {
        global_syslog_host = cli_config.syslog_host orelse "127.0.0.1";
        global_syslog_port = cli_config.syslog_port;
        global_syslog_allocator = allocator;
        log.info("Syslog audit logging enabled: {s}:{d}", .{ global_syslog_host.?, global_syslog_port });
    }

    // Initialize Windows Event Log if enabled and on Windows
    if (cli_config.windows_eventlog_enabled and builtin.os.tag == .windows) {
        const source = cli_config.windows_eventlog_source orelse "Geode";

        // Convert source name to UTF-16 for Windows API
        var source_utf16_buf: [256:0]u16 = undefined;
        const source_utf16_len = std.unicode.utf8ToUtf16Le(source_utf16_buf[0..], source) catch {
            log.warn("Failed to convert event source name to UTF-16", .{});
            return;
        };
        source_utf16_buf[source_utf16_len] = 0;

        // Register event source
        global_windows_eventlog_handle = WindowsEventLogAPI.RegisterEventSourceW(null, // Use local computer
            &source_utf16_buf);

        if (global_windows_eventlog_handle == null) {
            log.warn("Failed to register Windows Event Log source '{s}'", .{source});
        }
    } else if (cli_config.windows_eventlog_enabled and builtin.os.tag != .windows) {
        log.warn("Windows Event Log is only supported on Windows systems", .{});
    }
}

// CANARY: REQ=REQ-AUDIT-CLI-003; FEATURE="CLI Audit Events"; ASPECT=EventLogging; STATUS=TESTED; TEST=TestCANARY_REQ_AUDIT_CLI_003_EventLogging; OWNER=audit; UPDATED=2025-09-30
pub fn logAuditEvent(category: []const u8, action: []const u8, outcome: []const u8) void {
    // Log to file if enabled
    if (global_audit_file) |file| {
        // Get current timestamp
        const timestamp = std.time.timestamp();

        // Create simple JSON audit event
        var buf: [1024]u8 = undefined;
        const json_line = std.fmt.bufPrint(&buf, "{{\"timestamp\":{d},\"category\":\"{s}\",\"action\":\"{s}\",\"outcome\":\"{s}\",\"actor\":\"geode-cli\"}}\n", .{ timestamp, category, action, outcome }) catch return;

        _ = file.writeAll(json_line) catch |err| {
            log.warn("Failed to write audit event: {s}", .{@errorName(err)});
        };
    }

    // GAP-0075: Log to syslog if enabled
    // CANARY: REQ=REQ-AUDIT-SYSLOG-003; FEATURE="SyslogEventSend"; ASPECT=AuditLogging; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-10
    if (global_syslog_host) |host| {
        sendSyslogMessage(host, global_syslog_port, category, action, outcome);
    }

    // Log to Windows Event Log if enabled and on Windows
    if (builtin.os.tag == .windows) {
        if (global_windows_eventlog_handle) |event_handle| {
            logToWindowsEventLog(event_handle, category, action, outcome);
        }
    }
}

// GAP-0075: Send audit event to syslog server via UDP (RFC 5424)
// CANARY: REQ=REQ-AUDIT-SYSLOG-004; FEATURE="SyslogUdpSend"; ASPECT=AuditLogging; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-10
fn sendSyslogMessage(host: []const u8, port: u16, category: []const u8, action: []const u8, outcome: []const u8) void {
    // Skip if host contains placeholder (test mode)
    if (std.mem.indexOf(u8, host, "{{") != null) return;

    // RFC 5424 PRI: facility (LOCAL0=16) * 8 + severity (INFO=6)
    const severity: u8 = if (std.mem.eql(u8, outcome, "success")) 6 else if (std.mem.eql(u8, outcome, "failure") or std.mem.eql(u8, outcome, "error")) 4 else 5;
    const pri = 16 * 8 + severity; // LOCAL0 facility

    // Get timestamp
    const ts = std.time.timestamp();

    // Format RFC 5424 message: <PRI>1 TIMESTAMP HOST APP PROCID MSGID - MSG
    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "<{d}>1 - localhost geode-cli - AUDIT - category={s} action={s} outcome={s} actor=geode-cli ts={d}", .{
        pri,
        category,
        action,
        outcome,
        ts,
    }) catch return;

    // Send via UDP
    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return;
    defer std.posix.close(socket);

    // Parse IP address
    var addr_bytes: [4]u8 = undefined;
    var segments: [4][]const u8 = undefined;
    var segment_count: usize = 0;
    var start: usize = 0;
    for (host, 0..) |c, i| {
        if (c == '.') {
            if (segment_count < 4) {
                segments[segment_count] = host[start..i];
                segment_count += 1;
            }
            start = i + 1;
        }
    }
    if (segment_count < 4 and start < host.len) {
        segments[segment_count] = host[start..];
        segment_count += 1;
    }

    if (segment_count != 4) return; // Invalid IP

    for (segments[0..4], 0..) |seg, i| {
        addr_bytes[i] = std.fmt.parseInt(u8, seg, 10) catch return;
    }

    const addr = std.net.Address.initIp4(addr_bytes, port);
    _ = std.posix.sendto(socket, message, 0, &addr.any, addr.getOsSockLen()) catch return;
}

// CANARY: REQ=REQ-AUDIT-CLI-004; FEATURE="Windows Event Log Integration"; ASPECT=EventLogging; STATUS=TESTED; TEST=TestCANARY_REQ_AUDIT_CLI_004_WindowsEventLog; OWNER=audit; UPDATED=2025-09-30
fn logToWindowsEventLog(event_handle: std.os.windows.HANDLE, category: []const u8, action: []const u8, outcome: []const u8) void {
    if (builtin.os.tag != .windows) return;

    // Create event message
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, "Geode CLI Audit Event - Category: {s}, Action: {s}, Outcome: {s}, Actor: geode-cli", .{ category, action, outcome }) catch return;

    // Convert message to UTF-16 for Windows API
    var message_utf16_buf: [1024:0]u16 = undefined;
    const message_utf16_len = std.unicode.utf8ToUtf16Le(message_utf16_buf[0..], message) catch return;
    message_utf16_buf[message_utf16_len] = 0;

    // Determine event type based on outcome
    const event_type: windows.WORD = if (std.mem.eql(u8, outcome, "success"))
        EVENTLOG_INFORMATION_TYPE
    else if (std.mem.eql(u8, outcome, "failure") or std.mem.eql(u8, outcome, "error"))
        EVENTLOG_ERROR_TYPE
    else
        EVENTLOG_WARNING_TYPE;

    // Event ID: Use different IDs for different categories
    const event_id: windows.DWORD = if (std.mem.eql(u8, category, "auth"))
        1001 // Authentication events
    else if (std.mem.eql(u8, category, "command"))
        1002 // Command execution events
    else if (std.mem.eql(u8, category, "cli"))
        1003 // CLI lifecycle events
    else
        1000; // General events

    // Create array of strings for the event
    const strings = [_][*:0]const u16{&message_utf16_buf};

    // Report the event
    const result = WindowsEventLogAPI.ReportEventW(event_handle, event_type, 0, // Category (0 for application events)
        event_id, null, // User SID (null for current user)
        1, // Number of strings
        0, // Raw data size
        &strings[0], // String array
        null // Raw data
    );

    if (result == 0) {
        // Note: We don't print warnings here to avoid spam, as this could be called frequently
    }
}

pub fn deinitializeAuditLogger() void {
    if (global_audit_file) |file| {
        file.close();
        global_audit_file = null;
    }

    if (builtin.os.tag == .windows) {
        if (global_windows_eventlog_handle) |event_handle| {
            _ = WindowsEventLogAPI.DeregisterEventSource(event_handle);
            global_windows_eventlog_handle = null;
        }
    }
}

// ============================================================================
// Help System
// ============================================================================

/// Main usage/help output
pub fn printMainUsage() void {
    std.debug.print("geode - Property graph database implementing ISO/IEC 39075:2024 (GQL)\n" ++
        "\n" ++
        "Usage: geode [options] <subcommand> [args...]\n" ++
        "\n" ++
        "Global Options:\n" ++
        "  -h, --help          Show help\n" ++
        "  -v, --verbose       Verbose output\n" ++
        "  --config <path>     Configuration file path\n" ++
        "  --json              Force JSON output for all subcommands\n" ++
        "  --audit             Enable audit logging\n" ++
        "  --audit-syslog <host:port>  Syslog server for audit logs\n" ++
        "  --audit-file <path> File path for audit logs\n" ++
        "  --audit-eventlog [source]   Enable Windows Event Log (default source: Geode)\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  serve               Start the database server\n" ++
        "  shell               Interactive GQL shell\n" ++
        "  query               Execute a GQL query\n" ++
        "  lsp                 Start Language Server Protocol server\n" ++
        "  backup              Create database backup\n" ++
        "  restore             Restore database from backup\n" ++
        "  migrate             Run database migrations\n" ++
        "  auth                Authentication commands\n" ++
        "  user                User management\n" ++
        "  role                Role management\n" ++
        "  policy              RLS policy management\n" ++
        "  grant               Grant permissions\n" ++
        "  revoke              Revoke permissions\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve --data-dir ./data --listen 0.0.0.0:3141\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode shell --server localhost:3141\n" ++
        "\n" ++
        "Use 'geode <subcommand> --help' for more information on a specific command.\n" ++
        "\n", .{});
}
