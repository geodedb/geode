const std = @import("std");

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

// CANARY: REQ=REQ-LIB-MIGRATION-CONFIG-001; FEATURE="External Library Migration"; ASPECT=ConfigManagement; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// External configuration library - XDG compliant, multi-format support (YAML, TOML, JSON)
// Provides config file support with precedence: flags > env > project > user > system > defaults
const config_lib = @import("config");

// CANARY: REQ=REQ-SERVER-REFACTOR-007; FEATURE="ServerRefactoring"; ASPECT=CLI_ARGS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - CLI Argument Parsing Module (Third Increment)
// Extracted from server/main.zig to improve modularity and testability

/// Server configuration parsed from CLI arguments
pub const ServerConfig = struct {
    // Network configuration
    listen_quic: ?[]const u8 = null,
    listen_grpc: ?[]const u8 = null,
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,

    // Storage configuration
    data_dir: ?[]const u8 = null,

    // Logging
    log_level_arg: ?[]const u8 = null,

    // Query behavior
    order_keys_mode_expr: bool = false, // ident-only by default; env/flag can enable

    // Authentication (enabled by default for security; use --no-auth to disable)
    enable_auth: bool = true,

    // CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
    // --insecure-allow-all: when true, gps.decide() returns allow for every
    // request regardless of principal or resource. Default false (fail-closed).
    // NOT FOR PRODUCTION — exists only to provide an explicit, observable
    // bypass replacing the implicit auth-disabled short-circuit.
    insecure_allow_all: bool = false,

    // GAP-0259: Configurable QUIC idle timeout (default 300s / 5 minutes)
    idle_timeout_ms: u64 = 300000,

    // GAP-0327: Configurable QUIC connection cap. 0 = use the transport
    // default (1000). A small value makes connection-pool-exhaustion
    // behaviour deterministically testable.
    max_connections: usize = 0,

    // GAP-0260: Deferred persistence interval (default 30s)
    // Longer interval reduces persistence thread race window with query threads
    persist_interval_ms: u64 = 30000,

    // Cluster bootstrap configuration.
    // Set --cluster-port (or GEODE_CLUSTER_PORT) and --peers (or GEODE_PEERS, comma-separated)
    // to participate in a Raft cluster. Activation also requires GEODE_CLUSTER_TOKEN.
    // CANARY: REQ=REQ-DIST-CLI-001; FEATURE="DistributedClusterCLI"; ASPECT=ServerConfig; STATUS=TESTED; TEST=tests/test_cli_args_cluster.zig; OWNER=core; UPDATED=2026-05-25
    cluster_port: ?u16 = null,

    // Owned list of peer addresses in "host:port" form (cluster ports, not client ports).
    // Empty list = no peers configured via CLI. Env var GEODE_PEERS may still apply
    // downstream when cluster_bootstrap.parseConfig sees an empty CLI list.
    peers: [][]const u8 = &.{},

    // Whether cert_path/key_path were EXPLICITLY supplied by the operator
    // (via --cert/--key or a config file) as opposed to auto-derived from
    // --data-dir / GEODE_CERT_DIR / the /tmp fallback. An explicitly-provided
    // cert MUST be loaded as-is and never regenerated or replaced by a
    // throwaway self-signed cert. See
    // docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
    // CANARY: REQ=REQ-CLUSTER-CERT-PROVIDED-HONORED; FEATURE="DistributedClusterTLS"; ASPECT=ExplicitCertTracking; STATUS=TESTED; TEST=tests/test_cert_provided_cert_honored.zig; OWNER=distributed; UPDATED=2026-06-04
    cert_explicit: bool = false,
    key_explicit: bool = false,

    // Track which fields were allocated (vs static strings)
    _allocated_listen_quic: bool = false,
    _allocated_listen_grpc: bool = false,
    _allocated_cert_path: bool = false,
    _allocated_key_path: bool = false,
    _allocated_data_dir: bool = false,
    _allocated_log_level_arg: bool = false,
    _allocated_peers: bool = false,

    /// Free all allocated memory
    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        if (self._allocated_listen_quic) if (self.listen_quic) |s| allocator.free(s);
        if (self._allocated_listen_grpc) if (self.listen_grpc) |s| allocator.free(s);
        if (self._allocated_cert_path) if (self.cert_path) |s| allocator.free(s);
        if (self._allocated_key_path) if (self.key_path) |s| allocator.free(s);
        if (self._allocated_data_dir) if (self.data_dir) |s| allocator.free(s);
        if (self._allocated_log_level_arg) if (self.log_level_arg) |s| allocator.free(s);
        if (self._allocated_peers) {
            for (self.peers) |p| allocator.free(p);
            allocator.free(self.peers);
        }
    }
};

/// Get XDG-compliant config directory path for Geode
/// Returns ~/.config/geode on Linux/macOS, or %APPDATA%\geode on Windows
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    var paths = try config_lib.getPaths(allocator);
    defer paths.deinit();
    // Append /geode to the config home
    return try std.fmt.allocPrint(allocator, "{s}/geode", .{paths.config_home});
}

/// Load configuration from file (supports YAML, TOML, JSON)
/// Searches in order: project (.geode/config.*), user (~/.config/geode/config.*), system
pub fn loadConfigFile(allocator: std.mem.Allocator) !?config_lib.Value {
    // Try project config first
    const project_paths = [_][]const u8{
        ".geode/config.yaml",
        ".geode/config.yml",
        ".geode/config.toml",
        ".geode/config.json",
    };

    for (project_paths) |path| {
        if (config_lib.parseFile(allocator, path)) |result| {
            return result;
        } else |_| {
            continue;
        }
    }

    // Try user config
    var paths = config_lib.getPaths(allocator) catch return null;
    defer paths.deinit();

    var user_path_buf: [512]u8 = undefined;
    const user_extensions = [_][]const u8{ "yaml", "yml", "toml", "json" };

    for (user_extensions) |ext| {
        const user_path = std.fmt.bufPrint(&user_path_buf, "{s}/geode/config.{s}", .{ paths.config_home, ext }) catch continue;
        if (config_lib.parseFile(allocator, user_path)) |result| {
            return result;
        } else |_| {
            continue;
        }
    }

    return null;
}

/// Load configuration from a specific file path
pub fn loadConfigFromPath(allocator: std.mem.Allocator, path: []const u8) !config_lib.Value {
    return config_lib.parseFile(allocator, path);
}

/// Merge configuration from file into ServerConfig
/// File values are overridden by any explicitly set CLI arguments
pub fn mergeFileConfig(config: *ServerConfig, file_result: config_lib.Value) void {
    // Extract values from loaded config using the unified Value API
    if (file_result.getString("listen_quic")) |v| {
        if (config.listen_quic == null) config.listen_quic = v;
    }
    if (file_result.getString("listen_grpc")) |v| {
        if (config.listen_grpc == null) config.listen_grpc = v;
    }
    if (file_result.getString("cert_path")) |v| {
        if (config.cert_path == null) {
            config.cert_path = v;
            // A cert supplied via the config file is just as "explicit" as one
            // supplied via --cert: it must be loaded as-is, never regenerated.
            config.cert_explicit = true;
        }
    }
    if (file_result.getString("key_path")) |v| {
        if (config.key_path == null) {
            config.key_path = v;
            config.key_explicit = true;
        }
    }
    if (file_result.getString("data_dir")) |v| {
        if (config.data_dir == null) config.data_dir = v;
    }
    if (file_result.getString("log_level")) |v| {
        if (config.log_level_arg == null) config.log_level_arg = v;
    }
    if (file_result.getString("idle_timeout")) |v| {
        config.idle_timeout_ms = std.fmt.parseUnsigned(u64, v, 10) catch config.idle_timeout_ms;
    }
    if (file_result.getString("persist_interval")) |v| {
        config.persist_interval_ms = std.fmt.parseUnsigned(u64, v, 10) catch config.persist_interval_ms;
    }
}

/// Print help message to stdout
pub fn printHelp() void {
    const build_options = @import("build_options");
    std.debug.print("Geode Server " ++ build_options.version ++ "\n\n", .{});
    std.debug.print("Usage: geode serve [OPTIONS]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -c, --config <path>          Path to config file (YAML, TOML, or JSON)\n", .{});
    std.debug.print("  --listen <addr:port>         Listen on QUIC/TLS (e.g., 0.0.0.0:3141)\n", .{});
    std.debug.print("  --listen-grpc <addr:port>    Listen on gRPC (e.g., 0.0.0.0:3142)\n", .{});
    std.debug.print("  --cert <path>                Path to TLS certificate (default: auto-generate)\n", .{});
    std.debug.print("  --key <path>                 Path to TLS private key (default: auto-generate)\n", .{});
    std.debug.print("  --data_dir <path>            Data directory for storage and generated certs\n", .{});
    std.debug.print("  --data-dir <path>            Alias for --data_dir\n", .{});
    std.debug.print("  --order-keys expr            Allow expressions in ORDER BY\n", .{});
    std.debug.print("  --log-level <lvl>            Set log level trace|debug|info|warn|error|critical (default info)\n", .{});
    std.debug.print("  --idle-timeout <ms>          QUIC idle timeout in milliseconds (default: 300000)\n", .{});
    std.debug.print("  --max-connections <n>        Cap concurrent QUIC connections (default: 10000)\n", .{});
    std.debug.print("  --persist-interval <ms>      Background persistence interval in milliseconds (default: 100)\n", .{});
    std.debug.print("  --cluster-port <port>        Raft cluster listen port (also requires GEODE_CLUSTER_TOKEN to activate)\n", .{});
    std.debug.print("  --peers <h:p,h:p,...>        Comma-separated list of cluster peers (cluster ports, not client ports)\n", .{});
    std.debug.print("  --no-auth                    Disable authentication (NOT recommended for production)\n", .{});
    std.debug.print("  --insecure-allow-all         Bypass ALL authorization checks (NOT FOR PRODUCTION)\n", .{});
    std.debug.print("  --help                       Show this help message\n", .{});
    std.debug.print("\nConfig File Locations (searched in order):\n", .{});
    std.debug.print("  1. .geode/config.{{yaml|toml|json}}    (project config)\n", .{});
    std.debug.print("  2. ~/.config/geode/config.*          (user config)\n", .{});
    std.debug.print("\nIf no listen option is specified, defaults to 0.0.0.0:3141 (QUIC/TLS).\n", .{});
    std.debug.print("Auto-generated certificates are placed in data_dir or /tmp.\n", .{});
}

/// Parse command line arguments into ServerConfig
/// Returns null if help was requested (caller should exit)
pub fn parseArgs(allocator: std.mem.Allocator) !?ServerConfig {
    // Zig 0.16 compat: read /proc/self/cmdline to get process args.
    // NOTE: /proc files report size 0 via stat/length(), so we must read in
    // chunks until EOF rather than trusting length(). Max 64 KiB is safely
    // above Linux's ARG_MAX-aware cmdline truncation.
    const io = std.Io.Threaded.global_single_threaded.io();
    const cmdline_file = std.Io.Dir.openFileAbsolute(io, "/proc/self/cmdline", .{}) catch return error.StdioUnavailable;
    defer cmdline_file.close(io);

    const max_cmdline: usize = 64 * 1024;
    const cmdline_data = try allocator.alloc(u8, max_cmdline);
    defer allocator.free(cmdline_data);

    var total_read: usize = 0;
    while (total_read < max_cmdline) {
        const n = cmdline_file.readPositional(io, &.{cmdline_data[total_read..]}, total_read) catch return error.StdioUnavailable;
        if (n == 0) break;
        total_read += n;
    }
    const filled = cmdline_data[0..total_read];

    // Split by null bytes to get individual args
    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    var start: usize = 0;
    for (filled, 0..) |c, i| {
        if (c == 0) {
            if (i > start) {
                args_list.append(allocator, filled[start..i]) catch return error.OutOfMemory;
            }
            start = i + 1;
        }
    }
    if (args_list.items.len == 0) return error.StdioUnavailable;

    return try parseArgsFromSlice(allocator, args_list.items);
}

/// Parse command line arguments from a caller-supplied slice.
/// This is the testable seam under parseArgs — unit tests construct an
/// argv slice in-memory and avoid /proc/self/cmdline.
/// Returns null if --help/-h was encountered (caller should exit).
pub fn parseArgsFromSlice(allocator: std.mem.Allocator, args: []const []const u8) !?ServerConfig {
    var config = ServerConfig{};
    var custom_config_path: ?[]const u8 = null;

    if (args.len == 0) return error.StdioUnavailable;

    // Check for help flag first
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                return null; // Signal to caller that help was shown
            }
        }
    }

    // First pass: look for --config flag to get custom config path
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--config") or std.mem.eql(u8, args[ai], "-c")) {
            if (ai + 1 < args.len) {
                custom_config_path = args[ai + 1];
            }
            break;
        }
    }

    // Load config file (custom path or search for defaults)
    if (custom_config_path) |path| {
        // Load from specified path
        if (loadConfigFromPath(allocator, path)) |result| {
            var mutable_result = result;
            defer mutable_result.deinit();
            mergeFileConfig(&config, result);
        } else |err| {
            std.debug.print("Warning: Failed to load config file '{s}': {}\n", .{ path, err });
        }
    } else {
        // Search for config file in default locations
        if (loadConfigFile(allocator)) |maybe_result| {
            if (maybe_result) |result| {
                var mutable_result = result;
                defer mutable_result.deinit();
                mergeFileConfig(&config, mutable_result);
            }
        } else |_| {
            // No config file found, use defaults (this is normal)
        }
    }

    // Parse all arguments (CLI flags override config file values)
    ai = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];

        if ((std.mem.eql(u8, arg, "--listen-quic") or std.mem.eql(u8, arg, "--listen")) and ai + 1 < args.len) {
            config.listen_quic = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_listen_quic = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--listen-grpc") and ai + 1 < args.len) {
            config.listen_grpc = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_listen_grpc = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--cert") and ai + 1 < args.len) {
            config.cert_path = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_cert_path = true;
            config.cert_explicit = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--key") and ai + 1 < args.len) {
            config.key_path = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_key_path = true;
            config.key_explicit = true;
            ai += 1;
        } else if ((std.mem.eql(u8, arg, "--data_dir") or std.mem.eql(u8, arg, "--data-dir")) and ai + 1 < args.len) {
            config.data_dir = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_data_dir = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--order-keys") and ai + 1 < args.len) {
            const mode = args[ai + 1];
            if (std.mem.eql(u8, mode, "expr")) {
                config.order_keys_mode_expr = true;
            } else if (std.mem.eql(u8, mode, "ident-only")) {
                config.order_keys_mode_expr = false;
            }
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--log-level") and ai + 1 < args.len) {
            config.log_level_arg = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_log_level_arg = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--idle-timeout") and ai + 1 < args.len) {
            config.idle_timeout_ms = std.fmt.parseUnsigned(u64, args[ai + 1], 10) catch 300000;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--max-connections") and ai + 1 < args.len) {
            config.max_connections = std.fmt.parseUnsigned(usize, args[ai + 1], 10) catch 0;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--persist-interval") and ai + 1 < args.len) {
            config.persist_interval_ms = std.fmt.parseUnsigned(u64, args[ai + 1], 10) catch 100;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--cluster-port") and ai + 1 < args.len) {
            // CANARY: REQ=REQ-DIST-CLI-001; FEATURE="DistributedClusterCLI"; ASPECT=ClusterPort; STATUS=TESTED; TEST=tests/test_cli_args_cluster.zig; OWNER=core; UPDATED=2026-05-25
            config.cluster_port = std.fmt.parseUnsigned(u16, args[ai + 1], 10) catch null;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--peers") and ai + 1 < args.len) {
            // CANARY: REQ=REQ-DIST-CLI-001; FEATURE="DistributedClusterCLI"; ASPECT=PeersList; STATUS=TESTED; TEST=tests/test_cli_args_cluster.zig; OWNER=core; UPDATED=2026-05-25
            const raw = args[ai + 1];
            // Count non-empty parts so we can size the destination slice exactly.
            var count: usize = 0;
            var probe = std.mem.splitScalar(u8, raw, ',');
            while (probe.next()) |part| {
                if (part.len > 0) count += 1;
            }
            // If a previous --peers run already allocated a list, free it so we don't leak.
            if (config._allocated_peers) {
                for (config.peers) |p| allocator.free(p);
                allocator.free(config.peers);
                config._allocated_peers = false;
                config.peers = &.{};
            }
            const list = try allocator.alloc([]const u8, count);
            var idx: usize = 0;
            var it = std.mem.splitScalar(u8, raw, ',');
            while (it.next()) |part| {
                if (part.len == 0) continue;
                list[idx] = try allocator.dupe(u8, part);
                idx += 1;
            }
            config.peers = list;
            config._allocated_peers = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--enable-auth")) {
            config.enable_auth = true;
        } else if (std.mem.eql(u8, arg, "--no-auth")) {
            if (@import("builtin").mode != .Debug) {
                std.debug.print("Error: --no-auth is only available in debug builds. Use proper credentials for production.\n", .{});
                std.process.exit(1);
            }
            config.enable_auth = false;
            std.log.warn("Authentication disabled via --no-auth. This is NOT recommended for production use.", .{});
        } else if (std.mem.eql(u8, arg, "--insecure-allow-all")) {
            // CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
            config.insecure_allow_all = true;
        } else if (std.mem.eql(u8, arg, "--enable-fle") or std.mem.eql(u8, arg, "--enable-tde")) {
            // FLE/TDE are always available; flags accepted for compatibility
        } else if (std.mem.eql(u8, arg, "--tde-provider") and ai + 1 < args.len) {
            // TDE provider selection; accepted for compatibility (default provider used)
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            // Already processed in first pass, skip value
            if (ai + 1 < args.len) ai += 1;
        }
    }

    if (config.listen_quic == null and config.listen_grpc == null) {
        config.listen_quic = "0.0.0.0:3141";
    }
    return config;
}

/// Resolve certificate paths based on configuration.
/// Precedence: CLI flags > GEODE_CERT_DIR env > data_dir > /tmp fallback.
/// Returns the resolved cert_path/key_path plus whether each was EXPLICITLY
/// supplied by the operator (vs auto-derived). Callers must honor an explicit
/// cert by loading it as-is and failing loud if it cannot be read — never
/// regenerate or fall back. See
/// docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
pub fn resolveCertPaths(allocator: std.mem.Allocator, config: *ServerConfig) !struct {
    cert_path: []const u8,
    key_path: []const u8,
    cert_explicit: bool,
    key_explicit: bool,
} {
    // If QUIC is enabled and no custom certs specified, use defaults
    if (config.listen_quic != null) {
        if (config.cert_path == null or config.key_path == null) {
            // Check GEODE_CERT_DIR env var first (set by systemd unit).
            // This puts certs in /etc/geode/certs/ (0755) so non-root
            // processes can read the public cert for CA verification.
            const cert_dir: ?[]const u8 = posixGetenv("GEODE_CERT_DIR");

            if (config.cert_path == null) {
                if (cert_dir) |dir| {
                    config.cert_path = try std.fmt.allocPrint(allocator, "{s}/server.crt", .{dir});
                    config._allocated_cert_path = true;
                } else if (config.data_dir) |dir| {
                    config.cert_path = try std.fmt.allocPrint(allocator, "{s}/server.crt", .{dir});
                    config._allocated_cert_path = true;
                } else {
                    config.cert_path = "/tmp/geode-server.crt";
                }
            }

            if (config.key_path == null) {
                if (cert_dir) |dir| {
                    config.key_path = try std.fmt.allocPrint(allocator, "{s}/server.key", .{dir});
                    config._allocated_key_path = true;
                } else if (config.data_dir) |dir| {
                    config.key_path = try std.fmt.allocPrint(allocator, "{s}/server.key", .{dir});
                    config._allocated_key_path = true;
                } else {
                    config.key_path = "/tmp/geode-server.key";
                }
            }
        }
    } else {
        // For non-QUIC, use dummy paths if not specified
        config.cert_path = config.cert_path orelse "certs/server.crt";
        config.key_path = config.key_path orelse "certs/server.key";
    }

    return .{
        .cert_path = config.cert_path.?,
        .key_path = config.key_path.?,
        .cert_explicit = config.cert_explicit,
        .key_explicit = config.key_explicit,
    };
}
