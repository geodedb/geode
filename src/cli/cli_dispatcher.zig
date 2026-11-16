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

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const builtin = @import("builtin");
const build_options = @import("build_options");
const audit_cli = @import("audit_cli");
const geode = @import("geode");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=CLI; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("cli");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-CLI-001; FEATURE="External Library Migration"; ASPECT=CLIFramework; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// External CLI framework library - Cobra/Viper-class features with shell completion generation
const cli_lib = @import("cli");
const CliCommand = cli_lib.Command;
const CliFlagSpec = cli_lib.FlagSpec;
const CliFlagType = cli_lib.FlagType;
const CliShell = cli_lib.cli.Shell;

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-006; FEATURE="External Library Migration"; ASPECT=MCPModule; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
// MCP server module for AI/LLM integration
const geode_mcp = @import("geode_mcp");

// GAP-0075: Syslog audit logging integration
// CANARY: REQ=REQ-AUDIT-SYSLOG-001; FEATURE="SyslogAuditIntegration"; ASPECT=AuditLogging; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-10

// CANARY: REQ=REQ-M4.4-CLI-DISPATCHER-001; FEATURE="CLI Modularization"; ASPECT=CommandDispatch; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.4: CLI Dispatcher module - central command routing, flag parsing, and audit configuration

// Import command modules
const user_mgmt_cli = @import("user_mgmt_cli.zig");
const auth_cli_mod = @import("auth_cli.zig");
const backup_cli = @import("backup_cli.zig");
const storage_cli = @import("storage_cli.zig");
const session_cli = @import("session_cli.zig");
const authn_cli = @import("authn_cli.zig");
const apikey_cli = @import("apikey_cli.zig");
const mtls_cli = @import("mtls_cli.zig");
// GAP-0839: `geode tenant` connects to the server and issues CALL geode.tenant.*,
// so it delegates to cmdQuery (handled as a special subcommand in dispatch()).
const tenant_cli = @import("tenant_cli.zig");
// SONNY-6560: the options each command reads (unknown ones are refused).
const option_check = @import("option_check.zig");

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
pub const cmdApiKey = apikey_cli.cmdApiKey;
// GAP-0839: `geode tenant` — re-exported for completeness; dispatched specially
// in dispatch() because it needs cmdQuery (server connection) threaded in.
pub const cmdTenant = tenant_cli.cmdTenant;

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
    /// A CLIENT-SIDE deadline expired. Distinct from `general_error` because
    /// the statement is NOT known to have failed — it may still be executing
    /// server-side, so a caller can retry/poll instead of treating it as a hard
    /// failure. Kept in sync with `query_deadline.EXIT_TIMEOUT_ERROR`, which
    /// duplicates the value to avoid a cross-module import.
    // CANARY: REQ=REQ-CLI-TIMEOUT-EXIT-CODE-001; FEATURE="QueryTimeoutClassification"; ASPECT=DistinctExitCode; STATUS=TESTED; TEST=tests/test_cli_timeout_exit_code.zig; OWNER=cli; UPDATED=2026-09-01
    timeout_error = 4,
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

    /// SONNY-6559 (7): the strings are owned (parseAuditConfigFromEnv and
    /// the --audit-* flags duplicate them); they used to be leaked.
    pub fn deinit(self: *CliAuditConfig, allocator: std.mem.Allocator) void {
        inline for (.{ "syslog_host", "file_path", "windows_eventlog_source", "windows_eventlog_log" }) |field| {
            if (@field(self, field)) |owned| allocator.free(owned);
            @field(self, field) = null;
        }
    }

    /// Replace an owned string field, freeing the value it held (a flag
    /// given after the GEODE_AUDIT_* variable of the same setting).
    fn setOwned(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !void {
        const copy = try allocator.dupe(u8, value);
        if (field.*) |old| allocator.free(old);
        field.* = copy;
    }
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
var global_audit_file: ?std.Io.File = null;
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
    cmdAuth: *const CommandHandler,
    cmdFLE: *const CommandHandler,
) !void {
    // Build command table with handlers passed from main
    const commands = [_]CommandEntry{
        .{ .name = "serve", .handler = cmdServe, .description = "Start the Geode server" },
        .{ .name = "query", .handler = cmdQuery, .description = "Execute a GQL query" },
        .{ .name = "shell", .handler = cmdShell, .description = "Start interactive shell (REPL)" },
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
        .{ .name = "apikey", .handler = cmdApiKey, .description = "API key management" },
    };

    // Parse audit configuration from environment variables.
    // SONNY-6494: an audit setting that cannot be used refuses the command
    // (below, after --help / --version); it used to turn audit off with a
    // warning. parseAuditConfigFromEnv printed which setting.
    var audit_env_err: ?anyerror = null;
    var audit_cfg = parseAuditConfigFromEnv(allocator) catch |err| blk: {
        audit_env_err = err;
        break :blk CliAuditConfig{};
    };
    // SONNY-6559 (7): freed after the audit logger, which borrows the
    // strings, is closed (defers run in reverse order).
    defer audit_cfg.deinit(allocator);

    // Parse global audit flags
    var subcommand_start: usize = 1;
    var global_config: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--audit")) {
            audit_cfg.enabled = true;
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "--audit-syslog")) {
            // SONNY-6560: without its value the flag was skipped.
            if (i + 1 >= argv.len) refuseMissingGlobalValue(argv[i]);
            if (i + 1 < argv.len) {
                audit_cfg.syslog_enabled = true;
                audit_cfg.enabled = true;

                // SONNY-6487: host[:port] or [ipv6][:port] (the shared
                // grammar); a port that is not a port is refused -- it used
                // to send to 514.
                const hostport = argv[i + 1];
                const target = geode.host_port.split(hostport, 514) catch {
                    std.debug.print("Error: --audit-syslog '{f}' is not a valid address (expected <host>[:<port>] or [<ipv6>][:<port>], port 0-65535)\n", .{geode.dsn_credentials.redacted(hostport)});
                    return error.InvalidAuditSyslogAddress;
                };
                if (syslogTarget(target.host, target.port) == null) {
                    std.debug.print("Error: --audit-syslog '{f}': the syslog sender sends to an IPv4 address, a bracketed IPv6 address or localhost, not to a host name\n", .{geode.dsn_credentials.redacted(hostport)});
                    return error.InvalidAuditSyslogAddress;
                }
                try CliAuditConfig.setOwned(allocator, &audit_cfg.syslog_host, target.host);
                audit_cfg.syslog_port = target.port;

                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-file")) {
            if (i + 1 >= argv.len) refuseMissingGlobalValue(argv[i]);
            if (i + 1 < argv.len) {
                audit_cfg.file_enabled = true;
                audit_cfg.enabled = true;
                try CliAuditConfig.setOwned(allocator, &audit_cfg.file_path, argv[i + 1]);
                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-eventlog")) {
            audit_cfg.windows_eventlog_enabled = true;
            audit_cfg.enabled = true;

            // Check if there's an optional source name argument
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and findCommandName(argv[i + 1]) == null) {
                try CliAuditConfig.setOwned(allocator, &audit_cfg.windows_eventlog_source, argv[i + 1]);
                i += 1;
            } else {
                try CliAuditConfig.setOwned(allocator, &audit_cfg.windows_eventlog_source, "Geode");
            }
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printMainUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--version")) {
            std.debug.print("geode " ++ build_options.version ++ "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--verbose") or std.mem.eql(u8, argv[i], "-v") or
            std.mem.eql(u8, argv[i], "--json"))
        {
            // CANARY: REQ=REQ-SONNY-6560-GLOBAL-UNREAD-OPTIONS; FEATURE="CliOptions"; ASPECT=DocumentedUnreadRefused; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-14
            // SONNY-6560: geode --help documented these and nothing read
            // them ("For now, just accept the flag"): --json changed no
            // output, --verbose nothing.
            std.debug.print("Error: geode: option '{s}' is not supported (a subcommand's own options are given after it; see geode --help)\n", .{argv[i]});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        } else if (std.mem.eql(u8, argv[i], "--config")) {
            // SONNY-6560: only `geode serve` reads it (its parser scans the
            // whole command line for --config); checked once the
            // subcommand is known.
            if (i + 1 >= argv.len) refuseMissingGlobalValue(argv[i]);
            global_config = argv[i];
            i += 1;
            subcommand_start = i + 1;
        } else {
            break;
        }
    }

    if (subcommand_start >= argv.len) {
        std.debug.print("Error: missing subcommand\n", .{});
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // CANARY: REQ=REQ-SONNY-6494-AUDIT-FAILCLOSED; FEATURE="CLI Audit Configuration"; ASPECT=FailClosed; STATUS=TESTED; TEST=tests/test_sonny6494_audit_failclosed.zig; OWNER=audit; UPDATED=2026-11-13
    // SONNY-6494: audit fails closed. A command asked to audit whose audit
    // configuration or sink cannot be set up does not run (as the server's
    // own audit sink refuses startup when it cannot be opened); it used to
    // print a warning and run unaudited.
    if (audit_env_err) |err| {
        std.debug.print("Error: geode: the GEODE_AUDIT_* audit configuration is invalid ({s}); refusing to run without the audit logging it asks for\n", .{@errorName(err)});
        return err;
    }
    initializeAuditLogger(allocator, audit_cfg) catch |err| {
        std.debug.print("Error: geode: cannot open the audit sink ({s}{s}{s}); refusing to run without the audit logging that was requested\n", .{
            @errorName(err),
            if (audit_cfg.file_enabled) ", audit file " else "",
            if (audit_cfg.file_enabled) (audit_cfg.file_path orelse default_cli_audit_file) else "",
        });
        return error.AuditSinkUnavailable;
    };
    defer deinitializeAuditLogger();

    // Log CLI startup event
    logAuditEvent("cli", "startup", "success");

    const subcommand = argv[subcommand_start];

    // SONNY-6560: the global --config was accepted and ignored by every
    // command but serve.
    if (global_config) |opt| {
        if (!std.mem.eql(u8, subcommand, "serve")) {
            std.debug.print("Error: geode: option '{s}' is read by geode serve only (see geode serve --help)\n", .{opt});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // SONNY-6560: an option the command does not read, or a value option
    // without its value, is refused here (exit 2) before the command runs.
    option_check.enforce(subcommand, argv[subcommand_start + 1 ..]);

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
        logCommandSucceeded(cmd_entry.name);
    } else if (std.mem.eql(u8, subcommand, "audit")) {
        // Check for help flag first
        logAuditEvent("command", "audit", "started");
        var audit_i: usize = subcommand_start + 1;
        while (audit_i < argv.len) : (audit_i += 1) {
            if (std.mem.eql(u8, argv[audit_i], "-h") or std.mem.eql(u8, argv[audit_i], "--help")) {
                printAuditHelp();
                logCommandSucceeded("audit");
                return;
            }
        }
        // geode audit verify --file <path> ...
        var algo: audit_cli.HashAlgo = .sha256;
        var path: []const u8 = "audit.jsonl";
        var is_default_path = true;
        var require_digest = false;
        // SONNY-6322: one --pubkey per audit key epoch, in order (epoch 0 is
        // audit.jsonl.pub, epoch n audit.jsonl.pub.<n>).
        var pubkeys: [64][32]u8 = undefined;
        var pubkey_count: usize = 0;
        audit_i = subcommand_start + 1;
        var saw_verify = false;
        while (audit_i < argv.len) : (audit_i += 1) {
            const arg = argv[audit_i];
            // SONNY-6560: a value option without its value, an unknown
            // option or argument, and an --algo other than sha256 or
            // blake3 (which verified with sha256) are refused.
            if ((std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "--algo") or std.mem.eql(u8, arg, "--pubkey")) and audit_i + 1 >= argv.len) {
                std.debug.print("Error: geode audit verify: option '{s}' requires a value (see geode audit --help)\n", .{arg});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            if (std.mem.eql(u8, arg, "verify") and !saw_verify) {
                saw_verify = true;
                continue;
            } else if (std.mem.eql(u8, arg, "--file")) {
                path = argv[audit_i + 1];
                is_default_path = false;
                audit_i += 1;
            } else if (std.mem.eql(u8, arg, "--algo")) {
                const a = argv[audit_i + 1];
                audit_i += 1;
                algo = if (std.mem.eql(u8, a, "blake3")) .blake3 else if (std.mem.eql(u8, a, "sha256")) .sha256 else {
                    std.debug.print("Error: geode audit verify: unsupported --algo '{s}' (supported: sha256, blake3)\n", .{a});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
            } else if (std.mem.eql(u8, arg, "--require-digest")) {
                require_digest = true;
            } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "--pubkey")) {
                std.debug.print("Error: geode audit verify: unknown option '{s}' (see geode audit --help)\n", .{arg});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            } else if (!std.mem.eql(u8, arg, "--pubkey")) {
                std.debug.print("Error: geode audit: unexpected argument '{s}' (see geode audit --help)\n", .{arg});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            } else if (std.mem.eql(u8, arg, "--pubkey")) {
                // An invalid key used to be dropped silently, which turned
                // signature checking off.
                if (pubkey_count == pubkeys.len) {
                    std.debug.print("Error: at most {d} --pubkey values\n", .{pubkeys.len});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                pubkeys[pubkey_count] = audit_cli.hex32(argv[audit_i + 1]) catch {
                    std.debug.print("Error: --pubkey takes a 64-character hex Ed25519 public key\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                pubkey_count += 1;
                audit_i += 1;
            }
        }
        // SONNY-3147 / SONNY-6340 (3): one verdict. The verifier prints its
        // OK summary only when everything verified; a failure ends with this
        // FAILED line and a non-zero exit (3 for a broken chain link, as
        // before; 1 otherwise). No record contents are printed.
        _ = audit_cli.verifyFileEpochs(allocator, path, algo, 100, require_digest, pubkeys[0..pubkey_count], is_default_path) catch |err| {
            std.debug.print("FAILED ❌  audit log {s} did not verify: {s}\n", .{ path, @errorName(err) });
            std.process.exit(if (err == error.ChainMismatch) 3 else @intFromEnum(ExitCode.general_error));
        };
        // SONNY-6559 (11): returns through main (exit 0, as before).
        logCommandSucceeded("audit");
    } else if (std.mem.eql(u8, subcommand, "completion") or std.mem.eql(u8, subcommand, "completions")) {
        // CANARY: REQ=REQ-LIB-MIGRATION-CLI-002; FEATURE="External Library Migration"; ASPECT=ShellCompletions; STATUS=TESTED; TEST=test_completion_scripts_use_external_cli_library; OWNER=cli; UPDATED=2026-04-01
        // Shell completion script generation using external CLI library.
        // SONNY-6552: returns through main (exit 0), so the Debug leak
        // check runs.
        try handleCompletionsCommand(allocator, argv, subcommand_start);
        logCommandSucceeded("completion");
    } else if (std.mem.eql(u8, subcommand, "mcp")) {
        // CANARY: REQ=REQ-LIB-MIGRATION-MCP-006; FEATURE="External Library Migration"; ASPECT=MCPCommand; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
        // Model Context Protocol server for AI/LLM integration.
        // SONNY-6552: returns through main (exit 0, as before) instead of
        // std.process.exit, so main's DebugAllocator.deinit runs and a
        // Debug `geode mcp` reports its leaks.
        try handleMcpCommand(allocator, argv, subcommand_start);
        logCommandSucceeded("mcp");
    } else if (std.mem.eql(u8, subcommand, "login") or std.mem.eql(u8, subcommand, "logout")) {
        // CANARY: REQ=REQ-SONNY-6559-RETURN-THROUGH-MAIN; FEATURE="CliExitPaths"; ASPECT=ReturnThroughMain; STATUS=TESTED; TEST=tests/test_sonny6559_cli_exit_paths.zig; OWNER=cli; UPDATED=2026-11-14
        // SONNY-6559 (11): these commands return through main on success
        // (exit 0, as before), so main's DebugAllocator check and the
        // audit logger's close run; they ended with std.process.exit(0).
        // Top-level aliases - route to auth subcommands
        logAuditEvent("command", subcommand, "started");
        const auth_start_idx = if (subcommand_start > 0) subcommand_start - 1 else 0;
        try cmdAuth(allocator, argv, auth_start_idx);
        logCommandSucceeded(subcommand);
    } else if (std.mem.eql(u8, subcommand, "session")) {
        // Session management command
        logAuditEvent("command", "session", "started");
        try session_cli.cmdSession(allocator, argv, subcommand_start + 1);
        logCommandSucceeded("session");
    } else if (std.mem.eql(u8, subcommand, "authn")) {
        // Authentication provider configuration command
        logAuditEvent("command", "authn", "started");
        try authn_cli.cmdAuthn(allocator, argv, subcommand_start + 1);
        logCommandSucceeded("authn");
    } else if (std.mem.eql(u8, subcommand, "mtls")) {
        logAuditEvent("command", "mtls", "started");
        try mtls_cli.cmdMtls(allocator, argv, subcommand_start + 1);
        logCommandSucceeded("mtls");
    } else if (std.mem.eql(u8, subcommand, "tenant")) {
        // GAP-0839: tenant lifecycle administration over CALL geode.tenant.*.
        // It connects to the server (reusing cmdQuery's client + auth path) and
        // the server's admin_tenant gate enforces authorization. cmdQuery is in
        // scope here, so we thread it in (the command table can't hold cmdTenant
        // because its signature carries the extra cmdQuery parameter).
        logAuditEvent("command", "tenant", "started");
        try tenant_cli.cmdTenant(allocator, argv, subcommand_start, cmdQuery);
        logCommandSucceeded("tenant");
    } else {
        // Check if this is an option that should be handled by query command
        if (std.mem.startsWith(u8, subcommand, "--format") or
            std.mem.startsWith(u8, subcommand, "--param") or
            std.mem.startsWith(u8, subcommand, "--page-size") or
            std.mem.startsWith(u8, subcommand, "--server"))
        {
            // These are query command options, auto-route to query command
            logAuditEvent("command", "query", "started");
            try cmdQueryImplicit(allocator, argv, subcommand_start, cmdQuery);
            logCommandSucceeded("query");
        } else if (looksLikeGqlQuery(subcommand)) {
            // Check if this looks like a GQL query and auto-route to query command
            logAuditEvent("command", "query", "started");
            try cmdQueryImplicit(allocator, argv, subcommand_start, cmdQuery);
            logCommandSucceeded("query");
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

/// SONNY-6559 (11): the CLI audit log records a command's success when the
/// command returns to the dispatcher (a failure exits with its code first).
fn logCommandSucceeded(name: []const u8) void {
    logAuditEvent("command", name, "success");
}

/// SONNY-6560: a global option given without its value (it was skipped).
fn refuseMissingGlobalValue(opt: []const u8) noreturn {
    std.debug.print("Error: geode: option '{s}' requires a value (see geode --help)\n", .{opt});
    std.process.exit(@intFromEnum(ExitCode.usage_error));
}

/// The subcommands geode dispatches (for `--audit-eventlog [source]`: a
/// following subcommand name is not the event source).
fn findCommandName(name: []const u8) ?[]const u8 {
    const names = [_][]const u8{
        "serve",       "query", "shell",  "lsp",    "backup",  "restore", "migrate", "user",   "role",
        "policy",      "grant", "revoke", "auth",   "fle",     "storage", "apikey",  "audit",  "completion",
        "completions", "mcp",   "login",  "logout", "session", "authn",   "mtls",    "tenant",
    };
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return n;
    }
    return null;
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
// Shell Completion Generation
// ============================================================================

const geode_completion_global_flags = [_]CliFlagSpec{
    .{ .name = "help", .short = 'h', .help = "Show help", .ftype = CliFlagType.bool },
    .{ .name = "version", .help = "Show version", .ftype = CliFlagType.bool },
    .{ .name = "audit", .help = "Enable audit logging", .ftype = CliFlagType.bool },
    .{ .name = "audit-syslog", .help = "Syslog host:port for audit", .ftype = CliFlagType.string },
    .{ .name = "audit-file", .help = "Audit log file path", .ftype = CliFlagType.path },
};

const geode_completion_serve_flags = [_]CliFlagSpec{
    .{ .name = "listen", .help = "Listen address (host:port)", .ftype = CliFlagType.string },
    .{ .name = "listen-grpc", .help = "Listen address for gRPC", .ftype = CliFlagType.string },
    .{ .name = "data-dir", .help = "Data directory path", .ftype = CliFlagType.path },
    .{ .name = "cert", .help = "TLS certificate path", .ftype = CliFlagType.path },
    .{ .name = "key", .help = "TLS private key path", .ftype = CliFlagType.path },
    .{ .name = "idle-timeout", .help = "QUIC idle timeout in milliseconds", .ftype = CliFlagType.int },
    .{ .name = "persist-interval", .help = "Background persistence interval in milliseconds", .ftype = CliFlagType.int },
};

const geode_completion_query_flags = [_]CliFlagSpec{
    // SONNY-6560: the completion offered -s and -f, which geode query does
    // not read (-f is --file), and not dot/mermaid.
    .{ .name = "server", .help = "Server address", .ftype = CliFlagType.string },
    .{ .name = "format", .help = "Output format", .ftype = CliFlagType.string, .completions = &.{ "json", "table", "csv", "dot", "mermaid" } },
    .{ .name = "param", .help = "Query parameter", .ftype = CliFlagType.string_array, .is_repeatable = true },
    .{ .name = "page-size", .help = "Page size for paginated output", .ftype = CliFlagType.int },
};

const geode_completion_shell_flags = [_]CliFlagSpec{
    .{ .name = "server", .help = "Server address", .ftype = CliFlagType.string },
    .{ .name = "insecure-tls-skip-verify", .help = "Skip TLS verification", .ftype = CliFlagType.bool },
    .{ .name = "insecure", .help = "Skip TLS verification (deprecated)", .ftype = CliFlagType.bool, .is_deprecated = true },
    .{ .name = "client-cert", .help = "Client certificate path", .ftype = CliFlagType.path },
    .{ .name = "client-key", .help = "Client private key path", .ftype = CliFlagType.path },
};

const geode_completion_completion_flags = [_]CliFlagSpec{
    .{ .name = "shell", .short = 's', .help = "Shell type", .ftype = CliFlagType.string, .completions = &.{ "bash", "zsh", "fish", "powershell" } },
};

const geode_completion_mcp_flags = [_]CliFlagSpec{
    .{ .name = "stdio", .help = "Use stdio transport (stdin/stdout JSONRPC)", .ftype = CliFlagType.bool },
    .{ .name = "port", .help = "HTTP port", .ftype = CliFlagType.int },
    .{ .name = "endpoint", .short = 'e', .help = "Geode server endpoint", .ftype = CliFlagType.string },
};

const geode_completion_audit_verify_flags = [_]CliFlagSpec{
    .{ .name = "file", .help = "Audit log file path", .ftype = CliFlagType.path },
    .{ .name = "algo", .help = "Hash algorithm", .ftype = CliFlagType.string, .completions = &.{ "sha256", "blake3" } },
    .{ .name = "require-digest", .help = "Require all entries to have digest", .ftype = CliFlagType.bool },
    .{ .name = "pubkey", .help = "Ed25519 public key (hex)", .ftype = CliFlagType.string },
};

const geode_completion_audit_verify_cmd = CliCommand{
    .name = "verify",
    .summary = "Verify audit log integrity",
    .flags = &geode_completion_audit_verify_flags,
};

const geode_completion_audit_subcommands = [_]*const CliCommand{
    &geode_completion_audit_verify_cmd,
};

const geode_completion_serve_cmd = CliCommand{
    .name = "serve",
    .summary = "Start the Geode server",
    .flags = &geode_completion_serve_flags,
};

const geode_completion_query_cmd = CliCommand{
    .name = "query",
    .summary = "Execute a GQL query",
    .flags = &geode_completion_query_flags,
};

const geode_completion_shell_cmd = CliCommand{
    .name = "shell",
    .summary = "Start interactive shell (REPL)",
    .flags = &geode_completion_shell_flags,
};

const geode_completion_lsp_cmd = CliCommand{
    .name = "lsp",
    .summary = "Start Language Server Protocol server",
};

const geode_completion_backup_cmd = CliCommand{
    .name = "backup",
    .summary = "Create database backup",
};

const geode_completion_restore_cmd = CliCommand{
    .name = "restore",
    .summary = "Restore database from backup",
};

const geode_completion_migrate_cmd = CliCommand{
    .name = "migrate",
    .summary = "Database migration commands",
};

const geode_completion_user_cmd = CliCommand{
    .name = "user",
    .summary = "Manage users",
};

const geode_completion_role_cmd = CliCommand{
    .name = "role",
    .summary = "Manage roles",
};

const geode_completion_tenant_cmd = CliCommand{
    .name = "tenant",
    .summary = "Manage tenants (create/list/show/drop/set-quota) via CALL geode.tenant.*",
};

const geode_completion_policy_cmd = CliCommand{
    .name = "policy",
    .summary = "Manage policies",
};

const geode_completion_grant_cmd = CliCommand{
    .name = "grant",
    .summary = "Grant permissions",
};

const geode_completion_revoke_cmd = CliCommand{
    .name = "revoke",
    .summary = "Revoke permissions",
};

const geode_completion_auth_cmd = CliCommand{
    .name = "auth",
    .summary = "Authentication commands",
};

const geode_completion_login_cmd = CliCommand{
    .name = "login",
    .summary = "Authenticate and create a session",
};

const geode_completion_logout_cmd = CliCommand{
    .name = "logout",
    .summary = "End the current session",
};

const geode_completion_fle_cmd = CliCommand{
    .name = "fle",
    .summary = "Field-Level Encryption management",
};

const geode_completion_storage_cmd = CliCommand{
    .name = "storage",
    .summary = "Storage engine management",
};

const geode_completion_audit_cmd = CliCommand{
    .name = "audit",
    .summary = "Audit log management",
    .subcommands = &geode_completion_audit_subcommands,
};

const geode_completion_completion_cmd = CliCommand{
    .name = "completion",
    .summary = "Generate shell completion scripts",
    .aliases = &.{"completions"},
    .flags = &geode_completion_completion_flags,
};

const geode_completion_mtls_cmd = CliCommand{
    .name = "mtls",
    .summary = "Mutual TLS certificate-to-user mapping (not supported yet, SONNY-6458)",
};

const geode_completion_mcp_cmd = CliCommand{
    .name = "mcp",
    .summary = "Model Context Protocol server (AI/LLM integration)",
    .flags = &geode_completion_mcp_flags,
};

const geode_completion_session_cmd = CliCommand{
    .name = "session",
    .summary = "The local saved session (validate/rotate/invalidate-all/check-idle not supported, SONNY-6554)",
};

const geode_completion_authn_cmd = CliCommand{
    .name = "authn",
    .summary = "Authentication provider configuration (not supported, SONNY-6554)",
};

const geode_completion_apikey_cmd = CliCommand{
    .name = "apikey",
    .summary = "API key format check (create/list/revoke not supported, SONNY-6554)",
};

const geode_completion_subcommands = [_]*const CliCommand{
    &geode_completion_serve_cmd,
    &geode_completion_query_cmd,
    &geode_completion_shell_cmd,
    &geode_completion_lsp_cmd,
    &geode_completion_backup_cmd,
    &geode_completion_restore_cmd,
    &geode_completion_migrate_cmd,
    &geode_completion_user_cmd,
    &geode_completion_role_cmd,
    &geode_completion_tenant_cmd,
    &geode_completion_policy_cmd,
    &geode_completion_grant_cmd,
    &geode_completion_revoke_cmd,
    &geode_completion_auth_cmd,
    &geode_completion_login_cmd,
    &geode_completion_logout_cmd,
    &geode_completion_fle_cmd,
    &geode_completion_storage_cmd,
    &geode_completion_audit_cmd,
    &geode_completion_completion_cmd,
    &geode_completion_mtls_cmd,
    &geode_completion_mcp_cmd,
    &geode_completion_session_cmd,
    &geode_completion_authn_cmd,
    &geode_completion_apikey_cmd,
};

const geode_completion_root_cmd = CliCommand{
    .name = "geode",
    .summary = "Enterprise graph database implementing ISO/IEC 39075:2024",
    .flags = &geode_completion_global_flags,
    .subcommands = &geode_completion_subcommands,
};

fn parseCompletionShell(shell_str: []const u8) ?CliShell {
    if (std.mem.eql(u8, shell_str, "bash")) return .bash;
    if (std.mem.eql(u8, shell_str, "zsh")) return .zsh;
    if (std.mem.eql(u8, shell_str, "fish")) return .fish;
    if (std.mem.eql(u8, shell_str, "powershell") or std.mem.eql(u8, shell_str, "pwsh")) return .powershell;
    return null;
}

fn generateCompletionScript(allocator: std.mem.Allocator, shell: CliShell) ![]const u8 {
    return try cli_lib.generateCompletions(shell, &geode_completion_root_cmd, allocator);
}

/// Handle the completions subcommand using external CLI library
/// Generates shell completion scripts for bash, zsh, fish, and powershell
fn handleCompletionsCommand(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var shell_str: []const u8 = "bash"; // default to bash
    var saw_shell_arg = false;
    var ai: usize = start_idx + 1;

    while (ai < argv.len) : (ai += 1) {
        if (std.mem.eql(u8, argv[ai], "--shell") or std.mem.eql(u8, argv[ai], "-s")) {
            // SONNY-6560: without its value the option was skipped.
            if (ai + 1 >= argv.len) {
                std.debug.print("Error: geode completion: option '{s}' requires a value (see geode completion --help)\n", .{argv[ai]});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            shell_str = argv[ai + 1];
            if (parseCompletionShell(shell_str) == null) {
                std.debug.print("Error: Unknown shell type '{s}'. Supported: bash, zsh, fish, powershell\n", .{shell_str});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            ai += 1;
        } else if (std.mem.eql(u8, argv[ai], "-h") or std.mem.eql(u8, argv[ai], "--help")) {
            printCompletionsHelp();
            return;
        } else if (std.mem.startsWith(u8, argv[ai], "-")) {
            std.debug.print("Error: geode completion: unknown option '{s}' (see geode completion --help)\n", .{argv[ai]});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        } else if (!saw_shell_arg) {
            // `geode completion zsh`: the shell named as an argument. It
            // used to be ignored, so this printed the bash script.
            if (parseCompletionShell(argv[ai]) == null) {
                std.debug.print("Error: Unknown shell type '{s}'. Supported: bash, zsh, fish, powershell\n", .{argv[ai]});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            shell_str = argv[ai];
            saw_shell_arg = true;
        } else {
            std.debug.print("Error: geode completion: unexpected argument '{s}' (see geode completion --help)\n", .{argv[ai]});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // CANARY: REQ=REQ-LIB-MIGRATION-CLI-002; FEATURE="External Library Migration"; ASPECT=ShellCompletions; STATUS=TESTED; TEST=test_completion_scripts_use_external_cli_library; OWNER=cli; UPDATED=2026-04-01
    const shell = parseCompletionShell(shell_str) orelse unreachable;
    const script = try generateCompletionScript(allocator, shell);
    defer allocator.free(script);
    // CANARY: REQ=REQ-SONNY-6559-COMPLETION-STDOUT; FEATURE="CliExitPaths"; ASPECT=CompletionOnStdout; STATUS=TESTED; TEST=tests/test_sonny6559_cli_exit_paths.zig; OWNER=cli; UPDATED=2026-11-14
    // SONNY-6559 (8): the script is the command's output: stdout, so
    // `geode completion --shell bash > file` writes it. It went to stderr
    // (std.debug.print) and the file was empty.
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), script);
}

test "completion scripts use external cli library" {
    const bash = try generateCompletionScript(std.testing.allocator, .bash);
    defer std.testing.allocator.free(bash);

    try std.testing.expect(std.mem.indexOf(u8, bash, "serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "session") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "apikey") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "--shell") != null);
}

fn printCompletionsHelp() void {
    std.debug.print("Generate shell completion scripts\n\n", .{});
    std.debug.print("Usage: geode completion [<shell> | --shell <shell>]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -s, --shell <shell>    Shell type: bash, zsh, fish, powershell (default: bash)\n", .{});
    std.debug.print("  -h, --help             Show this help message\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode completion --shell bash > /etc/bash_completion.d/geode\n", .{});
    std.debug.print("  geode completion --shell zsh > ~/.zsh/completions/_geode\n", .{});
    std.debug.print("  geode completion --shell fish > ~/.config/fish/completions/geode.fish\n", .{});
}

fn printAuditHelp() void {
    std.debug.print("Audit log management and verification\n\n", .{});
    std.debug.print("Usage: geode audit <subcommand> [options]\n\n", .{});
    std.debug.print("Subcommands:\n", .{});
    std.debug.print("  verify                  Verify audit log integrity\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --file <path>          Audit log file path (default: audit.jsonl)\n", .{});
    std.debug.print("  --algo <algorithm>     Hash algorithm: sha256, blake3 (default: sha256)\n", .{});
    std.debug.print("  --require-digest       Require all entries to have digest\n", .{});
    std.debug.print("  --pubkey <hex>         Ed25519 public key of an audit key epoch, once per epoch in order\n", .{});
    std.debug.print("                         (audit.jsonl.pub, then audit.jsonl.pub.1, ...); a signature that\n", .{});
    std.debug.print("                         does not verify fails the command\n", .{});
    std.debug.print("  -h, --help             Show this help message\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode audit verify --file /var/log/geode/audit.jsonl\n", .{});
    std.debug.print("  geode audit verify --algo blake3 --require-digest\n", .{});
    std.debug.print("  geode audit verify --file <graph dir>/audit.jsonl --pubkey <audit.jsonl.pub> --pubkey <audit.jsonl.pub.1>\n", .{});
}

/// Print bash completion script
fn printBashCompletions() void {
    const script =
        \\# Bash completion for geode
        \\_geode() {
        \\    local cur prev opts commands
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\
        \\    commands="serve query shell lsp backup restore migrate user role policy grant revoke auth fle storage audit completion mcp"
        \\    opts="--help --version --verbose --json --config --audit --audit-syslog --audit-file"
        \\
        \\    case "${prev}" in
        \\        geode)
        \\            COMPREPLY=( $(compgen -W "${commands} ${opts}" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        serve)
        \\            COMPREPLY=( $(compgen -W "--listen --data-dir --cert --key --help" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        query)
        \\            COMPREPLY=( $(compgen -W "--server --format --param --help" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        shell)
        \\            COMPREPLY=( $(compgen -W "--server --insecure-tls-skip-verify --insecure --help" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        completion)
        \\            COMPREPLY=( $(compgen -W "--shell --help" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        mcp)
        \\            COMPREPLY=( $(compgen -W "serve --stdio --port --endpoint --help" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        --shell|-s)
        \\            COMPREPLY=( $(compgen -W "bash zsh fish powershell" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\    esac
        \\
        \\    if [[ ${cur} == -* ]]; then
        \\        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        \\    else
        \\        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        \\    fi
        \\}
        \\complete -F _geode geode
        \\
    ;
    std.debug.print("{s}", .{script});
}

/// Print zsh completion script
fn printZshCompletions() void {
    const script =
        \\#compdef geode
        \\# Zsh completion for geode
        \\
        \\_geode() {
        \\    local -a commands
        \\    commands=(
        \\        'serve:Start the Geode server'
        \\        'query:Execute a GQL query'
        \\        'shell:Start interactive shell (REPL)'
        \\        'lsp:Start Language Server Protocol server'
        \\        'backup:Create database backup'
        \\        'restore:Restore database from backup'
        \\        'migrate:Database migration commands'
        \\        'user:Manage users'
        \\        'role:Manage roles'
        \\        'policy:Manage policies'
        \\        'grant:Grant permissions'
        \\        'revoke:Revoke permissions'
        \\        'auth:Authentication commands'
        \\        'fle:Field-Level Encryption management'
        \\        'storage:Storage engine management'
        \\        'audit:Audit log management'
        \\        'completion:Generate shell completion scripts'
        \\        'mcp:Model Context Protocol server (AI/LLM integration)'
        \\    )
        \\
        \\    _arguments -C \
        \\        '(-h --help)'{-h,--help}'[Show help]' \
        \\        '--version[Show version]' \
        \\        '(-v --verbose)'{-v,--verbose}'[Enable verbose output]' \
        \\        '--json[Output in JSON format]' \
        \\        '--config[Configuration file path]:file:_files' \
        \\        '--audit[Enable audit logging]' \
        \\        '--audit-syslog[Syslog host:port for audit]:host:' \
        \\        '--audit-file[Audit log file path]:file:_files' \
        \\        '1: :->command' \
        \\        '*::arg:->args'
        \\
        \\    case $state in
        \\        command)
        \\            _describe -t commands 'geode commands' commands
        \\            ;;
        \\    esac
        \\}
        \\
        \\_geode "$@"
        \\
    ;
    std.debug.print("{s}", .{script});
}

/// Print fish completion script
fn printFishCompletions() void {
    const script =
        \\# Fish completion for geode
        \\complete -c geode -f
        \\
        \\# Global options
        \\complete -c geode -s h -l help -d 'Show help'
        \\complete -c geode -l version -d 'Show version'
        \\complete -c geode -s v -l verbose -d 'Enable verbose output'
        \\complete -c geode -l json -d 'Output in JSON format'
        \\complete -c geode -l config -d 'Configuration file path' -r
        \\complete -c geode -l audit -d 'Enable audit logging'
        \\complete -c geode -l audit-syslog -d 'Syslog host:port for audit' -r
        \\complete -c geode -l audit-file -d 'Audit log file path' -r
        \\
        \\# Commands
        \\complete -c geode -n "__fish_use_subcommand" -a serve -d 'Start the Geode server'
        \\complete -c geode -n "__fish_use_subcommand" -a query -d 'Execute a GQL query'
        \\complete -c geode -n "__fish_use_subcommand" -a shell -d 'Start interactive shell (REPL)'
        \\complete -c geode -n "__fish_use_subcommand" -a lsp -d 'Start Language Server Protocol server'
        \\complete -c geode -n "__fish_use_subcommand" -a backup -d 'Create database backup'
        \\complete -c geode -n "__fish_use_subcommand" -a restore -d 'Restore database from backup'
        \\complete -c geode -n "__fish_use_subcommand" -a migrate -d 'Database migration commands'
        \\complete -c geode -n "__fish_use_subcommand" -a user -d 'Manage users'
        \\complete -c geode -n "__fish_use_subcommand" -a role -d 'Manage roles'
        \\complete -c geode -n "__fish_use_subcommand" -a policy -d 'Manage policies'
        \\complete -c geode -n "__fish_use_subcommand" -a grant -d 'Grant permissions'
        \\complete -c geode -n "__fish_use_subcommand" -a revoke -d 'Revoke permissions'
        \\complete -c geode -n "__fish_use_subcommand" -a auth -d 'Authentication commands'
        \\complete -c geode -n "__fish_use_subcommand" -a fle -d 'Field-Level Encryption management'
        \\complete -c geode -n "__fish_use_subcommand" -a storage -d 'Storage engine management'
        \\complete -c geode -n "__fish_use_subcommand" -a audit -d 'Audit log management'
        \\complete -c geode -n "__fish_use_subcommand" -a completion -d 'Generate shell completion scripts'
        \\complete -c geode -n "__fish_use_subcommand" -a mtls -d 'Mutual TLS certificate-to-user mapping (not supported yet)'
        \\complete -c geode -n "__fish_use_subcommand" -a mcp -d 'Model Context Protocol server (AI/LLM integration)'
        \\
        \\# Subcommand options
        \\complete -c geode -n "__fish_seen_subcommand_from serve" -s l -l listen -d 'Listen address (host:port)' -r
        \\complete -c geode -n "__fish_seen_subcommand_from serve" -s d -l data-dir -d 'Data directory path' -r
        \\complete -c geode -n "__fish_seen_subcommand_from query" -s s -l server -d 'Server address' -r
        \\complete -c geode -n "__fish_seen_subcommand_from query" -s f -l format -d 'Output format' -ra 'json table csv'
        \\complete -c geode -n "__fish_seen_subcommand_from shell" -s s -l server -d 'Server address' -r
        \\complete -c geode -n "__fish_seen_subcommand_from shell" -l insecure-tls-skip-verify -d 'Skip TLS verification'
        \\complete -c geode -n "__fish_seen_subcommand_from shell" -l insecure -d 'Skip TLS verification (deprecated)'
        \\complete -c geode -n "__fish_seen_subcommand_from completion" -s s -l shell -d 'Shell type' -ra 'bash zsh fish powershell'
        \\complete -c geode -n "__fish_seen_subcommand_from mcp" -l stdio -d 'Use stdio transport (stdin/stdout JSONRPC)'
        \\complete -c geode -n "__fish_seen_subcommand_from mcp" -l port -d 'HTTP port' -r
        \\complete -c geode -n "__fish_seen_subcommand_from mcp" -s e -l endpoint -d 'Geode server endpoint' -r
        \\
    ;
    std.debug.print("{s}", .{script});
}

/// Print PowerShell completion script
fn printPowershellCompletions() void {
    const script =
        \\# PowerShell completion for geode
        \\Register-ArgumentCompleter -Native -CommandName geode -ScriptBlock {
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\
        \\    $commands = @(
        \\        @{Name='serve'; Description='Start the Geode server'}
        \\        @{Name='query'; Description='Execute a GQL query'}
        \\        @{Name='shell'; Description='Start interactive shell (REPL)'}
        \\        @{Name='lsp'; Description='Start Language Server Protocol server'}
        \\        @{Name='backup'; Description='Create database backup'}
        \\        @{Name='restore'; Description='Restore database from backup'}
        \\        @{Name='migrate'; Description='Database migration commands'}
        \\        @{Name='user'; Description='Manage users'}
        \\        @{Name='role'; Description='Manage roles'}
        \\        @{Name='policy'; Description='Manage policies'}
        \\        @{Name='grant'; Description='Grant permissions'}
        \\        @{Name='revoke'; Description='Revoke permissions'}
        \\        @{Name='auth'; Description='Authentication commands'}
        \\        @{Name='fle'; Description='Field-Level Encryption management'}
        \\        @{Name='storage'; Description='Storage engine management'}
        \\        @{Name='audit'; Description='Audit log management'}
        \\        @{Name='completion'; Description='Generate shell completion scripts'}
        \\        @{Name='mcp'; Description='Model Context Protocol server (AI/LLM integration)'}
        \\    )
        \\
        \\    $commands | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object {
        \\        [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Description)
        \\    }
        \\}
        \\
    ;
    std.debug.print("{s}", .{script});
}

// ============================================================================
// MCP (Model Context Protocol) Server Command
// ============================================================================

/// Handle the mcp subcommand - starts an MCP server for AI/LLM integration
/// CANARY: REQ=REQ-LIB-MIGRATION-MCP-007; FEATURE="External Library Migration"; ASPECT=MCPCommandHandler; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
fn handleMcpCommand(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var http_port: u16 = 8080;
    var endpoint: ?[]const u8 = "localhost:3141";
    var use_stdio: bool = false;
    var bearer_token: ?[]const u8 = null;
    var no_auth: bool = false;
    var read_only: bool = false;
    var ai: usize = start_idx + 1;

    var saw_serve = false;
    while (ai < argv.len) : (ai += 1) {
        const arg = argv[ai];
        // CANARY: REQ=REQ-SONNY-6560-MCP-OPTIONS; FEATURE="CliOptions"; ASPECT=McpOptionsRefused; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-14
        // SONNY-6560 / SONNY-6559 (9): a value option without its value, a
        // --port that is not a port (it became 8080), an unknown option and
        // a stray argument are refused; each used to be skipped.
        const takes_value = std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "--endpoint") or
            std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--token");
        if (takes_value and ai + 1 >= argv.len) {
            std.debug.print("Error: geode mcp: option '{s}' requires a value (see geode mcp --help)\n", .{arg});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (std.mem.eql(u8, arg, "--port")) {
            http_port = std.fmt.parseInt(u16, argv[ai + 1], 10) catch {
                std.debug.print("Error: geode mcp: option '--port' takes a port number 0-65535, not '{s}'\n", .{argv[ai + 1]});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--endpoint") or std.mem.eql(u8, arg, "-e")) {
            endpoint = argv[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--token")) {
            bearer_token = argv[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, argv[ai], "--no-auth")) {
            // Record the request; the release-build gate is applied after the
            // parse loop because it depends on the selected transport (which
            // may be specified by a later argument, e.g. `--stdio --no-auth`).
            no_auth = true;
        } else if (std.mem.eql(u8, argv[ai], "--stdio")) {
            use_stdio = true;
        } else if (std.mem.eql(u8, argv[ai], "--read-only")) {
            // CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=CliFlag; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
            read_only = true;
        } else if (std.mem.eql(u8, argv[ai], "-h") or std.mem.eql(u8, argv[ai], "--help")) {
            printMcpHelp();
            return;
        } else if (std.mem.eql(u8, argv[ai], "serve") and !saw_serve) {
            // Skip the 'serve' subcommand as it's the default action
            saw_serve = true;
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: geode mcp: unknown option '{s}' (see geode mcp --help)\n", .{arg});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        } else {
            std.debug.print("Error: geode mcp: unexpected argument '{s}' (see geode mcp --help)\n", .{arg});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // SEC-08 / GAP-0345: `--no-auth` disables MCP-level bearer auth. On the
    // network-exposed HTTP transport that is a release footgun, so it stays
    // debug-only there. The stdio transport, by contrast, is a local pipe owned
    // by the spawning process (Claude Desktop/Code, the test harness, etc.) with
    // no network surface, so MCP-level auth is meaningless and `--no-auth` is
    // permitted in release. The gate runs here, post-parse, because the
    // transport may be selected by an argument that follows `--no-auth`
    // (e.g. `geode mcp --no-auth --stdio`). The geode *endpoint* credentials in
    // the `--endpoint` DSN are unaffected and still authenticate to the server.
    if (no_auth and !use_stdio and @import("builtin").mode != .Debug) {
        std.debug.print("Error: --no-auth is only available in debug builds for the HTTP transport. Use --token for production, or --stdio for a local pipe.\n", .{});
        std.process.exit(1);
    }

    // SONNY-6494: a malformed --endpoint DSN is refused here, saying what is
    // wrong, instead of every tool call later failing with "Failed to
    // initialize client". The DSN is not echoed: it may carry a password.
    if (endpoint) |ep| geode_mcp.client.checkEndpoint(allocator, ep) catch |err| {
        const why = geode_mcp.client.endpointErrorMessage(err) orelse @errorName(err);
        std.debug.print("Error: --endpoint: {s}\n", .{why});
        std.process.exit(2);
    };

    // SEC-08: Also check GEODE_MCP_TOKEN env var as fallback for bearer token
    if (bearer_token == null) {
        bearer_token = posixGetenv("GEODE_MCP_TOKEN");
    }

    // Create and start MCP server with Options struct
    // SEC-08: Default auth_mode is .bearer; --no-auth explicitly disables it
    const server = try geode_mcp.GeodeMcpServer.init(allocator, if (no_auth) .{
        .geode_endpoint = endpoint,
        .http_port = http_port,
        .auth_mode = .none,
        .bearer_token = bearer_token,
        .read_only = read_only,
    } else .{
        .geode_endpoint = endpoint,
        .http_port = http_port,
        .bearer_token = bearer_token,
        .read_only = read_only,
    });
    defer server.deinit();

    if (use_stdio) {
        // stdio transport: stdin/stdout are reserved exclusively for JSONRPC messages.
        // Do NOT write anything to stdout except JSONRPC responses.
        // Log to stderr only for critical errors (std.debug.print uses stderr in Zig).
        try server.serveStdio();
    } else {
        // HTTP transport: status messages go to stderr via std.debug.print
        std.debug.print("Starting MCP server on HTTP port {d}...\n", .{http_port});
        if (endpoint) |ep| {
            std.debug.print("Connected to Geode at {s}\n", .{ep});
        }
        const actual_port = try server.serveHttp();
        std.debug.print("MCP server listening on port {d}\n", .{actual_port});
        // CANARY: REQ=REQ-SONNY-6644-MCP-HTTP-SESSION; FEATURE="MCPServer"; ASPECT=HttpTransportStaysUp; STATUS=TESTED; TEST=tests/test_sonny6644_mcp_http_session.zig; OWNER=mcp; UPDATED=2026-11-16
        // SONNY-6644: serveHttp returns once its listener thread runs. This
        // returned with it, and the deferred deinit stopped the server: the
        // HTTP transport printed its port and exited 0. It serves until
        // SIGINT or SIGTERM.
        waitForMcpShutdownSignal();
        std.debug.print("MCP server stopping\n", .{});
    }
}

var g_mcp_shutdown = std.atomic.Value(bool).init(false);

fn handleMcpShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    g_mcp_shutdown.store(true, .release);
}

/// Block until SIGINT or SIGTERM.
fn waitForMcpShutdownSignal() void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleMcpShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    const io = std.Io.Threaded.global_single_threaded.io();
    while (!g_mcp_shutdown.load(.acquire)) {
        io.sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn printMcpHelp() void {
    std.debug.print("Model Context Protocol (MCP) server for AI/LLM integration\n\n", .{});
    std.debug.print("Usage: geode mcp [serve] [options]\n\n", .{});
    std.debug.print("Transports:\n", .{});
    std.debug.print("  --stdio             Use stdio transport (stdin/stdout JSONRPC)\n", .{});
    std.debug.print("                      Required for Claude Desktop, Claude Code, etc.\n", .{});
    std.debug.print("  --port <port>       HTTP transport port (default: 8080); HTTP is the\n", .{});
    std.debug.print("                      transport unless --stdio is given\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -e, --endpoint <dsn>  Geode server endpoint (default: localhost:3141)\n", .{});
    std.debug.print("  --token <token>     Bearer token HTTP clients must present (default:\n", .{});
    std.debug.print("                      GEODE_MCP_TOKEN)\n", .{});
    std.debug.print("  --no-auth           No MCP bearer auth: --stdio, or a debug build's HTTP\n", .{});
    std.debug.print("  --read-only         Refuse mutating/unparseable query tool calls\n", .{});
    std.debug.print("                      pre-wire (fail-closed; no data modification)\n", .{});
    std.debug.print("  -h, --help          Show this help message\n\n", .{});
    std.debug.print("Description:\n", .{});
    std.debug.print("  Starts a Model Context Protocol server that exposes Geode as an\n", .{});
    std.debug.print("  AI-accessible tool. LLMs can use the MCP interface to:\n", .{});
    std.debug.print("    - Execute GQL queries\n", .{});
    std.debug.print("    - Explore graph schemas\n", .{});
    std.debug.print("    - Access query explain plans\n", .{});
    std.debug.print("    - Use GQL query templates\n\n", .{});
    std.debug.print("  When using --stdio, stdout is reserved exclusively for JSONRPC\n", .{});
    std.debug.print("  messages. All log output goes to stderr.\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode mcp --stdio                  # stdio transport (for AI clients)\n", .{});
    std.debug.print("  geode mcp serve --port 9000        # HTTP transport on port 9000\n", .{});
    std.debug.print("  geode mcp serve -e host:3141       # Connect to specific endpoint\n", .{});
}

// ============================================================================
// Audit Configuration and Logging
// ============================================================================

/// Cross-platform environment variable helper
pub fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return getEnvVarOwned(allocator, key) catch null;
}

const default_cli_audit_file = "/var/log/geode/cli-audit.log";

pub const AuditEnvError = error{
    /// GEODE_AUDIT_SYSLOG_PORT is not 1-5 digits in 0..65535.
    InvalidAuditSyslogPort,
    /// GEODE_AUDIT_SYSLOG_HOST is not an IPv4 address, a bracketed IPv6
    /// address or localhost (optionally with :port), or names a port as
    /// well as GEODE_AUDIT_SYSLOG_PORT.
    InvalidAuditSyslogHost,
    /// A GEODE_AUDIT_*_ENABLED switch is not 1/0, true/false or yes/no.
    InvalidAuditSwitch,
};

/// SONNY-6511: a GEODE_AUDIT_*_ENABLED switch is 1/0, true/false or yes/no,
/// in any case. Anything else is refused (it used to read as false, turning
/// audit off without a word), as every other audit setting is (SONNY-6494).
pub fn parseAuditSwitch(name: []const u8, value: []const u8) AuditEnvError!bool {
    inline for (.{ "1", "true", "yes" }) |on| {
        if (std.ascii.eqlIgnoreCase(value, on)) return true;
    }
    inline for (.{ "0", "false", "no" }) |off| {
        if (std.ascii.eqlIgnoreCase(value, off)) return false;
    }
    std.debug.print("Error: {s} '{s}' is not a switch (1/0, true/false or yes/no)\n", .{ name, value });
    return error.InvalidAuditSwitch;
}

// CANARY: REQ=REQ-AUDIT-CLI-001; FEATURE="CLI Audit Configuration"; ASPECT=Configuration; STATUS=TESTED; TEST=TestCANARY_REQ_AUDIT_CLI_001_Configuration; OWNER=audit; UPDATED=2025-09-30
pub fn parseAuditConfigFromEnv(allocator: std.mem.Allocator) !CliAuditConfig {
    var cli_config = CliAuditConfig{};
    errdefer inline for (.{ "syslog_host", "file_path", "windows_eventlog_source", "windows_eventlog_log" }) |field| {
        if (@field(cli_config, field)) |owned| allocator.free(owned);
    };

    // Check if audit is enabled
    if (getEnvVar(allocator, "GEODE_AUDIT_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.enabled = try parseAuditSwitch("GEODE_AUDIT_ENABLED", value);
    }

    // Syslog configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.syslog_enabled = try parseAuditSwitch("GEODE_AUDIT_SYSLOG_ENABLED", value);
    }

    // SONNY-6494: the --audit-syslog grammar (SONNY-6487, geode.host_port);
    // a port that is not a port is refused (it used to become 514), and so
    // is a host the sender cannot send to (it used to drop every message).
    var port_from_env = false;
    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_PORT")) |value| {
        defer allocator.free(value);
        cli_config.syslog_port = geode.host_port.parsePort(value) catch {
            std.debug.print("Error: GEODE_AUDIT_SYSLOG_PORT '{s}' is not a port (1-5 digits, 0-65535)\n", .{value});
            return error.InvalidAuditSyslogPort;
        };
        port_from_env = true;
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_SYSLOG_HOST")) |value| {
        defer allocator.free(value);
        const target = geode.host_port.split(value, cli_config.syslog_port) catch {
            std.debug.print("Error: GEODE_AUDIT_SYSLOG_HOST '{f}' is not a valid address (expected <host>[:<port>] or [<ipv6>][:<port>], port 0-65535)\n", .{geode.dsn_credentials.redacted(value)});
            return error.InvalidAuditSyslogHost;
        };
        if (syslogTarget(target.host, target.port) == null) {
            std.debug.print("Error: GEODE_AUDIT_SYSLOG_HOST '{f}': the syslog sender sends to an IPv4 address, a bracketed IPv6 address or localhost, not to a host name\n", .{geode.dsn_credentials.redacted(value)});
            return error.InvalidAuditSyslogHost;
        }
        if (port_from_env and target.port != cli_config.syslog_port) {
            std.debug.print("Error: GEODE_AUDIT_SYSLOG_HOST '{f}' names port {d} and GEODE_AUDIT_SYSLOG_PORT names {d}\n", .{ geode.dsn_credentials.redacted(value), target.port, cli_config.syslog_port });
            return error.InvalidAuditSyslogHost;
        }
        cli_config.syslog_host = try allocator.dupe(u8, target.host);
        cli_config.syslog_port = target.port;
    }

    // Note: Protocol and facility configuration can be added later if needed

    // File configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_FILE_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.file_enabled = try parseAuditSwitch("GEODE_AUDIT_FILE_ENABLED", value);
    }

    if (getEnvVar(allocator, "GEODE_AUDIT_FILE_PATH")) |value| {
        cli_config.file_path = value; // Keep ownership
    }

    // Windows Event Log configuration
    if (getEnvVar(allocator, "GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED")) |value| {
        defer allocator.free(value);
        cli_config.windows_eventlog_enabled = try parseAuditSwitch("GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED", value);
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
        const path = cli_config.file_path orelse default_cli_audit_file;

        // Create directory if it doesn't exist
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        global_audit_file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // Try to create the file
                break :blk try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
            },
            else => return err,
        };

        // Seek to end for append mode
        if (global_audit_file) |file| {
            const io = std.Io.Threaded.global_single_threaded.io();
            const len = file.length(io) catch 0;
            // Use writePositionalAll at end to effectively seek; or write a no-op
            // The streaming writer will begin at the current OS position, so we
            // set the position by writing nothing at the end offset.
            _ = file.writePositionalAll(io, "", len) catch {};
        }
    }

    // GAP-0075: Initialize syslog logging if enabled
    // CANARY: REQ=REQ-AUDIT-SYSLOG-002; FEATURE="SyslogSenderInit"; ASPECT=AuditLogging; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-10
    if (cli_config.syslog_enabled) {
        global_syslog_host = cli_config.syslog_host orelse "127.0.0.1";
        global_syslog_port = cli_config.syslog_port;
        global_syslog_allocator = allocator;
        log.info("Syslog audit logging enabled", &.{
            Attr.string("host", global_syslog_host.?),
            Attr.int("port", global_syslog_port),
        });
    }

    // Initialize Windows Event Log if enabled and on Windows
    if (cli_config.windows_eventlog_enabled and builtin.os.tag == .windows) {
        const source = cli_config.windows_eventlog_source orelse "Geode";

        // Convert source name to UTF-16 for Windows API
        var source_utf16_buf: [256:0]u16 = undefined;
        const source_utf16_len = std.unicode.utf8ToUtf16Le(source_utf16_buf[0..], source) catch {
            log.warn("Failed to convert event source name to UTF-16", &.{});
            return;
        };
        source_utf16_buf[source_utf16_len] = 0;

        // Register event source
        global_windows_eventlog_handle = WindowsEventLogAPI.RegisterEventSourceW(null, // Use local computer
            &source_utf16_buf);

        if (global_windows_eventlog_handle == null) {
            log.warn("Failed to register Windows Event Log source", &.{
                Attr.string("source", source),
            });
        }
    } else if (cli_config.windows_eventlog_enabled and builtin.os.tag != .windows) {
        log.warn("Windows Event Log is only supported on Windows systems", &.{});
    }
}

// CANARY: REQ=REQ-AUDIT-CLI-003; FEATURE="CLI Audit Events"; ASPECT=EventLogging; STATUS=TESTED; TEST=TestCANARY_REQ_AUDIT_CLI_003_EventLogging; OWNER=audit; UPDATED=2025-09-30
pub fn logAuditEvent(category: []const u8, action: []const u8, outcome: []const u8) void {
    // Log to file if enabled
    if (global_audit_file) |file| {
        // Get current timestamp
        const timestamp = compat_timestamp();

        // Create simple JSON audit event
        var buf: [1024]u8 = undefined;
        const json_line = std.fmt.bufPrint(&buf, "{{\"timestamp\":{d},\"category\":\"{s}\",\"action\":\"{s}\",\"outcome\":\"{s}\",\"actor\":\"geode-cli\"}}\n", .{ timestamp, category, action, outcome }) catch return;

        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), json_line) catch |err| {
            log.warn("Failed to write audit event", &.{
                Attr.string("error", @errorName(err)),
            });
        };
    }

    // GAP-0075: Log to syslog if enabled
    // CANARY: REQ=REQ-AUDIT-SYSLOG-003; FEATURE="SyslogEventSend"; ASPECT=AuditLogging; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-10
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
// CANARY: REQ=REQ-AUDIT-SYSLOG-004; FEATURE="SyslogUdpSend"; ASPECT=AuditLogging; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-10
fn sendSyslogMessage(host: []const u8, port: u16, category: []const u8, action: []const u8, outcome: []const u8) void {
    // Skip if host contains placeholder (test mode)
    if (std.mem.indexOf(u8, host, "{{") != null) return;

    // RFC 5424 PRI: facility (LOCAL0=16) * 8 + severity (INFO=6)
    const severity: u8 = if (std.mem.eql(u8, outcome, "success")) 6 else if (std.mem.eql(u8, outcome, "failure") or std.mem.eql(u8, outcome, "error")) 4 else 5;
    const pri = 16 * 8 + severity; // LOCAL0 facility

    // Get timestamp
    const ts = compat_timestamp();

    // Format RFC 5424 message: <PRI>1 TIMESTAMP HOST APP PROCID MSGID - MSG
    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "<{d}>1 - localhost geode-cli - AUDIT - category={s} action={s} outcome={s} actor=geode-cli ts={d}", .{
        pri,
        category,
        action,
        outcome,
        ts,
    }) catch return;

    // SONNY-6487: an IPv4 or IPv6 literal (or localhost). The address used to
    // be assembled with the wrong byte order (127.0.0.1 went to 1.0.0.127 on
    // a little-endian host) and IPv6 targets were dropped.
    const target = syslogTarget(host, port) orelse return;
    // Send via UDP using linux syscalls (std.posix.socket removed in Zig 0.16)
    const linux = std.os.linux;
    const family: u32 = switch (target) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const sock_rc = linux.socket(family, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(sock_rc)) < 0) return;
    const sock_fd: i32 = @intCast(sock_rc);
    defer _ = linux.close(sock_fd);

    switch (target) {
        .ip4 => |ip| {
            var sa: linux.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, ip.port),
                .addr = std.mem.readInt(u32, &ip.bytes, .little),
            };
            _ = linux.sendto(sock_fd, message.ptr, message.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        },
        .ip6 => |ip| {
            var sa: linux.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, ip.port),
                .flowinfo = ip.flow,
                .addr = ip.bytes,
                .scope_id = ip.interface.index,
            };
            _ = linux.sendto(sock_fd, message.ptr, message.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
        },
    }
}

/// SONNY-6487: the syslog destination: an IPv4 or IPv6 literal, or
/// `localhost` (127.0.0.1). The sender does not resolve other names.
fn syslogTarget(host: []const u8, port: u16) ?std.Io.net.IpAddress {
    const literal = if (std.ascii.eqlIgnoreCase(host, "localhost")) "127.0.0.1" else host;
    return std.Io.net.IpAddress.parse(literal, port) catch null;
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
    // The host is the audit configuration's string, freed after this.
    global_syslog_host = null;
    if (global_audit_file) |file| {
        file.close(std.Io.Threaded.global_single_threaded.io());
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
        "  --version           Show the version\n" ++
        "  --config <path>     Configuration file for geode serve (geode serve --config)\n" ++
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
        "  login               Authenticate (alias for auth login)\n" ++
        "  logout              Logout (alias for auth logout)\n" ++
        "  user                User management\n" ++
        "  role                Role management\n" ++
        "  tenant              Tenant lifecycle (create/list/show/drop/set-quota)\n" ++
        "  policy              RLS policy management\n" ++
        "  grant               Grant permissions\n" ++
        "  revoke              Revoke permissions\n" ++
        "  completion          Generate shell completion scripts\n" ++
        "  mcp                 Model Context Protocol server (AI/LLM integration)\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve --data-dir ./data --listen 0.0.0.0:3141\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode shell --server localhost:3141\n" ++
        "\n" ++
        "Use 'geode <subcommand> --help' for more information on a specific command.\n" ++
        "An option a command does not read, or a value option without its value,\n" ++
        "exits 2 (usage error).\n" ++
        "\n", .{});
}
