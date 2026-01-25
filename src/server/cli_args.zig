const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-CONFIG-001; FEATURE="External Library Migration"; ASPECT=ConfigManagement; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// External configuration library - XDG compliant, multi-format support (YAML, TOML, JSON)
// Provides config file support with precedence: flags > env > project > user > system > defaults
const config_lib = @import("config");

// CANARY: REQ=REQ-SERVER-REFACTOR-007; FEATURE="ServerRefactoring"; ASPECT=CLI_ARGS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - CLI Argument Parsing Module (Third Increment)
// Extracted from server/main.zig to improve modularity and testability

/// Server configuration parsed from CLI arguments
pub const ServerConfig = struct {
    // Output formatting
    result_format_txt: bool = false,
    disable_estimates: bool = false,
    compact_profile: bool = false,
    memcurve_profile: bool = false,

    // Network configuration
    listen_quic: ?[]const u8 = null,
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    force_no_tls: bool = false,

    // Storage configuration
    data_dir: ?[]const u8 = null,

    // Logging
    log_level_arg: ?[]const u8 = null,

    // Test overrides
    test_wal_skip_ratio: ?f64 = null,
    test_exit_after_first: bool = false,
    match_max_results_override: ?usize = null,
    match_max_frontier_override: ?usize = null,

    // Query behavior
    order_keys_mode_expr: bool = true, // enable property-based ordering by default

    // Catalog
    catalog_create_name: ?[]const u8 = null,
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
}

/// Print help message to stdout
pub fn printHelp() void {
    std.debug.print("Geode Server v0.19.0\n\n", .{});
    std.debug.print("Usage: geode serve [OPTIONS]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -c, --config <path>          Path to config file (YAML, TOML, or JSON)\n", .{});
    std.debug.print("  --listen-quic <addr:port>    Listen on QUIC/TLS (e.g., 0.0.0.0:3141)\n", .{});
    std.debug.print("  --cert <path>                Path to TLS certificate (default: auto-generate)\n", .{});
    std.debug.print("  --key <path>                 Path to TLS private key (default: auto-generate)\n", .{});
    std.debug.print("  --data_dir <path>            Data directory for storage and generated certs\n", .{});
    std.debug.print("  --result-format <txt|json>   Result format (default: json)\n", .{});
    std.debug.print("  --no-estimates               Disable query estimation\n", .{});
    std.debug.print("  --profile-compact            Enable compact profiling\n", .{});
    std.debug.print("  --profile-memcurve           Enable memory curve profiling\n", .{});
    std.debug.print("  --order-keys expr            Allow expressions in ORDER BY\n", .{});
    std.debug.print("  --match-max-results <N>      Override MATCH guard max_results (test/deterministic)\n", .{});
    std.debug.print("  --match-max-frontier <N>     Override MATCH guard max_frontier (test/deterministic)\n", .{});
    std.debug.print("  --log-level <lvl>            Set log level trace|debug|info|warn|error|critical (default info)\n", .{});
    std.debug.print("  --help                       Show this help message\n", .{});
    std.debug.print("\nConfig File Locations (searched in order):\n", .{});
    std.debug.print("  1. .geode/config.{yaml|toml|json}    (project config)\n", .{});
    std.debug.print("  2. ~/.config/geode/config.*          (user config)\n", .{});
    std.debug.print("\nIf no listen option is specified, defaults to stdio mode.\n", .{});
    std.debug.print("Auto-generated certificates are placed in data_dir or /tmp.\n", .{});
}

/// Parse command line arguments into ServerConfig
/// Returns null if help was requested (caller should exit)
pub fn parseArgs(allocator: std.mem.Allocator) !?ServerConfig {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
        if (loadConfigFile(allocator)) |result| {
            var mutable_result = result;
            defer mutable_result.deinit();
            mergeFileConfig(&config, result);
        } else |_| {
            // No config file found, use defaults (this is normal)
        }
    }

    // Parse all arguments (CLI flags override config file values)
    ai = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];

        if (std.mem.eql(u8, arg, "--result-format") and ai + 1 < args.len) {
            const f = args[ai + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) {
                config.result_format_txt = true;
            }
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--no-estimates")) {
            config.disable_estimates = true;
        } else if (std.mem.eql(u8, arg, "--profile-compact")) {
            config.compact_profile = true;
        } else if (std.mem.eql(u8, arg, "--profile-memcurve")) {
            config.memcurve_profile = true;
        } else if (std.mem.eql(u8, arg, "--test-wal-skip-ratio") and ai + 1 < args.len) {
            const v = std.fmt.parseFloat(f64, args[ai + 1]) catch -1.0;
            if (v >= 0.0) config.test_wal_skip_ratio = v;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--listen-quic") and ai + 1 < args.len) {
            config.listen_quic = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--cert") and ai + 1 < args.len) {
            config.cert_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--key") and ai + 1 < args.len) {
            config.key_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--data_dir") and ai + 1 < args.len) {
            config.data_dir = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--order-keys") and ai + 1 < args.len) {
            const mode = args[ai + 1];
            if (std.mem.eql(u8, mode, "expr")) {
                config.order_keys_mode_expr = true;
            } else if (std.mem.eql(u8, mode, "ident-only")) {
                config.order_keys_mode_expr = false;
            }
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--test-exit-after-first-request")) {
            config.test_exit_after_first = true;
        } else if (std.mem.eql(u8, arg, "--no-tls")) {
            config.force_no_tls = true;
        } else if (std.mem.eql(u8, arg, "--log-level") and ai + 1 < args.len) {
            config.log_level_arg = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--catalog-create") and ai + 1 < args.len) {
            config.catalog_create_name = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--match-max-results") and ai + 1 < args.len) {
            const mv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (mv > 0) config.match_max_results_override = mv;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--match-max-frontier") and ai + 1 < args.len) {
            const fv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (fv > 0) config.match_max_frontier_override = fv;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            // Already processed in first pass, skip value
            if (ai + 1 < args.len) ai += 1;
        }
    }

    return config;
}

/// Resolve certificate paths based on configuration
/// Returns struct with cert_path and key_path fields
pub fn resolveCertPaths(allocator: std.mem.Allocator, config: *ServerConfig) !struct { cert_path: []const u8, key_path: []const u8 } {
    // If QUIC is enabled and no custom certs specified, use defaults
    if (config.listen_quic != null) {
        if (config.cert_path == null or config.key_path == null) {
            // Use default paths or fallback to /tmp
            const default_cert = if (config.data_dir) |dir|
                try std.fmt.allocPrint(allocator, "{s}/server.crt", .{dir})
            else
                "/tmp/geode-server.crt";

            const default_key = if (config.data_dir) |dir|
                try std.fmt.allocPrint(allocator, "{s}/server.key", .{dir})
            else
                "/tmp/geode-server.key";

            config.cert_path = config.cert_path orelse default_cert;
            config.key_path = config.key_path orelse default_key;
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
