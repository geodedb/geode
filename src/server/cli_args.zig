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

    // GAP-0259: Configurable QUIC idle timeout (default 300s / 5 minutes)
    idle_timeout_ms: u64 = 300000,

    // GAP-0260: Deferred persistence interval (default 30s)
    // Longer interval reduces persistence thread race window with query threads
    persist_interval_ms: u64 = 30000,

    // Track which fields were allocated (vs static strings)
    _allocated_listen_quic: bool = false,
    _allocated_listen_grpc: bool = false,
    _allocated_cert_path: bool = false,
    _allocated_key_path: bool = false,
    _allocated_data_dir: bool = false,
    _allocated_log_level_arg: bool = false,

    /// Free all allocated memory
    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        if (self._allocated_listen_quic) if (self.listen_quic) |s| allocator.free(s);
        if (self._allocated_listen_grpc) if (self.listen_grpc) |s| allocator.free(s);
        if (self._allocated_cert_path) if (self.cert_path) |s| allocator.free(s);
        if (self._allocated_key_path) if (self.key_path) |s| allocator.free(s);
        if (self._allocated_data_dir) if (self.data_dir) |s| allocator.free(s);
        if (self._allocated_log_level_arg) if (self.log_level_arg) |s| allocator.free(s);
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
        if (config.cert_path == null) config.cert_path = v;
    }
    if (file_result.getString("key_path")) |v| {
        if (config.key_path == null) config.key_path = v;
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
    std.debug.print("  --persist-interval <ms>      Background persistence interval in milliseconds (default: 100)\n", .{});
    std.debug.print("  --no-auth                    Disable authentication (NOT recommended for production)\n", .{});
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
    // Zig 0.16 compat: read /proc/self/cmdline to get process args
    const io = std.Io.Threaded.global_single_threaded.io();
    const cmdline_file = std.Io.Dir.openFileAbsolute(io, "/proc/self/cmdline", .{}) catch return error.StdioUnavailable;
    defer cmdline_file.close(io);
    const cmdline_len = cmdline_file.length(io) catch return error.StdioUnavailable;
    const cmdline_data = try allocator.alloc(u8, @intCast(cmdline_len));
    defer allocator.free(cmdline_data);
    _ = cmdline_file.readPositionalAll(io, cmdline_data, 0) catch return error.StdioUnavailable;
    // Split by null bytes to get individual args
    var args_list = std.ArrayList([:0]u8).empty;
    defer args_list.deinit(allocator);
    var start: usize = 0;
    for (cmdline_data, 0..) |c, i| {
        if (c == 0) {
            if (i > start) {
                cmdline_data[i] = 0; // ensure sentinel
                const arg: [:0]u8 = cmdline_data[start..i :0];
                args_list.append(allocator, arg) catch return error.OutOfMemory;
            }
            start = i + 1;
        }
    }
    const args = args_list.items;

    var config = ServerConfig{};
    var custom_config_path: ?[]const u8 = null;

    // Check for help flag first
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null; // Signal to caller that help was shown
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
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--key") and ai + 1 < args.len) {
            config.key_path = try allocator.dupe(u8, args[ai + 1]);
            config._allocated_key_path = true;
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
        } else if (std.mem.eql(u8, arg, "--persist-interval") and ai + 1 < args.len) {
            config.persist_interval_ms = std.fmt.parseUnsigned(u64, args[ai + 1], 10) catch 100;
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
/// Returns struct with cert_path and key_path fields.
pub fn resolveCertPaths(allocator: std.mem.Allocator, config: *ServerConfig) !struct { cert_path: []const u8, key_path: []const u8 } {
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
    };
}
