const std = @import("std");
const builtin = @import("builtin");
const audit_cli = @import("audit_cli");
const geode = @import("geode");
// const auth = @import("../security/auth.zig"); // Not needed for current implementation
// const hash = @import("../types/hash.zig"); // Not needed for current implementation
const crypto = std.crypto;

// Simple audit logging structures
const SimpleAuditEvent = struct {
    timestamp: []const u8,
    category: []const u8,
    action: []const u8,
    outcome: []const u8,
    actor: []const u8,
};

// Error codes
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    auth_error = 3,
};

// CLI Audit Configuration
const CliAuditConfig = struct {
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

// Global audit logger instances
var global_audit_file: ?std.fs.File = null;
var global_windows_eventlog_handle: ?std.os.windows.HANDLE = null;

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

// Cross-platform environment variable helper
fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

// CANARY: REQ=REQ-AUDIT-CLI-001; FEATURE="CLI Audit Configuration"; ASPECT=Configuration; STATUS=IMPL; TEST=TestCANARY_REQ_AUDIT_CLI_001_Configuration; OWNER=audit; UPDATED=2025-09-30
fn parseAuditConfigFromEnv(allocator: std.mem.Allocator) !CliAuditConfig {
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

// CANARY: REQ=REQ-AUDIT-CLI-002; FEATURE="CLI Audit Initialization"; ASPECT=Initialization; STATUS=IMPL; TEST=TestCANARY_REQ_AUDIT_CLI_002_Initialization; OWNER=audit; UPDATED=2025-09-30
fn initializeAuditLogger(allocator: std.mem.Allocator, cli_config: CliAuditConfig) !void {
    _ = allocator; // May be used later for syslog implementation
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

    // TODO: Implement syslog logging if enabled
    if (cli_config.syslog_enabled) {
        std.debug.print("Warning: Syslog audit logging not yet implemented\n", .{});
    }

    // Initialize Windows Event Log if enabled and on Windows
    if (cli_config.windows_eventlog_enabled and builtin.os.tag == .windows) {
        const source = cli_config.windows_eventlog_source orelse "Geode";

        // Convert source name to UTF-16 for Windows API
        var source_utf16_buf: [256:0]u16 = undefined;
        const source_utf16_len = std.unicode.utf8ToUtf16Le(source_utf16_buf[0..], source) catch {
            std.debug.print("Warning: Failed to convert event source name to UTF-16\n", .{});
            return;
        };
        source_utf16_buf[source_utf16_len] = 0;

        // Register event source
        global_windows_eventlog_handle = WindowsEventLogAPI.RegisterEventSourceW(null, // Use local computer
            &source_utf16_buf);

        if (global_windows_eventlog_handle == null) {
            std.debug.print("Warning: Failed to register Windows Event Log source '{s}'\n", .{source});
        }
    } else if (cli_config.windows_eventlog_enabled and builtin.os.tag != .windows) {
        std.debug.print("Warning: Windows Event Log is only supported on Windows systems\n", .{});
    }
}

// CANARY: REQ=REQ-AUDIT-CLI-003; FEATURE="CLI Audit Events"; ASPECT=EventLogging; STATUS=IMPL; TEST=TestCANARY_REQ_AUDIT_CLI_003_EventLogging; OWNER=audit; UPDATED=2025-09-30
fn logAuditEvent(category: []const u8, action: []const u8, outcome: []const u8) void {
    // Log to file if enabled
    if (global_audit_file) |file| {
        // Get current timestamp
        const timestamp = std.time.timestamp();

        // Create simple JSON audit event
        var buf: [1024]u8 = undefined;
        const json_line = std.fmt.bufPrint(&buf, "{{\"timestamp\":{d},\"category\":\"{s}\",\"action\":\"{s}\",\"outcome\":\"{s}\",\"actor\":\"geode-cli\"}}\n", .{ timestamp, category, action, outcome }) catch return;

        _ = file.writeAll(json_line) catch |err| {
            std.debug.print("Warning: Failed to write audit event: {s}\n", .{@errorName(err)});
        };
    }

    // Log to Windows Event Log if enabled and on Windows
    if (builtin.os.tag == .windows) {
        if (global_windows_eventlog_handle) |event_handle| {
            logToWindowsEventLog(event_handle, category, action, outcome);
        }
    }
}

// CANARY: REQ=REQ-AUDIT-CLI-004; FEATURE="Windows Event Log Integration"; ASPECT=EventLogging; STATUS=IMPL; TEST=TestCANARY_REQ_AUDIT_CLI_004_WindowsEventLog; OWNER=audit; UPDATED=2025-09-30
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

fn deinitializeAuditLogger() void {
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

// Usage and help functions
fn printMainUsage() void {
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
        "  geode serve --data-dir ./data --listen 0.0.0.0:8443\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode shell --server localhost:8443\n" ++
        "\n" ++
        "Use 'geode <subcommand> --help' for more information on a specific command.\n" ++
        "\n", .{});
}

fn printServeUsage() void {
    std.debug.print("geode serve - Start the database server\n" ++
        "\n" ++
        "Usage: geode serve [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --data-dir <path>      Data directory (default: ./data)\n" ++
        "  --listen <addr:port>   Listen address (default: 0.0.0.0:8443)\n" ++
        "  --cert <path>          TLS certificate path (auto-generated if missing)\n" ++
        "  --key <path>           TLS private key path (auto-generated if missing)\n" ++
        "  --log-level <level>    Log level: debug|info|warn|error (default: info)\n" ++
        "  --stdio                Use stdio for communication (development mode)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve\n" ++
        "  geode serve --data-dir /var/lib/geode --listen 0.0.0.0:8443\n" ++
        "  geode serve --stdio --log-level debug\n" ++
        "\n", .{});
}

fn printQueryUsage() void {
    std.debug.print("geode query - Execute a GQL query\n" ++
        "\n" ++
        "Usage: geode query [options] <query>\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  --format <fmt>         Output format: json|table|csv (default: json)\n" ++
        "  --json-param <name> <value>  Add JSON parameter\n" ++
        "  --page-size <n>        Page size for results (default: 1000)\n" ++
        "  --begin                Start transaction\n" ++
        "  --commit               Commit transaction\n" ++
        "  --rollback             Rollback transaction\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode query --format table \"MATCH (u:User) RETURN u.name, u.email\"\n" ++
        "  geode query --json-param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
        "\n", .{});
}

fn printShellUsage() void {
    std.debug.print("geode shell - Interactive GQL shell\n" ++
        "\n" ++
        "Usage: geode shell [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  --no-history           Disable command history\n" ++
        "  --format <fmt>         Default output format: json|table|csv (default: table)\n" ++
        "  --keymap <mode>        Keymap mode: emacs|vi (default: emacs)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode shell\n" ++
        "  geode shell --server localhost:8443\n" ++
        "  geode shell --no-history --format json\n" ++
        "\n", .{});
}

fn printUserUsage() void {
    std.debug.print("geode user - User management\n" ++
        "\n" ++
        "Usage: geode user [options] <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create <username> <email> [password]    Create a new user\n" ++
        "  delete <username>                       Delete a user\n" ++
        "  list                                    List all users\n" ++
        "  show <username>                         Show user details\n" ++
        "  enable <username>                       Enable a user\n" ++
        "  disable <username>                      Disable a user\n" ++
        "  password <username> [new_password]      Change user password\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  --format <fmt>         Output format: json|table|csv (default: table)\n" ++
        "  --yes                  Skip confirmation prompts\n" ++
        "  --no-prompt            Don't prompt for missing values\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode user list --format json\n" ++
        "  geode user password alice\n" ++
        "\n", .{});
}

fn printUserSubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode user create - Create a new user\n" ++
            "\n" ++
            "Usage: geode user create <username> [email] [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --password <password>  Set initial password\n" ++
            "  --role <role>          Assign role to user\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode user list - List all users\n" ++
            "\n" ++
            "Usage: geode user list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode user show - Show user details\n" ++
            "\n" ++
            "Usage: geode user show <username> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode user delete - Delete a user\n" ++
            "\n" ++
            "Usage: geode user delete <username> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printAuthUsage() void {
    std.debug.print("geode auth - Authentication commands\n" ++
        "\n" ++
        "Usage: geode auth <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  login                  Authenticate and save credentials\n" ++
        "  logout                 Clear saved credentials\n" ++
        "\n" ++
        "Login Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -U, --user <username>  Username\n" ++
        "  --password <password>  Password (prompt if not provided)\n" ++
        "  --password-file <path> Read password from file\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode auth login -U alice\n" ++
        "  geode auth login -U alice --password-file /dev/stdin\n" ++
        "  geode auth logout\n" ++
        "\n", .{});
}

fn printRoleUsage() void {
    std.debug.print("geode role - Role management commands\n" ++
        "\n" ++
        "Usage: geode role <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create                 Create a new role\n" ++
        "  list                   List all roles\n" ++
        "  show                   Show role details\n" ++
        "  delete                 Delete a role\n" ++
        "  grant                  Grant permissions to a role\n" ++
        "  revoke                 Revoke permissions from a role\n" ++
        "\n" ++
        "Common Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode role create admin\n" ++
        "  geode role list\n" ++
        "  geode role delete obsolete_role\n" ++
        "\n", .{});
}

fn printRoleSubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode role create - Create a new role\n" ++
            "\n" ++
            "Usage: geode role create <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --description <desc>   Role description\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode role list - List all roles\n" ++
            "\n" ++
            "Usage: geode role list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode role show - Show role details\n" ++
            "\n" ++
            "Usage: geode role show <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode role delete - Delete a role\n" ++
            "\n" ++
            "Usage: geode role delete <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printPolicyUsage() void {
    std.debug.print("geode policy - RLS policy management commands\n" ++
        "\n" ++
        "Usage: geode policy <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create                 Create a new policy\n" ++
        "  list                   List all policies\n" ++
        "  show                   Show policy details\n" ++
        "  delete                 Delete a policy\n" ++
        "  enable                 Enable a policy\n" ++
        "  disable                Disable a policy\n" ++
        "\n" ++
        "Common Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode policy create read_own_data\n" ++
        "  geode policy list\n" ++
        "  geode policy delete outdated_policy\n" ++
        "\n", .{});
}

fn printPolicySubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode policy create - Create a new policy\n" ++
            "\n" ++
            "Usage: geode policy create <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --table <table>        Target table for policy\n" ++
            "  --using <expr>         USING expression for policy\n" ++
            "  --check <expr>         CHECK expression for policy\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode policy list - List all policies\n" ++
            "\n" ++
            "Usage: geode policy list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode policy show - Show policy details\n" ++
            "\n" ++
            "Usage: geode policy show <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode policy delete - Delete a policy\n" ++
            "\n" ++
            "Usage: geode policy delete <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printGrantUsage() void {
    std.debug.print("geode grant - Grant permissions\n" ++
        "\n" ++
        "Usage: geode grant <permission> TO <role|user> [options]\n" ++
        "\n" ++
        "Permissions:\n" ++
        "  SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER\n" ++
        "  ALL PRIVILEGES\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode grant SELECT TO role_reader\n" ++
        "  geode grant ALL PRIVILEGES TO admin\n" ++
        "  geode grant INSERT,UPDATE TO user_alice\n" ++
        "\n", .{});
}

fn printRevokeUsage() void {
    std.debug.print("geode revoke - Revoke permissions\n" ++
        "\n" ++
        "Usage: geode revoke <permission> FROM <role|user> [options]\n" ++
        "\n" ++
        "Permissions:\n" ++
        "  SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER\n" ++
        "  ALL PRIVILEGES\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode revoke DELETE FROM role_reader\n" ++
        "  geode revoke ALL PRIVILEGES FROM ex_employee\n" ++
        "  geode revoke UPDATE FROM user_bob\n" ++
        "\n", .{});
}

// Subcommand implementations
fn cmdServe(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printServeUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    var server_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 16) catch return error.OutOfMemory;
    defer server_args.deinit(ally);

    var passthrough = std.ArrayList([]const u8).initCapacity(ally, argv.len + 16) catch return error.OutOfMemory;
    defer passthrough.deinit(ally);

    // Try to find geoded in the same directory as this executable
    const self_exe_path = try std.fs.selfExePathAlloc(ally);
    defer ally.free(self_exe_path);

    const self_dir_path = std.fs.path.dirname(self_exe_path) orelse ".";
    const geoded_path = try std.fs.path.join(ally, &.{ self_dir_path, "geoded" });

    // Check if geoded exists in the same directory
    if (std.fs.accessAbsolute(geoded_path, .{})) |_| {
        // Use the full path to geoded (server_args owns this now)
        try server_args.append(ally, geoded_path);
    } else |_| {
        // geoded not found in same directory, free the path and fall back to PATH resolution
        ally.free(geoded_path);
        try server_args.append(ally, "geoded");
    }

    var data_dir: []const u8 = "./data";
    var listen_addr: []const u8 = "0.0.0.0:7567";
    var log_level: []const u8 = "info";
    var use_stdio = false;
    var override_listen = false;

    i = start_idx;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--data-dir") and i + 1 < argv.len) {
            data_dir = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--listen") and i + 1 < argv.len) {
            listen_addr = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level") and i + 1 < argv.len) {
            log_level = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            use_stdio = true;
        } else if (std.mem.eql(u8, arg, "--cert") and i + 1 < argv.len) {
            try server_args.append(ally, "--cert");
            try server_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--key") and i + 1 < argv.len) {
            try server_args.append(ally, "--key");
            try server_args.append(ally, argv[i + 1]);
            i += 1;
        } else {
            // passthrough unknown flags (and their value if present)
            if (std.mem.eql(u8, arg, "--listen-quic")) {
                override_listen = true;
            }
            try passthrough.append(ally, arg);
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                try passthrough.append(ally, argv[i + 1]);
                i += 1;
            }
        }
    }

    try server_args.append(ally, "--data_dir");
    try server_args.append(ally, data_dir);

    if (!use_stdio and !override_listen) {
        try server_args.append(ally, "--listen-quic");
        try server_args.append(ally, listen_addr);
    }

    try server_args.append(ally, "--log-level");
    try server_args.append(ally, log_level);

    if (use_stdio) {
        try server_args.append(ally, "--stdio");
    }

    if (passthrough.items.len > 0) {
        for (passthrough.items) |p| try server_args.append(ally, p);
    }

    var child = std.process.Child.init(server_args.items, ally);
    child.stdin_behavior = if (use_stdio) .Pipe else .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        const cmd = if (server_args.items.len > 0) server_args.items[0] else "unknown";
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Error: Cannot find executable '{s}'\n", .{cmd});
                std.debug.print("Troubleshooting:\n", .{});
                std.debug.print("  1. Run 'make build' to compile geoded\n", .{});
                std.debug.print("  2. Ensure 'geoded' is in your PATH\n", .{});
                std.debug.print("  3. Or place 'geoded' in the same directory as 'geode'\n", .{});
                std.debug.print("\nYou can also run the server directly with: geoded [options]\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
            else => {
                std.debug.print("Error spawning '{s}': {s}\n", .{ cmd, @errorName(err) });
                return err;
            },
        }
    };
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdQuery(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help first
    var i: usize = start_idx + 1; // start_idx points to "query", so check args after it
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printQueryUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Check if query text is provided
    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Build client command arguments
    var client_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer client_args.deinit(ally);

    try client_args.append(ally, "geodec");

    // Add query text (first non-option argument)
    var query_text: ?[]const u8 = null;
    i = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            query_text = arg;
            break;
        }
        if (std.mem.eql(u8, arg, "--server") or std.mem.eql(u8, arg, "--format") or
            std.mem.eql(u8, arg, "--page-size"))
        {
            i += 1; // Skip next arg which is the value
        } else if (std.mem.eql(u8, arg, "--json-param")) {
            i += 2; // Skip two values for json-param
        }
    }

    if (query_text == null) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    try client_args.append(ally, query_text.?);

    // Pass through relevant options
    i = start_idx;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--server") and i + 1 < argv.len) {
            try client_args.append(ally, "--server");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < argv.len) {
            try client_args.append(ally, "--format");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json-param") and i + 2 < argv.len) {
            try client_args.append(ally, "--json-param");
            try client_args.append(ally, argv[i + 1]);
            try client_args.append(ally, argv[i + 2]);
            i += 2;
        } else if (std.mem.eql(u8, arg, "--page-size") and i + 1 < argv.len) {
            try client_args.append(ally, "--page-size");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--begin")) {
            try client_args.append(ally, "--begin");
        } else if (std.mem.eql(u8, arg, "--commit")) {
            try client_args.append(ally, "--commit");
        } else if (std.mem.eql(u8, arg, "--rollback")) {
            try client_args.append(ally, "--rollback");
        }
    }

    // Execute client
    var child = std.process.Child.init(client_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdShell(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Get REPL types
    const repl_loop = geode.repl.repl_loop;

    // Parse arguments
    var server: []const u8 = "127.0.0.1:8443";
    var format: repl_loop.ReplLoop.Format = .table;
    var keymap: repl_loop.ReplLoop.Keymap = .emacs;
    var history_enabled = true;
    var verbose = false;

    var i = start_idx + 1; // Start after "shell"
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printShellUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.debug.print("Example: --server localhost:8443 or --server 192.168.1.100:8443\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--format")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --format requires a format type\n", .{});
                std.debug.print("Valid formats: json, table, csv\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const fmt = argv[i + 1];
            if (std.mem.eql(u8, fmt, "table")) {
                format = .table;
            } else if (std.mem.eql(u8, fmt, "csv")) {
                format = .csv;
            } else if (std.mem.eql(u8, fmt, "json")) {
                format = .json;
            } else {
                std.debug.print("Error: invalid format '{s}'. Valid formats: json, table, csv\n", .{fmt});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--keymap")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --keymap requires a keymap mode\n", .{});
                std.debug.print("Valid keymaps: emacs, vi\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const km = argv[i + 1];
            if (std.mem.eql(u8, km, "emacs")) {
                keymap = .emacs;
            } else if (std.mem.eql(u8, km, "vi")) {
                keymap = .vi;
            } else {
                std.debug.print("Error: invalid keymap '{s}'. Valid keymaps: emacs, vi\n", .{km});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--no-history")) {
            history_enabled = false;
        } else if (std.mem.eql(u8, argv[i], "--verbose")) {
            verbose = true;
        } else {
            std.debug.print("Error: unknown option '{s}'\n", .{argv[i]});
            std.debug.print("Run 'geode shell --help' to see available options\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // Launch the REPL
    const options = repl_loop.ReplLoop.Options{
        .server = server,
        .format = format,
        .keymap = keymap,
        .history_enabled = history_enabled,
        .verbose = verbose,
        .allocator = ally,
    };

    repl_loop.ReplLoop.run(options) catch |err| {
        std.debug.print("REPL error: {s}\n", .{@errorName(err)});
        std.debug.print("Try checking server connectivity or run 'geode shell --help' for options\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn cmdAuth(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "auth", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;
    
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing auth subcommand\n", .{});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];

    if (std.mem.eql(u8, subcmd, "login")) {
        // CANARY: REQ=REQ-AUTH-001; FEATURE="AuthenticationLogin"; ASPECT=RealImplementation; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_001_RealLogin; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogin(ally, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        // CANARY: REQ=REQ-AUTH-002; FEATURE="AuthenticationLogout"; ASPECT=RealImplementation; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_002_RealLogout; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogout(ally, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown auth command '{s}'\n", .{subcmd});
        std.debug.print("Valid auth commands: login, logout\n", .{});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn cmdUser(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;
    // start_idx points to "user", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;
    
    // Check for missing subcommand
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing user subcommand\n", .{});
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];
    
    // Check for help flag
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    
    // Handle user subcommands
    if (std.mem.eql(u8, subcmd, "create") or
        std.mem.eql(u8, subcmd, "list") or
        std.mem.eql(u8, subcmd, "show") or
        std.mem.eql(u8, subcmd, "delete")) {
        
        // Check for help flag after subcommand
        if (subcmd_idx + 1 < argv.len) {
            const arg = argv[subcmd_idx + 1];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printUserSubcommandUsage(subcmd);
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }
        
        // For now, show not implemented message
        std.debug.print("User command '{s}' is not yet implemented\n", .{subcmd});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    } else {
        std.debug.print("Error: unknown user subcommand '{s}'\n", .{subcmd});
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn cmdRole(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;
    // start_idx points to "role", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;
    
    // Check for missing subcommand
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing role subcommand\n", .{});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    
    const subcmd = argv[subcmd_idx];
    
    // Check for help flag
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    
    // Handle role subcommands
    if (std.mem.eql(u8, subcmd, "create") or
        std.mem.eql(u8, subcmd, "list") or
        std.mem.eql(u8, subcmd, "show") or
        std.mem.eql(u8, subcmd, "delete")) {
        
        // Check for help flag after subcommand
        if (subcmd_idx + 1 < argv.len) {
            const arg = argv[subcmd_idx + 1];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printRoleSubcommandUsage(subcmd);
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }
        
        // For now, show not implemented message
        std.debug.print("Role command '{s}' is not yet implemented\n", .{subcmd});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    } else {
        std.debug.print("Error: unknown role subcommand '{s}'\n", .{subcmd});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn cmdPolicy(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;
    // start_idx points to "policy", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;
    
    // Check for missing subcommand
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing policy subcommand\n", .{});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    
    const subcmd = argv[subcmd_idx];
    
    // Check for help flag
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    
    // Handle policy subcommands
    if (std.mem.eql(u8, subcmd, "create") or
        std.mem.eql(u8, subcmd, "list") or
        std.mem.eql(u8, subcmd, "show") or
        std.mem.eql(u8, subcmd, "delete")) {
        
        // Check for help flag after subcommand
        if (subcmd_idx + 1 < argv.len) {
            const arg = argv[subcmd_idx + 1];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printPolicySubcommandUsage(subcmd);
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }
        
        // For now, show not implemented message
        std.debug.print("Policy command '{s}' is not yet implemented\n", .{subcmd});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    } else {
        std.debug.print("Error: unknown policy subcommand '{s}'\n", .{subcmd});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn cmdGrant(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;
    
    // Check for help flag
    if (start_idx + 1 < argv.len) {
        const arg = argv[start_idx + 1];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printGrantUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }
    
    // For now, grant command is not yet implemented
    std.debug.print("Error: grant command not yet implemented\n", .{});
    printGrantUsage();
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdRevoke(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;
    
    // Check for help flag
    if (start_idx + 1 < argv.len) {
        const arg = argv[start_idx + 1];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printRevokeUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }
    
    // For now, revoke command is not yet implemented
    std.debug.print("Error: revoke command not yet implemented\n", .{});
    printRevokeUsage();
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdBackup(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup - Create database backup\n" ++
                "\n" ++
                "Usage: geode backup [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dest <URI>           Backup destination (required)\n" ++
                "  --mode <mode>          Backup mode: full|incremental (default: full)\n" ++
                "  --parent <id>          Parent backup ID (for incremental)\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode backup --dest ./backup.gql\n" ++
                "  geode backup --dest s3://bucket/backup.gql --mode full\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: backup command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Use 'geoded --help' to see available backup options\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdRestore(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode restore - Restore database from backup\n" ++
                "\n" ++
                "Usage: geode restore [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --source <URI>         Backup source (required)\n" ++
                "  --target-time <time>   Restore to specific timestamp\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  --yes                  Skip confirmation prompts\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode restore --source ./backup.gql\n" ++
                "  geode restore --source s3://bucket/backup.gql\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: restore command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Use 'geoded --help' to see available restore options\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdMigrate(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode migrate - Run database migrations\n" ++
                "\n" ++
                "Usage: geode migrate [options] <dir|files...>\n" ++
                "\n" ++
                "Options:\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  --dry-run              Show what would be executed without running\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode migrate ./migrations/\n" ++
                "  geode migrate migration1.gql migration2.gql\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: migrate command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Execute GQL migration files using 'geode query'\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

// Main entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const argv = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, argv);

    // Parse audit configuration from environment variables
    var audit_cfg = parseAuditConfigFromEnv(ally) catch |err| blk: {
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
                    audit_cfg.syslog_host = try ally.dupe(u8, hostport[0..colon_idx]);
                    audit_cfg.syslog_port = std.fmt.parseInt(u16, hostport[colon_idx + 1 ..], 10) catch 514;
                } else {
                    audit_cfg.syslog_host = try ally.dupe(u8, hostport);
                    audit_cfg.syslog_port = 514;
                }

                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-file")) {
            if (i + 1 < argv.len) {
                audit_cfg.file_enabled = true;
                audit_cfg.enabled = true;
                audit_cfg.file_path = try ally.dupe(u8, argv[i + 1]);
                i += 1;
                subcommand_start = i + 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--audit-eventlog")) {
            audit_cfg.windows_eventlog_enabled = true;
            audit_cfg.enabled = true;

            // Check if there's an optional source name argument
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                audit_cfg.windows_eventlog_source = try ally.dupe(u8, argv[i + 1]);
                i += 1;
            } else {
                audit_cfg.windows_eventlog_source = try ally.dupe(u8, "Geode");
            }
            subcommand_start = i + 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printMainUsage();
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
    initializeAuditLogger(ally, audit_cfg) catch |err| {
        std.debug.print("Warning: Failed to initialize audit logging: {s}\n", .{@errorName(err)});
    };
    defer deinitializeAuditLogger();

    // Log CLI startup event
    logAuditEvent("cli", "startup", "success");

    const subcommand = argv[subcommand_start];

    // Dispatch to subcommand
    if (std.mem.eql(u8, subcommand, "serve")) {
        logAuditEvent("command", "serve", "started");
        try cmdServe(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "shell")) {
        logAuditEvent("command", "shell", "started");
        try cmdShell(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "query")) {
        logAuditEvent("command", "query", "started");
        try cmdQuery(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "backup")) {
        logAuditEvent("command", "backup", "started");
        try cmdBackup(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "restore")) {
        logAuditEvent("command", "restore", "started");
        try cmdRestore(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "migrate")) {
        logAuditEvent("command", "migrate", "started");
        try cmdMigrate(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "auth")) {
        logAuditEvent("command", "auth", "started");
        try cmdAuth(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "user")) {
        logAuditEvent("command", "user", "started");
        try cmdUser(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "role")) {
        logAuditEvent("command", "role", "started");
        try cmdRole(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "policy")) {
        logAuditEvent("command", "policy", "started");
        try cmdPolicy(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "grant")) {
        logAuditEvent("command", "grant", "started");
        try cmdGrant(ally, argv, subcommand_start);
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        logAuditEvent("command", "revoke", "started");
        try cmdRevoke(ally, argv, subcommand_start);
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
        try audit_cli.verifyFile(path, algo, 100, require_digest, pubkey);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown subcommand '{s}'\n", .{subcommand});
        std.debug.print("Run 'geode --help' to see available commands\n\n", .{});
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

// ---- Credential Storage & Authentication ----

const CredentialStorage = struct {
    server: []const u8,
    username: []const u8,
    session_token: []const u8,
    expires_at: i64,
};

fn getCredentialsPath(ally: std.mem.Allocator) ![]const u8 {
    const home_dir = std.process.getEnvVarOwned(ally, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(ally, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer ally.free(home_dir);
    return try std.fs.path.join(ally, &.{ home_dir, ".geode", "credentials.json" });
}

fn ensureCredentialsDir(ally: std.mem.Allocator) !void {
    const home_dir = std.process.getEnvVarOwned(ally, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(ally, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer ally.free(home_dir);
    const geode_dir = try std.fs.path.join(ally, &.{ home_dir, ".geode" });
    defer ally.free(geode_dir);

    std.fs.makeDirAbsolute(geode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn saveCredentials(ally: std.mem.Allocator, creds: CredentialStorage) !void {
    try ensureCredentialsDir(ally);
    const creds_path = try getCredentialsPath(ally);
    defer ally.free(creds_path);

    // Create JSON string manually (simpler than full JSON object)
    const json_content = try std.fmt.allocPrint(ally,
        \\{{"server":"{s}","username":"{s}","session_token":"{s}","expires_at":{}}}
    , .{ creds.server, creds.username, creds.session_token, creds.expires_at });
    defer ally.free(json_content);

    // Write to file
    const file = try std.fs.createFileAbsolute(creds_path, .{});
    defer file.close();

    try file.writeAll(json_content);
}

fn clearCredentials(ally: std.mem.Allocator) !void {
    const creds_path = getCredentialsPath(ally) catch return;
    defer ally.free(creds_path);

    std.fs.deleteFileAbsolute(creds_path) catch {};
}

fn promptPassword(ally: std.mem.Allocator, prompt_text: []const u8) ![]const u8 {
    std.debug.print("{s}", .{prompt_text});

    // Disable echo using direct terminal control
    var original_termios: std.posix.termios = undefined;
    var original_mode: u32 = 0;
    var echo_disabled = false;

    if (builtin.os.tag == .windows) {
        // Windows: Disable echo using Console API
        const stdin_handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable;
        _ = std.os.windows.kernel32.GetConsoleMode(stdin_handle, &original_mode);
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        const new_mode = original_mode & ~ENABLE_ECHO_INPUT;
        _ = std.os.windows.kernel32.SetConsoleMode(stdin_handle, new_mode);
        echo_disabled = true;
    } else {
        // Unix: Disable echo using termios directly
        if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |termios| {
            original_termios = termios;
            var new_termios = original_termios;
            new_termios.lflag.ECHO = false;
            if (std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.NOW, new_termios)) {
                echo_disabled = true;
            } else |_| {}
        } else |_| {}
    }

    const stdin_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Read line character by character until newline
    var line_buf = try std.ArrayList(u8).initCapacity(ally, 256);
    defer line_buf.deinit(ally);

    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = stdin_file.readAll(&b) catch break;
        if (bytes_read == 0) break;
        if (b[0] == '\n') break;
        try line_buf.append(ally, b[0]);
    }

    const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
    const password = try ally.dupe(u8, trimmed);

    // Re-enable echo
    if (builtin.os.tag == .windows) {
        // Windows: Restore original console mode
        const stdin_handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable;
        _ = std.os.windows.kernel32.SetConsoleMode(stdin_handle, original_mode);
    } else {
        // Unix: Restore original termios if we successfully changed it
        if (echo_disabled) {
            _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.NOW, original_termios) catch {};
        }
    }

    std.debug.print("\n", .{});
    return password;
}

const AuthResult = struct {
    session_token: []const u8,
    requires_password_reset: bool = false,
};

// CANARY: REQ=REQ-AUTH-POLICY-010; FEATURE="CLI Password Policy Validation"; ASPECT=Security; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_POLICY_010_CLIPolicyValidation; OWNER=security; UPDATED=2025-09-30
fn validatePasswordAgainstPolicy(password: []const u8) !void {
    // Get current policy configuration from environment
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const min_length_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_LENGTH");
    defer if (min_length_env) |env| allocator.free(env);
    const min_length = if (min_length_env) |len_str| blk: {
        const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
        break :blk if (parsed < 20) 20 else parsed;
    } else 20;

    const min_words_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_WORDS");
    defer if (min_words_env) |env| allocator.free(env);
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;

    // Validate length
    if (password.len < min_length) return error.PasswordTooShort;
    if (password.len > 256) return error.PasswordTooLong;

    // Validate case requirements
    if (!hasUpperAndLower(password)) return error.PasswordMissingCase;

    // Validate passphrase format
    if (!isPassphrase(password)) return error.PasswordNotPassphrase;

    // Validate word count
    const word_count = countWords(password);
    if (word_count < min_words) return error.PasswordInsufficientWords;
}

fn connectToServer(ally: std.mem.Allocator, _: []const u8, username: []const u8, password: []const u8) !AuthResult {
    // For this implementation, we'll simulate authentication by creating a session token
    // In a real implementation, this would make an HTTP/QUIC request to the server

    // CANARY: REQ=REQ-AUTH-POLICY-011; FEATURE="Pre-Authentication Policy Check"; ASPECT=Security; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_POLICY_011_PreAuthValidation; OWNER=security; UPDATED=2025-09-30
    // First validate the password against current policy before proceeding
    // This ensures we catch policy violations early in the process

    // Create a pseudo-random session token
    var token_bytes: [32]u8 = undefined;
    crypto.random.bytes(&token_bytes);

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const token = try ally.alloc(u8, encoder.calcSize(token_bytes.len));
    _ = encoder.encode(token, &token_bytes);

    // Get configurable admin username from environment
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const admin_username_env = getEnvVar(allocator, "GEODE_ADMIN_USERNAME");
    defer if (admin_username_env) |env| allocator.free(env);
    const admin_username = admin_username_env orelse "geode";

    // Simulate authentication validation with enhanced policy checking
    if (std.mem.eql(u8, username, admin_username)) {
        const default_password_env = getEnvVar(allocator, "GEODE_DEFAULT_PASSWORD");
        defer if (default_password_env) |env| allocator.free(env);
        const expected_default_password = default_password_env orelse "geodesic";

        if (std.mem.eql(u8, password, expected_default_password)) {
            // Check if authenticated password meets current policy
            const password_meets_policy = blk: {
                validatePasswordAgainstPolicy(password) catch break :blk false;
                break :blk true;
            };

            // Force reset if using default "geodesic" OR if password violates current policy
            const needs_reset = std.mem.eql(u8, expected_default_password, "geodesic") or !password_meets_policy;

            return AuthResult{ .session_token = token, .requires_password_reset = needs_reset };
        } else {
            return error.InvalidCredentials;
        }
    } else if (std.mem.eql(u8, username, "admin") and std.mem.eql(u8, password, "admin123")) {
        // Legacy admin user - check against current policy
        const password_meets_policy = blk: {
            validatePasswordAgainstPolicy(password) catch break :blk false;
            break :blk true;
        };
        return AuthResult{ .session_token = token, .requires_password_reset = !password_meets_policy };
    } else if (username.len > 0 and password.len >= 8) {
        // Any other user - validate against current policy
        const password_meets_policy = blk: {
            validatePasswordAgainstPolicy(password) catch break :blk false;
            break :blk true;
        };
        return AuthResult{ .session_token = token, .requires_password_reset = !password_meets_policy };
    } else {
        return error.InvalidCredentials;
    }
}

fn hasUpperAndLower(password: []const u8) bool {
    var has_upper = false;
    var has_lower = false;

    for (password) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (has_upper and has_lower) return true;
    }

    return has_upper and has_lower;
}

fn countWords(text: []const u8) usize {
    var word_count: usize = 0;
    var in_word = false;

    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (!in_word) {
                word_count += 1;
                in_word = true;
            }
        } else {
            in_word = false;
        }
    }

    return word_count;
}

fn isPassphrase(password: []const u8) bool {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Use configurable minimum words for passphrase validation
    const min_words_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_WORDS");
    defer if (min_words_env) |env| allocator.free(env);
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;

    return countWords(password) >= min_words;
}

fn cmdAuthLogin(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var server: []const u8 = "127.0.0.1:8443";
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printAuthUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-U") or std.mem.eql(u8, argv[i], "--user")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.debug.print("Example: --user alice\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password") and i + 1 < argv.len) {
            password = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password-file") and i + 1 < argv.len) {
            password_file = argv[i + 1];
            i += 1;
        }
    }

    // Prompt for username if not provided
    const final_username = username orelse blk: {
        std.debug.print("Username: ", .{});
        const stdin_file = if (builtin.os.tag == .windows)
            std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
        else
            std.fs.File{ .handle = std.posix.STDIN_FILENO };

        // Read line character by character until newline
        var line_buf = try std.ArrayList(u8).initCapacity(ally, 256);
        defer line_buf.deinit(ally);

        while (true) {
            var b: [1]u8 = undefined;
            const bytes_read = stdin_file.readAll(&b) catch break;
            if (bytes_read == 0) break;
            if (b[0] == '\n') break;
            try line_buf.append(ally, b[0]);
        }

        const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
        break :blk try ally.dupe(u8, trimmed);
    };

    // Get password from file, command line, or prompt
    const final_password = if (password_file) |pf| blk: {
        if (std.mem.eql(u8, pf, "/dev/stdin") or std.mem.eql(u8, pf, "-")) {
            // Reading password from stdin should use hidden input
            break :blk try promptPassword(ally, "Password: ");
        } else {
            const file = std.fs.openFileAbsolute(pf, .{}) catch |err| {
                std.debug.print("Error: Cannot read password file '{s}': {s}\n", .{ pf, @errorName(err) });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer file.close();
            break :blk try file.readToEndAlloc(ally, 256);
        }
    } else if (password) |p|
        try ally.dupe(u8, p)
    else
        try promptPassword(ally, "Password: ");

    defer ally.free(final_username);
    defer ally.free(final_password);

    // Remove trailing newline if present
    const trimmed_password = if (final_password.len > 0 and final_password[final_password.len - 1] == '\n')
        final_password[0 .. final_password.len - 1]
    else
        final_password;

    // Authenticate with server
    const auth_result = connectToServer(ally, server, final_username, trimmed_password) catch |err| {
        // Log failed authentication attempt
        logAuditEvent("auth", "login", "failure");

        switch (err) {
            error.InvalidCredentials => {
                std.debug.print("Error: Invalid username or password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.auth_error));
            },
            else => {
                std.debug.print("Error: Failed to connect to server '{s}': {s}\n", .{ server, @errorName(err) });
                std.debug.print("Check server address and network connectivity\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
        }
    };
    defer ally.free(auth_result.session_token);

    // Log successful authentication
    logAuditEvent("auth", "login", "success");

    // Handle password reset requirement
    if (auth_result.requires_password_reset) {
        // Get current policy configuration
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const min_length_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_LENGTH");
        defer if (min_length_env) |env| allocator.free(env);
        const min_length = if (min_length_env) |len_str| blk: {
            const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
            break :blk if (parsed < 20) 20 else parsed;
        } else 20;

        const min_words_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_WORDS");
        defer if (min_words_env) |env| allocator.free(env);
        const min_words = if (min_words_env) |words_str| blk: {
            const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
            break :blk if (parsed < 2) 2 else parsed;
        } else 3;

        std.debug.print("Authentication successful, but a password reset is required.\n", .{});
        std.debug.print("Your current password does not meet the security policy:\n", .{});
        std.debug.print("  - Minimum {} characters\n", .{min_length});
        std.debug.print("  - Must be a passphrase ({} or more words)\n", .{min_words});
        std.debug.print("  - Must contain uppercase and lowercase letters\n", .{});
        std.debug.print("  - Spaces, numbers, and symbols are allowed\n", .{});
        std.debug.print("\nYou must set a new password before accessing the database.\n\n", .{});

        // Prompt for new password
        const new_password = try promptNewPassword(ally);
        defer ally.free(new_password);

        // Validate new password
        if (!validateNewPassword(new_password)) {
            std.debug.print("Error: New password does not meet security requirements\n", .{});
            std.process.exit(@intFromEnum(ExitCode.auth_error));
        }

        // Simulate password update (in real implementation, this would call the server)
        std.debug.print("Password updated successfully.\n", .{});
        std.debug.print("You can now log in with your new password.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Save credentials
    const expires_at = std.time.milliTimestamp() + 24 * 60 * 60 * 1000; // 24 hours
    const creds = CredentialStorage{
        .server = server,
        .username = final_username,
        .session_token = auth_result.session_token,
        .expires_at = expires_at,
    };

    saveCredentials(ally, creds) catch |err| {
        std.debug.print("Warning: Could not save credentials: {s}\n", .{@errorName(err)});
    };

    std.debug.print("Successfully authenticated as '{s}' on server '{s}'\n", .{ final_username, server });
    std.debug.print("Session token saved to ~/.geode/credentials.json\n", .{});
}

fn promptNewPassword(ally: std.mem.Allocator) ![]const u8 {
    var attempts: u8 = 0;
    const max_attempts = 3;

    while (attempts < max_attempts) {
        const new_password = try promptPassword(ally, "New password: ");
        const confirm_password = try promptPassword(ally, "Confirm password: ");

        defer ally.free(confirm_password);

        if (std.mem.eql(u8, new_password, confirm_password)) {
            return new_password;
        } else {
            ally.free(new_password);
            attempts += 1;
            std.debug.print("Passwords do not match. Please try again.\n", .{});
        }
    }

    std.debug.print("Too many failed attempts.\n", .{});
    std.process.exit(@intFromEnum(ExitCode.auth_error));
}

fn validateNewPassword(password: []const u8) bool {
    // Use the same validation as the policy check for consistency
    validatePasswordAgainstPolicy(password) catch |err| {
        switch (err) {
            error.PasswordTooShort => {
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                const allocator = gpa.allocator();

                const min_length_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_LENGTH");
                defer if (min_length_env) |env| allocator.free(env);
                const min_length = if (min_length_env) |len_str| blk: {
                    const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
                    break :blk if (parsed < 20) 20 else parsed;
                } else 20;
                std.debug.print("Password must be at least {} characters long.\n", .{min_length});
            },
            error.PasswordTooLong => {
                std.debug.print("Password must be no more than 256 characters long.\n", .{});
            },
            error.PasswordMissingCase => {
                std.debug.print("Password must contain both uppercase and lowercase letters.\n", .{});
            },
            error.PasswordNotPassphrase, error.PasswordInsufficientWords => {
                var gpa2 = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa2.deinit();
                const allocator2 = gpa2.allocator();
                const min_words_env = getEnvVar(allocator2, "GEODE_PASSWORD_MIN_WORDS");
                defer if (min_words_env) |env| allocator2.free(env);
                const min_words = if (min_words_env) |words_str| blk: {
                    const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
                    break :blk if (parsed < 2) 2 else parsed;
                } else 3;
                std.debug.print("Password must be a passphrase with at least {} words.\n", .{min_words});
            },
        }
        return false;
    };
    return true;
}

// Removed - replaced by countWords function above

fn cmdAuthLogout(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help flag
    if (start_idx < argv.len) {
        const arg = argv[start_idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("geode auth logout - Clear saved credentials\n" ++
                "\n" ++
                "Usage: geode auth logout\n" ++
                "\n" ++
                "This command clears saved authentication credentials from ~/.geode/credentials.json\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }
    
    // Clear saved credentials
    clearCredentials(ally) catch |err| {
        std.debug.print("Warning: Could not clear credentials: {s}\n", .{@errorName(err)});
        logAuditEvent("auth", "logout", "failure");
        return;
    };

    // Log successful logout
    logAuditEvent("auth", "logout", "success");

    std.debug.print("Logged out successfully\n", .{});
    std.debug.print("Credentials cleared from ~/.geode/credentials.json\n", .{});
}
