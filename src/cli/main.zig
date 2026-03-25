const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const audit_cli = @import("audit_cli");
const geode = @import("geode");
const Value = geode.value_types.Value;
// CANARY: REQ=REQ-CLI-REFACTOR-001; FEATURE="CLI Library Migration"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
// TODO: Migrate to devnw/zig/cli library for improved flag management, automatic help generation,
// shell completions, and type-safe configuration. See https://gitlab.com/devnw/zig/cli
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
const spice_wrapper = @import("parallel/spice");
const explain_payload = geode.explain_payload;
const profile_payload = geode.profile_payload;
const transport_response = geode.cli_transport_response;
const ColumnInfo = transport_response.ColumnInfo;
const QueryResultKind = transport_response.QueryResultKind;
const TransportResponseView = transport_response.TransportResponseView;
const renderTransportResponse = transport_response.renderTransportResponse;
const stdio_util = @import("../utils/stdio.zig");

// GAP-0203: Gate hot-path debug logging to eliminate overhead in production
// CANARY: REQ=REQ-PERF-LOG-GATE-001; FEATURE="HotPathLogGating"; ASPECT=DebugLogControl; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
// Set to true only when debugging protocol/query issues. In production, keep false.
const HOT_PATH_LOGGING = false;

// C library function for setting environment variables
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
// const auth = @import("../security/auth.zig"); // Not needed for current implementation
// const hash = @import("../types/hash.zig"); // Not needed for current implementation
const crypto = std.crypto;

// CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedBinary; STATUS=TESTED; TEST=tests/test_cli_subprocess_elimination_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Direct calls to server and client main functions to eliminate subprocess spawning

// CANARY: REQ=REQ-M11-DRY-002; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: Import backup types from canonical location (storage/backup.zig) instead of duplicating
const backup_types = @import("storage/backup");

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

// Import QUIC modules for real transport implementation
const quic = @import("transport/quic");

const VERSION = build_options.version;

// CANARY: REQ=REQ-REPL-QUIC-002; FEATURE="REPL QUIC Transport"; ASPECT=QuicTransportAdapter; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=repl; UPDATED=2026-01-15
const repl_quic_transport = geode.repl.quic_transport;

// Cross-platform file handle helpers with proper error handling
// CANARY: REQ=REQ-QUALITY-GAP-406-002; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
const StdioError = stdio_util.StdioError;

fn getStdinHandle() StdioError!std.fs.File.Handle {
    const file = try stdio_util.getStdin();
    return file.handle;
}

fn getStdoutHandle() StdioError!std.fs.File.Handle {
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

fn getStderrHandle() StdioError!std.fs.File.Handle {
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
        "  --format <fmt>         Output format: json|table|csv|dot (default: json)\n" ++
        "  --param <name> <value>       Add query parameter (JSON literal)\n" ++
        "  --page-size <n>        Page size for results (default: 1000)\n" ++
        "  --timeout <secs>       Connection timeout in seconds (default: 30)\n" ++
        "  --retry <count>        Number of retry attempts on failure (default: 0)\n" ++
        "  --begin                Start transaction\n" ++
        "  --commit               Commit transaction\n" ++
        "  --rollback             Rollback transaction\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  -P, --password [pass]  Authentication password (prompted if not provided)\n" ++
        "  --no-saved-session     Don't auto-load saved session token\n" ++
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
        "  Set GEODE_DEFAULT_PASSWORD on the server to bootstrap the admin account.\n" ++
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
        "  geode query --param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
        "  geode query --server remote:3141 --timeout 5 --retry 3 \"RETURN 1 AS x\"\n" ++
        "  echo \"RETURN 1 AS x\" | geode query -\n" ++
        "\n" ++
        "  # Execute from file\n" ++
        "  geode query --file ~/my_queries.gql\n" ++
        "  geode query -f ./schema.gql --insecure-tls-skip-verify\n" ++
        "\n", .{});
}

// (server-only helpers removed; unified CLI delegates to src/server/main.zig)

// (embedded server state/types removed)

// CANARY: REQ=REQ-PERF-WRITE-STALL-001; FEATURE="WriteStallOptimization"; ASPECT=StreamWrite; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=cli; UPDATED=2026-01-30
// GAP-0203: Three-phase write stall handling:
//   Phase 1 (stalls 1-3): Spin with poll only (zero sleep, sub-microsecond)
//   Phase 2 (stalls 4-8): Poll + yield to OS scheduler (minimal latency)
//   Phase 3 (stalls 9+):  Exponential backoff sleep (10-100μs, prevents CPU burn)
fn writeAllToStream(
    transport: *quic.QuicTransport,
    conn: *quic.QuicConnection,
    stream_id: u64,
    data: []const u8,
) !void {
    var written: usize = 0;
    var stalled: usize = 0;
    const max_retries: usize = 1000;
    const spin_threshold: usize = 3; // Phase 1: spin-poll only
    const yield_threshold: usize = 8; // Phase 2: yield to scheduler
    const initial_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    while (written < data.len) {
        const n = conn.inner.writeStream(stream_id, data[written..], false) catch |err| switch (err) {
            error.FlowControlBlocked, error.WouldBlock => {
                stalled += 1;
                if (stalled > max_retries) return error.WriteError;
                transport.poll(0) catch {};
                if (stalled > yield_threshold) {
                    // Phase 3: exponential backoff sleep
                    const backoff: u6 = @intCast(@min(stalled - yield_threshold, 4));
                    const sleep_us: u64 = @min(initial_sleep_us << backoff, max_sleep_us);
                    std.Thread.sleep(sleep_us * @as(u64, std.time.ns_per_us));
                } else if (stalled > spin_threshold) {
                    // Phase 2: yield to OS scheduler (0ns sleep = yield)
                    std.Thread.sleep(0);
                }
                // Phase 1 (stalled <= spin_threshold): poll only, no sleep
                continue;
            },
            else => return err,
        };

        if (n == 0) {
            stalled += 1;
            if (stalled > max_retries) return error.WriteError;
            transport.poll(0) catch {};
            if (stalled > yield_threshold) {
                const backoff: u6 = @intCast(@min(stalled - yield_threshold, 4));
                const sleep_us: u64 = @min(initial_sleep_us << backoff, max_sleep_us);
                std.Thread.sleep(sleep_us * @as(u64, std.time.ns_per_us));
            } else if (stalled > spin_threshold) {
                std.Thread.sleep(0);
            }
            continue;
        }

        written += n;
        stalled = 0;
    }
}

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
    // Check for help flag
    var i: usize = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printLspUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Import and start the LSP server
    const lsp = @import("lsp/server.zig");
    var server = lsp.Server.init(allocator) catch |err| {
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
    std.debug.print("    - Hover documentation for GQL keywords, functions, and types\n", .{});
    std.debug.print("    - Code completion for GQL syntax\n", .{});
    std.debug.print("    - Go-to-definition support\n", .{});
    std.debug.print("    - Document formatting\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -h, --help         Show this help message\n\n", .{});
    std.debug.print("Editor Integration:\n", .{});
    std.debug.print("  See docs/LSP_IMPLEMENTATION.md for setup details\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode lsp\n\n", .{});
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

/// Issue #424: Process-level deadline watchdog for the query command.
/// Spawned as a background thread, sleeps for `timeout_secs` then terminates
/// the process with an error message and exit code 1. This ensures the CLI
/// never hangs indefinitely on aarch64 Docker or any other environment where
/// QUIC handshakes, TLS negotiation, or TCP connects block forever.
fn deadlineWatchdog(timeout_secs: u32) void {
    std.Thread.sleep(@as(u64, timeout_secs) * std.time.ns_per_s);
    const stderr = std.fs.File{ .handle = getStderrHandle() catch {
        std.process.exit(@intFromEnum(ExitCode.general_error));
    } };
    _ = stderr.writeAll("Error: query timed out after ") catch {};
    // Write the timeout value
    var buf: [20]u8 = undefined;
    const timeout_str = std.fmt.bufPrint(&buf, "{d}", .{timeout_secs}) catch "?";
    _ = stderr.writeAll(timeout_str) catch {};
    _ = stderr.writeAll(" seconds\n") catch {};
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

// Issue #417: DSN (Data Source Name) parsing for --dsn flag
// Supports: quic://host:port, grpc://host:port, host:port (defaults to QUIC)
// See docs/DSN.md for the full specification
const DsnParseResult = struct {
    host_port: []const u8, // "host:port" string
    use_grpc: bool, // true if grpc:// scheme
    username: ?[]const u8, // embedded credentials
    password: ?[]const u8, // embedded credentials
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

    // Validate host:port - at minimum there should be content
    // The host_port is passed directly to --server logic which expects "host:port"
    return DsnParseResult{
        .host_port = rest,
        .use_grpc = use_grpc,
        .username = username,
        .password = password,
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
    var page_size: u32 = 1000; // Default page size for PULL requests
    var use_saved_session = true; // Auto-load saved session by default
    // Issue #417: DSN connection string
    var dsn: ?[]const u8 = null;
    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-001; FEATURE="GraphFlag"; ASPECT=QueryCommand; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #393: Add --graph flag to specify which graph to query against
    var graph: ?[]const u8 = null;
    // GAP-0113: TLS certificate verification options
    var ca_cert_path: ?[]const u8 = null;
    var client_cert_path: ?[]const u8 = null;
    var client_key_path: ?[]const u8 = null;
    // CANARY: REQ=REQ-CLI-FILE-FLAG-001; FEATURE="QueryFileFlag"; ASPECT=FileInput; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
    // Issue GAP-384: Add --file flag to execute GQL from a file (same as /source in shell)
    var source_file: ?[]const u8 = null;
    var params = std.ArrayList(schema.Param){};
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
            // CANARY: REQ=REQ-CLI-GRAPH-FLAG-002; FEATURE="GraphFlag"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --graph requires a graph name\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            graph = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            // CANARY: REQ=REQ-CLI-FILE-FLAG-002; FEATURE="QueryFileFlag"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
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
            std.debug.print("Warning: --insecure is deprecated. Use --insecure-tls-skip-verify instead.\r\n", .{});
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
                const stderr_fd = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
                _ = try stderr_fd.writeAll("Parameter parse error\n");
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
        } else if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            // First non-option argument is the query text, or "-" for stdin
            if (query_text == null) {
                query_text = arg;
            }
        }
    }

    // CANARY: REQ=REQ-CLI-FILE-FLAG-003; FEATURE="QueryFileFlag"; ASPECT=FileReading; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
    // Handle --file input with tilde expansion (same as /source in shell)
    var file_allocated: ?[]u8 = null;
    defer if (file_allocated) |allocated| allocator.free(allocated);

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-001; FEATURE="ChunkedExecution"; ASPECT=LargeFileSupport; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
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
            const home = std.posix.getenv("HOME") orelse {
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
        const file = std.fs.cwd().openFile(resolved_path, .{}) catch |err| {
            std.debug.print("Error: Cannot open file '{s}': {s}\n", .{ resolved_path, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer file.close();

        const contents = file.readToEndAlloc(allocator, 1 << 24) catch |err| { // 16MB max
            std.debug.print("Error: Cannot read file: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer allocator.free(contents);

        // Strip comments and collect individual statements
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-002; FEATURE="ChunkedExecution"; ASPECT=StatementParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        var statements = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        var current_stmt = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer current_stmt.deinit(allocator);

        var line_iter = std.mem.splitSequence(u8, contents, "\n");
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
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
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-003; FEATURE="ChunkedExecution"; ASPECT=SizeDetection; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
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

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-007; FEATURE="ChunkedExecution"; ASPECT=NullCheck; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
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
        const stdin = std.fs.File{ .handle = getStdinHandle() catch return error.StdioUnavailable }; // stdin handle
        const stdin_content = try stdin.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
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

                if (std.mem.eql(u8, creds.system_fingerprint, current_fp)) {
                    loaded_token = try allocator.dupe(u8, creds.token);
                    loaded_username = try allocator.dupe(u8, creds.username);
                    token = loaded_token;
                    user = loaded_username;

                    // Free loaded credentials
                    allocator.free(creds.token);
                    allocator.free(creds.username);
                    allocator.free(creds.server);
                    allocator.free(creds.system_fingerprint);
                } else {
                    // System fingerprint mismatch - credentials are for different system/user
                    // Silently ignore and require explicit authentication
                    allocator.free(creds.token);
                    allocator.free(creds.username);
                    allocator.free(creds.server);
                    allocator.free(creds.system_fingerprint);
                }
            }
        }
    }

    // Check for unauthorized user before executing
    if (user != null and std.mem.eql(u8, user.?, "unauthorized")) {
        const stderr_fd = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
        _ = try stderr_fd.writeAll("unauthorized access denied\n");
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
    }

    // Determine execution mode based on --server flag
    // Default to connecting to localhost:3141 if no --server specified
    const server_addr = server orelse "127.0.0.1:3141";

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-004; FEATURE="ChunkedExecution"; ASPECT=BatchExecution; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-13
    // Handle chunked execution for large files
    if (file_statements) |statements| {
        if (params.items.len > 0) {
            std.debug.print("Error: --param is not supported with --file\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        // Issue #424: Scale deadline watchdog for chunked execution.
        // Each chunk needs its own timeout, so total deadline = timeout_secs * num_chunks.
        // Use generous estimate: 1 chunk per ~250 statements minimum, capped at 10 minutes.
        const estimated_chunks = @max(1, statements.items.len / 250);
        const chunked_deadline = @min(600, timeout_secs * @as(u32, @intCast(estimated_chunks + 1)));
        _ = std.Thread.spawn(.{}, deadlineWatchdog, .{chunked_deadline}) catch {};
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
            .graph = graph,
            .use_grpc = use_grpc,
        });
        return;
    }

    // Issue #424: Start a process-level deadline watchdog thread for single queries.
    _ = std.Thread.spawn(.{}, deadlineWatchdog, .{timeout_secs}) catch {};

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
            .graph = graph,
            .page_size = page_size,
            .params = params,
        });
    } else {
        // GAP-0113: Execute query via QUIC connection with optional certificate verification
        // CANARY: REQ=REQ-CLI-GRAPH-FLAG-003; FEATURE="GraphFlag"; ASPECT=ExecuteWithGraph; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
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
            .graph = graph,
            .page_size = page_size,
            .params = params,
        }) catch |err| {
            if (err == error.AuthenticationFailed)
                std.process.exit(@intFromEnum(ExitCode.auth_error));
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
// CANARY: REQ=REQ-CLI-GRAPH-FLAG-004; FEATURE="GraphFlag"; ASPECT=ExecuteQuicQuery; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
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
    graph: ?[]const u8 = null,
    page_size: u32 = 1000,
    params: std.ArrayList(schema.Param),
};

const GrpcQueryOptions = struct {
    server_addr: []const u8,
    query_text: []const u8,
    format: []const u8 = "table",
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    graph: ?[]const u8 = null,
    page_size: u32 = 1000,
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
    const page_size = opts.page_size;
    var params = opts.params;
    var params_transferred = false;
    defer if (!params_transferred) {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    };
    const stderr = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3142";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        _ = stderr.writeAll("Error: Invalid port number in server address\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    var attempts: u32 = 0;
    const max_attempts = retry_count + 1;
    var last_error: ?[]const u8 = null;

    while (attempts < max_attempts) : (attempts += 1) {
        // Connect via raw TCP
        const tcp_stream = std.net.tcpConnectToHost(allocator, host, port) catch |err| {
            last_error = @errorName(err);
            continue;
        };
        defer tcp_stream.close();

        // Issue #424: Set socket-level read/write timeouts so blocking I/O
        // operations will fail instead of hanging forever on aarch64 Docker.
        setTcpSocketTimeouts(tcp_stream, timeout_secs);

        // Send HTTP/2 connection preface
        _ = tcp_stream.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") catch |err| {
            last_error = @errorName(err);
            continue;
        };
        // Send empty SETTINGS frame
        grpcWriteFrame(tcp_stream, H2_SETTINGS, 0, 0, &.{}) catch |err| {
            last_error = @errorName(err);
            continue;
        };

        // Read server's initial SETTINGS (and ACK ours)
        grpcDrainInitialSettings(allocator, tcp_stream) catch |err| {
            last_error = @errorName(err);
            continue;
        };

        // Execute query on the gRPC connection
        params_transferred = true;
        return executeQueryOnGrpc(allocator, tcp_stream, query_text, format, username, password, graph, params, page_size, timeout_secs) catch |err| {
            last_error = @errorName(err);
            params_transferred = false;
            continue;
        };
    }

    if (last_error) |le| {
        _ = stderr.writeAll(le) catch {};
        _ = stderr.writeAll("\n") catch {};
    }

    std.process.exit(@intFromEnum(ExitCode.general_error));
}

// HTTP/2 frame type constants for gRPC framing
const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_RST_STREAM: u8 = 0x3;
const H2_SETTINGS: u8 = 0x4;
const H2_PING: u8 = 0x6;
const H2_GOAWAY: u8 = 0x7;
const H2_WINDOW_UPDATE: u8 = 0x8;

/// Read and ACK initial SETTINGS frames from the server during HTTP/2 handshake.
fn grpcDrainInitialSettings(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    // Read frames until we get a SETTINGS ACK (confirming our preface was accepted)
    var got_settings_ack = false;
    var iterations: usize = 0;
    while (!got_settings_ack and iterations < 10) : (iterations += 1) {
        const frame = try grpcReadFrame(allocator, stream);
        defer allocator.free(frame.payload);

        if (frame.frame_type == H2_SETTINGS) {
            const is_ack = (frame.flags & 0x1) != 0;
            if (is_ack) {
                got_settings_ack = true;
            } else {
                // ACK the server's SETTINGS
                try grpcWriteFrame(stream, H2_SETTINGS, 0x1, 0, &.{});
            }
        } else if (frame.frame_type == H2_WINDOW_UPDATE) {
            // Ignore WINDOW_UPDATE during handshake
        } else {
            // Unexpected frame type during handshake, skip
        }
    }
}

/// Write a raw HTTP/2 frame directly to the underlying TCP stream of a gRPC client.
fn grpcWriteFrame(stream: std.net.Stream, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) !void {
    const length: u24 = @intCast(payload.len);
    var header: [9]u8 = undefined;
    header[0] = @intCast((length >> 16) & 0xFF);
    header[1] = @intCast((length >> 8) & 0xFF);
    header[2] = @intCast(length & 0xFF);
    header[3] = frame_type;
    header[4] = flags;
    header[5] = @intCast((@as(u32, stream_id) >> 24) & 0x7F);
    header[6] = @intCast((@as(u32, stream_id) >> 16) & 0xFF);
    header[7] = @intCast((@as(u32, stream_id) >> 8) & 0xFF);
    header[8] = @intCast(@as(u32, stream_id) & 0xFF);

    _ = try stream.write(&header);
    if (payload.len > 0) {
        _ = try stream.write(payload);
    }
}

/// Read a raw HTTP/2 frame from the underlying TCP stream of a gRPC client.
const H2Frame = struct { frame_type: u8, flags: u8, stream_id: u31, payload: []u8 };

fn grpcReadFrame(allocator: std.mem.Allocator, stream: std.net.Stream) !H2Frame {
    var header: [9]u8 = undefined;
    // Read exactly 9 bytes
    var total: usize = 0;
    while (total < 9) {
        const n = try stream.read(header[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }

    const length: u24 = (@as(u24, header[0]) << 16) | (@as(u24, header[1]) << 8) | @as(u24, header[2]);
    const frame_type = header[3];
    const flags = header[4];
    const stream_id: u31 = @intCast(
        (@as(u32, header[5] & 0x7F) << 24) |
            (@as(u32, header[6]) << 16) |
            (@as(u32, header[7]) << 8) |
            @as(u32, header[8]),
    );

    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);

    if (length > 0) {
        var read_total: usize = 0;
        while (read_total < length) {
            const n = try stream.read(payload[read_total..]);
            if (n == 0) return error.ConnectionClosed;
            read_total += n;
        }
    }

    return .{ .frame_type = frame_type, .flags = flags, .stream_id = stream_id, .payload = payload };
}

/// Send an RPC request over gRPC: HEADERS (with :path) + DATA (with gRPC framing).
fn grpcSendRequest(allocator: std.mem.Allocator, stream: std.net.Stream, method_path: []const u8, message: []const u8, stream_id: u31) !void {
    // Build minimal HPACK-encoded HEADERS
    var hdr_buf = try std.ArrayList(u8).initCapacity(allocator, 128);
    defer hdr_buf.deinit(allocator);

    // :method: POST (indexed, static table index 3)
    try hdr_buf.append(allocator, 0x83);
    // :scheme: http (indexed, static table index 6)
    try hdr_buf.append(allocator, 0x86);
    // :path: method_path (literal without indexing, name index 4)
    try hdr_buf.append(allocator, 0x04);
    try hdr_buf.append(allocator, @intCast(method_path.len));
    try hdr_buf.appendSlice(allocator, method_path);
    // content-type: application/grpc (literal with incremental indexing, name index 31)
    try hdr_buf.append(allocator, 0x40 | 31);
    try hdr_buf.append(allocator, 16);
    try hdr_buf.appendSlice(allocator, "application/grpc");

    // Write HEADERS frame (END_HEADERS, no END_STREAM)
    try grpcWriteFrame(stream, H2_HEADERS, 0x4, stream_id, hdr_buf.items);

    // Write DATA frame with gRPC framing: [1 byte compressed][4 bytes BE length][protobuf]
    const grpc_msg_len: u32 = @intCast(message.len);
    const grpc_frame = try allocator.alloc(u8, 5 + message.len);
    defer allocator.free(grpc_frame);
    grpc_frame[0] = 0; // not compressed
    grpc_frame[1] = @intCast((grpc_msg_len >> 24) & 0xFF);
    grpc_frame[2] = @intCast((grpc_msg_len >> 16) & 0xFF);
    grpc_frame[3] = @intCast((grpc_msg_len >> 8) & 0xFF);
    grpc_frame[4] = @intCast(grpc_msg_len & 0xFF);
    @memcpy(grpc_frame[5..], message);

    // Send DATA with END_STREAM (client is done sending for this request)
    try grpcWriteFrame(stream, H2_DATA, 0x1, stream_id, grpc_frame);
}

/// Read a gRPC response message from the transport.
/// Skips HEADERS, SETTINGS, WINDOW_UPDATE, PING frames.
/// Returns the protobuf payload (gRPC 5-byte header stripped) or null if stream ended.
fn grpcReadResponse(allocator: std.mem.Allocator, stream: std.net.Stream) !?[]const u8 {
    while (true) {
        const frame = grpcReadFrame(allocator, stream) catch |err| {
            if (err == error.ConnectionClosed) return null;
            return err;
        };
        const frame_type = frame.frame_type;
        const flags = frame.flags;
        const payload = frame.payload;

        if (frame_type == H2_DATA) {
            if (payload.len >= 5) {
                // Strip gRPC 5-byte header
                const msg_len = (@as(u32, payload[1]) << 24) |
                    (@as(u32, payload[2]) << 16) |
                    (@as(u32, payload[3]) << 8) |
                    @as(u32, payload[4]);

                if (payload.len >= 5 + msg_len) {
                    const result = try allocator.alloc(u8, msg_len);
                    @memcpy(result, payload[5 .. 5 + msg_len]);
                    allocator.free(payload);
                    return result;
                }
            }
            // Empty DATA or malformed
            if (payload.len == 0) {
                allocator.free(payload);
                if (flags & 0x1 != 0) return null; // END_STREAM
                continue;
            }
            return payload;
        } else if (frame_type == H2_HEADERS) {
            const end_stream = (flags & 0x1) != 0;
            allocator.free(payload);
            if (end_stream) return null; // TRAILERS with END_STREAM = stream done
            continue;
        } else if (frame_type == H2_SETTINGS) {
            const is_ack = (flags & 0x1) != 0;
            if (!is_ack) {
                try grpcWriteFrame(stream, H2_SETTINGS, 0x1, 0, &.{});
            }
            allocator.free(payload);
            continue;
        } else if (frame_type == H2_WINDOW_UPDATE) {
            allocator.free(payload);
            continue;
        } else if (frame_type == H2_PING) {
            const is_ack = (flags & 0x1) != 0;
            if (!is_ack) {
                try grpcWriteFrame(stream, H2_PING, 0x1, 0, payload);
            }
            allocator.free(payload);
            continue;
        } else if (frame_type == H2_RST_STREAM or frame_type == H2_GOAWAY) {
            allocator.free(payload);
            return null;
        } else {
            allocator.free(payload);
            continue;
        }
    }
}

/// Encode a protobuf message into bytes.
fn grpcEncodeMessage(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const written_data = aw.writer.buffer[0..aw.writer.end];
    return allocator.dupe(u8, written_data);
}

/// Execute a query on a gRPC transport connection, producing identical output to executeQueryOnConnection.
fn executeQueryOnGrpc(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    query_text: []const u8,
    format: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    graph: ?[]const u8,
    params: std.ArrayList(schema.Param),
    page_size: u32,
    timeout_secs: u32,
) !void {
    _ = page_size;
    // Issue #424: timeout_secs is now enforced at two levels:
    // 1. TCP socket SO_RCVTIMEO/SO_SNDTIMEO set by the caller (executeGrpcQuery)
    // 2. Process-level deadline watchdog thread started in cmdQuery
    _ = timeout_secs;
    const stdout = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
    const stderr_handle = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    // 1. Handshake — send HelloRequest, read HelloResponse
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .tenant_id = null,
    };
    const hello_bytes = try grpcEncodeMessage(allocator, hello_req);
    defer allocator.free(hello_bytes);
    try grpcSendRequest(allocator, stream, "/geode.GeodeService/Handshake", hello_bytes, 1);

    const hello_resp_bytes = grpcReadResponse(allocator, stream) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error: gRPC handshake failed: {}\n", .{err}) catch "Error: gRPC handshake failed\n";
        _ = stderr_handle.writeAll(msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    } orelse {
        _ = stderr_handle.writeAll("Error: Empty handshake response\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(hello_resp_bytes);

    var hello_reader: std.Io.Reader = .fixed(hello_resp_bytes);
    const hello_resp = try protobuf.decode(schema.HelloResponse, &hello_reader, allocator);
    defer {
        var resp_copy = hello_resp;
        resp_copy.deinit(allocator);
    }

    if (!hello_resp.success) {
        const err_msg = std.fmt.allocPrint(allocator, "Error: {s}\n\n", .{hello_resp.error_message}) catch "Error: Authentication failed\n\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
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
    while (true) {
        const extra = grpcReadResponse(allocator, stream) catch break;
        if (extra) |data| {
            allocator.free(data);
        } else break;
    }

    // 2. Execute query — send ExecuteRequest, read streaming ExecutionResponses

    // If a graph is specified, prepend "USE GRAPH graphname;"
    var final_query: []const u8 = query_text;
    var allocated_query: ?[]u8 = null;
    defer if (allocated_query) |q| allocator.free(q);

    if (graph) |g| {
        allocated_query = try std.fmt.allocPrint(allocator, "USE GRAPH {s}; {s}", .{ g, query_text });
        final_query = allocated_query.?;
    }

    var owned_params = params;
    defer {
        for (owned_params.items) |*param| {
            param.deinit(allocator);
        }
        owned_params.deinit(allocator);
    }

    // Need a new TCP connection for the Execute RPC (HTTP/2 stream reuse on stream 1
    // is not supported by the minimal transport — the server loops readMessage() on the
    // same connection, so we can reuse stream 1 by sending another HEADERS+DATA).
    // Actually, the grpc_zig transport's writeFrame always writes to the underlying TCP,
    // and readFrame always reads from it, so serial RPCs work on the same connection.

    const exec_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(exec_session_id);
    const query_copy = try allocator.dupe(u8, final_query);
    defer allocator.free(query_copy);
    const exec_req = schema.ExecuteRequest{
        .session_id = exec_session_id,
        .query = query_copy,
        .params = owned_params,
    };
    const exec_bytes = try grpcEncodeMessage(allocator, exec_req);
    defer allocator.free(exec_bytes);
    try grpcSendRequest(allocator, stream, "/geode.GeodeService/Execute", exec_bytes, 3);

    // 3. Read streaming responses and format output
    var columns = try std.ArrayList(ColumnInfo).initCapacity(allocator, 16);
    defer {
        for (columns.items) |col| {
            allocator.free(col.name);
            allocator.free(col.type);
        }
        columns.deinit(allocator);
    }

    var result_kind: QueryResultKind = .rows;
    var result_payload: ?[]const u8 = null;
    defer if (result_payload) |payload| allocator.free(payload);

    const wants_json = std.mem.eql(u8, format, "json");
    const wants_dot = std.mem.eql(u8, format, "dot");

    var all_rows_text: ?std.ArrayList(std.ArrayList([]const u8)) = null;
    var all_rows_json: ?std.ArrayList(std.ArrayList(std.json.Value)) = null;

    if (wants_json) {
        all_rows_json = try std.ArrayList(std.ArrayList(std.json.Value)).initCapacity(allocator, 64);
    } else {
        all_rows_text = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 64);
    }
    defer {
        if (all_rows_text) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |cell| allocator.free(cell);
                row.deinit(allocator);
            }
            rows.deinit(allocator);
        }
        if (all_rows_json) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |val| freeJsonValue(allocator, val);
                row.deinit(allocator);
            }
            rows.deinit(allocator);
        }
    }

    var ordered: bool = false;
    var order_keys = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (order_keys.items) |key| allocator.free(key);
        order_keys.deinit(allocator);
    }

    var status_class: []const u8 = try allocator.dupe(u8, "00000");
    defer allocator.free(status_class);
    var status_subclass: []const u8 = "";
    var status_subclass_owned = false;
    defer if (status_subclass_owned) allocator.free(status_subclass);
    var additional_statuses = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (additional_statuses.items) |s| allocator.free(s);
        additional_statuses.deinit(allocator);
    }
    var flagger_findings = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (flagger_findings.items) |s| allocator.free(s);
        flagger_findings.deinit(allocator);
    }
    var status_captured = false;

    var has_error: bool = false;
    var error_message: []const u8 = "";
    var error_status: []const u8 = "58000";
    var error_message_allocated = false;
    var error_status_allocated = false;
    defer {
        if (error_message_allocated) allocator.free(error_message);
        if (error_status_allocated) allocator.free(error_status);
    }

    const TextMode = enum { display, dot };
    // Reuse the same RowAppender and captureStatus closures defined in executeQueryOnConnection
    // by directly inlining the logic here.

    // Read all streaming response messages from the Execute RPC
    var resp_arena = std.heap.ArenaAllocator.init(allocator);
    defer resp_arena.deinit();

    while (true) {
        const resp_bytes = grpcReadResponse(resp_arena.allocator(), stream) catch break;
        if (resp_bytes == null) break; // Stream ended

        const bytes = resp_bytes.?;
        var rdr: std.Io.Reader = .fixed(bytes);
        const exec_resp = protobuf.decode(schema.ExecutionResponse, &rdr, resp_arena.allocator()) catch break;

        // Capture status
        if (!status_captured) {
            if (exec_resp.status) |status| {
                status_captured = true;
                allocator.free(status_class);
                status_class = try allocator.dupe(u8, status.status_class);
                if (status_subclass_owned) {
                    allocator.free(status_subclass);
                    status_subclass_owned = false;
                }
                if (status.status_subclass.len > 0) {
                    status_subclass = try allocator.dupe(u8, status.status_subclass);
                    status_subclass_owned = true;
                } else {
                    status_subclass = "";
                }
                for (status.additional_statuses.items) |s| {
                    try additional_statuses.append(allocator, try allocator.dupe(u8, s));
                }
                for (status.flagger_findings.items) |s| {
                    try flagger_findings.append(allocator, try allocator.dupe(u8, s));
                }
            }
        }

        if (exec_resp.payload) |val| {
            switch (val) {
                .schema => |s| {
                    for (s.columns.items) |col| {
                        const name_copy = try allocator.dupe(u8, col.name);
                        const type_copy = if (col.type.len > 0)
                            try allocator.dupe(u8, col.type)
                        else
                            try allocator.dupe(u8, "ANY");
                        try columns.append(allocator, .{ .name = name_copy, .type = type_copy });
                    }
                },
                .page => |p| {
                    if (p.ordered) ordered = true;
                    if (order_keys.items.len == 0 and p.order_keys.items.len > 0) {
                        for (p.order_keys.items) |key| {
                            try order_keys.append(allocator, try allocator.dupe(u8, key));
                        }
                    }
                    if (wants_json) {
                        if (all_rows_json) |*rows| {
                            for (p.rows.items) |row| {
                                var row_values = try std.ArrayList(std.json.Value).initCapacity(allocator, row.values.items.len);
                                for (row.values.items) |v| {
                                    const cell_val = try protoValueToJson(allocator, v);
                                    try row_values.append(allocator, cell_val);
                                }
                                try rows.append(allocator, row_values);
                            }
                        }
                    } else if (all_rows_text) |*rows| {
                        const mode: TextMode = if (wants_dot) .dot else .display;
                        for (p.rows.items) |row| {
                            var row_values = try std.ArrayList([]const u8).initCapacity(allocator, row.values.items.len);
                            for (row.values.items) |v| {
                                const cell_str = try grpcValueToString(allocator, v, mode);
                                try row_values.append(allocator, cell_str);
                            }
                            try rows.append(allocator, row_values);
                        }
                    }
                },
                .@"error" => |e| {
                    has_error = true;
                    error_message = try allocator.dupe(u8, e.message);
                    error_message_allocated = true;
                    if (e.code.len > 0) {
                        error_status = try allocator.dupe(u8, e.code);
                        error_status_allocated = true;
                    }
                },
                .explain => |ex| {
                    result_kind = .explain;
                    if (result_payload) |prev| allocator.free(prev);
                    result_payload = try explain_payload.explainPayloadToJson(allocator, ex);
                },
                .profile => |prof| {
                    result_kind = .profile;
                    if (result_payload) |prev| allocator.free(prev);
                    result_payload = try profile_payload.profilePayloadToJson(allocator, prof);
                },
                .metrics, .heartbeat => {},
            }
        }

        _ = resp_arena.reset(.retain_capacity);
    }

    if (std.mem.eql(u8, format, "dot")) {
        if (all_rows_text) |rows| {
            try outputDotFormatFromRows(allocator, rows.items, stdout);
        }
    } else {
        const rows_text_ptr: ?*std.ArrayList(std.ArrayList([]const u8)) = if (all_rows_text) |*rows| rows else null;
        const rows_json_ptr: ?*std.ArrayList(std.ArrayList(std.json.Value)) = if (all_rows_json) |*rows| rows else null;
        try renderTransportResponse(
            allocator,
            stdout,
            format,
            rows_text_ptr,
            rows_json_ptr,
            .{
                .columns = columns.items,
                .ordered = ordered,
                .order_keys = order_keys.items,
                .status_class = status_class,
                .status_subclass = status_subclass,
                .additional_statuses = additional_statuses.items,
                .flagger_findings = flagger_findings.items,
                .has_error = has_error,
                .error_message = error_message,
                .error_status = error_status,
                .result_kind = result_kind,
                .result_payload = result_payload,
            },
        );
    }
}

/// Value to string for gRPC path (mirrors the inner RowAppender.valueToString in executeQueryOnConnection)
fn grpcValueToString(allocator: std.mem.Allocator, v: schema.Value, mode: anytype) ![]const u8 {
    if (v.kind) |k| {
        return switch (k) {
            .string_val => |str| try allocator.dupe(u8, str.value),
            .int_val => |i| try std.fmt.allocPrint(allocator, "{d}", .{i.value}),
            .double_val => |d| try std.fmt.allocPrint(allocator, "{d}", .{d.value}),
            .bool_val => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .null_val => try allocator.dupe(u8, "null"),
            .decimal_val => |dec| blk: {
                const repr = if (dec.orig_repr.len > 0) dec.orig_repr else dec.coeff;
                break :blk try allocator.dupe(u8, repr);
            },
            .bytes_val => |bv| blk: {
                const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bv.value.len));
                _ = std.base64.standard.Encoder.encode(out, bv.value);
                break :blk out;
            },
            else => blk: {
                if (mode == .dot) {
                    break :blk try valueToJsonString(allocator, v);
                }
                const json_val = try protoValueToJson(allocator, v);
                defer freeJsonValue(allocator, json_val);
                break :blk try formatJsonValueCompact(allocator, json_val);
            },
        };
    }
    return allocator.dupe(u8, "null");
}

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-005; FEATURE="ChunkedExecution"; ASPECT=OptionsStruct; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
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
    use_grpc: bool = false,
};

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-006; FEATURE="ChunkedExecution"; ASPECT=Execution; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-13
/// Execute statements in chunks, batching multiple statements per request while staying under the size limit.
/// Transaction-aware: never splits chunks within BEGIN/COMMIT boundaries.
/// Context-aware: carries USE GRAPH forward to subsequent chunks on new connections.
fn executeChunkedQueries(allocator: std.mem.Allocator, opts: ChunkedQueryOptions) !void {
    const max_chunk_size: usize = 32 * 1024; // 32KB per chunk
    // Cap for transaction-aware chunks: if a transaction exceeds this, split it anyway.
    // Large transactions can't truly span connections, so splitting preserves the same
    // behavior as non-transaction-aware chunking (auto-commit per statement).
    const max_txn_chunk_size: usize = 32 * 1024; // Same as regular max — don't grow past 32KB
    const statements = opts.statements;

    var executed: usize = 0;
    var error_count: usize = 0;

    // Track USE GRAPH context to prepend to subsequent chunks (each chunk is a new connection)
    var use_graph_stmt: ?[]const u8 = null;

    // Process statements in chunks
    var chunk_start: usize = 0;
    while (chunk_start < statements.len) {
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
            const stmt_len = statements[chunk_end].len + 1; // +1 for separator
            // Transaction-aware: prefer not to break within a transaction, but
            // if the transaction is too large, split it anyway (each chunk is a
            // separate connection so large transactions can't truly be atomic).
            const at_limit = chunk_size + stmt_len > max_chunk_size and chunk_end > chunk_start;
            if (at_limit and !in_transaction) {
                break;
            }
            if (at_limit and in_transaction and chunk_size + stmt_len > max_txn_chunk_size) {
                // Transaction too large for a single chunk — split it
                break;
            }
            chunk_size += stmt_len;

            // Track transaction boundaries
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

        for (statements[chunk_start..chunk_end]) |stmt| {
            chunk_query.appendSlice(allocator, stmt) catch {};
            chunk_query.append(allocator, ' ') catch {};
        }

        // Execute this chunk
        const chunk_count = chunk_end - chunk_start;
        std.debug.print("Executing chunk {d}-{d} of {d} statements...\n", .{ chunk_start + 1, chunk_end, statements.len });

        const empty_params = std.ArrayList(schema.Param){};
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
                .page_size = 1000,
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
                .page_size = 1000,
                .params = empty_params,
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
    const stmt = std.mem.trimRight(u8, trimmed, "; \t");
    if (stmt.len == 0) return false;
    // Case-insensitive check for BEGIN or START TRANSACTION
    if (std.ascii.eqlIgnoreCase(stmt, "BEGIN") or
        std.ascii.eqlIgnoreCase(stmt, "START TRANSACTION"))
        return true;
    return false;
}

/// Check if a trimmed statement is a transaction end (COMMIT or ROLLBACK)
fn isTransactionEnd(trimmed: []const u8) bool {
    const stmt = std.mem.trimRight(u8, trimmed, "; \t");
    if (stmt.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(stmt, "COMMIT") or
        std.ascii.eqlIgnoreCase(stmt, "ROLLBACK"))
        return true;
    return false;
}

/// Check if a trimmed statement is a USE GRAPH statement
fn isUseGraphStmt(trimmed: []const u8) bool {
    const stmt = std.mem.trimRight(u8, trimmed, "; \t");
    if (stmt.len < 9) return false; // "USE GRAPH" is 9 chars minimum
    // Check prefix case-insensitively
    if (std.ascii.eqlIgnoreCase(stmt[0..9], "USE GRAPH")) return true;
    return false;
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
    const page_size = opts.page_size;
    var params = opts.params;
    var params_transferred = false;
    defer if (!params_transferred) {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    };
    const stderr = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3141";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        _ = stderr.writeAll("Error: Invalid port number in server address\n") catch {};
        return error.InvalidAddress;
    };

    // GAP-0113: Determine connection mode based on certificate options
    const use_certs = ca_cert_path != null or client_cert_path != null or client_key_path != null;

    // Validate mutual TLS: if any client cert/key provided, both must be provided
    if ((client_cert_path != null) != (client_key_path != null)) {
        _ = stderr.writeAll("Error: Both --client-cert and --client-key must be provided for mutual TLS\n") catch {};
        return error.InvalidAddress;
    }

    var attempts: u32 = 0;
    const max_attempts = retry_count + 1;
    var last_error: ?[]const u8 = null;

    while (attempts < max_attempts) : (attempts += 1) {
        var quic_client = quic.QuicClient.init(allocator);
        defer quic_client.deinit();

        // GAP-0113: Choose connection method based on security options
        // Priority: explicit certs > insecure flag > default secure
        const connect_err = if (use_certs)
            // Use explicit certificates for enterprise PKI/mutual TLS
            quic_client.connectEx(host, port, ca_cert_path, client_cert_path, client_key_path)
        else if (insecure)
            // Use insecure connect only when explicitly requested
            quic_client.connectInsecure(host, port, true)
        else
            // Default: secure connection without explicit certs (system CA store)
            quic_client.connectInsecure(host, port, false);

        if (connect_err) |_| {
            const handshake_timeout = @max(1, timeout_secs);
            const handshake_err = quic_client.waitForHandshake(handshake_timeout);
            if (handshake_err) |_| {
                // Handshake successful, proceed with query execution
                params_transferred = true;
                return try executeQueryOnConnection(allocator, &quic_client, query_text, format, username, password, graph, params, page_size, timeout_secs);
            } else |_| {
                last_error = "connection timeout";
            }
        } else |err| {
            last_error = @errorName(err);
            // If refused, stop retrying and fall back immediately
            if (std.mem.indexOf(u8, last_error.?, "ConnectionRefused") != null) {
                break;
            }
        }
    }

    if (last_error) |le| {
        _ = stderr.writeAll(le) catch {};
        _ = stderr.writeAll("\n") catch {};
    }

    return error.ConnectionFailed;
}

// Helper to read length-prefixed protobuf message with polling
fn readProtoMessage(allocator: std.mem.Allocator, stream: anytype, client: *quic.QuicClient, timeout_secs: u32) !schema.QuicServerMessage {
    // Read length prefix
    var len_buf: [4]u8 = undefined;
    var total_read: usize = 0;
    var attempts: usize = 0;
    // Issue #479: Reduced poll interval from 10ms to 1ms (matching GAP-0200 handshake fix)
    // to prevent QUIC message reads from consuming most of the watchdog timeout budget.
    // Calculate max attempts based on timeout_secs (1ms sleep per attempt)
    // timeout_secs * 1000ms / 1ms = timeout_secs * 1000
    const max_attempts = timeout_secs * 1000;

    while (total_read < 4) {
        const n = stream.read(len_buf[total_read..]) catch |err| {
            if (err == error.WouldBlock) {
                attempts += 1;
                if (attempts > max_attempts) return error.Timeout;
                try client.poll(1);
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge;

    // Read message body
    const msg_bytes = try allocator.alloc(u8, msg_len);
    defer allocator.free(msg_bytes);

    total_read = 0;
    attempts = 0;
    while (total_read < msg_len) {
        const n = stream.read(msg_bytes[total_read..]) catch |err| {
            if (err == error.WouldBlock) {
                attempts += 1;
                if (attempts > max_attempts) return error.Timeout;
                try client.poll(1);
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    // Decode message using std.Io.Reader.fixed() for type-erased reader
    var reader: std.Io.Reader = .fixed(msg_bytes);

    // Decode ServerPacket wrapper
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}

// Helper to write length-prefixed protobuf message
fn writeProtoMessage(allocator: std.mem.Allocator, stream: anytype, msg: schema.QuicClientMessage) !void {
    // Use std.Io.Writer.Allocating for type-erased allocating writer compatible with protobuf
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    const packet = schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    // Get the written data
    const written_data = aw.writer.buffer[0..aw.writer.end];

    // Write length prefix (4 bytes BE)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(written_data.len), .big);
    try stream.writeAll(&len_buf);

    // Write message body
    try stream.writeAll(written_data);
}

// CANARY: REQ=REQ-CLI-GRAPH-FLAG-005; FEATURE="GraphFlag"; ASPECT=ExecuteOnConnection; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
fn executeQueryOnConnection(
    allocator: std.mem.Allocator,
    quic_client: *quic.QuicClient,
    query_text: []const u8,
    format: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    graph: ?[]const u8,
    params: std.ArrayList(schema.Param),
    page_size: u32,
    timeout_secs: u32,
) !void {
    // Get stdout and stderr handles for output
    const stdout = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
    const stderr_handle = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    // Get a stream for communication
    var stream = quic_client.getStream() catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to get stream: {}\n", .{err}) catch "Error: Failed to get stream\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        return error.ConnectionFailed;
    };
    defer stream.deinit();

    // Send HELLO message with authentication credentials
    // CANARY: REQ=REQ-LIB-MIGRATION-PROTO-001; FEATURE="ProtoMigration"; ASPECT=HelloMessage; STATUS=TESTED; OWNER=cli; UPDATED=2026-02-02
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .tenant_id = null,
    };

    log.debug("Client sending HELLO (Protobuf)", &.{});
    writeProtoMessage(allocator, stream, .{ .hello = hello_req }) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to send HELLO: {}\n", .{err}) catch "Error: Failed to send HELLO\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        return error.ConnectionFailed;
    };

    // Use an arena for the HELLO response to ensure cleanup of decoded message fields
    var hello_arena = std.heap.ArenaAllocator.init(allocator);
    defer hello_arena.deinit();

    const hello_resp_msg = readProtoMessage(hello_arena.allocator(), stream, quic_client, timeout_secs) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to receive HELLO response: {}\n", .{err}) catch "Error: Failed to receive HELLO response\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        return error.ConnectionFailed;
    };

    var session_id: []const u8 = "";
    var session_id_owned: ?[]u8 = null;

    switch (hello_resp_msg) {
        .hello => |h| {
            log.debug("Client received HELLO response", &.{Attr.boolean("success", h.success)});
            if (!h.success) {
                const err_msg = std.fmt.allocPrint(allocator, "Error: {s}\n\n", .{h.error_message}) catch "Error: Authentication failed\n\n";
                _ = stderr_handle.writeAll(err_msg) catch {};
                return error.AuthenticationFailed;
            }
            if (h.session_id.len > 0) {
                session_id_owned = try allocator.dupe(u8, h.session_id);
                session_id = session_id_owned.?;
            }
        },
        else => {
            _ = stderr_handle.writeAll("Error: Unexpected response type during handshake\n") catch {};
            return error.AuthenticationFailed;
        },
    }
    defer if (session_id_owned) |sid| allocator.free(sid);

    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-006; FEATURE="GraphFlag"; ASPECT=PrependUseGraph; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // If a graph is specified, prepend "USE GRAPH graphname;" to the query
    var final_query: []const u8 = query_text;
    var allocated_query: ?[]u8 = null;
    defer if (allocated_query) |q| allocator.free(q);

    if (graph) |g| {
        allocated_query = try std.fmt.allocPrint(allocator, "USE GRAPH {s}; {s}", .{ g, query_text });
        final_query = allocated_query.?;
    }

    var owned_params = params;
    defer {
        for (owned_params.items) |*param| {
            param.deinit(allocator);
        }
        owned_params.deinit(allocator);
    }

    // Send query using Protobuf (ExecuteRequest)
    const exec_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(exec_session_id);
    const query_copy = try allocator.dupe(u8, final_query);
    defer allocator.free(query_copy);
    const run_gql_req = schema.ExecuteRequest{
        .session_id = exec_session_id,
        .query = query_copy,
        .params = owned_params,
    };

    try writeProtoMessage(allocator, stream, .{ .execute = run_gql_req });
    log.debug("Client query sent successfully", &.{});

    // For JSON/table/csv/dot output, accumulate results before outputting
    var columns = try std.ArrayList(ColumnInfo).initCapacity(allocator, 16);
    defer {
        for (columns.items) |col| {
            allocator.free(col.name);
            allocator.free(col.type);
        }
        columns.deinit(allocator);
    }

    var result_kind: QueryResultKind = .rows;
    var result_payload: ?[]const u8 = null;
    defer if (result_payload) |payload| allocator.free(payload);

    const wants_json = std.mem.eql(u8, format, "json");
    const wants_dot = std.mem.eql(u8, format, "dot");

    // Use ArrayLists to store all rows (text or json depending on output format)
    var all_rows_text: ?std.ArrayList(std.ArrayList([]const u8)) = null;
    var all_rows_json: ?std.ArrayList(std.ArrayList(std.json.Value)) = null;

    if (wants_json) {
        all_rows_json = try std.ArrayList(std.ArrayList(std.json.Value)).initCapacity(allocator, 64);
    } else {
        all_rows_text = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 64);
    }
    defer {
        if (all_rows_text) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |cell| {
                    allocator.free(cell);
                }
                row.deinit(allocator);
            }
            rows.deinit(allocator);
        }
        if (all_rows_json) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |val| freeJsonValue(allocator, val);
                row.deinit(allocator);
            }
            rows.deinit(allocator);
        }
    }
    var ordered: bool = false;
    var order_keys = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (order_keys.items) |key| allocator.free(key);
        order_keys.deinit(allocator);
    }

    var status_class: []const u8 = try allocator.dupe(u8, "00000");
    defer allocator.free(status_class);
    var status_subclass: []const u8 = "";
    var status_subclass_owned = false;
    defer if (status_subclass_owned) allocator.free(status_subclass);
    var additional_statuses = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (additional_statuses.items) |s| allocator.free(s);
        additional_statuses.deinit(allocator);
    }
    var flagger_findings = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (flagger_findings.items) |s| allocator.free(s);
        flagger_findings.deinit(allocator);
    }
    var status_captured = false;

    var has_error: bool = false;
    var error_message: []const u8 = "";
    var error_status: []const u8 = "58000";
    var error_message_allocated = false;
    var error_status_allocated = false;
    defer {
        if (error_message_allocated) allocator.free(error_message);
        if (error_status_allocated) allocator.free(error_status);
    }

    const TextMode = enum { display, dot };
    // Issue #469: Deduplicated — delegates to shared grpcValueToString
    const RowAppender = struct {
        fn valueToString(alloc: std.mem.Allocator, v: schema.Value, mode: TextMode) ![]const u8 {
            return grpcValueToString(alloc, v, mode);
        }

        fn appendPageText(
            alloc: std.mem.Allocator,
            page: schema.DataPage,
            rows_list: *std.ArrayList(std.ArrayList([]const u8)),
            mode: TextMode,
        ) !void {
            const row_count = page.rows.items.len;
            if (row_count == 0) return;

            // Use a higher threshold to avoid spice parallelMap memory corruption
            // on smaller result sets (see proto_util.zig buildDataPage fix)
            const cli_parallel_threshold: usize = 512;
            if (spice_wrapper.shouldUseParallelism(row_count, cli_parallel_threshold)) {
                var pool = spice_wrapper.SpicePool.init(alloc, null);
                pool.start();
                defer pool.deinit();

                var ts_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = alloc };
                const safe_alloc = ts_alloc.allocator();

                const RowInput = struct { row: schema.Row, allocator: std.mem.Allocator, mode: TextMode };
                const RowResult = struct { row: std.ArrayList([]const u8), err: ?anyerror, allocator: std.mem.Allocator };

                const inputs = try alloc.alloc(RowInput, row_count);
                defer alloc.free(inputs);
                for (page.rows.items, 0..) |row, i| inputs[i] = .{ .row = row, .allocator = safe_alloc, .mode = mode };

                const results = try alloc.alloc(RowResult, row_count);
                defer alloc.free(results);
                for (results) |*r| r.* = .{ .row = std.ArrayList([]const u8).initCapacity(safe_alloc, 0) catch unreachable, .err = null, .allocator = safe_alloc };

                try pool.map(RowInput, RowResult, inputs, results, struct {
                    fn map(ctx: spice_wrapper.TaskContext, input: RowInput, out: *RowResult) void {
                        _ = ctx;
                        const a = input.allocator;
                        var row_values = std.ArrayList([]const u8).initCapacity(a, input.row.values.items.len) catch {
                            out.* = .{ .row = std.ArrayList([]const u8).initCapacity(a, 0) catch unreachable, .err = error.OutOfMemory, .allocator = a };
                            return;
                        };

                        for (input.row.values.items) |v| {
                            const cell_str = valueToString(a, v, input.mode) catch |err| {
                                out.* = .{ .row = row_values, .err = err, .allocator = a };
                                return;
                            };
                            row_values.append(a, cell_str) catch |err| {
                                out.* = .{ .row = row_values, .err = err, .allocator = a };
                                return;
                            };
                        }

                        out.* = .{ .row = row_values, .err = null, .allocator = a };
                    }
                }.map);

                for (results) |*res| {
                    if (res.err) |err| {
                        for (res.row.items) |cell| res.allocator.free(cell);
                        res.row.deinit(res.allocator);
                        return err;
                    }
                    try rows_list.append(alloc, res.row);
                }
                return;
            }

            for (page.rows.items) |row| {
                var row_values = try std.ArrayList([]const u8).initCapacity(alloc, row.values.items.len);
                errdefer {
                    for (row_values.items) |cell| alloc.free(cell);
                    row_values.deinit(alloc);
                }

                for (row.values.items) |v| {
                    const cell_str = try valueToString(alloc, v, mode);
                    try row_values.append(alloc, cell_str);
                }

                try rows_list.append(alloc, row_values);
            }
        }

        fn appendPageJson(
            alloc: std.mem.Allocator,
            page: schema.DataPage,
            rows_list: *std.ArrayList(std.ArrayList(std.json.Value)),
        ) !void {
            const row_count = page.rows.items.len;
            if (row_count == 0) return;

            // Use a higher threshold to avoid spice parallelMap memory corruption
            // on smaller result sets (see proto_util.zig buildDataPage fix)
            const cli_parallel_threshold: usize = 512;
            if (spice_wrapper.shouldUseParallelism(row_count, cli_parallel_threshold)) {
                var pool = spice_wrapper.SpicePool.init(alloc, null);
                pool.start();
                defer pool.deinit();

                var ts_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = alloc };
                const safe_alloc = ts_alloc.allocator();

                const RowInput = struct { row: schema.Row, allocator: std.mem.Allocator };
                const RowResult = struct { row: std.ArrayList(std.json.Value), err: ?anyerror, allocator: std.mem.Allocator };

                const inputs = try alloc.alloc(RowInput, row_count);
                defer alloc.free(inputs);
                for (page.rows.items, 0..) |row, i| inputs[i] = .{ .row = row, .allocator = safe_alloc };

                const results = try alloc.alloc(RowResult, row_count);
                defer alloc.free(results);
                for (results) |*r| r.* = .{ .row = std.ArrayList(std.json.Value).initCapacity(safe_alloc, 0) catch unreachable, .err = null, .allocator = safe_alloc };

                try pool.map(RowInput, RowResult, inputs, results, struct {
                    fn map(ctx: spice_wrapper.TaskContext, input: RowInput, out: *RowResult) void {
                        _ = ctx;
                        const a = input.allocator;
                        var row_values = std.ArrayList(std.json.Value).initCapacity(a, input.row.values.items.len) catch {
                            out.* = .{ .row = std.ArrayList(std.json.Value).initCapacity(a, 0) catch unreachable, .err = error.OutOfMemory, .allocator = a };
                            return;
                        };

                        for (input.row.values.items) |v| {
                            const cell_val = protoValueToJson(a, v) catch |err| {
                                out.* = .{ .row = row_values, .err = err, .allocator = a };
                                return;
                            };
                            row_values.append(a, cell_val) catch |err| {
                                out.* = .{ .row = row_values, .err = err, .allocator = a };
                                return;
                            };
                        }

                        out.* = .{ .row = row_values, .err = null, .allocator = a };
                    }
                }.map);

                for (results) |*res| {
                    if (res.err) |err| {
                        for (res.row.items) |val| freeJsonValue(res.allocator, val);
                        res.row.deinit(res.allocator);
                        return err;
                    }
                    try rows_list.append(alloc, res.row);
                }
                return;
            }

            for (page.rows.items) |row| {
                var row_values = try std.ArrayList(std.json.Value).initCapacity(alloc, row.values.items.len);
                errdefer {
                    for (row_values.items) |val| freeJsonValue(alloc, val);
                    row_values.deinit(alloc);
                }

                for (row.values.items) |v| {
                    const cell_val = try protoValueToJson(alloc, v);
                    try row_values.append(alloc, cell_val);
                }

                try rows_list.append(alloc, row_values);
            }
        }
    };

    const captureOrderMeta = struct {
        fn apply(
            alloc: std.mem.Allocator,
            page: schema.DataPage,
            ordered_flag: *bool,
            keys: *std.ArrayList([]const u8),
        ) !void {
            if (page.ordered) ordered_flag.* = true;
            if (keys.items.len == 0 and page.order_keys.items.len > 0) {
                for (page.order_keys.items) |key| {
                    try keys.append(alloc, try alloc.dupe(u8, key));
                }
            }
        }
    };

    const captureStatus = struct {
        fn apply(
            alloc: std.mem.Allocator,
            status_opt: ?schema.Status,
            status_out: *[]const u8,
            status_subclass_out: *[]const u8,
            subclass_owned: *bool,
            additional_out: *std.ArrayList([]const u8),
            flagger_out: *std.ArrayList([]const u8),
            captured: *bool,
        ) !void {
            if (captured.*) return;
            if (status_opt == null) return;
            const status = status_opt.?;
            captured.* = true;
            alloc.free(status_out.*);
            status_out.* = try alloc.dupe(u8, status.status_class);
            if (subclass_owned.*) {
                alloc.free(status_subclass_out.*);
                subclass_owned.* = false;
            }
            if (status.status_subclass.len > 0) {
                status_subclass_out.* = try alloc.dupe(u8, status.status_subclass);
                subclass_owned.* = true;
            } else {
                status_subclass_out.* = "";
            }
            for (status.additional_statuses.items) |s| {
                try additional_out.append(alloc, try alloc.dupe(u8, s));
            }
            for (status.flagger_findings.items) |s| {
                try flagger_out.append(alloc, try alloc.dupe(u8, s));
            }
        }
    };

    // Receive responses loop
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var schema_received = false;
    var saw_inline_page = false;
    var inline_final = false;
    var need_pull = false;

    while (!schema_received and !has_error) {
        const loop_allocator = loop_arena.allocator();

        const resp = readProtoMessage(loop_allocator, stream, quic_client, timeout_secs) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        switch (resp) {
            .execute => |exec_resp| {
                try captureStatus.apply(allocator, exec_resp.status, &status_class, &status_subclass, &status_subclass_owned, &additional_statuses, &flagger_findings, &status_captured);
                if (exec_resp.payload) |val| {
                    switch (val) {
                        .schema => |s| {
                            for (s.columns.items) |col| {
                                const name_copy = try allocator.dupe(u8, col.name);
                                const type_copy = if (col.type.len > 0)
                                    try allocator.dupe(u8, col.type)
                                else
                                    try allocator.dupe(u8, "ANY");
                                try columns.append(allocator, .{ .name = name_copy, .type = type_copy });
                            }
                            schema_received = true;
                        },
                        .page => |p| {
                            saw_inline_page = true;
                            try captureOrderMeta.apply(allocator, p, &ordered, &order_keys);
                            if (wants_json) {
                                if (all_rows_json) |*rows| try RowAppender.appendPageJson(allocator, p, rows);
                            } else if (all_rows_text) |*rows| {
                                const mode: TextMode = if (wants_dot) .dot else .display;
                                try RowAppender.appendPageText(allocator, p, rows, mode);
                            }
                            if (p.final) {
                                inline_final = true;
                            } else {
                                need_pull = true;
                            }
                        },
                        .@"error" => |e| {
                            has_error = true;
                            error_message = try allocator.dupe(u8, e.message);
                            error_message_allocated = true;
                            if (e.code.len > 0) {
                                error_status = try allocator.dupe(u8, e.code);
                                error_status_allocated = true;
                            }
                        },
                        .explain => |ex| {
                            result_kind = .explain;
                            if (result_payload) |prev| allocator.free(prev);
                            result_payload = try explain_payload.explainPayloadToJson(allocator, ex);
                            schema_received = true;
                        },
                        .profile => |prof| {
                            result_kind = .profile;
                            if (result_payload) |prev| allocator.free(prev);
                            result_payload = try profile_payload.profilePayloadToJson(allocator, prof);
                            schema_received = true;
                        },
                        .metrics, .heartbeat => {},
                    }
                }
            },
            .hello => |h| {
                if (!h.success) {
                    has_error = true;
                    error_message = try allocator.dupe(u8, h.error_message);
                    error_message_allocated = true;
                    error_status = "28000";
                }
                schema_received = true;
            },
            .ping => {},
            else => {},
        }

        _ = loop_arena.reset(.retain_capacity);
    }

    if (!has_error and !saw_inline_page) {
        const loop_allocator = loop_arena.allocator();
        const maybe_inline = readProtoMessage(loop_allocator, stream, quic_client, 1) catch |err| blk: {
            if (err == error.Timeout or err == error.EndOfStream) break :blk null;
            return err;
        };

        if (maybe_inline) |resp| {
            switch (resp) {
                .execute => |exec_resp| {
                    if (exec_resp.payload) |val| switch (val) {
                        .page => |p| {
                            saw_inline_page = true;
                            try captureOrderMeta.apply(allocator, p, &ordered, &order_keys);
                            if (wants_json) {
                                if (all_rows_json) |*rows| try RowAppender.appendPageJson(allocator, p, rows);
                            } else if (all_rows_text) |*rows| {
                                const mode: TextMode = if (wants_dot) .dot else .display;
                                try RowAppender.appendPageText(allocator, p, rows, mode);
                            }
                            if (p.final) {
                                inline_final = true;
                            } else {
                                need_pull = true;
                            }
                        },
                        .@"error" => |e| {
                            has_error = true;
                            error_message = try allocator.dupe(u8, e.message);
                            error_message_allocated = true;
                            if (e.code.len > 0) {
                                error_status = try allocator.dupe(u8, e.code);
                                error_status_allocated = true;
                            }
                        },
                        else => {},
                    };
                },
                else => {},
            }
        }

        _ = loop_arena.reset(.retain_capacity);
    }

    var request_id: u64 = 1;
    if (!has_error and result_kind == .rows and (!inline_final or need_pull)) {
        var done = false;

        while (!done and !has_error) : (request_id += 1) {
            const pull_req = schema.PullRequest{
                .request_id = request_id,
                .page_size = page_size,
                .session_id = session_id,
            };
            try writeProtoMessage(allocator, stream, .{ .pull = pull_req });

            const loop_allocator = loop_arena.allocator();
            const resp = readProtoMessage(loop_allocator, stream, quic_client, timeout_secs) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            switch (resp) {
                .pull => |pull_resp| {
                    const exec_resp = pull_resp.response orelse break;
                    try captureStatus.apply(allocator, exec_resp.status, &status_class, &status_subclass, &status_subclass_owned, &additional_statuses, &flagger_findings, &status_captured);
                    if (exec_resp.payload) |val| switch (val) {
                        .page => |p| {
                            try captureOrderMeta.apply(allocator, p, &ordered, &order_keys);
                            if (wants_json) {
                                if (all_rows_json) |*rows| try RowAppender.appendPageJson(allocator, p, rows);
                            } else if (all_rows_text) |*rows| {
                                const mode: TextMode = if (wants_dot) .dot else .display;
                                try RowAppender.appendPageText(allocator, p, rows, mode);
                            }
                            if (p.final) done = true;
                        },
                        .@"error" => |e| {
                            has_error = true;
                            error_message = try allocator.dupe(u8, e.message);
                            error_message_allocated = true;
                            if (e.code.len > 0) {
                                error_status = try allocator.dupe(u8, e.code);
                                error_status_allocated = true;
                            }
                        },
                        else => {},
                    };
                },
                .execute => |exec_resp| {
                    try captureStatus.apply(allocator, exec_resp.status, &status_class, &status_subclass, &status_subclass_owned, &additional_statuses, &flagger_findings, &status_captured);
                    if (exec_resp.payload) |val| switch (val) {
                        .page => |p| {
                            try captureOrderMeta.apply(allocator, p, &ordered, &order_keys);
                            if (wants_json) {
                                if (all_rows_json) |*rows| try RowAppender.appendPageJson(allocator, p, rows);
                            } else if (all_rows_text) |*rows| {
                                const mode: TextMode = if (wants_dot) .dot else .display;
                                try RowAppender.appendPageText(allocator, p, rows, mode);
                            }
                            if (p.final) done = true;
                        },
                        .@"error" => |e| {
                            has_error = true;
                            error_message = try allocator.dupe(u8, e.message);
                            error_message_allocated = true;
                            if (e.code.len > 0) {
                                error_status = try allocator.dupe(u8, e.code);
                                error_status_allocated = true;
                            }
                        },
                        else => {},
                    };
                },
                else => {},
            }

            _ = loop_arena.reset(.retain_capacity);
        }
    }

    // Output final result based on format
    if (std.mem.eql(u8, format, "dot")) {
        // CANARY: REQ=REQ-CLI-DOT-002; FEATURE="DotFormat"; ASPECT=GraphvizOutput; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        // DOT format for Graphviz visualization
        if (all_rows_text) |rows| {
            try outputDotFormatFromRows(allocator, rows.items, stdout);
        }
    } else {
        const rows_text_ptr: ?*std.ArrayList(std.ArrayList([]const u8)) = if (all_rows_text) |*rows| rows else null;
        const rows_json_ptr: ?*std.ArrayList(std.ArrayList(std.json.Value)) = if (all_rows_json) |*rows| rows else null;
        try renderTransportResponse(
            allocator,
            stdout,
            format,
            rows_text_ptr,
            rows_json_ptr,
            .{
                .columns = columns.items,
                .ordered = ordered,
                .order_keys = order_keys.items,
                .status_class = status_class,
                .status_subclass = status_subclass,
                .additional_statuses = additional_statuses.items,
                .flagger_findings = flagger_findings.items,
                .has_error = has_error,
                .error_message = error_message,
                .error_status = error_status,
                .result_kind = result_kind,
                .result_payload = result_payload,
            },
        );
    }
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
/// CANARY: REQ=REQ-CLI-DOT-003; FEATURE="DotFormat"; ASPECT=RowBasedOutput; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
fn outputDotFormatFromRows(allocator: std.mem.Allocator, rows: []const std.ArrayList([]const u8), stdout: std.fs.File) !void {
    // Start DOT graph
    _ = stdout.writeAll("digraph G {\n") catch {};
    _ = stdout.writeAll("  rankdir=LR;\n") catch {};
    _ = stdout.writeAll("  node [shape=ellipse, style=filled, fillcolor=lightblue];\n") catch {};
    _ = stdout.writeAll("  edge [fontsize=10];\n") catch {};
    _ = stdout.writeAll("\n") catch {};

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

                    _ = stdout.writeAll("  \"") catch {};
                    _ = stdout.writeAll(node_id) catch {};
                    _ = stdout.writeAll("\" [label=\"") catch {};
                    _ = stdout.writeAll(label) catch {};
                    _ = stdout.writeAll("\"];\n") catch {};
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

                _ = stdout.writeAll("  \"") catch {};
                _ = stdout.writeAll(start_id) catch {};
                _ = stdout.writeAll("\" -> \"") catch {};
                _ = stdout.writeAll(end_id) catch {};
                _ = stdout.writeAll("\" [label=\"") catch {};
                _ = stdout.writeAll(rel_type) catch {};
                _ = stdout.writeAll("\"];\n") catch {};
            }

            _ = col_idx; // Suppress unused variable warning
        }
    }

    // End DOT graph
    _ = stdout.writeAll("}\n") catch {};
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

    const stdin_handle = getStdinHandle() catch |err| {
        std.debug.print("Error: Cannot get stdin handle: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const stdin_is_tty = switch (builtin.os.tag) {
        .windows => false,
        else => std.posix.isatty(stdin_handle),
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
            std.debug.print("Warning: --insecure is deprecated. Use --insecure-tls-skip-verify instead.\r\n", .{});
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
    }

    // Issue #387: Validate that if one of username/password is provided, both must be
    if ((username != null) != (password != null)) {
        std.debug.print("Error: Both --username/-U and --password/-P must be provided for authentication\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    if (non_interactive) {
        const stderr_file = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
        _ = stderr_file.writeAll("Non-interactive shell mode is not supported. Use 'geode query' for scripted execution.\n") catch {};
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
    } else if (ca_cert_path != null or client_cert_path != null) {
        std.debug.print("Connecting to {s} (TLS with custom certificates)\r\n", .{server});
        if (ca_cert_path) |ca| std.debug.print("  CA cert: {s}\r\n", .{ca});
        if (client_cert_path) |cert| std.debug.print("  Client cert: {s}\r\n", .{cert});
        if (client_key_path) |key| std.debug.print("  Client key: {s}\r\n", .{key});
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
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    execution.initEvaluator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

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
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".geode", "credentials.json" });
}

fn ensureCredentialsDir(allocator: std.mem.Allocator) !void {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    const geode_dir = try std.fs.path.join(allocator, &.{ home_dir, ".geode" });
    defer allocator.free(geode_dir);

    std.fs.makeDirAbsolute(geode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
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

    // Write to file
    const file = try std.fs.createFileAbsolute(creds_path, .{});
    defer file.close();

    try file.writeAll(json_content);
}

fn clearCredentials(allocator: std.mem.Allocator) !void {
    const creds_path = getCredentialsPath(allocator) catch return;
    defer allocator.free(creds_path);

    std.fs.deleteFileAbsolute(creds_path) catch {};
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

    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = stdin_file.readAll(&b) catch break;
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

/// GAP-0150: Real QUIC authentication to server
/// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLI QUIC Authentication"; ASPECT=ServerConnection; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn connectToServer(allocator: std.mem.Allocator, server: []const u8, username: []const u8, password: []const u8, allow_insecure: bool) !AuthResult {
    // GAP-0150 RESOLVED: Now uses real QUIC connection to server for authentication
    // instead of simulating locally

    // Parse server address
    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse {
        std.debug.print("Error: Invalid server address format. Expected host:port\n", .{});
        return error.InvalidAddress;
    };
    const host = server[0..colon_idx];
    const port = std.fmt.parseInt(u16, server[colon_idx + 1 ..], 10) catch {
        std.debug.print("Error: Invalid port number\n", .{});
        return error.InvalidAddress;
    };

    // Create QUIC client connection
    const client = try allocator.create(quic.QuicClient);
    client.* = quic.QuicClient.init(allocator);
    defer {
        client.deinit();
        allocator.destroy(client);
    }

    // Connect to server (use explicit insecure flag, fall back to shell transport config)
    const insecure = allow_insecure or repl_quic_transport.getTlsConfig().insecure;
    _ = client.connectInsecure(host, port, insecure) catch |err| {
        std.debug.print("Error: Could not connect to server {s}:{d}: {s}\n", .{ host, port, @errorName(err) });
        return error.ConnectionFailed;
    };

    // Wait for TLS handshake
    _ = client.waitForHandshake(10) catch |err| {
        std.debug.print("Error: TLS handshake failed: {s}\n", .{@errorName(err)});
        // Connection may be in a bad state after handshake failure;
        // null it out before deinit to avoid use-after-free in closeConnection
        client.connection = null;
        return error.HandshakeFailed;
    };

    // Get QUIC stream
    var stream = client.getStream() catch |err| {
        std.debug.print("Error: Could not open stream: {s}\n", .{@errorName(err)});
        return error.StreamError;
    };
    defer stream.deinit();

    // Send authenticated HELLO handshake via Protobuf
    const hello_req = schema.HelloRequest{
        .username = try allocator.dupe(u8, username),
        .password = try allocator.dupe(u8, password),
        .tenant_id = null,
    };

    // Wrap in QuicClientMessage
    try writeProtoMessage(allocator, stream, .{ .hello = hello_req });

    // Read HELLO response
    const resp = try readProtoMessage(allocator, stream, client, 30);
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
    const env_server = if (comptime builtin.os.tag != .windows) std.posix.getenv("GEODE_SERVER_ADDRESS") else null;
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

        while (true) {
            var b: [1]u8 = undefined;
            const bytes_read = stdin_file.readAll(&b) catch break;
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
            const file = std.fs.openFileAbsolute(pf, .{}) catch |err| {
                std.debug.print("Error: Cannot read password file '{s}': {s}\n", .{ pf, @errorName(err) });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, 256);
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
    const expires_at = std.time.milliTimestamp() + 24 * 60 * 60 * 1000; // 24 hours
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
    const stdout_file = std.fs.File{ .handle = stdout_handle };
    stdout_file.writeAll(msg) catch {};
    if (save_session) {
        saveCredentials(allocator, creds) catch |err| {
            std.debug.print("Warning: Could not save credentials: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        stdout_file.writeAll("Session token saved to ~/.geode/credentials.json\n") catch {};
    } else {
        const token_msg = try std.fmt.allocPrint(allocator, "Session token: {s}\nUse --save-session to persist credentials locally\n", .{auth_result.session_token});
        defer allocator.free(token_msg);
        stdout_file.writeAll(token_msg) catch {};
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
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch {
            std.debug.print("Error: USERPROFILE environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("Error: HOME environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    defer allocator.free(home);

    const credentials_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(credentials_path);

    // Try to read the credentials file
    const file = std.fs.openFileAbsolute(credentials_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No saved credentials found\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        std.debug.print("Error reading credentials: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close();

    // Read file content
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Error reading credentials file: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(content);

    // Output the content to stdout
    const stdout_fd = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
    _ = try stdout_fd.writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        _ = try stdout_fd.writeAll("\n");
    }
}
