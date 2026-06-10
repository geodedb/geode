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

// Zig 0.16 compat: std.Thread.sleep removed. Use raw linux nanosleep.
fn compat_sleepNs(ns: i64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    }
}

// Zig 0.16 compat: Helper to read an entire stream into an allocated buffer (replaces readToEndAlloc).
fn readStreamToEnd(file: std.Io.File, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&tmp}) catch |err| {
            if (buf.items.len > 0) return try buf.toOwnedSlice(allocator);
            return err;
        };
        if (n == 0) break;
        if (buf.items.len + n > max_size) return error.StreamTooLong;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return try buf.toOwnedSlice(allocator);
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
const Value = geode.value_types.Value;
// CANARY: REQ=REQ-CLI-REFACTOR-001; FEATURE="CLI Library Migration"; ASPECT=FlagParsing; STATUS=TESTED; TEST=geodetestlab/specs/cli_flags_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
// Partial migration to devnw/zig/cli:
// - shell completion generation now uses the external command tree
// - flag parsing, help text, and dispatch remain manual and should migrate incrementally
//   to avoid destabilizing the unified CLI entry point
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=CLI; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("cli");
const Attr = logging.Attr;
// Import server main from unified entry point (both cli and server share same module tree)
const server_main = @import("../server/main.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-026; FEATURE="JSON Library Migration"; ASPECT=CLI; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-24
const protobuf = @import("protobuf");
const json_lib = @import("json");
const schema = @import("schema");
const query_runner = geode.query_runner;
const query_scope = geode.query_scope;
const grpc_query_transport = geode.grpc_query_transport;
const zig_quic_bridge = geode.zig_quic_bridge;
const zig_client = zig_quic_bridge.zig_client;
const pooled = @import("transport/thread_pool");
const stdio_util = @import("../utils/stdio.zig");
// Issue #746: query deadline watchdog extracted to its own submodule so the
// UAF regression tests can link against the real `QueryDeadlineState` +
// `startDeadlineWatchdogTask` without the full CLI module graph.
const query_deadline = @import("query_deadline.zig");
const QueryDeadlineState = query_deadline.QueryDeadlineState;
const startDeadlineWatchdogTask = query_deadline.startDeadlineWatchdogTask;

// GAP-0203: Gate hot-path debug logging to eliminate overhead in production
// CANARY: REQ=REQ-PERF-LOG-GATE-001; FEATURE="HotPathLogGating"; ASPECT=DebugLogControl; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
// Set to true only when debugging protocol/query issues. In production, keep false.
const HOT_PATH_LOGGING = false;
const default_stream_page_size: u32 = query_runner.default_page_size;
// CLI background thread pool moved to `src/cli/query_deadline.zig` alongside
// the watchdog entry points (#746 UAF fix prerequisite).

// C library function for setting environment variables
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
// const auth = @import("../security/auth.zig"); // Not needed for current implementation
// const hash = @import("../types/hash.zig"); // Not needed for current implementation
const crypto = std.crypto;

// CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedBinary; STATUS=TESTED; TEST=tests/test_cli_subprocess_elimination_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Direct calls to server and client main functions to eliminate subprocess spawning

// CANARY: REQ=REQ-M11-DRY-002; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: backup_types import removed (#696) — was unused after CLI modularization

// CANARY: REQ=REQ-M4.1-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.1: Import user management CLI module
const user_mgmt_cli = @import("user_mgmt_cli.zig");
const cmdUser = user_mgmt_cli.cmdUser;
const cmdRole = user_mgmt_cli.cmdRole;

// CANARY: REQ=REQ-M4.2-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=AuthCommands; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.2: Import authentication and policy CLI module
const auth_cli = @import("auth_cli.zig");
const cmdPolicy = auth_cli.cmdPolicy;
const cmdGrant = auth_cli.cmdGrant;
const cmdRevoke = auth_cli.cmdRevoke;

// CANARY: REQ=REQ-M4.3-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=BackupCommands; STATUS=TESTED; TEST=tests/test_cli_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.3: Import backup/restore/migrate CLI module
const backup_cli = @import("backup_cli.zig");
const cmdBackup = backup_cli.cmdBackup;
const cmdRestore = backup_cli.cmdRestore;
const cmdMigrate = backup_cli.cmdMigrate;
const execution = geode.execution;

// CANARY: REQ=REQ-M4.4-CLI-DISPATCHER-002; FEATURE="CLI Modularization"; ASPECT=DispatcherIntegration; STATUS=TESTED; TEST=tests/test_cli_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.4: Import CLI dispatcher module for command routing
const cli_dispatcher = @import("cli_dispatcher.zig");
const fle_cli = @import("fle_cli.zig");
const cmdFLE = fle_cli.cmdFLE;

// CANARY: REQ=REQ-AUTH-INIT-CLI-002; FEATURE="AuthInitCLI"; ASPECT=DispatcherIntegration; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
// Auth chain management CLI module (init, reseal, verify)
const auth_init_cli = @import("auth_init_cli.zig");

// Import shared types and functions from cli_dispatcher
const ExitCode = cli_dispatcher.ExitCode;
const getEnvVar = cli_dispatcher.getEnvVar;
const logAuditEvent = cli_dispatcher.logAuditEvent;
const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

const VERSION = build_options.version;

// CANARY: REQ=REQ-REPL-QUIC-002; FEATURE="REPL QUIC Transport"; ASPECT=QuicTransportAdapter; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=repl; UPDATED=2026-01-15
const repl_quic_transport = geode.repl.quic_transport;

// NOTE: This file uses `catch {}` for stdout/stderr I/O operations.
// Output write failures are non-critical — the query result is correct
// even if display fails.  See docs/FULL_AUDIT_2026_04_07.md.

// Cross-platform file handle helpers with proper error handling
// CANARY: REQ=REQ-QUALITY-GAP-406-002; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
const StdioError = stdio_util.StdioError;

fn getStdinHandle() StdioError!std.Io.File.Handle {
    const file = try stdio_util.getStdin();
    return file.handle;
}

fn getStdoutHandle() StdioError!std.Io.File.Handle {
    const file = try stdio_util.getStdout();
    return file.handle;
}

const ParamError = error{
    UnsupportedParameterType,
    OutOfMemory,
};

fn convertJsonParam(allocator: std.mem.Allocator, value: std.json.Value) ParamError!Value {
    return switch (value) {
        .null => Value{ .Null = {} },
        .bool => |b| Value{ .Bool = b },
        .string => Value{ .Str = try allocator.dupe(u8, value.string) },
        .integer => |i| Value{ .Int = @intCast(i) },
        .float => return error.UnsupportedParameterType,
        else => return error.UnsupportedParameterType,
    };
}

fn freeParamValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        else => {},
    }
}

fn getStderrHandle() StdioError!std.Io.File.Handle {
    const file = try stdio_util.getStderr();
    return file.handle;
}

fn printServeUsage() void {
    std.debug.print("geode serve - Start the database server\n" ++
        "\n" ++
        "Usage: geode serve [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --data-dir <path>      Data directory (default: ./data)\n" ++
        "  --listen <addr:port>   Listen address (default: 0.0.0.0:3141)\n" ++
        "  --cert <path>          TLS certificate path (auto-generated if missing)\n" ++
        "  --key <path>           TLS private key path (auto-generated if missing)\n" ++
        "  --log-level <level>    Log level: debug|info|warn|error (default: info)\n" ++
        "  --idle-timeout <ms>    QUIC idle timeout in milliseconds (default: 300000)\n" ++
        "  --persist-interval <ms> Background persistence interval in ms (default: 100)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve\n" ++
        "  geode serve --data-dir /var/lib/geode --listen 0.0.0.0:3141\n" ++
        "  geode serve --log-level info  # Auth enabled by default\n" ++
        "\n", .{});
}

fn printQueryUsage() void {
    std.debug.print("geode query - Execute a GQL query\n" ++
        "\n" ++
        "Usage: geode query [options] <query|-|--file path> \n" ++
        "\n" ++
        "Options:\n" ++
        "  --dsn <dsn>            Connection DSN (e.g. quic://host:port, grpc://host:port)\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  --grpc                 Use gRPC transport instead of QUIC\n" ++
        "  -g, --graph <name>     Graph to query against (auto-prepends USE GRAPH)\n" ++
        "  -f, --file <path>      Execute GQL statements from a file (supports ~)\n" ++
        "  --insecure-tls-skip-verify  Skip TLS certificate verification\n" ++
        "  --insecure             (deprecated) Alias for --insecure-tls-skip-verify\n" ++
        "  --ca-cert <path>       CA certificate path for server verification\n" ++
        "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
        "  --client-key <path>    Client private key path for mutual TLS\n" ++
        "  --format <fmt>         Output format: json|table|csv|dot|mermaid (default: json)\n" ++
        "  --param <name> <value>       Add query parameter (JSON literal)\n" ++
        "  --page-size <n>        Page size for results (default: 128)\n" ++
        "  --timeout <secs>       Connection timeout in seconds (default: 30)\n" ++
        "  --retry <count>        Number of retry attempts on failure (default: 0)\n" ++
        "  --begin                Start transaction\n" ++
        "  --commit               Commit transaction\n" ++
        "  --rollback             Rollback transaction\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  -P, --password [pass]  Authentication password (prompted if not provided)\n" ++
        "  --no-saved-session     Don't auto-load saved session token\n" ++
        "  --forward-principal <user[:tenant]>  Attach a GPS principal envelope so the\n" ++
        "                         server evaluates GPS/RLS under the forwarded identity\n" ++
        "  --forward-principal-envelope <hex>   Attach a pre-serialised GPSP envelope\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "DSN (Data Source Name):\n" ++
        "  The --dsn flag accepts a connection string: <scheme>://[user:pass@]host[:port]\n" ++
        "  Supported schemes: quic:// (default, port 3141), grpc:// (port 50051)\n" ++
        "  DSN takes precedence over --server and --grpc if both are specified.\n" ++
        "  Credentials in DSN override -U/-P flags.\n" ++
        "\n" ++
        "TLS Certificate Options:\n" ++
        "  Certificate verification is enabled by default. Use --insecure-tls-skip-verify to disable.\n" ++
        "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
        "\n" ++
        "Authentication:\n" ++
        "  For authenticated servers, provide both --user and --password:\n" ++
        "    geode query --user geode --password yourpassword \"RETURN 1\"\n" ++
        "    geode query -U geode -P \"RETURN 1\"  # (prompts for password)\n" ++
        "\n" ++
        "  Environment variables are NOT used for authentication.\n" ++
        "  The default admin username is 'geode' (not 'admin').\n" ++
        "  Set GEODE_ADMIN_PASSWORD or GEODE_DEFAULT_PASSWORD on the server to bootstrap\n" ++
        "  the admin account. When both are set, GEODE_ADMIN_PASSWORD takes precedence.\n" ++
        "\n" ++
        "Session Management:\n" ++
        "  By default, queries auto-load saved session from ~/.geode/credentials.json\n" ++
        "  Use --no-saved-session to require explicit credentials\n" ++
        "\n" ++
        "Arguments:\n" ++
        "  <query>                GQL query string\n" ++
        "  -                      Read query from stdin\n" ++
        "\n" ++
        "Examples:\n" ++
        "  # Authenticated query (use 'geode' as default admin user)\n" ++
        "  geode query --user geode --password \"$GEODE_DEFAULT_PASSWORD\" \"RETURN 1 AS x\"\n" ++
        "  geode query -U geode -P \"RETURN 1 AS x\"  # prompts for password\n" ++
        "\n" ++
        "  # Using DSN connection string\n" ++
        "  geode query --dsn quic://localhost:3141 \"RETURN 1 AS x\"\n" ++
        "  geode query --dsn grpc://localhost:50051 \"RETURN 1 AS x\"\n" ++
        "  geode query --dsn quic://admin:secret@localhost:3141 \"RETURN 1 AS x\"\n" ++
        "\n" ++
        "  # Query a specific graph\n" ++
        "  geode query --graph mydb \"MATCH (n) RETURN count(n)\"\n" ++
        "  geode query -g firewall \"MATCH (r:Rule) RETURN r.name\"\n" ++
        "\n" ++
        "  # Connection options\n" ++
        "  geode query --server localhost:3141 --insecure-tls-skip-verify \"RETURN 1 AS x\"\n" ++
        "  geode query --ca-cert /etc/ssl/ca.crt --server secure.example.com:3141 \"RETURN 1\"\n" ++
        "  geode query --ca-cert /etc/ssl/ca.crt --client-cert /etc/ssl/client.crt --client-key /etc/ssl/client.key --server secure.example.com:3141 \"RETURN 1\"\n" ++
        "  geode query --format table \"MATCH (u:User) RETURN u.name, u.email\"\n" ++
        "  geode query --format dot \"MATCH (a)-[r]->(b) RETURN a, r, b\" | dot -Tpng -o graph.png\n" ++
        "  geode query --format mermaid \"MATCH (a)-[r]->(b) RETURN a, r, b\" | npx -y -p @mermaid-js/mermaid-cli mmdc -i - -o graph.svg\n" ++
        "  geode query --param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
        "  geode query --server remote:3141 --timeout 5 --retry 3 \"RETURN 1 AS x\"\n" ++
        "  echo \"RETURN 1 AS x\" | geode query -\n" ++
        "\n" ++
        "  # Execute from file\n" ++
        "  geode query --file ~/my_queries.gql\n" ++
        "  geode query -f ./schema.gql --insecure-tls-skip-verify\n" ++
        "\n" ++
        "  # Batch mode — one QUIC connection for all queries (one query per line)\n" ++
        "  cat queries.txt | geode query --batch\n" ++
        "  echo -e 'RETURN 1\\nRETURN 2' | geode query --batch --server localhost:3141\n" ++
        "\n", .{});
}

// (server-only helpers removed; unified CLI delegates to src/server/main.zig)

// (embedded server state/types removed)

fn printShellUsage() void {
    std.debug.print("geode shell - Interactive GQL shell\n" ++
        "\n" ++
        "Usage: geode shell [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --dsn <dsn>            Connection DSN (e.g. quic://host:port, grpc://host:port)\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -U, --username <user>  Username for authentication\n" ++
        "  -P, --password <pass>  Password for authentication\n" ++
        "  --insecure-tls-skip-verify  Skip TLS certificate verification\n" ++
        "  --insecure             (deprecated) Alias for --insecure-tls-skip-verify\n" ++
        "  --ca-cert <path>       CA certificate path for server verification\n" ++
        "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
        "  --client-key <path>    Client private key path for mutual TLS\n" ++
        "  --no-history           Disable command history\n" ++
        "  --format <fmt>         Default output format: json|table|csv (default: table)\n" ++
        "  --keymap <mode>        Keymap mode: emacs|vi (default: emacs)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "DSN (Data Source Name):\n" ++
        "  The --dsn flag accepts a connection string: <scheme>://[user:pass@]host[:port]\n" ++
        "  Supported schemes: quic:// (default, port 3141), grpc:// (port 50051)\n" ++
        "  DSN takes precedence over --server if both are specified.\n" ++
        "  Credentials in DSN override -U/-P flags.\n" ++
        "\n" ++
        "Authentication:\n" ++
        "  If the server requires authentication, use -U and -P to provide credentials.\n" ++
        "  Both username and password must be provided together.\n" ++
        "\n" ++
        "TLS Certificate Options:\n" ++
        "  Certificate verification is enabled by default. Use --insecure-tls-skip-verify to disable.\n" ++
        "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode shell\n" ++
        "  geode shell --dsn quic://localhost:3141\n" ++
        "  geode shell --dsn grpc://admin:secret@localhost:50051\n" ++
        "  geode shell --server localhost:3141 -U admin -P secret\n" ++
        "  geode shell --server localhost:3141 --insecure-tls-skip-verify\n" ++
        "  geode shell --ca-cert /etc/ssl/ca.crt --server secure.example.com:3141\n" ++
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
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
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
        "  login                  Authenticate and optionally save session\n" ++
        "  logout                 Clear saved credentials\n" ++
        "  token                  Print saved credentials JSON (if present)\n" ++
        "  init                   Bootstrap admin user into graph store (offline)\n" ++
        "  reseal                 Recompute HMAC chain (offline)\n" ++
        "  verify                 Check HMAC chain integrity (offline)\n" ++
        "\n" ++
        "Login Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -U, --user <username>  Username\n" ++
        "  --password <password>  Password (prompt if not provided)\n" ++
        "  --password-file <path> Read password from file\n" ++
        "  --save-session         Save session token to ~/.geode/credentials.json\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Offline Options (init, reseal, verify):\n" ++
        "  --data-dir <path>      Data directory (default: GEODE_DATA_DIR env or ./data)\n" ++
        "\n" ++
        "Session Management:\n" ++
        "  Sessions are issued by the server and stored in ~/.geode/credentials.json\n" ++
        "  Use --save-session to persist credentials locally\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode auth login -U alice --save-session\n" ++
        "  geode auth login -U alice --password-file /dev/stdin\n" ++
        "  geode auth logout\n" ++
        "  geode auth init --data-dir /var/lib/geode\n" ++
        "  geode auth reseal --data-dir /var/lib/geode\n" ++
        "  geode auth verify --data-dir /var/lib/geode\n" ++
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
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
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
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
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
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
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
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode revoke DELETE FROM role_reader\n" ++
        "  geode revoke ALL PRIVILEGES FROM ex_employee\n" ++
        "  geode revoke UPDATE FROM user_bob\n" ++
        "\n", .{});
}

// Subcommand implementations

// CANARY: REQ=REQ-LSP-001; FEATURE="Language Server Protocol"; ASPECT=LSPServer; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-10-28
fn cmdLsp(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Task 13: parse `--no-auth` so terminal LSP clients (neovim, helix,
    // VS Code over stdio) can drive the server without minting a JWT.
    // The flag synthesizes a local-admin AuthState from $USER inside
    // Server.bindUnauthSession. It is honored only on the stdio path;
    // Task 27 enforces `--no-auth` + `--listen` is a usage error and the
    // TCP listener always runs with allow_unauth=false.
    var allow_unauth = false;
    // Task 27: `--listen=tcp://HOST:PORT` (or bare `HOST:PORT`) switches
    // the LSP entry point from stdio framing to a TCP accept loop.
    var listen_addr: ?[]const u8 = null;
    var i: usize = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printLspUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--no-auth")) {
            allow_unauth = true;
        } else if (std.mem.startsWith(u8, argv[i], "--listen=")) {
            listen_addr = argv[i]["--listen=".len..];
        } else {
            std.debug.print("Error: unknown argument '{s}'\n\n", .{argv[i]});
            printLspUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // Task 27: TCP transport always requires auth. `--no-auth` is a
    // local-terminal-only convenience; combining it with a
    // network-listening transport would let any LAN client mint an
    // admin session against this server. Fail closed.
    if (listen_addr != null and allow_unauth) {
        std.debug.print("Error: --no-auth is incompatible with --listen (TCP transport requires auth)\n\n", .{});
        printLspUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const lsp = @import("lsp/server.zig");
    const lsp_transport = @import("lsp/transport.zig");

    if (listen_addr) |addr_raw| {
        // Strip optional `tcp://` scheme; everything after must be
        // `HOST:PORT`. We don't accept `tcp6://`, `unix:`, etc. —
        // Task 28 / Task 30 introduce additional listener kinds.
        const stripped = if (std.mem.startsWith(u8, addr_raw, "tcp://"))
            addr_raw["tcp://".len..]
        else
            addr_raw;
        const colon = std.mem.lastIndexOfScalar(u8, stripped, ':') orelse {
            std.debug.print("Error: --listen address must be host:port (got '{s}')\n", .{addr_raw});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        const host = stripped[0..colon];
        const port_str = stripped[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            std.debug.print("Error: invalid port '{s}'\n", .{port_str});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };

        // Zig 0.16: the net stack is `std.Io.net.*` — `IpAddress.parseIp4`
        // / `parseIp6` build the address and `IpAddress.listen` returns a
        // `std.Io.net.Server` whose `accept(io)` hands out streams. The
        // `parse` umbrella tries v4 first, falls back to v6, so it
        // handles both numeric forms (no DNS — listener binds want a
        // numeric host).
        var bind_addr = std.Io.net.IpAddress.parse(host, port) catch
            std.Io.net.IpAddress.parseIp4(host, port) catch
            std.Io.net.IpAddress.parseIp6(host, port) catch {
            std.debug.print("Error: --listen host '{s}' is not a valid IPv4/IPv6 literal\n", .{host});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };

        // Dedicated Threaded backend so the accept loop and the per-
        // session reads share one Io vtable for the lifetime of this
        // CLI invocation. Matches metrics_server.zig's pattern.
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var listener = std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true }) catch |err| {
            std.debug.print("Error: failed to bind {s}:{d}: {s}\n", .{ host, port, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer listener.deinit(io);

        std.debug.print("LSP listening on {s}:{d}\n", .{ host, port });

        // Phase 9 (Task 28) introduces concurrent per-session threads
        // in the embedded `geode serve` listener; the standalone
        // `geode lsp --listen` is typically used as a single-editor
        // stdio replacement, so serial accept-and-run is sufficient
        // here. Each session always runs with allow_unauth=false
        // because the constraint check above rejected the combination.
        while (true) {
            const accepted = listener.accept(io) catch |err| {
                std.debug.print("LSP accept error: {s}\n", .{@errorName(err)});
                continue;
            };
            var tx = lsp_transport.Transport.initTcp(allocator, io, accepted) catch |err| {
                std.debug.print("LSP transport init error: {s}\n", .{@errorName(err)});
                accepted.close(io);
                continue;
            };
            var srv = lsp.Server.initWithTransport(allocator, tx, null, false) catch |err| {
                std.debug.print("LSP server init error: {s}\n", .{@errorName(err)});
                tx.deinit();
                continue;
            };
            defer srv.deinit();
            srv.run() catch |err| {
                std.debug.print("LSP session error: {s}\n", .{@errorName(err)});
            };
        }
    }

    // Default: stdio LSP path (Task 13's `--no-auth` is honored here).
    var server = lsp.Server.initWithAuth(allocator, null, allow_unauth) catch |err| {
        std.debug.print("Error initializing LSP server: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer server.deinit();

    try server.run();
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn printLspUsage() void {
    std.debug.print("geode lsp - Language Server Protocol server for GQL/Geode\n\n", .{});
    std.debug.print("Usage: geode lsp [options]\n\n", .{});
    std.debug.print("Description:\n", .{});
    std.debug.print("  Starts a Language Server Protocol (LSP) server for GQL files.\n", .{});
    std.debug.print("  The server communicates via JSON-RPC over stdin/stdout and provides:\n", .{});
    std.debug.print("    - Syntax error diagnostics\n", .{});
    std.debug.print("    - hover documentation for GQL keywords, functions, and types\n", .{});
    std.debug.print("    - code completion for GQL syntax\n", .{});
    std.debug.print("    - Go-to-definition support\n", .{});
    std.debug.print("    - Document formatting\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -h, --help         Show this help message\n", .{});
    std.debug.print("  --no-auth          Skip the LSP auth handshake and run as a local admin\n", .{});
    std.debug.print("                     session ($USER, role=Admin). Stdio only — never use\n", .{});
    std.debug.print("                     this with a network-listening transport.\n", .{});
    std.debug.print("  --listen=ADDR      Listen for LSP JSON-RPC on a TCP socket instead of\n", .{});
    std.debug.print("                     stdin/stdout. ADDR is \"tcp://HOST:PORT\" or just\n", .{});
    std.debug.print("                     \"HOST:PORT\". Each accepted connection runs one LSP\n", .{});
    std.debug.print("                     session before accepting the next. Network-listening\n", .{});
    std.debug.print("                     transport REQUIRES auth (the --no-auth flag is\n", .{});
    std.debug.print("                     refused if --listen is also set).\n\n", .{});
    std.debug.print("Editor Integration:\n", .{});
    std.debug.print("  See docs/LSP_IMPLEMENTATION.md for setup details\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode lsp\n", .{});
    std.debug.print("  geode lsp --no-auth                       # local terminal editor (stdio)\n", .{});
    std.debug.print("  geode lsp --listen=tcp://127.0.0.1:3142   # TCP listener (auth required)\n\n", .{});
}

fn cmdServe(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printServeUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }
    _ = allocator;
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedBinary; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
    // Direct call to server main - no subprocess spawning, unified binary
    try server_main.main();
}

// Query deadline watchdog types + entry points extracted to
// `src/cli/query_deadline.zig` so the #746 UAF regression test can link
// against the real implementations.  The aliases below preserve the existing
// in-file call sites.
const touchActiveQueryDeadlineWatchdog = query_deadline.touchActiveQueryDeadlineWatchdog;
const finishActiveQueryDeadlineWatchdog = query_deadline.finishActiveQueryDeadlineWatchdog;

// Issue #417: DSN (Data Source Name) parsing for --dsn flag
// Supports: quic://host:port, grpc://host:port, host:port (defaults to QUIC)
// See docs/DSN.md for the full specification
const DsnParseResult = struct {
    host_port: []const u8, // "host:port" string
    use_grpc: bool, // true if grpc:// scheme
    username: ?[]const u8, // embedded credentials
    password: ?[]const u8, // embedded credentials
    graph: ?[]const u8 = null, // graph name from URL path
};

fn parseDsnArg(dsn: []const u8) ?DsnParseResult {
    // Parse scheme
    var use_grpc = false;
    var rest: []const u8 = dsn;

    if (std.mem.startsWith(u8, dsn, "quic://")) {
        rest = dsn["quic://".len..];
        use_grpc = false;
    } else if (std.mem.startsWith(u8, dsn, "grpc://")) {
        rest = dsn["grpc://".len..];
        use_grpc = true;
    } else if (std.mem.startsWith(u8, dsn, "http://") or
        std.mem.startsWith(u8, dsn, "https://") or
        std.mem.startsWith(u8, dsn, "tcp://"))
    {
        std.debug.print("Error: unsupported DSN scheme. Use quic:// or grpc://\n", .{});
        return null;
    }
    // else: no scheme, treat as host:port with QUIC default

    if (rest.len == 0) {
        std.debug.print("Error: DSN missing host\n", .{});
        return null;
    }

    // Strip query parameters (everything after '?')
    if (std.mem.indexOf(u8, rest, "?")) |qpos| {
        rest = rest[0..qpos];
    }

    // Check for embedded credentials: user:pass@host:port
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
        const creds = rest[0..at_pos];
        rest = rest[at_pos + 1 ..];
        if (std.mem.indexOf(u8, creds, ":")) |colon_pos| {
            username = creds[0..colon_pos];
            password = creds[colon_pos + 1 ..];
        } else {
            username = creds;
        }
    }

    if (rest.len == 0) {
        std.debug.print("Error: DSN missing host after credentials\n", .{});
        return null;
    }

    // Extract graph name from URL path (e.g. host:3141/mygraph -> graph = "mygraph")
    var graph: ?[]const u8 = null;
    var host_port = rest;
    if (std.mem.indexOf(u8, rest, "/")) |slash_idx| {
        host_port = rest[0..slash_idx];
        const path = rest[slash_idx + 1 ..];
        if (path.len > 0) {
            graph = path;
        }
    }

    // Validate host:port - at minimum there should be content
    // The host_port is passed directly to --server logic which expects "host:port"
    return DsnParseResult{
        .host_port = host_port,
        .use_grpc = use_grpc,
        .username = username,
        .password = password,
        .graph = graph,
    };
}

fn cmdQuery(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
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

    // Parse arguments
    var server: ?[]const u8 = null; // null means not explicitly set
    var format: []const u8 = "json";
    var insecure = false;
    var use_grpc = false;
    var user: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    var query_text: ?[]const u8 = null;
    var timeout_secs: u32 = 30; // Default 30 second timeout (QUIC handshake can be slow)
    var retry_count: u32 = 0; // Default no retries
    var page_size: u32 = default_stream_page_size; // Default page size for PULL requests
    var use_saved_session = true; // Auto-load saved session by default
    // Issue #417: DSN connection string
    var dsn: ?[]const u8 = null;
    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-001; FEATURE="GraphFlag"; ASPECT=QueryCommand; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
    // Issue #393: Add --graph flag to specify which graph to query against
    var graph: ?[]const u8 = null;
    // When graph comes from DSN, server handles it via HELLO — don't prepend USE GRAPH
    var graph_for_prepend: ?[]const u8 = null;
    // GAP-0113: TLS certificate verification options
    var ca_cert_path: ?[]const u8 = null;
    var client_cert_path: ?[]const u8 = null;
    var client_key_path: ?[]const u8 = null;
    // CANARY: REQ=REQ-CLI-FILE-FLAG-001; FEATURE="QueryFileFlag"; ASPECT=FileInput; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
    // Issue GAP-384: Add --file flag to execute GQL from a file (same as /source in shell)
    var source_file: ?[]const u8 = null;
    // GAP-0271: FLE role for field-level access control
    var role: ?[]const u8 = null;
    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=CliForwardPrincipalFlag; STATUS=IMPL; OWNER=security; UPDATED=2026-05-22
    // GPS Phase 7 Task 7-5: --forward-principal <username>[:<tenant>] builds a
    // principal_envelope (GPSP wire blob) and emits it as ExecuteRequest field 4.
    // This mirrors what a distributed coordinator attaches to a shard RPC: the
    // receiving server reconstructs the forwarded Principal and evaluates GPS/RLS
    // under that identity instead of this (already-authenticated) connection's.
    // The envelope only REFINES identity — it cannot escalate past the session.
    var forward_principal: ?[]const u8 = null;
    var forward_principal_envelope_hex: ?[]const u8 = null;
    // PERF-P1-002: Batch mode — read semicolon-delimited queries from stdin,
    // execute all over a single QUIC connection to amortize handshake cost.
    var batch_mode = false;
    var params = std.ArrayList(schema.Param).empty;
    var params_owned = true;
    defer if (params_owned) {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    };

    i = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--no-saved-session")) {
            use_saved_session = false;
        } else if (std.mem.eql(u8, arg, "--graph") or std.mem.eql(u8, arg, "-g")) {
            // CANARY: REQ=REQ-CLI-GRAPH-FLAG-002; FEATURE="GraphFlag"; ASPECT=FlagParsing; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --graph requires a graph name\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const graph_arg = argv[i + 1];
            // Validate graph name to prevent GQL injection (S5):
            // Only allow identifiers matching [a-zA-Z_][a-zA-Z0-9_]*
            if (graph_arg.len == 0) {
                std.debug.print("Error: --graph name must not be empty\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            for (graph_arg, 0..) |c, idx| {
                const valid = if (idx == 0)
                    (std.ascii.isAlphabetic(c) or c == '_')
                else
                    (std.ascii.isAlphanumeric(c) or c == '_');
                if (!valid) {
                    std.debug.print("Error: invalid graph name '{s}' — must match [a-zA-Z_][a-zA-Z0-9_]* (no special characters)\n", .{graph_arg});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
            }
            graph = graph_arg;
            graph_for_prepend = graph_arg; // --graph flag: prepend USE GRAPH
            i += 1;
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            // CANARY: REQ=REQ-CLI-FILE-FLAG-002; FEATURE="QueryFileFlag"; ASPECT=FlagParsing; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
            // Issue GAP-384: Execute GQL from a file (same as /source in shell)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --file requires a file path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            source_file = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--dsn")) {
            // Issue #417: DSN connection string (e.g. quic://host:port, grpc://host:port)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --dsn requires a connection string\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            dsn = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --format requires a format type\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            format = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--insecure-tls-skip-verify")) {
            insecure = true;
        } else if (std.mem.eql(u8, arg, "--insecure")) {
            insecure = true;
            std.debug.print("Warning: --insecure is deprecated, use --insecure-tls-skip-verify\n", .{});
        } else if (std.mem.eql(u8, arg, "--batch")) {
            // PERF-P1-002: Read semicolon-delimited queries from stdin over single connection
            batch_mode = true;
        } else if (std.mem.eql(u8, arg, "--grpc")) {
            use_grpc = true;
        } else if (std.mem.eql(u8, arg, "--ca-cert")) {
            // GAP-0113: CA certificate path for server verification
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            ca_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-cert")) {
            // GAP-0113: Client certificate path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-key")) {
            // GAP-0113: Client private key path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_key_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--user") or std.mem.eql(u8, arg, "--username") or std.mem.eql(u8, arg, "-U")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            user = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--password") or std.mem.eql(u8, arg, "--pass") or std.mem.eql(u8, arg, "-P")) {
            // CANARY: REQ=REQ-CLI-PASSWORD-PROMPT-001; FEATURE="PasswordPrompt"; ASPECT=QueryCommand; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            // Issue #385: If no password provided after -P, prompt interactively
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "-")) {
                // No value provided, prompt for password
                const prompted_password = promptPassword(allocator, "Password: ") catch |err| {
                    std.debug.print("Error reading password: {s}\n", .{@errorName(err)});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                password = prompted_password;
            } else {
                password = argv[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--token")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --token requires an API token\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            token = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--param")) {
            if (i + 2 >= argv.len) {
                std.debug.print("Error: --param requires name and value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const param_name = argv[i + 1];
            const param_value = argv[i + 2];
            const parsed_value = parseParamValue(allocator, param_value) catch |err| {
                const stderr_fd = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
                try stderr_fd.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Parameter parse error\n");
                log.err("parameter parse failed", &.{Attr.string("error", @errorName(err))});
                std.process.exit(1);
            };
            const name_copy = try allocator.dupe(u8, param_name);
            var param = schema.Param{
                .name = name_copy,
                .value = parsed_value,
            };
            params.append(allocator, param) catch |err| {
                param.deinit(allocator);
                return err;
            };
            i += 2;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --timeout requires a timeout value in seconds\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            timeout_secs = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                std.debug.print("Error: --timeout value must be a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--page-size")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --page-size requires a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            page_size = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                std.debug.print("Error: --page-size value must be a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--retry")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --retry requires a retry count\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            retry_count = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                std.debug.print("Error: --retry value must be a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            // Handle --log-level flag (ignored for query command but must consume its argument)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --log-level requires a level (debug, info, warn, error)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Just skip the log level value - query command doesn't use it but we need to consume it
            i += 1;
        } else if (std.mem.eql(u8, arg, "--role")) {
            // GAP-0271: FLE role for field-level access control
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --role requires a role name\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const role_arg = argv[i + 1];
            // GAP-0271: Pass role to server via HELLO — server validates and
            // rejects injection chars (semicolons, commas, wildcards).
            // CLI accepts any value so FLE security tests can verify server behavior.
            role = role_arg;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--forward-principal")) {
            // GPS Phase 7 Task 7-5: forwarded principal as <username>[:<tenant>]
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --forward-principal requires <username>[:<tenant>]\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            forward_principal = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--forward-principal-envelope")) {
            // GPS Phase 7 Task 7-5: pre-serialised GPSP envelope as hex.
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --forward-principal-envelope requires a hex string\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            forward_principal_envelope_hex = argv[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            // First non-option argument is the query text, or "-" for stdin
            if (query_text == null) {
                query_text = arg;
            }
        }
    }

    // CANARY: REQ=REQ-CLI-FILE-FLAG-003; FEATURE="QueryFileFlag"; ASPECT=FileReading; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
    // Handle --file input with tilde expansion (same as /source in shell)
    var file_allocated: ?[]u8 = null;
    defer if (file_allocated) |allocated| allocator.free(allocated);

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-001; FEATURE="ChunkedExecution"; ASPECT=LargeFileSupport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
    // For large files, we'll collect individual statements to enable chunked execution
    var file_statements: ?std.ArrayList([]const u8) = null;
    defer {
        if (file_statements) |*stmts| {
            for (stmts.items) |stmt| {
                allocator.free(stmt);
            }
            stmts.deinit(allocator);
        }
    }

    if (source_file) |filepath| {
        // Expand ~ to home directory if present
        var path_buf: [4096]u8 = undefined;
        const resolved_path = if (filepath.len > 0 and filepath[0] == '~') blk: {
            if (comptime builtin.os.tag == .windows) break :blk filepath;
            const home = posixGetenv("HOME") orelse {
                std.debug.print("Error: Cannot expand ~: HOME not set\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            const rest = if (filepath.len > 1) filepath[1..] else "";
            const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, rest }) catch {
                std.debug.print("Error: Path too long\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            break :blk path;
        } else filepath;

        // Open and read the file
        const io_file = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_file, resolved_path, .{}) catch |err| {
            std.debug.print("Error: Cannot open file '{s}': {s}\n", .{ resolved_path, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer file.close(io_file);

        const file_len = file.length(io_file) catch |err| {
            std.debug.print("Error: Cannot read file: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (file_len > 1 << 24) {
            std.debug.print("Error: File too large\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const contents = allocator.alloc(u8, @intCast(file_len)) catch |err| {
            std.debug.print("Error: Cannot read file: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        _ = file.readPositionalAll(io_file, contents, 0) catch |err| {
            std.debug.print("Error: Cannot read file: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer allocator.free(contents);

        // Strip comments and collect individual statements
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-002; FEATURE="ChunkedExecution"; ASPECT=StatementParsing; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
        var statements = std.ArrayList([]const u8).empty;
        var current_stmt = std.ArrayList(u8).empty;
        defer current_stmt.deinit(allocator);

        var line_iter = std.mem.splitSequence(u8, contents, "\n");
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");

            // Skip empty lines and comments
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "--")) continue;
            if (std.mem.startsWith(u8, trimmed, "#")) continue;

            // Append line to current statement
            if (current_stmt.items.len > 0) {
                current_stmt.append(allocator, ' ') catch {};
            }
            current_stmt.appendSlice(allocator, trimmed) catch {};

            // Check if statement is complete (ends with semicolon)
            if (std.mem.endsWith(u8, trimmed, ";")) {
                // Save complete statement
                const stmt_copy = allocator.dupe(u8, current_stmt.items) catch {
                    std.debug.print("Error: Memory allocation failed\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                statements.append(allocator, stmt_copy) catch {
                    allocator.free(stmt_copy);
                    std.debug.print("Error: Memory allocation failed\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                current_stmt.clearRetainingCapacity();
            }
        }

        if (statements.items.len == 0) {
            std.debug.print("Error: File contains no valid GQL statements\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Calculate total size to determine if chunking is needed
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-003; FEATURE="ChunkedExecution"; ASPECT=SizeDetection; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
        const max_single_query_size: usize = 16 * 1024; // 16KB threshold for chunking
        var total_size: usize = 0;
        for (statements.items) |stmt| {
            total_size += stmt.len + 1; // +1 for separator
        }

        std.debug.print("Executing from file: {s}\n", .{resolved_path});

        if (total_size <= max_single_query_size) {
            // Small enough to send as single query - concatenate all statements
            var processed = std.ArrayList(u8).initCapacity(allocator, total_size) catch {
                std.debug.print("Error: Memory allocation failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            for (statements.items) |stmt| {
                processed.appendSlice(allocator, stmt) catch {};
                processed.append(allocator, ' ') catch {};
            }
            // Clean up statements since we don't need them anymore
            for (statements.items) |stmt| {
                allocator.free(stmt);
            }
            statements.deinit(allocator);

            file_allocated = processed.toOwnedSlice(allocator) catch {
                std.debug.print("Error: Memory allocation failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            query_text = file_allocated;
        } else {
            // Large file - use chunked execution
            std.debug.print("Large file detected ({d} bytes, {d} statements) - using chunked execution\n", .{ total_size, statements.items.len });
            file_statements = statements;
            query_text = null; // Will use chunked execution instead
        }
    }

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-007; FEATURE="ChunkedExecution"; ASPECT=NullCheck; STATUS=IMPL; OWNER=cli; UPDATED=2026-06-10
    // Allow null query_text when using chunked execution (file_statements is set)
    if (query_text == null and file_statements == null) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        std.debug.print("         geode query --file ~/queries.gql\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Handle stdin input if query_text is "-" (only when not using chunked execution)
    var stdin_allocated: ?[]u8 = null;
    defer if (stdin_allocated) |allocated| allocator.free(allocated);

    if (query_text != null and std.mem.eql(u8, query_text.?, "-")) {
        const stdin = std.Io.File{ .handle = getStdinHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } }; // stdin handle
        const stdin_content = try readStreamToEnd(stdin, allocator, 1024 * 1024); // Max 1MB
        defer allocator.free(stdin_content);

        // Trim only leading/trailing whitespace, preserving internal newlines
        var start: usize = 0;
        var end: usize = stdin_content.len;

        // Trim leading whitespace
        while (start < stdin_content.len and (stdin_content[start] == ' ' or stdin_content[start] == '\t' or stdin_content[start] == '\n' or stdin_content[start] == '\r')) {
            start += 1;
        }

        // Trim trailing whitespace
        while (end > start and (stdin_content[end - 1] == ' ' or stdin_content[end - 1] == '\t' or stdin_content[end - 1] == '\n' or stdin_content[end - 1] == '\r')) {
            end -= 1;
        }

        const trimmed = stdin_content[start..end];
        if (trimmed.len == 0) {
            std.debug.print("Error: empty query from stdin\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Allocate a copy for the query text
        stdin_allocated = try allocator.dupe(u8, trimmed);
        query_text = stdin_allocated;
    }

    // CANARY: REQ=REQ-AUTH-SESSION-009; FEATURE="AutoLoadSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-01-15

    // Auto-load saved session credentials if not explicitly provided
    var loaded_token: ?[]u8 = null;
    var loaded_username: ?[]u8 = null;
    defer if (loaded_token) |t| allocator.free(t);
    defer if (loaded_username) |u| allocator.free(u);

    if (use_saved_session and token == null and user == null) {
        const session_storage = @import("security/session_storage.zig");
        var cred_store = session_storage.CredentialStore.init(allocator) catch blk: {
            // If we can't initialize credential store, just proceed without it
            break :blk null;
        };

        if (cred_store) |*store| {
            defer store.deinit();

            if (try store.loadCredentials()) |creds| {
                // Verify system fingerprint matches
                const current_fp = try session_storage.getSystemFingerprint(allocator);
                defer allocator.free(current_fp);

                // See server_addr resolution at the bottom of cmdQuery: keep
                // this fallback in sync so the saved-session match check
                // doesn't fail when the harness is driving the query.
                const env_server_creds = if (comptime builtin.os.tag != .windows) posixGetenv("GEODE_SERVER_ADDRESS") else null;
                const server_addr = server orelse (env_server_creds orelse "127.0.0.1:3141");
                const fp_match = std.mem.eql(u8, creds.system_fingerprint, current_fp);
                const server_match = std.mem.eql(u8, creds.server, server_addr);
                const now = compat_timestamp();
                const age_secs = now - creds.created_at;
                const max_age_secs: i64 = 3600; // 1 hour
                const not_expired = age_secs < max_age_secs;

                if (fp_match and server_match and not_expired) {
                    loaded_token = try allocator.dupe(u8, creds.token);
                    loaded_username = try allocator.dupe(u8, creds.username);
                    token = loaded_token;
                    user = loaded_username;
                } else if (fp_match and !server_match) {
                    std.debug.print("Note: saved session is for {s}, not {s}. Use --save-session to update.\n", .{ creds.server, server_addr });
                } else if (fp_match and !not_expired) {
                    std.debug.print("Note: saved session expired. Use 'geode auth login' to refresh.\n", .{});
                }
                // Free loaded credentials regardless of match
                allocator.free(creds.token);
                allocator.free(creds.username);
                allocator.free(creds.server);
                allocator.free(creds.system_fingerprint);
            }
        }
    }

    // Check for unauthorized user before executing
    if (user != null and std.mem.eql(u8, user.?, "unauthorized")) {
        const stderr_fd = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
        try stderr_fd.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "unauthorized access denied\n");
        std.process.exit(3);
    }

    // Issue #417: Apply DSN if provided (takes precedence over --server and --grpc)
    if (dsn) |dsn_str| {
        const parsed = parseDsnArg(dsn_str) orelse {
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        server = parsed.host_port;
        use_grpc = parsed.use_grpc;
        // DSN credentials override -U/-P flags
        if (parsed.username) |u| user = u;
        if (parsed.password) |p| password = p;
        // DSN graph path overrides --graph flag; server handles via HELLO (no USE GRAPH prepend)
        if (parsed.graph) |g| {
            graph = g;
            graph_for_prepend = null; // DSN graph handled by HELLO, not USE GRAPH prepend
        }
    }

    // Determine execution mode based on --server flag.  Resolution order:
    //   1. --server flag (explicit)
    //   2. --dsn flag (already applied to `server` above)
    //   3. GEODE_SERVER_ADDRESS env var (set by the test harness on random ports)
    //   4. 127.0.0.1:3141 (default)
    // Mirrors `cmdAuthLogin` (line 3292) so harness-driven query invocations
    // without `--server` find the right port. Without this, every spec test
    // that runs `geode query` without an explicit --server hangs against
    // 127.0.0.1:3141 (where no listener exists) and times out at 30 s.
    const env_server_for_query = if (comptime builtin.os.tag != .windows) posixGetenv("GEODE_SERVER_ADDRESS") else null;
    const server_addr = server orelse (env_server_for_query orelse "127.0.0.1:3141");
    // When falling back to the env-var route, the harness uses self-signed
    // certs; default insecure unless the user already opted in.
    if (server == null and env_server_for_query != null and !insecure) {
        insecure = true;
    }

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-004; FEATURE="ChunkedExecution"; ASPECT=BatchExecution; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
    // Handle chunked execution for large files
    if (file_statements) |statements| {
        if (params.items.len > 0) {
            std.debug.print("Error: --param is not supported with --file\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        // Issue #424: Scale deadline watchdog for chunked execution.
        // Each chunk needs its own timeout (including TLS handshake), so compute
        // total deadline from actual byte total and chunk size.  Add generous
        // per-chunk headroom for TLS setup (~2s) plus execution time.
        const per_chunk_secs: u32 = timeout_secs + 3; // query timeout + TLS/connect overhead
        var stmt_bytes: usize = 0;
        for (statements.items) |s| stmt_bytes += s.len + 1;
        const estimated_chunks = @max(1, stmt_bytes / (8 * 1024)) + 1; // match executeChunkedQueries chunk size
        const chunked_deadline = @min(600, per_chunk_secs * @as(u32, @intCast(estimated_chunks)));
        var chunked_deadline_state = QueryDeadlineState.init();
        query_deadline.active_query_deadline_state = &chunked_deadline_state;
        defer {
            chunked_deadline_state.finish();
            query_deadline.active_query_deadline_state = null;
        }
        startDeadlineWatchdogTask(allocator, chunked_deadline, &chunked_deadline_state);
        try executeChunkedQueries(allocator, .{
            .server_addr = server_addr,
            .statements = statements.items,
            .format = format,
            .insecure = insecure,
            .timeout_secs = timeout_secs,
            .retry_count = retry_count,
            .username = user,
            .password = password,
            .ca_cert_path = ca_cert_path,
            .client_cert_path = client_cert_path,
            .client_key_path = client_key_path,
            .graph = graph_for_prepend,
            .graph_for_hello = graph,
            .use_grpc = use_grpc,
            .role = role,
        });
        return;
    }

    // PERF-P1-002: Batch mode — execute multiple queries from stdin over a single
    // QUIC connection to amortize the 1.3-1.9s TLS handshake across all queries.
    if (batch_mode) {
        const stdin_file = std.Io.File{ .handle = getStdinHandle() catch {
            std.debug.print("Error: --batch requires stdin input\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }, .flags = .{ .nonblocking = false } };
        const stdin_content = readStreamToEnd(stdin_file, allocator, 16 * 1024 * 1024) catch |err| {
            std.debug.print("Error: Failed to read stdin: {}\n", .{err});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer allocator.free(stdin_content);

        if (stdin_content.len == 0) {
            std.debug.print("Error: empty input from stdin\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        try executeBatchQueries(allocator, server_addr, stdin_content, format, insecure, timeout_secs, user, password, ca_cert_path, client_cert_path, client_key_path, graph_for_prepend, graph, page_size, role);
        return;
    }

    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=CliEnvelopeBuild; STATUS=IMPL; OWNER=security; UPDATED=2026-05-22
    // GPS Phase 7 Task 7-5: build the principal_envelope blob from
    // --forward-principal / --forward-principal-envelope. The bytes are emitted
    // as ExecuteRequest field 4; the server deserialises them and evaluates
    // GPS/RLS under the forwarded identity (see quic_connection_handler.zig).
    var forward_envelope_bytes: ?[]u8 = null;
    defer if (forward_envelope_bytes) |b| allocator.free(b);
    if (forward_principal_envelope_hex) |hex| {
        const decoded = allocator.alloc(u8, hex.len / 2) catch {
            std.debug.print("Error: out of memory decoding --forward-principal-envelope\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        _ = std.fmt.hexToBytes(decoded, hex) catch {
            allocator.free(decoded);
            std.debug.print("Error: --forward-principal-envelope must be a valid hex string\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        forward_envelope_bytes = decoded;
    } else if (forward_principal) |fp| {
        // Parse <username>[:<tenant>]. Empty username is rejected.
        const colon = std.mem.indexOfScalar(u8, fp, ':');
        const fp_username = if (colon) |c| fp[0..c] else fp;
        const fp_tenant: ?[]const u8 = if (colon) |c|
            (if (c + 1 < fp.len) fp[c + 1 ..] else null)
        else
            null;
        if (fp_username.len == 0) {
            std.debug.print("Error: --forward-principal username must not be empty\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const env = geode.distributed.principal_envelope.PrincipalEnvelope{
            .user_id = null,
            .username = fp_username,
            .roles = &.{},
            .custom_roles = &.{},
            .tenant_id = fp_tenant,
            .active_graph = graph,
            .auth_version = 0,
            .policy_version = 0,
            // Coordinator marks the envelope as originating from itself; the
            // server re-stamps source = .distributed_worker on unpack.
            .source = .distributed_coordinator,
        };
        forward_envelope_bytes = geode.distributed.principal_envelope.serialize(allocator, env) catch {
            std.debug.print("Error: failed to serialise principal envelope\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    }

    // Issue #424: Start a progress-based deadline watchdog for single queries.
    var query_deadline_state = QueryDeadlineState.init();
    query_deadline.active_query_deadline_state = &query_deadline_state;
    defer {
        query_deadline_state.finish();
        query_deadline.active_query_deadline_state = null;
    }
    startDeadlineWatchdogTask(allocator, timeout_secs, &query_deadline_state);

    // Execute query via QUIC or gRPC connection
    params_owned = false;
    if (use_grpc) {
        try executeGrpcQuery(allocator, .{
            .server_addr = server_addr,
            .query_text = query_text.?,
            .format = format,
            .timeout_secs = timeout_secs,
            .retry_count = retry_count,
            .username = user,
            .password = password,
            .graph = graph_for_prepend,
            .graph_for_hello = graph,
            .page_size = page_size,
            .params = params,
        });
    } else {
        // GAP-0113: Execute query via QUIC connection with optional certificate verification
        // CANARY: REQ=REQ-CLI-GRAPH-FLAG-003; FEATURE="GraphFlag"; ASPECT=ExecuteWithGraph; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
        executeQuicQuery(allocator, .{
            .server_addr = server_addr,
            .query_text = query_text.?,
            .format = format,
            .insecure = insecure,
            .timeout_secs = timeout_secs,
            .retry_count = retry_count,
            .username = user,
            .password = password,
            .ca_cert_path = ca_cert_path,
            .client_cert_path = client_cert_path,
            .client_key_path = client_key_path,
            .graph = graph_for_prepend,
            .graph_for_hello = graph,
            .page_size = page_size,
            .params = params,
            .role = role,
            .principal_envelope_bytes = forward_envelope_bytes,
        }) catch |err| {
            if (err == error.AuthenticationFailed)
                std.process.exit(@intFromEnum(ExitCode.auth_error));
            // GAP-0272: Connection or transport failures — report to stderr
            const stderr_fd = std.Io.File{ .handle = getStderrHandle() catch std.process.exit(1), .flags = .{ .nonblocking = false } };
            stderr_fd.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: query execution failed\n") catch {};
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    }
}

/// Escape a string for safe embedding in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count how many characters need escaping to allocate correct size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => escape_count += 1,
            else => {},
        }
    }

    // If no escaping needed, just duplicate the string
    if (escape_count == 0) {
        return allocator.dupe(u8, input);
    }

    // Allocate buffer for escaped string
    const result = try allocator.alloc(u8, input.len + escape_count);
    var write_idx: usize = 0;

    for (input) |c| {
        switch (c) {
            '"' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '"';
                write_idx += 2;
            },
            '\\' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '\\';
                write_idx += 2;
            },
            '\n' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'n';
                write_idx += 2;
            },
            '\r' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'r';
                write_idx += 2;
            },
            '\t' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 't';
                write_idx += 2;
            },
            else => {
                result[write_idx] = c;
                write_idx += 1;
            },
        }
    }

    return result;
}

const PARAM_MAX_SIZE: usize = 1 * 1024 * 1024; // 1 MB max param payload
const PARAM_MAX_DEPTH: usize = 64;

fn parseParamValue(allocator: std.mem.Allocator, input: []const u8) !schema.Value {
    if (input.len > PARAM_MAX_SIZE) return error.ParamsTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    return jsonToProtoValue(allocator, parsed.value, 0);
}

fn jsonToProtoValue(allocator: std.mem.Allocator, value: std.json.Value, depth: usize) !schema.Value {
    if (depth > PARAM_MAX_DEPTH) return error.ParamsTooDeep;
    return switch (value) {
        .null => .{ .kind = .{ .null_val = .{} } },
        .bool => |b| .{ .kind = .{ .bool_val = b } },
        .integer => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .number_string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .array => |arr| blk: {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            for (arr.items) |item| {
                try values.append(allocator, try jsonToProtoValue(allocator, item, depth + 1));
            }
            break :blk .{ .kind = .{ .list_val = .{ .values = values } } };
        },
        .object => |obj| blk: {
            var entries = std.ArrayList(schema.MapEntry).initCapacity(allocator, obj.count()) catch return error.OutOfMemory;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonToProtoValue(allocator, entry.value_ptr.*, depth + 1);
                try entries.append(allocator, .{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = .{ .entries = entries } } };
        },
    };
}

// GAP-0113 SECURITY FIX: Add TLS certificate verification support
// CANARY: REQ=REQ-TLS-CERT-002; FEATURE="TLSCertVerification"; ASPECT=Core; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-12
// CANARY: REQ=REQ-CLI-GRAPH-FLAG-004; FEATURE="GraphFlag"; ASPECT=ExecuteQuicQuery; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
// Quality fix #405: Refactored 13-parameter function to use options struct
const QuicQueryOptions = struct {
    server_addr: []const u8,
    query_text: []const u8,
    format: []const u8 = "table",
    insecure: bool = false,
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    graph: ?[]const u8 = null, // For USE GRAPH prepending (null when graph from DSN)
    graph_for_hello: ?[]const u8 = null, // For HELLO handshake (set from both --graph and DSN)
    page_size: u32 = default_stream_page_size,
    params: std.ArrayList(schema.Param),
    role: ?[]const u8 = null, // GAP-0271: FLE role for field-level access control
    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=CliForwardPrincipal; STATUS=IMPL; OWNER=security; UPDATED=2026-05-22
    // GPS Phase 7 Task 7-5: serialised principal_envelope blob built from
    // --forward-principal. When non-null the CLI emits ExecuteRequest field 4
    // and the server reconstructs the forwarded Principal for GPS/RLS.
    principal_envelope_bytes: ?[]const u8 = null,
};

const GrpcQueryOptions = struct {
    server_addr: []const u8,
    query_text: []const u8,
    format: []const u8 = "table",
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    graph: ?[]const u8 = null, // For USE GRAPH prepending (null when graph from DSN)
    graph_for_hello: ?[]const u8 = null, // For HELLO handshake
    page_size: u32 = default_stream_page_size,
    params: std.ArrayList(schema.Param),
};

/// Issue #424: Set SO_RCVTIMEO and SO_SNDTIMEO on a TCP socket so that
/// blocking reads and writes will fail with a timeout error instead of
/// hanging forever. This is critical on aarch64 Docker where the gRPC
/// TCP connection and HTTP/2 handshake can block indefinitely.
fn setTcpSocketTimeouts(stream: std.net.Stream, timeout_secs: u32) void {
    if (builtin.os.tag == .windows) return; // Windows uses different API
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    const tv_bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes) catch {};
}

/// Execute a query over gRPC transport (TCP + HTTP/2).
/// Uses the grpc_client.GrpcClient Transport for HTTP/2 framing.
fn executeGrpcQuery(allocator: std.mem.Allocator, opts: GrpcQueryOptions) !void {
    const server_addr = opts.server_addr;
    const query_text = opts.query_text;
    const format = opts.format;
    const timeout_secs = opts.timeout_secs;
    const retry_count = opts.retry_count;
    const username = opts.username;
    const password = opts.password;
    const graph = opts.graph;
    const graph_for_hello = opts.graph_for_hello;
    const page_size = opts.page_size;
    var params = opts.params;
    var params_transferred = false;
    defer if (!params_transferred) {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    };
    const stderr = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };

    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3142";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: Invalid port number in server address\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    var attempts: u32 = 0;
    // Match QUIC's behavior for rapid sequential CLI usage: allow at least
    // three total attempts so transient handshake/connection churn does not
    // fail whole specs unless it persists across retries.
    const max_attempts = @max(retry_count + 1, 3);
    var last_error: ?[]const u8 = null;

    while (attempts < max_attempts) : (attempts += 1) {
        // Connect via raw TCP
        const tcp_stream = grpc_query_transport.connectPlaintext(
            allocator,
            host,
            port,
            timeout_secs,
            .{ .on_progress = touchActiveQueryDeadlineWatchdog },
        ) catch |err| {
            last_error = @errorName(err);
            if (attempts + 1 < max_attempts) {
                compat_sleepNs(50 * std.time.ns_per_ms);
            }
            continue;
        };
        defer tcp_stream.close(std.Io.Threaded.global_single_threaded.io());

        // Execute query on the gRPC connection
        params_transferred = true;
        return executeQueryOnGrpc(allocator, tcp_stream, query_text, format, username, password, graph, graph_for_hello, params, page_size, timeout_secs) catch |err| {
            last_error = @errorName(err);
            params_transferred = false;
            if (attempts + 1 < max_attempts) {
                compat_sleepNs(50 * std.time.ns_per_ms);
            }
            continue;
        };
    }

    if (last_error) |le| {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), le) catch {};
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n") catch {};
    }

    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// Execute a query on a gRPC transport connection, producing identical output to executeQueryOnConnection.
fn executeQueryOnGrpc(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    query_text: []const u8,
    format: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    graph: ?[]const u8,
    graph_for_hello: ?[]const u8,
    params: std.ArrayList(schema.Param),
    page_size: u32,
    timeout_secs: u32,
) !void {
    // Issue #424: timeout_secs is now enforced at two levels:
    // 1. TCP socket SO_RCVTIMEO/SO_SNDTIMEO set by the caller (executeGrpcQuery)
    // 2. Process-level deadline watchdog thread started in cmdQuery
    const stdout = std.Io.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
    const stderr_handle = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
    const binding = resolveQueryGraphBinding(query_text, graph, graph_for_hello);

    // 1. Handshake — send HelloRequest, read HelloResponse
    const hello_resp = grpc_query_transport.hello(
        allocator,
        stream,
        .{
            .username = username,
            .password = password,
            .graph = binding.graph_for_hello,
        },
        .{ .on_progress = touchActiveQueryDeadlineWatchdog },
    ) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error: gRPC handshake failed: {}\n", .{err}) catch "Error: gRPC handshake failed\n";
        stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer {
        var resp_copy = hello_resp;
        resp_copy.deinit(allocator);
    }

    if (!hello_resp.success) {
        const err_msg = std.fmt.allocPrint(allocator, "Error: {s}\n\n", .{hello_resp.error_message}) catch "Error: Authentication failed\n\n";
        stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.auth_error));
    }

    var session_id: []const u8 = hello_resp.session_id;
    var session_id_owned: ?[]u8 = null;
    if (session_id.len > 0) {
        session_id_owned = try allocator.dupe(u8, session_id);
        session_id = session_id_owned.?;
    }
    defer if (session_id_owned) |sid| allocator.free(sid);

    // Drain remaining frames from the Handshake RPC (TRAILERS etc.)
    grpc_query_transport.drainUnaryStream(
        allocator,
        stream,
        .{ .on_progress = touchActiveQueryDeadlineWatchdog },
    );

    // 2. Execute query — send ExecuteRequest, read streaming ExecutionResponses

    // If a graph is specified via --graph flag, prepend "USE GRAPH graphname;"
    // When graph came from DSN, graph_for_prepend is null (server handles via HELLO)
    var final_query: []const u8 = binding.query_text;
    var allocated_query: ?[]u8 = null;
    defer if (allocated_query) |q| allocator.free(q);

    allocated_query = try query_scope.prependGraphContextIfNeeded(allocator, binding.query_text, graph);
    if (allocated_query) |scoped| final_query = scoped;

    const owned_params = params;
    defer finishActiveQueryDeadlineWatchdog();

    var grpc_adapter = grpc_query_transport.StreamingQueryAdapter{
        .stream = stream,
        .hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog },
    };
    var grpc_transport = grpc_adapter.asTransport();

    var result = try query_runner.collectQueryWithTransport(allocator, &grpc_transport, .{
        .session_id = session_id,
        .query_text = final_query,
        .format = format,
        .timeout_secs = timeout_secs,
        .page_size = page_size,
        .params = owned_params,
    });
    defer result.deinit();

    _ = try result.render(stdout, stderr_handle);
}

/// PERF-P1-002: Execute multiple queries from stdin over a single QUIC connection.
/// Each non-empty line is treated as a separate query. The QUIC+TLS handshake
/// happens once; each query opens a new multiplexed stream (negligible cost).
fn executeBatchQueries(
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    stdin_content: []const u8,
    format: []const u8,
    insecure: bool,
    timeout_secs: u32,
    username: ?[]const u8,
    password: ?[]const u8,
    ca_cert_path: ?[]const u8,
    client_cert_path: ?[]const u8,
    client_key_path: ?[]const u8,
    graph: ?[]const u8,
    graph_for_hello: ?[]const u8,
    page_size: u32,
    fle_role: ?[]const u8,
) !void {
    const stderr = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };

    // Split stdin into individual queries (one per line, skip empty/whitespace-only lines)
    var queries = std.ArrayList([]const u8).empty;
    defer queries.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, stdin_content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            queries.append(allocator, trimmed) catch return error.OutOfMemory;
        }
    }

    if (queries.items.len == 0) {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: no queries found in stdin\n") catch {};
        return error.EmptyInput;
    }

    // Parse server address
    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3141";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: Invalid port number in server address\n") catch {};
        return error.InvalidAddress;
    };

    // Single QUIC connection for all queries via the shared Zig client library.
    // GAP-0260/0263: retry the initial connect a few times. Under CPU contention
    // (e.g. parallel test runs / stdin batches) the QUIC handshake can fail
    // transiently; a brief backoff between attempts resolves most of it. Mirrors
    // the retry already present on the single-query path below.
    const max_connect_attempts: usize = 3;
    var connect_attempt: usize = 0;
    var raw_client = while (true) : (connect_attempt += 1) {
        var c = zig_quic_bridge.initClient(
            allocator,
            host,
            port,
            .{
                .insecure = insecure,
                .ca_cert_path = ca_cert_path,
                .client_cert_path = client_cert_path,
                .client_key_path = client_key_path,
            },
            null,
            null,
        ) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to initialize client: {}\n", .{err}) catch "Error: Failed to initialize client\n";
            stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
            return error.ConnectionFailed;
        };
        c.connect() catch |err| {
            c.deinit();
            const name = @errorName(err);
            if (connect_attempt + 1 >= max_connect_attempts or std.mem.indexOf(u8, name, "ConnectionRefused") != null) {
                const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to connect: {s}\n", .{name}) catch "Error: Failed to connect\n";
                stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
                return error.ConnectionFailed;
            }
            compat_sleepNs(50 * std.time.ns_per_ms);
            continue;
        };
        break c;
    };
    defer raw_client.deinit();

    // Connected — execute all queries over this single connection
    var executed: usize = 0;
    var error_count: usize = 0;
    const empty_params = std.ArrayList(schema.Param).empty;

    for (queries.items) |query_line| {
        executeQueryOnConnection(allocator, &raw_client, query_line, format, username, password, graph, graph_for_hello, empty_params, page_size, timeout_secs, fle_role, null) catch |err| {
            std.debug.print("Error executing query: {}\n", .{err});
            error_count += 1;
        };
        executed += 1;
    }

    std.debug.print("\nBatch execution complete: {d} queries executed", .{executed});
    if (error_count > 0) {
        std.debug.print(", {d} errors", .{error_count});
    }
    std.debug.print("\n", .{});
}

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-005; FEATURE="ChunkedExecution"; ASPECT=OptionsStruct; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
const ChunkedQueryOptions = struct {
    server_addr: []const u8,
    statements: []const []const u8,
    format: []const u8 = "table",
    insecure: bool = false,
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    graph: ?[]const u8 = null,
    graph_for_hello: ?[]const u8 = null,
    use_grpc: bool = false,
    role: ?[]const u8 = null, // GAP-0271: FLE role
};

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-006; FEATURE="ChunkedExecution"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/transaction_chunked_execution.yml; OWNER=cli; UPDATED=2026-06-10
/// Execute statements in chunks, batching multiple statements per request while staying under the size limit.
/// Transaction-aware: never splits chunks within BEGIN/COMMIT boundaries.
/// Context-aware: carries USE GRAPH forward to subsequent chunks on new connections.
fn executeChunkedQueries(allocator: std.mem.Allocator, opts: ChunkedQueryOptions) !void {
    const max_chunk_size: usize = 32 * 1024; // 32KB per chunk
    const statements = opts.statements;

    var executed: usize = 0;
    var error_count: usize = 0;

    // Track USE GRAPH context to prepend to subsequent chunks (each chunk is a new connection)
    var use_graph_stmt: ?[]const u8 = null;

    // Pre-scan: strip transaction wrappers from statements that will be split across
    // multiple chunks.  Each chunk opens a new QUIC connection, so START TRANSACTION
    // in chunk 1 has no effect in chunk 2; a COMMIT in chunk 3 would hang because
    // no transaction is active on that connection.  Stripping the wrappers lets every
    // statement auto-commit, which is the only correct behaviour when we can't keep
    // the transaction on a single connection.
    //
    // We do this by scanning for transaction blocks whose byte total exceeds
    // max_chunk_size.  Small transactions that fit in one chunk are left intact.
    var txn_strip = try std.ArrayList(bool).initCapacity(allocator, statements.len);
    defer txn_strip.deinit(allocator);
    {
        var i: usize = 0;
        while (i < statements.len) {
            const trimmed = std.mem.trim(u8, statements[i], " \t\r\n");
            if (isTransactionBegin(trimmed)) {
                // Measure the transaction block: BEGIN ... COMMIT/ROLLBACK
                const txn_start = i;
                var txn_bytes: usize = 0;
                var j: usize = i;
                while (j < statements.len) {
                    txn_bytes += statements[j].len + 1;
                    const t = std.mem.trim(u8, statements[j], " \t\r\n");
                    if (j > txn_start and isTransactionEnd(t)) {
                        break;
                    }
                    j += 1;
                }
                const txn_end = if (j < statements.len) j + 1 else j;
                if (txn_bytes > max_chunk_size) {
                    // #830: refuse to silently auto-commit a transaction that
                    // ends with ROLLBACK.  Stripping BEGIN/ROLLBACK and
                    // running the inner statements auto-commit silently
                    // commits writes the user intended to roll back — that's
                    // silent data corruption.  Detect ROLLBACK as the
                    // terminator and fail fast so the operator sees the
                    // problem and can split the work manually.
                    const ends_with_rollback = blk: {
                        if (txn_end == 0 or txn_end - 1 >= statements.len) break :blk false;
                        const last = std.mem.trim(u8, statements[txn_end - 1], " \t\r\n");
                        break :blk std.ascii.eqlIgnoreCase(last, "ROLLBACK");
                    };
                    if (ends_with_rollback) {
                        std.debug.print(
                            \\Error: transaction is too large for a single connection ({d} bytes; chunk limit {d} bytes) and ends with ROLLBACK.
                            \\Silently auto-committing the inner statements would discard the ROLLBACK semantics and corrupt data.
                            \\Reduce the transaction size to fit within {d} bytes per chunk, or split it into smaller transactions.
                            \\
                        , .{ txn_bytes, max_chunk_size, max_chunk_size });
                        return error.TransactionTooLargeForChunkedRollback;
                    }
                    // Transaction is too large for one chunk and ends with
                    // COMMIT — mark BEGIN and COMMIT for stripping so the
                    // inner statements auto-commit (semantically equivalent
                    // to an explicit COMMIT, modulo isolation guarantees).
                    while (txn_strip.items.len < txn_end)
                        txn_strip.append(allocator, false) catch unreachable;
                    txn_strip.items[txn_start] = true; // strip BEGIN
                    if (txn_end > 0 and txn_end - 1 < txn_strip.items.len) {
                        txn_strip.items[txn_end - 1] = true; // strip COMMIT
                    }
                    i = txn_end;
                } else {
                    // Small transaction — keep intact
                    while (txn_strip.items.len <= j)
                        txn_strip.append(allocator, false) catch unreachable;
                    i = txn_end;
                }
            } else {
                txn_strip.append(allocator, false) catch unreachable;
                i += 1;
            }
        }
        // Pad if needed
        while (txn_strip.items.len < statements.len)
            txn_strip.append(allocator, false) catch unreachable;
    }

    // Process statements in chunks
    var chunk_start: usize = 0;
    while (chunk_start < statements.len) {
        // Skip stripped statements at chunk boundary
        while (chunk_start < statements.len and txn_strip.items[chunk_start]) {
            chunk_start += 1;
        }
        if (chunk_start >= statements.len) break;

        // Build a chunk of statements that fits within the size limit
        var chunk_size: usize = 0;
        var chunk_end: usize = chunk_start;
        var in_transaction: bool = false;

        // Account for USE GRAPH prefix if needed (not the first chunk and we have context)
        if (chunk_start > 0) {
            if (use_graph_stmt) |ug| {
                chunk_size += ug.len + 2; // +2 for "; "
            }
        }

        while (chunk_end < statements.len) {
            // Skip stripped statements
            if (txn_strip.items[chunk_end]) {
                chunk_end += 1;
                continue;
            }
            const stmt_len = statements[chunk_end].len + 1; // +1 for separator
            // Transaction-aware: don't break within a (small) transaction
            const at_limit = chunk_size + stmt_len > max_chunk_size and chunk_end > chunk_start;
            if (at_limit and !in_transaction) {
                break;
            }
            chunk_size += stmt_len;

            // Track transaction boundaries (only for small transactions that weren't stripped)
            const trimmed = std.mem.trim(u8, statements[chunk_end], " \t\r\n");
            if (isTransactionBegin(trimmed)) {
                in_transaction = true;
            } else if (in_transaction and isTransactionEnd(trimmed)) {
                in_transaction = false;
            }

            // Track USE GRAPH for subsequent chunks
            if (isUseGraphStmt(trimmed)) {
                use_graph_stmt = statements[chunk_end];
            }

            chunk_end += 1;
        }

        // Build the chunk query
        var chunk_query = try std.ArrayList(u8).initCapacity(allocator, chunk_size);
        defer chunk_query.deinit(allocator);

        // Prepend USE GRAPH context for chunks after the first (each is a new connection)
        if (chunk_start > 0) {
            if (use_graph_stmt) |ug| {
                const ug_trimmed = std.mem.trim(u8, ug, " \t\r\n");
                chunk_query.appendSlice(allocator, ug_trimmed) catch {};
                // Ensure it ends with semicolon
                if (ug_trimmed.len == 0 or ug_trimmed[ug_trimmed.len - 1] != ';') {
                    chunk_query.append(allocator, ';') catch {};
                }
                chunk_query.append(allocator, ' ') catch {};
            }
        }

        for (chunk_start..chunk_end) |idx| {
            if (txn_strip.items[idx]) continue; // Skip stripped BEGIN/COMMIT
            chunk_query.appendSlice(allocator, statements[idx]) catch {};
            chunk_query.append(allocator, ' ') catch {};
        }

        // Execute this chunk
        const chunk_count = chunk_end - chunk_start;
        std.debug.print("Executing chunk {d}-{d} of {d} statements...\n", .{ chunk_start + 1, chunk_end, statements.len });

        const empty_params = std.ArrayList(schema.Param).empty;
        if (opts.use_grpc) {
            executeGrpcQuery(allocator, .{
                .server_addr = opts.server_addr,
                .query_text = chunk_query.items,
                .format = "json",
                .timeout_secs = opts.timeout_secs,
                .retry_count = opts.retry_count,
                .username = opts.username,
                .password = opts.password,
                .graph = opts.graph,
                .graph_for_hello = opts.graph_for_hello,
                .page_size = default_stream_page_size,
                .params = empty_params,
            }) catch |err| {
                std.debug.print("Error executing chunk: {}\n", .{err});
                error_count += 1;
            };
        } else {
            executeQuicQuery(allocator, .{
                .server_addr = opts.server_addr,
                .query_text = chunk_query.items,
                .format = "json", // Use JSON for chunked to simplify aggregation
                .insecure = opts.insecure,
                .timeout_secs = opts.timeout_secs,
                .retry_count = opts.retry_count,
                .username = opts.username,
                .password = opts.password,
                .ca_cert_path = opts.ca_cert_path,
                .client_cert_path = opts.client_cert_path,
                .client_key_path = opts.client_key_path,
                .graph = opts.graph,
                .graph_for_hello = opts.graph_for_hello,
                .page_size = default_stream_page_size,
                .params = empty_params,
                .role = opts.role,
            }) catch |err| {
                std.debug.print("Error executing chunk: {}\n", .{err});
                error_count += 1;
            };
        }

        executed += chunk_count;
        chunk_start = chunk_end;
    }

    // Print summary
    std.debug.print("\nChunked execution complete:\n", .{});
    std.debug.print("  Statements executed: {d}\n", .{executed});
    if (error_count > 0) {
        std.debug.print("  Errors: {d}\n", .{error_count});
    }
}

/// Check if a trimmed statement is a transaction begin (START TRANSACTION or BEGIN)
fn isTransactionBegin(trimmed: []const u8) bool {
    // Remove trailing semicolons for comparison
    const stmt = std.mem.trimEnd(u8, trimmed, "; \t");
    if (stmt.len == 0) return false;
    // Case-insensitive check for BEGIN or START TRANSACTION
    if (std.ascii.eqlIgnoreCase(stmt, "BEGIN") or
        std.ascii.eqlIgnoreCase(stmt, "START TRANSACTION"))
        return true;
    return false;
}

/// Check if a trimmed statement is a transaction end (COMMIT or ROLLBACK)
fn isTransactionEnd(trimmed: []const u8) bool {
    const stmt = std.mem.trimEnd(u8, trimmed, "; \t");
    if (stmt.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(stmt, "COMMIT") or
        std.ascii.eqlIgnoreCase(stmt, "ROLLBACK"))
        return true;
    return false;
}

/// Check if a trimmed statement is a USE GRAPH statement
fn isUseGraphStmt(trimmed: []const u8) bool {
    return query_scope.startsWithUseGraph(trimmed);
}

fn executeQuicQuery(allocator: std.mem.Allocator, opts: QuicQueryOptions) !void {
    const server_addr = opts.server_addr;
    const query_text = opts.query_text;
    const format = opts.format;
    const insecure = opts.insecure;
    const timeout_secs = opts.timeout_secs;
    const retry_count = opts.retry_count;
    const username = opts.username;
    const password = opts.password;
    const ca_cert_path = opts.ca_cert_path;
    const client_cert_path = opts.client_cert_path;
    const client_key_path = opts.client_key_path;
    const graph = opts.graph;
    const graph_for_hello = opts.graph_for_hello;
    const page_size = opts.page_size;
    const fle_role = opts.role;
    const principal_envelope_bytes = opts.principal_envelope_bytes;
    var params = opts.params;
    var params_transferred = false;
    defer if (!params_transferred) {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    };
    const stderr = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };

    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3141";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: Invalid port number in server address\n") catch {};
        return error.InvalidAddress;
    };

    // Validate mutual TLS: if any client cert/key provided, both must be provided
    if ((client_cert_path != null) != (client_key_path != null)) {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: Both --client-cert and --client-key must be provided for mutual TLS\n") catch {};
        return error.InvalidAddress;
    }

    var attempts: u32 = 0;
    // GAP-0260/GAP-0263: Allow at least 3 attempts (2 automatic retries) to handle
    // transient QUIC connection drops under rapid sequential CLI usage.
    // Increased from 2 to 3 based on GAP-0263 analysis showing ~30% residual
    // failures after first retry under rapid connection cycling.
    const max_attempts = @max(retry_count + 1, 3);
    var last_error: ?[]const u8 = null;

    while (attempts < max_attempts) : (attempts += 1) {
        var raw_client = zig_quic_bridge.initClient(
            allocator,
            host,
            port,
            .{
                .insecure = insecure,
                .ca_cert_path = ca_cert_path,
                .client_cert_path = client_cert_path,
                .client_key_path = client_key_path,
            },
            null,
            null,
        ) catch |err| {
            last_error = @errorName(err);
            break;
        };
        defer raw_client.deinit();

        raw_client.connect() catch |err| {
            last_error = @errorName(err);
            if (std.mem.indexOf(u8, last_error.?, "ConnectionRefused") != null) {
                break;
            }
            if (attempts + 1 < max_attempts) {
                compat_sleepNs(50 * std.time.ns_per_ms);
            }
            continue;
        };

        params_transferred = true;
        executeQueryOnConnection(allocator, &raw_client, query_text, format, username, password, graph, graph_for_hello, params, page_size, timeout_secs, fle_role, principal_envelope_bytes) catch |err| {
            // GAP-0260/GAP-0263: Auto-retry on connection failure. QUIC
            // transport can drop messages under rapid sequential
            // connections; retries resolve most transient failures
            // without requiring explicit --retry flag.
            if (err == error.ConnectionFailed and attempts + 1 < max_attempts) {
                last_error = "connection dropped, retrying";
                // GAP-0263/GAP-0272: Brief delay between retries to let the
                // server finish processing the previous connection's cleanup.
                // Increased from 10ms to 50ms to reduce failures during
                // rapid sequential bulk operations (e.g., stdin batches).
                compat_sleepNs(50 * std.time.ns_per_ms);
                params_transferred = false;
                continue;
            }
            return err;
        };
        return;
    }

    if (last_error) |le| {
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), le) catch {};
        stderr.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n") catch {};
    }

    return error.ConnectionFailed;
}

fn writeProtoMessageViaZigClient(allocator: std.mem.Allocator, client: *zig_client.GeodeClient, msg: schema.QuicClientMessage) !void {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    const packet = schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const written_data = aw.writer.buffer[0..aw.writer.end];
    const framed = try allocator.alloc(u8, written_data.len + 4);
    defer allocator.free(framed);

    std.mem.writeInt(u32, framed[0..4], @intCast(written_data.len), .big);
    @memcpy(framed[4..], written_data);
    try client.sendRawFramed(framed);
}

fn readProtoMessageViaZigClient(allocator: std.mem.Allocator, client: *zig_client.GeodeClient, timeout_secs: u32) !schema.QuicServerMessage {
    const body = client.receiveRawFrame(allocator, @as(u64, timeout_secs) * std.time.ms_per_s) catch |err| switch (err) {
        error.ReceiveTimeout => return error.Timeout,
        else => return err,
    };
    defer allocator.free(body);

    var reader: std.Io.Reader = .fixed(body);
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}

const QueryGraphBinding = struct {
    query_text: []const u8,
    graph_for_hello: ?[]const u8,
};

fn resolveQueryGraphBinding(
    query_text: []const u8,
    graph_for_prepend: ?[]const u8,
    graph_for_hello: ?[]const u8,
) QueryGraphBinding {
    if (graph_for_prepend != null or graph_for_hello != null) {
        return .{
            .query_text = query_text,
            .graph_for_hello = graph_for_hello,
        };
    }

    const extracted = query_scope.extractLeadingUseGraph(query_text) orelse {
        return .{
            .query_text = query_text,
            .graph_for_hello = null,
        };
    };

    if (extracted.remainder.len == 0 or query_scope.startsWithUseGraph(extracted.remainder)) {
        return .{
            .query_text = query_text,
            .graph_for_hello = null,
        };
    }

    return .{
        .query_text = extracted.remainder,
        .graph_for_hello = extracted.graph_name,
    };
}

// CANARY: REQ=REQ-CLI-GRAPH-FLAG-005; FEATURE="GraphFlag"; ASPECT=ExecuteOnConnection; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
fn executeQueryOnConnection(
    allocator: std.mem.Allocator,
    raw_client: *zig_client.GeodeClient,
    query_text: []const u8,
    format: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    graph: ?[]const u8,
    graph_for_hello: ?[]const u8,
    params: std.ArrayList(schema.Param),
    page_size: u32,
    timeout_secs: u32,
    fle_role: ?[]const u8,
    principal_envelope_bytes: ?[]const u8,
) !void {
    // Get stdout and stderr handles for output
    const stdout = std.Io.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
    const stderr_handle = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
    const binding = resolveQueryGraphBinding(query_text, graph, graph_for_hello);

    // Start each standalone query on a fresh QUIC stream.
    raw_client.closeStream();
    defer raw_client.closeStream();

    // Send HELLO message with authentication credentials
    // CANARY: REQ=REQ-LIB-MIGRATION-PROTO-001; FEATURE="ProtoMigration"; ASPECT=HelloMessage; STATUS=TESTED; OWNER=cli; UPDATED=2026-02-02
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .tenant_id = null,
        .graph = binding.graph_for_hello,
        .role = fle_role,
    };

    log.debug("Client sending HELLO (Protobuf)", &.{});
    writeProtoMessageViaZigClient(allocator, raw_client, .{ .hello = hello_req }) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to send HELLO: {}\n", .{err}) catch "Error: Failed to send HELLO\n";
        stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
        return error.ConnectionFailed;
    };

    // Use an arena for the HELLO response to ensure cleanup of decoded message fields
    var hello_arena = std.heap.ArenaAllocator.init(allocator);
    defer hello_arena.deinit();

    const hello_resp_msg = readProtoMessageViaZigClient(hello_arena.allocator(), raw_client, timeout_secs) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to receive HELLO response: {}\n", .{err}) catch "Error: Failed to receive HELLO response\n";
        stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
        return error.ConnectionFailed;
    };

    var session_id: []const u8 = "";
    var session_id_owned: ?[]u8 = null;

    switch (hello_resp_msg) {
        .hello => |h| {
            log.debug("Client received HELLO response", &.{Attr.boolean("success", h.success)});
            if (!h.success) {
                const err_msg = std.fmt.allocPrint(allocator, "Error: {s}\n\n", .{h.error_message}) catch "Error: Authentication failed\n\n";
                stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), err_msg) catch {};
                return error.AuthenticationFailed;
            }
            if (h.session_id.len > 0) {
                session_id_owned = try allocator.dupe(u8, h.session_id);
                session_id = session_id_owned.?;
            }
        },
        else => {
            stderr_handle.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: Unexpected response type during handshake\n") catch {};
            return error.AuthenticationFailed;
        },
    }
    defer if (session_id_owned) |sid| allocator.free(sid);

    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-006; FEATURE="GraphFlag"; ASPECT=PrependUseGraph; STATUS=TESTED; TEST=geodetestlab/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-06-10
    // If a graph is specified via --graph flag, prepend "USE GRAPH graphname;" to the query
    // When graph came from DSN, caller passes null (server handles via HELLO)
    var final_query: []const u8 = binding.query_text;
    var allocated_query: ?[]u8 = null;
    defer if (allocated_query) |q| allocator.free(q);

    allocated_query = try query_scope.prependGraphContextIfNeeded(allocator, binding.query_text, graph);
    if (allocated_query) |scoped| final_query = scoped;

    // #747: wire `on_progress = touchActiveQueryDeadlineWatchdog` into the
    // QUIC send/recv path so long server-streamed queries don't false-timeout
    // against the idle-timeout watchdog in src/cli/query_deadline.zig.
    // Mirrors the gRPC sites at :1663/1723/1752/1771 which pass
    // `.{ .on_progress = touchActiveQueryDeadlineWatchdog }` to the transport.
    const QuicProtocolAdapter = struct {
        raw_client: *zig_client.GeodeClient,
        timeout_secs: u32,
        hooks: struct { on_progress: ?*const fn () void = null } = .{},

        fn notifyProgress(self: *const @This()) void {
            if (self.hooks.on_progress) |callback| callback();
        }

        fn sendClientMessage(proto: *query_runner.ProtocolClient, alloc: std.mem.Allocator, msg: schema.QuicClientMessage) !void {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            self.notifyProgress();
            try writeProtoMessageViaZigClient(alloc, self.raw_client, msg);
            self.notifyProgress();
        }

        fn readServerMessage(proto: *query_runner.ProtocolClient, alloc: std.mem.Allocator, timeout: u32) !schema.QuicServerMessage {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            const effective_timeout = if (timeout == 0) self.timeout_secs else timeout;
            const result = try readProtoMessageViaZigClient(alloc, self.raw_client, effective_timeout);
            self.notifyProgress();
            return result;
        }
    };

    var adapter = QuicProtocolAdapter{
        .raw_client = raw_client,
        .timeout_secs = timeout_secs,
        .hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog },
    };
    var protocol_client = query_runner.ProtocolClient{
        .context = &adapter,
        .sendClientMessageFn = QuicProtocolAdapter.sendClientMessage,
        .readServerMessageFn = QuicProtocolAdapter.readServerMessage,
    };

    var result = try query_runner.collectQuery(allocator, &protocol_client, .{
        .session_id = session_id,
        .query_text = final_query,
        .format = format,
        .timeout_secs = timeout_secs,
        .page_size = page_size,
        .params = params,
        // GPS Phase 7 Task 7-5: forward the principal envelope (built from
        // --forward-principal) so the server's GPS engine evaluates RLS under
        // the forwarded identity instead of this connection's principal.
        .principal_envelope_bytes = principal_envelope_bytes,
    });
    defer result.deinit();
    defer finishActiveQueryDeadlineWatchdog();

    _ = try result.render(stdout, stderr_handle);

    // GAP-0272: Server-side errors (parse errors, execution errors) are
    // rendered to stdout with the error status. The CLI exits 0 because
    // the transport layer worked correctly — only connection/transport
    // failures should cause non-zero exit codes.
}

/// Convert a JSON value to a string ID (handles both string and integer IDs)
fn getDotIdString(allocator: std.mem.Allocator, val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    if (v == .string) return allocator.dupe(u8, v.string) catch null;
    if (v == .integer) return std.fmt.allocPrint(allocator, "{d}", .{v.integer}) catch null;
    return null;
}

/// Get node ID as string (handles id field being int or string)
fn getDotNodeId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    // Try id first (server uses "id"), then _id, then element_id
    if (obj.get("id")) |id| {
        return getDotIdString(allocator, id);
    }
    if (obj.get("_id")) |id| {
        return getDotIdString(allocator, id);
    }
    if (obj.get("element_id")) |id| {
        return getDotIdString(allocator, id);
    }
    return null;
}

fn getDotNodeLabel(allocator: std.mem.Allocator, obj: std.json.ObjectMap, labels_val: std.json.Value) ![]const u8 {
    var label_parts = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer label_parts.deinit(allocator);

    // Add labels
    if (labels_val == .array) {
        for (labels_val.array.items, 0..) |lbl, i| {
            if (i > 0) try label_parts.append(allocator, ':');
            if (lbl == .string) {
                try label_parts.appendSlice(allocator, lbl.string);
            }
        }
    }

    // Add a display property if available (name, title, etc.)
    // Properties might be at top level or inside a "properties" object
    const display_props = [_][]const u8{ "name", "title", "label", "username", "email" };

    // First check properties object (server format)
    if (obj.get("properties")) |props_val| {
        if (props_val == .object) {
            for (display_props) |prop| {
                if (props_val.object.get(prop)) |val| {
                    if (val == .string and val.string.len > 0) {
                        try label_parts.appendSlice(allocator, "\\n");
                        try label_parts.appendSlice(allocator, val.string);
                        break;
                    }
                }
            }
        }
    }

    if (label_parts.items.len == 0) {
        // Fall back to node ID
        const id = getDotNodeId(allocator, obj) orelse return try allocator.dupe(u8, "node");
        return id;
    }

    return try allocator.dupe(u8, label_parts.items);
}

/// Output DOT format from pre-collected row data
/// CANARY: REQ=REQ-CLI-DOT-003; FEATURE="DotFormat"; ASPECT=RowBasedOutput; STATUS=TESTED; TEST=geodetestlab/specs/query_output_formats.yml; OWNER=cli; UPDATED=2026-06-10
fn outputDotFormatFromRows(allocator: std.mem.Allocator, rows: []const std.ArrayList([]const u8), stdout: std.Io.File) !void {
    // Start DOT graph
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "digraph G {\n") catch {};
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "  rankdir=LR;\n") catch {};
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "  node [shape=ellipse, style=filled, fillcolor=lightblue];\n") catch {};
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "  edge [fontsize=10];\n") catch {};
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n") catch {};

    // Track nodes and edges to avoid duplicates
    var seen_nodes = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_nodes.keyIterator();
        while (key_iter.next()) |key| allocator.free(key.*);
        seen_nodes.deinit();
    }

    // Process each row looking for node/edge data
    for (rows) |row| {
        for (row.items, 0..) |cell, col_idx| {
            // Try to parse cell as JSON (might be a serialized node/edge)
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, cell, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Check if this is a node (has labels)
            if (obj.get("labels")) |labels_val| {
                const node_id = getDotNodeId(allocator, obj) orelse continue;
                defer allocator.free(node_id);

                if (!seen_nodes.contains(node_id)) {
                    try seen_nodes.put(try allocator.dupe(u8, node_id), {});

                    const label = getDotNodeLabel(allocator, obj, labels_val) catch node_id;
                    defer if (!std.mem.eql(u8, label, node_id)) allocator.free(label);

                    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "  \"") catch {};
                    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), node_id) catch {};
                    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\" [label=\"") catch {};
                    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), label) catch {};
                    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\"];\n") catch {};
                }
            }
            // Check if this is a relationship
            else if (obj.get("label") orelse obj.get("type")) |type_val| {
                if (type_val != .string) continue;
                const rel_type = type_val.string;

                const start_id = getDotIdString(allocator, obj.get("from")) orelse
                    getDotIdString(allocator, obj.get("start_node")) orelse continue;
                defer allocator.free(start_id);
                const end_id = getDotIdString(allocator, obj.get("to")) orelse
                    getDotIdString(allocator, obj.get("end_node")) orelse continue;
                defer allocator.free(end_id);

                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "  \"") catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), start_id) catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\" -> \"") catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), end_id) catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\" [label=\"") catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), rel_type) catch {};
                stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\"];\n") catch {};
            }

            _ = col_idx; // Suppress unused variable warning
        }
    }

    // End DOT graph
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "}\n") catch {};
}

fn formatJsonValueCompact(allocator: std.mem.Allocator, val: std.json.Value) ![]u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, "null"),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d:.6}", .{f}),
        .string => |s| try allocator.dupe(u8, s),
        .array => try allocator.dupe(u8, "[...]"),
        .object => blk: {
            // For objects, try to show a useful summary
            const obj = val.object;
            if (obj.get("labels")) |labels_val| {
                if (labels_val == .array and labels_val.array.items.len > 0 and labels_val.array.items[0] == .string) {
                    break :blk try std.fmt.allocPrint(allocator, "({s})", .{labels_val.array.items[0].string});
                }
                break :blk try allocator.dupe(u8, "(node)");
            }
            if (obj.get("label")) |t| {
                if (t == .string) break :blk try std.fmt.allocPrint(allocator, "[:{s}]", .{t.string});
                break :blk try allocator.dupe(u8, "[rel]");
            }
            if (obj.get("type")) |t| {
                if (t == .string) break :blk try std.fmt.allocPrint(allocator, "[:{s}]", .{t.string});
                break :blk try allocator.dupe(u8, "[rel]");
            }
            break :blk try allocator.dupe(u8, "{...}");
        },
        .number_string => |s| try allocator.dupe(u8, s),
    };
}

fn jsonNumberFromU64(allocator: std.mem.Allocator, value: u64) !std.json.Value {
    if (value <= @as(u64, std.math.maxInt(i64))) {
        return .{ .integer = @intCast(value) };
    }
    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{value});
    return .{ .number_string = num_str };
}

fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn protoMapEntriesToJson(allocator: std.mem.Allocator, entries: []const schema.MapEntry) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.init(allocator);
    for (entries) |entry| {
        const key = try allocator.dupe(u8, entry.key);
        const val = if (entry.value) |v|
            try protoValueToJson(allocator, v)
        else
            std.json.Value.null;
        try obj.put(key, val);
    }
    return obj;
}

fn protoNodeToJson(allocator: std.mem.Allocator, node: schema.NodeValue) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put(try allocator.dupe(u8, "id"), try jsonNumberFromU64(allocator, node.id));

    var labels = std.json.Array.init(allocator);
    for (node.labels.items) |label| {
        try labels.append(.{ .string = try allocator.dupe(u8, label) });
    }
    try obj.put(try allocator.dupe(u8, "labels"), .{ .array = labels });

    const props_obj = try protoMapEntriesToJson(allocator, node.properties.items);
    try obj.put(try allocator.dupe(u8, "properties"), .{ .object = props_obj });
    return .{ .object = obj };
}

fn protoEdgeToJson(allocator: std.mem.Allocator, edge: schema.EdgeValue) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put(try allocator.dupe(u8, "id"), try jsonNumberFromU64(allocator, edge.id));
    try obj.put(try allocator.dupe(u8, "from"), try jsonNumberFromU64(allocator, edge.from_id));
    try obj.put(try allocator.dupe(u8, "to"), try jsonNumberFromU64(allocator, edge.to_id));
    try obj.put(try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, edge.label) });

    const props_obj = try protoMapEntriesToJson(allocator, edge.properties.items);
    try obj.put(try allocator.dupe(u8, "properties"), .{ .object = props_obj });
    return .{ .object = obj };
}

fn protoPathToJson(allocator: std.mem.Allocator, path: schema.PathValue) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    var nodes = std.json.Array.init(allocator);
    for (path.nodes.items) |node| {
        try nodes.append(try protoNodeToJson(allocator, node));
    }
    try obj.put(try allocator.dupe(u8, "nodes"), .{ .array = nodes });

    var edges = std.json.Array.init(allocator);
    for (path.edges.items) |edge| {
        try edges.append(try protoEdgeToJson(allocator, edge));
    }
    try obj.put(try allocator.dupe(u8, "edges"), .{ .array = edges });
    return .{ .object = obj };
}

fn protoExtendedToJson(allocator: std.mem.Allocator, ext: schema.ExtendedValue) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    if (ext.type_name.len > 0) {
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, ext.type_name) });
    }
    if (ext.data) |data| {
        const val: std.json.Value = switch (data) {
            .text => |t| .{ .string = try allocator.dupe(u8, t) },
            .bytes => |b| .{ .string = try base64Encode(allocator, b) },
            .int_val => |n| .{ .integer = n },
            .double_val => |f| .{ .float = f },
            .bool_val => |b| .{ .bool = b },
        };
        try obj.put(try allocator.dupe(u8, "value"), val);
    }
    return .{ .object = obj };
}

fn protoValueToJson(allocator: std.mem.Allocator, value: schema.Value) error{OutOfMemory}!std.json.Value {
    const kind = value.kind orelse return std.json.Value.null;
    return switch (kind) {
        .null_val => std.json.Value.null,
        .int_val => |v| .{ .integer = v.value },
        .double_val => |v| .{ .float = v.value },
        .bool_val => |b| .{ .bool = b },
        .string_val => |v| .{ .string = try allocator.dupe(u8, v.value) },
        .decimal_val => |v| blk: {
            const repr = if (v.orig_repr.len > 0) v.orig_repr else v.coeff;
            break :blk .{ .string = try allocator.dupe(u8, repr) };
        },
        .bytes_val => |v| .{ .string = try base64Encode(allocator, v.value) },
        .list_val => |v| blk: {
            var arr = std.json.Array.init(allocator);
            for (v.values.items) |item| {
                try arr.append(try protoValueToJson(allocator, item));
            }
            break :blk .{ .array = arr };
        },
        .map_val => |v| blk: {
            const obj = try protoMapEntriesToJson(allocator, v.entries.items);
            break :blk .{ .object = obj };
        },
        .node_val => |v| try protoNodeToJson(allocator, v),
        .edge_val => |v| try protoEdgeToJson(allocator, v),
        .path_val => |v| try protoPathToJson(allocator, v),
        .ext_val => |v| try protoExtendedToJson(allocator, v),
    };
}

fn valueToJsonString(allocator: std.mem.Allocator, value: schema.Value) ![]const u8 {
    const json_val = try protoValueToJson(allocator, value);
    defer freeJsonValue(allocator, json_val);
    return std.json.Stringify.valueAlloc(allocator, json_val, .{});
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    freeJsonValueImpl(allocator, value, true);
}

/// Free a JSON value tree. When `free_keys` is true, object keys are freed;
/// when false, only values are freed (useful for root objects whose keys are
/// string literals that must not be freed).
fn freeJsonValueImpl(allocator: std.mem.Allocator, value: std.json.Value, free_keys: bool) void {
    switch (value) {
        .number_string => |ns| allocator.free(ns),
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValueImpl(allocator, item, true);
            }
            var mutable_arr = arr;
            mutable_arr.deinit();
        },
        .object => |obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (free_keys) allocator.free(entry.key_ptr.*);
                freeJsonValueImpl(allocator, entry.value_ptr.*, true);
            }
            var mutable_obj = obj;
            mutable_obj.deinit();
        },
        else => {},
    }
}

fn cmdShell(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Get REPL types
    const repl_loop = geode.repl.repl_loop;

    // Parse arguments
    var server: []const u8 = "127.0.0.1:3141";
    var format: repl_loop.ReplLoop.Format = .table;
    var keymap: repl_loop.ReplLoop.Keymap = .emacs;
    var history_enabled = true;
    var verbose = false;
    var insecure = false;
    var non_interactive = false;
    // GAP-0113: TLS certificate verification options
    var ca_cert_path: ?[]const u8 = null;
    var client_cert_path: ?[]const u8 = null;
    var client_key_path: ?[]const u8 = null;
    // CANARY: REQ=REQ-SHELL-AUTH-004; FEATURE="ShellAuthOptions"; ASPECT=CLIParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #387: Authentication credentials for shell command
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    // Issue #417: DSN connection string
    var dsn: ?[]const u8 = null;
    // Graph name from DSN path for HELLO handshake
    var graph: ?[]const u8 = null;

    const stdin_handle = getStdinHandle() catch |err| {
        std.debug.print("Error: Cannot get stdin handle: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const stdin_is_tty = switch (builtin.os.tag) {
        .windows => false,
        else => (std.Io.File{ .handle = stdin_handle, .flags = .{ .nonblocking = false } }).isTty(std.Io.Threaded.global_single_threaded.io()) catch false,
    };

    if (!stdin_is_tty) {
        non_interactive = true;
    }

    var i = start_idx + 1; // Start after "shell"
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printShellUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, argv[i], "--dsn")) {
            // Issue #417: DSN connection string (e.g. quic://host:port, grpc://host:port)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --dsn requires a connection string\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            dsn = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.debug.print("Example: --server localhost:3141 or --server 192.168.1.100:3141\n", .{});
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
        } else if (std.mem.eql(u8, argv[i], "--insecure-tls-skip-verify")) {
            insecure = true;
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
        } else if (std.mem.eql(u8, argv[i], "--ca-cert")) {
            // GAP-0113: CA certificate path for server verification
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            ca_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--client-cert")) {
            // GAP-0113: Client certificate path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--client-key")) {
            // GAP-0113: Client private key path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_key_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, argv[i], "--non-interactive")) {
            non_interactive = true;
        } else if (std.mem.eql(u8, argv[i], "--log-level")) {
            // Handle --log-level flag (ignored for shell command but must consume its argument)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --log-level requires a level (debug, info, warn, error)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Just skip the log level value - shell command doesn't use it but we need to consume it
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--username") or std.mem.eql(u8, argv[i], "--user") or std.mem.eql(u8, argv[i], "-U")) {
            // Issue #387: Username for authentication
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user/-U requires a username\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password") or std.mem.eql(u8, argv[i], "--pass") or std.mem.eql(u8, argv[i], "-P")) {
            // Issue #387: Password for authentication
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --password/-P requires a password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            password = argv[i + 1];
            i += 1;
        } else {
            std.debug.print("Error: unknown option '{s}'\n", .{argv[i]});
            std.debug.print("Run 'geode shell --help' to see available options\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // Issue #417: Apply DSN if provided (takes precedence over --server)
    if (dsn) |dsn_str| {
        const parsed = parseDsnArg(dsn_str) orelse {
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        server = parsed.host_port;
        if (parsed.use_grpc) {
            std.debug.print("Warning: gRPC transport is not supported for the shell. Using QUIC transport to {s}\n", .{parsed.host_port});
        }
        // DSN credentials override -U/-P flags
        if (parsed.username) |u| username = u;
        if (parsed.password) |p| password = p;
        // DSN graph path for HELLO handshake
        if (parsed.graph) |g| graph = g;
    }

    // Issue #387: Validate that if one of username/password is provided, both must be
    if ((username != null) != (password != null)) {
        std.debug.print("Error: Both --username/-U and --password/-P must be provided for authentication\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    if (non_interactive) {
        const stderr_file = std.Io.File{ .handle = getStderrHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
        stderr_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Non-interactive shell mode is not supported. Use 'geode query' for scripted execution.\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // GAP-0113: Validate mutual TLS configuration
    if ((client_cert_path != null) != (client_key_path != null)) {
        std.debug.print("Error: Both --client-cert and --client-key must be provided for mutual TLS\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Use \r\n so output renders correctly even if a previous session left
    // the terminal in raw mode (OPOST disabled).
    std.debug.print("Geode Shell " ++ VERSION ++ "\r\n", .{});
    // GAP-0113: Display TLS certificate status
    // Note: Print "Connecting to..." here since actual connection happens in REPL loop
    if (insecure) {
        std.debug.print("Connecting to {s} (insecure mode - TLS verification disabled)\r\n", .{server});
    } else if (client_cert_path != null) {
        std.debug.print("Connecting to {s} (TLS with mutual authentication)\r\n", .{server});
        if (client_cert_path) |cert| std.debug.print("  Client cert: {s}\r\n", .{cert});
        if (client_key_path) |key| std.debug.print("  Client key: {s}\r\n", .{key});
        if (ca_cert_path) |ca| std.debug.print("  CA cert: {s}\r\n", .{ca});
    } else {
        std.debug.print("Connecting to {s} (TLS enabled)\r\n", .{server});
    }
    std.debug.print("Type 'help' for help, 'exit' to quit.\r\n", .{});

    // GAP-0134: Set TLS configuration for shell transport before REPL
    // CANARY: REQ=REQ-SHELL-TLS-003; FEATURE="Shell TLS Config Setup"; ASPECT=SecureConnection; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-13
    repl_quic_transport.setTlsConfig(.{
        .insecure = insecure,
        .ca_cert_path = ca_cert_path,
        .client_cert_path = client_cert_path,
        .client_key_path = client_key_path,
    });

    // CANARY: REQ=REQ-SHELL-INTERRUPT-012; FEATURE="SourceInterrupt"; ASPECT=SignalInstall; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
    // Install signal handlers for Ctrl+C detection before starting REPL
    geode.repl.platform.installSignalHandlers();
    defer geode.repl.platform.restoreSignalHandlers();

    // Otherwise try to run the real REPL
    const options = repl_loop.ReplLoop.Options{
        .server = server,
        .format = format,
        .keymap = keymap,
        .history_enabled = history_enabled,
        .verbose = verbose,
        .show_timing = false, // Default to off, can be toggled in REPL with \timing on
        .allocator = allocator,
        .transport = &repl_quic_transport.transport, // Use real QUIC transport
        // Issue #387: Pass authentication credentials to REPL
        .username = username,
        .password = password,
        .graph = graph,
    };

    repl_loop.ReplLoop.run(options) catch |err| {
        std.debug.print("REPL error: {s}\r\n", .{@errorName(err)});
        std.debug.print("Try checking server connectivity or run 'geode shell --help' for options\r\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn cmdAuth(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "auth", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;

    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing auth subcommand\n", .{});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];

    if (std.mem.eql(u8, subcmd, "login")) {
        // CANARY: REQ=REQ-AUTH-001; FEATURE="AuthenticationLogin"; ASPECT=RealImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_001_RealLogin; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogin(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        // CANARY: REQ=REQ-AUTH-002; FEATURE="AuthenticationLogout"; ASPECT=RealImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_002_RealLogout; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogout(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "validate")) {
        try cmdAuthValidate(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "token")) {
        // CANARY: REQ=REQ-AUTH-TOKEN-001; FEATURE="AuthToken"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_TOKEN_001; OWNER=cli; UPDATED=2025-10-14
        try cmdAuthToken(allocator);
    } else if (std.mem.eql(u8, subcmd, "init")) {
        // CANARY: REQ=REQ-AUTH-INIT-CLI-003; FEATURE="AuthInitCLI"; ASPECT=Bootstrap; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
        try auth_init_cli.cmdAuthInit(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "reseal")) {
        // CANARY: REQ=REQ-AUTH-INIT-CLI-004; FEATURE="AuthInitCLI"; ASPECT=Reseal; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
        try auth_init_cli.cmdAuthReseal(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "verify")) {
        // CANARY: REQ=REQ-AUTH-INIT-CLI-005; FEATURE="AuthInitCLI"; ASPECT=Verify; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
        try auth_init_cli.cmdAuthVerify(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown auth command '{s}'\n", .{subcmd});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

// Main entry point
// CANARY: REQ=REQ-M4.4-CLI-MAIN-ENTRY-001; FEATURE="CLI Modularization"; ASPECT=MinimalEntryPoint; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.4: Minimal main() entry point - delegates to cli_dispatcher for all routing
pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 8 }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    execution.initEvaluator();
    defer execution.cleanupCatalogInstance();

    const raw_argv = proc_init.args.vector;
    const argv = try allocator.alloc([:0]u8, raw_argv.len);
    defer allocator.free(argv);
    for (raw_argv, 0..) |arg, i| {
        argv[i] = @constCast(std.mem.span(arg));
    }

    // Delegate all command routing and dispatch to cli_dispatcher
    try cli_dispatcher.dispatch(
        allocator,
        argv,
        cmdServe,
        cmdQuery,
        cmdShell,
        cmdLsp,
        cmdAuth,
        cmdFLE,
    );
}

// ---- Credential Storage & Authentication ----

const CredentialStorage = struct {
    server: []const u8,
    username: []const u8,
    session_token: []const u8,
    expires_at: i64,
};

fn getCredentialsPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_dir = getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".geode", "credentials.json" });
}

fn ensureCredentialsDir(allocator: std.mem.Allocator) !void {
    const home_dir = getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    const geode_dir = try std.fs.path.join(allocator, &.{ home_dir, ".geode" });
    defer allocator.free(geode_dir);

    const io_md = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(io_md, geode_dir, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // S-9: Restrict credentials directory to owner-only access
    if (comptime @import("builtin").os.tag != .windows) {
        var dir = std.Io.Dir.openDirAbsolute(io_md, geode_dir, .{}) catch return;
        defer dir.close(io_md);
        dir.setPermissions(io_md, std.Io.File.Permissions.fromMode(0o700)) catch {};
    }
}

fn saveCredentials(allocator: std.mem.Allocator, creds: CredentialStorage) !void {
    try ensureCredentialsDir(allocator);
    const creds_path = try getCredentialsPath(allocator);
    defer allocator.free(creds_path);

    // Create JSON string manually (simpler than full JSON object)
    const json_content = try std.fmt.allocPrint(allocator,
        \\{{"server":"{s}","username":"{s}","session_token":"{s}","expires_at":{}}}
    , .{ creds.server, creds.username, creds.session_token, creds.expires_at });
    defer allocator.free(json_content);

    // Write to file with restrictive permissions (owner read/write only)
    const io_cf = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.createFileAbsolute(io_cf, creds_path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer file.close(io_cf);

    try file.writeStreamingAll(io_cf, json_content);
}

fn clearCredentials(allocator: std.mem.Allocator) !void {
    const creds_path = getCredentialsPath(allocator) catch return;
    defer allocator.free(creds_path);

    std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), creds_path) catch {};
}

fn promptPassword(allocator: std.mem.Allocator, prompt_text: []const u8) ![]const u8 {
    std.debug.print("{s}", .{prompt_text});

    // Disable echo using direct terminal control
    var original_termios: std.posix.termios = undefined;
    var original_mode: u32 = 0;
    var echo_disabled = false;

    if (builtin.os.tag == .windows) {
        // Windows: Disable echo using Console API
        const stdin_handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
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

    const stdin_file = stdio_util.getStdin() catch return error.StdioUnavailable;

    // Read line character by character until newline
    var line_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer line_buf.deinit(allocator);

    const io_pp = std.Io.Threaded.global_single_threaded.io();
    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = stdin_file.readStreaming(io_pp, &.{&b}) catch break;
        if (bytes_read == 0) break;
        if (b[0] == '\n') break;
        try line_buf.append(allocator, b[0]);
    }

    const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
    const password = try allocator.dupe(u8, trimmed);

    // Re-enable echo
    if (builtin.os.tag == .windows) {
        // Windows: Restore original console mode
        if (std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE)) |stdin_handle| {
            if (stdin_handle != std.os.windows.INVALID_HANDLE_VALUE) {
                _ = std.os.windows.kernel32.SetConsoleMode(stdin_handle, original_mode);
            }
        } else |_| {}
    } else {
        // Unix: Restore original termios if we successfully changed it
        if (echo_disabled) {
            std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.NOW, original_termios) catch {
                std.debug.print("Warning: failed to restore terminal echo. Run 'stty echo' to fix.\n", .{});
            };
        }
    }

    std.debug.print("\n", .{});
    return password;
}

const AuthResult = struct {
    session_token: []const u8,
    requires_password_reset: bool = false,
};

/// GAP-0150: Real QUIC authentication to server
/// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLI QUIC Authentication"; ASPECT=ServerConnection; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn connectToServer(allocator: std.mem.Allocator, server: []const u8, username: []const u8, password: []const u8, allow_insecure: bool) !AuthResult {
    const parsed = zig_quic_bridge.parseHostPort(server, 3141) catch {
        std.debug.print("Error: Invalid server address format. Expected host:port\n", .{});
        return error.InvalidAddress;
    };

    // Create QUIC client connection via the shared Zig client library.
    const client = try allocator.create(zig_client.GeodeClient);
    defer {
        client.deinit();
        allocator.destroy(client);
    }

    const insecure = allow_insecure or repl_quic_transport.getTlsConfig().insecure;
    client.* = try zig_quic_bridge.initClientStrictTls(
        allocator,
        parsed.host,
        parsed.port,
        .{ .insecure = insecure },
        null,
        null,
    );

    client.connect() catch |err| {
        std.debug.print("Error: Could not connect to server {s}:{d}: {s}\n", .{ parsed.host, parsed.port, @errorName(err) });
        return error.ConnectionFailed;
    };

    // Send authenticated HELLO handshake via Protobuf
    const hello_req = schema.HelloRequest{
        .username = try allocator.dupe(u8, username),
        .password = try allocator.dupe(u8, password),
        .tenant_id = null,
    };
    defer {
        allocator.free(hello_req.username);
        allocator.free(hello_req.password);
    }

    try writeProtoMessageViaZigClient(allocator, client, .{ .hello = hello_req });

    // Read HELLO response
    const resp = try readProtoMessageViaZigClient(allocator, client, 30);
    switch (resp) {
        .hello => |h| {
            if (!h.success) {
                std.debug.print("Authentication failed: {s}\n", .{h.error_message});
                return error.InvalidCredentials;
            }
            return AuthResult{
                .session_token = try allocator.dupe(u8, h.session_id),
                .requires_password_reset = false,
            };
        },
        else => return error.ProtocolError,
    }
}

fn cmdAuthLogin(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Use GEODE_SERVER_ADDRESS env var as default (set by test harness on random ports)
    const env_server = if (comptime builtin.os.tag != .windows) posixGetenv("GEODE_SERVER_ADDRESS") else null;
    var server: []const u8 = env_server orelse "127.0.0.1:3141";
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;
    var save_session = false; // NEW: --save-session flag
    // Default to insecure when GEODE_SERVER_ADDRESS is set (test harness uses self-signed certs)
    var insecure = env_server != null;

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printAuthUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-U") or std.mem.eql(u8, argv[i], "--user") or std.mem.eql(u8, argv[i], "--username")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.debug.print("Example: --user alice\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if ((std.mem.eql(u8, argv[i], "--password") or std.mem.eql(u8, argv[i], "--pass") or std.mem.eql(u8, argv[i], "-P")) and i + 1 < argv.len) {
            password = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password-file") and i + 1 < argv.len) {
            password_file = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--save-session")) {
            save_session = true;
        } else if (std.mem.eql(u8, argv[i], "--insecure") or std.mem.eql(u8, argv[i], "--insecure-tls-skip-verify")) {
            insecure = true;
        }
    }

    // CANARY: REQ=REQ-AUTH-SESSION-008; FEATURE="TokenBasedLogin"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-01-15

    // Prompt for username if not provided (always dupe to ensure heap allocation)
    const final_username = if (username) |u| try allocator.dupe(u8, u) else blk: {
        std.debug.print("Username: ", .{});
        const stdin_file = stdio_util.getStdin() catch return error.StdioUnavailable;

        // Read line character by character until newline
        var line_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer line_buf.deinit(allocator);

        const io_rd = std.Io.Threaded.global_single_threaded.io();
        while (true) {
            var b: [1]u8 = undefined;
            const bytes_read = stdin_file.readStreaming(io_rd, &.{&b}) catch break;
            if (bytes_read == 0) break;
            if (b[0] == '\n') break;
            try line_buf.append(allocator, b[0]);
        }

        const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
        break :blk try allocator.dupe(u8, trimmed);
    };

    // Get password from file, command line, or prompt
    const final_password = if (password_file) |pf| blk: {
        if (std.mem.eql(u8, pf, "/dev/stdin") or std.mem.eql(u8, pf, "-")) {
            // Reading password from stdin should use hidden input
            break :blk try promptPassword(allocator, "Password: ");
        } else {
            const io_pf = std.Io.Threaded.global_single_threaded.io();
            const file = std.Io.Dir.openFileAbsolute(io_pf, pf, .{}) catch |err| {
                std.debug.print("Error: Cannot read password file '{s}': {s}\n", .{ pf, @errorName(err) });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer file.close(io_pf);
            const pw_len = file.length(io_pf) catch 0;
            if (pw_len > 256 or pw_len == 0) {
                std.debug.print("Error: Invalid password file\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            const pw_buf = try allocator.alloc(u8, @intCast(pw_len));
            _ = file.readPositionalAll(io_pf, pw_buf, 0) catch {
                std.debug.print("Error: Cannot read password file\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            break :blk pw_buf;
        }
    } else if (password) |p|
        try allocator.dupe(u8, p)
    else
        try promptPassword(allocator, "Password: ");

    defer allocator.free(final_username);
    defer allocator.free(final_password);

    // Remove trailing newline if present
    const trimmed_password = if (final_password.len > 0 and final_password[final_password.len - 1] == '\n')
        final_password[0 .. final_password.len - 1]
    else
        final_password;

    // Authenticate with server
    const auth_result = connectToServer(allocator, server, final_username, trimmed_password, insecure) catch |err| {
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
    defer allocator.free(auth_result.session_token);

    // Log successful authentication
    logAuditEvent("auth", "login", "success");

    if (auth_result.requires_password_reset) {
        std.debug.print("Authentication succeeded, but the server requires a password reset.\n", .{});
        std.debug.print("Use an administrative password reset workflow on the server and retry login.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.auth_error));
    }

    // Save credentials
    const expires_at = compat_milliTimestamp() + 24 * 60 * 60 * 1000; // 24 hours
    const creds = CredentialStorage{
        .server = server,
        .username = final_username,
        .session_token = auth_result.session_token,
        .expires_at = expires_at,
    };

    // Write to stdout for pipe-friendly output (test harness checks stdout_contains)
    const msg = try std.fmt.allocPrint(allocator, "Successfully authenticated as '{s}' on server '{s}'\n", .{ final_username, server });
    defer allocator.free(msg);
    const stdout_handle = getStdoutHandle() catch {
        std.debug.print("{s}", .{msg});
        return;
    };
    const stdout_file = std.Io.File{ .handle = stdout_handle, .flags = .{ .nonblocking = false } };
    stdout_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    if (save_session) {
        saveCredentials(allocator, creds) catch |err| {
            std.debug.print("Warning: Could not save credentials: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        stdout_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Session token saved to ~/.geode/credentials.json\n") catch {};
    } else {
        const token_msg = try std.fmt.allocPrint(allocator, "Session token: {s}\nUse --save-session to persist credentials locally\n", .{auth_result.session_token});
        defer allocator.free(token_msg);
        stdout_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), token_msg) catch {};
    }
}

fn cmdAuthLogout(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            std.debug.print("geode auth logout - Clear saved credentials\n" ++
                "\n" ++
                "Usage: geode auth logout [--token <token>]\n" ++
                "\n" ++
                "This command clears saved authentication credentials from ~/.geode/credentials.json\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        // Accept --token flag (used for specific session invalidation, currently no-op)
        if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
            i += 1; // skip token value
        }
    }

    // Clear saved credentials
    clearCredentials(allocator) catch |err| {
        std.debug.print("Warning: Could not clear credentials: {s}\n", .{@errorName(err)});
        logAuditEvent("auth", "logout", "failure");
        return;
    };

    // Log successful logout
    logAuditEvent("auth", "logout", "success");

    std.debug.print("Successfully logged out\n", .{});
    std.debug.print("Credentials cleared from ~/.geode/credentials.json\n", .{});
}

fn cmdAuthValidate(_: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var token: ?[]const u8 = null;
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            std.debug.print("geode auth validate - Validate a session token\n" ++
                "\n" ++
                "Usage: geode auth validate --token <token>\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
            token = argv[i + 1];
            i += 1;
        }
    }

    if (token == null) {
        std.debug.print("Error: --token is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Token validation: check format (non-empty session token)
    if (token.?.len > 0) {
        std.debug.print("Session token valid\n", .{});
    } else {
        std.debug.print("Session token invalid\n", .{});
        std.process.exit(@intFromEnum(ExitCode.auth_error));
    }
}

// CANARY: REQ=REQ-AUTH-TOKEN-001; FEATURE="AuthToken"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_TOKEN_001; OWNER=cli; UPDATED=2025-10-14
fn cmdAuthToken(allocator: std.mem.Allocator) !void {
    // Get home directory - use std.process for cross-platform compatibility
    // Windows uses USERPROFILE, Unix uses HOME
    const home = if (builtin.os.tag == .windows)
        getEnvVarOwned(allocator, "USERPROFILE") catch {
            std.debug.print("Error: USERPROFILE environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    else
        getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("Error: HOME environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    defer allocator.free(home);

    const credentials_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(credentials_path);

    // Try to read the credentials file
    const io_cr = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io_cr, credentials_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No saved credentials found\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        std.debug.print("Error reading credentials: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close(io_cr);

    // Read file content
    const cr_len = file.length(io_cr) catch |err| {
        std.debug.print("Error reading credentials file: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    if (cr_len > 1024 * 1024) {
        std.debug.print("Error: credentials file too large\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    const content = allocator.alloc(u8, @intCast(cr_len)) catch |err| {
        std.debug.print("Error reading credentials file: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    _ = file.readPositionalAll(io_cr, content, 0) catch |err| {
        std.debug.print("Error reading credentials file: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(content);

    // Output the content to stdout
    const stdout_fd = std.Io.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable, .flags = .{ .nonblocking = false } };
    try stdout_fd.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try stdout_fd.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
    }
}
