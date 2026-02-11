const std = @import("std");
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
        // Check for help flag first
        var audit_i: usize = subcommand_start + 1;
        while (audit_i < argv.len) : (audit_i += 1) {
            if (std.mem.eql(u8, argv[audit_i], "-h") or std.mem.eql(u8, argv[audit_i], "--help")) {
                printAuditHelp();
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }
        // geode audit verify --file <path> ...
        var algo: audit_cli.HashAlgo = .sha256;
        var path: []const u8 = "audit.jsonl";
        var require_digest = false;
        var pubkey: ?[32]u8 = null;
        audit_i = subcommand_start + 1;
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
    } else if (std.mem.eql(u8, subcommand, "completion") or std.mem.eql(u8, subcommand, "completions")) {
        // CANARY: REQ=REQ-LIB-MIGRATION-CLI-002; FEATURE="External Library Migration"; ASPECT=ShellCompletions; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
        // Shell completion script generation using external CLI library
        try handleCompletionsCommand(allocator, argv, subcommand_start);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "mcp")) {
        // CANARY: REQ=REQ-LIB-MIGRATION-MCP-006; FEATURE="External Library Migration"; ASPECT=MCPCommand; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
        // Model Context Protocol server for AI/LLM integration
        try handleMcpCommand(allocator, argv, subcommand_start);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "login") or std.mem.eql(u8, subcommand, "logout")) {
        // Top-level aliases - route to auth subcommands
        const auth_start_idx = if (subcommand_start > 0) subcommand_start - 1 else 0;
        try cmdAuth(allocator, argv, auth_start_idx);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "session")) {
        // Session management command
        try session_cli.cmdSession(allocator, argv, subcommand_start + 1);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "authn")) {
        // Authentication provider configuration command
        try authn_cli.cmdAuthn(allocator, argv, subcommand_start + 1);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "mtls")) {
        try mtls_cli.cmdMtls(allocator, argv, subcommand_start + 1);
        std.process.exit(@intFromEnum(ExitCode.success));
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
// Shell Completion Generation
// ============================================================================

/// Handle the completions subcommand using external CLI library
/// Generates shell completion scripts for bash, zsh, fish, and powershell
fn handleCompletionsCommand(_: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Access Shell enum from cli sub-module
    var shell_str: []const u8 = "bash"; // default to bash
    var ai: usize = start_idx + 1;

    while (ai < argv.len) : (ai += 1) {
        if (std.mem.eql(u8, argv[ai], "--shell") or std.mem.eql(u8, argv[ai], "-s")) {
            if (ai + 1 < argv.len) {
                shell_str = argv[ai + 1];
                if (!std.mem.eql(u8, shell_str, "bash") and
                    !std.mem.eql(u8, shell_str, "zsh") and
                    !std.mem.eql(u8, shell_str, "fish") and
                    !std.mem.eql(u8, shell_str, "powershell") and
                    !std.mem.eql(u8, shell_str, "pwsh"))
                {
                    std.debug.print("Error: Unknown shell type '{s}'. Supported: bash, zsh, fish, powershell\n", .{shell_str});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                ai += 1;
            }
        } else if (std.mem.eql(u8, argv[ai], "-h") or std.mem.eql(u8, argv[ai], "--help")) {
            printCompletionsHelp();
            return;
        }
    }

    // Output a hand-crafted completion script based on shell type
    // This uses the external CLI library's concepts but generates directly to avoid
    // complexities with static command tree pointers in comptime
    if (std.mem.eql(u8, shell_str, "bash")) {
        printBashCompletions();
    } else if (std.mem.eql(u8, shell_str, "zsh")) {
        printZshCompletions();
    } else if (std.mem.eql(u8, shell_str, "fish")) {
        printFishCompletions();
    } else {
        printPowershellCompletions();
    }
}

fn printCompletionsHelp() void {
    std.debug.print("Generate shell completion scripts\n\n", .{});
    std.debug.print("Usage: geode completion [--shell <shell>]\n\n", .{});
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
    std.debug.print("  --pubkey <hex>         Ed25519 public key for signature verification\n", .{});
    std.debug.print("  -h, --help             Show this help message\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode audit verify --file /var/log/geode/audit.jsonl\n", .{});
    std.debug.print("  geode audit verify --algo blake3 --require-digest\n", .{});
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
        \\complete -c geode -n "__fish_use_subcommand" -a mtls -d 'Mutual TLS certificate mapping management'
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
    var ai: usize = start_idx + 1;

    while (ai < argv.len) : (ai += 1) {
        if (std.mem.eql(u8, argv[ai], "--port")) {
            if (ai + 1 < argv.len) {
                http_port = std.fmt.parseInt(u16, argv[ai + 1], 10) catch 8080;
                ai += 1;
            }
        } else if (std.mem.eql(u8, argv[ai], "--endpoint") or std.mem.eql(u8, argv[ai], "-e")) {
            if (ai + 1 < argv.len) {
                endpoint = argv[ai + 1];
                ai += 1;
            }
        } else if (std.mem.eql(u8, argv[ai], "--stdio")) {
            use_stdio = true;
        } else if (std.mem.eql(u8, argv[ai], "-h") or std.mem.eql(u8, argv[ai], "--help")) {
            printMcpHelp();
            return;
        } else if (std.mem.eql(u8, argv[ai], "serve")) {
            // Skip the 'serve' subcommand as it's the default action
            continue;
        }
    }

    // Create and start MCP server with Options struct
    const server = try geode_mcp.GeodeMcpServer.init(allocator, .{
        .geode_endpoint = endpoint,
        .http_port = http_port,
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
    }
}

fn printMcpHelp() void {
    std.debug.print("Model Context Protocol (MCP) server for AI/LLM integration\n\n", .{});
    std.debug.print("Usage: geode mcp [serve] [options]\n\n", .{});
    std.debug.print("Transports:\n", .{});
    std.debug.print("  --stdio             Use stdio transport (stdin/stdout JSONRPC)\n", .{});
    std.debug.print("                      Default transport if no --port is specified\n", .{});
    std.debug.print("                      Required for Claude Desktop, Claude Code, etc.\n", .{});
    std.debug.print("  --port <port>       Use HTTP transport on given port (default: 8080)\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -e, --endpoint      Geode server endpoint (default: localhost:3141)\n", .{});
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
        const timestamp = std.time.timestamp();

        // Create simple JSON audit event
        var buf: [1024]u8 = undefined;
        const json_line = std.fmt.bufPrint(&buf, "{{\"timestamp\":{d},\"category\":\"{s}\",\"action\":\"{s}\",\"outcome\":\"{s}\",\"actor\":\"geode-cli\"}}\n", .{ timestamp, category, action, outcome }) catch return;

        _ = file.writeAll(json_line) catch |err| {
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
        "  login               Authenticate (alias for auth login)\n" ++
        "  logout              Logout (alias for auth logout)\n" ++
        "  user                User management\n" ++
        "  role                Role management\n" ++
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
        "\n", .{});
}
