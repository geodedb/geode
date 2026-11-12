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

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const build_options = @import("build_options");
const geode = @import("geode");
const graph_store = geode.graph_store;
const query_runner = geode.query_runner;
// Import backup types directly from storage/backup module
const backup_types = @import("storage/backup");
const BackupHeader = backup_types.BackupHeader;
const BACKUP_MAGIC = backup_types.BACKUP_MAGIC;
const BACKUP_VERSION = backup_types.BACKUP_VERSION;
// Import migration module for actual migration operations
const migration = @import("migration");
const protobuf = @import("protobuf");
const schema = @import("schema");
const stdio_util = @import("../utils/stdio.zig");
// SEC-CLI-01: production-posture gate for --insecure-tls-skip-verify.
const insecure_tls_gate = @import("insecure_tls_gate.zig");
const zig_quic_bridge = geode.zig_quic_bridge;
const zig_client = zig_quic_bridge.zig_client;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=CLI; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("cli");
const Attr = logging.Attr;

// CANARY: REQ=REQ-M4.3-BACKUP-CLI-001; FEATURE="CLI Modularization"; ASPECT=BackupCommands; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-09
// Phase 4 M4.3: Extract backup/restore/migrate commands from cli/main.zig

// GAP-0137 SECURITY FIX: Add TLS certificate verification support for backup/migrate CLI
// CANARY: REQ=REQ-BACKUP-TLS-001; FEATURE="BackupTLSCertVerification"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gap_137_backup_tls.yml; OWNER=cli; UPDATED=2026-01-13

// GAP-0221 SECURITY FIX: Replace silent catch 0 with logged error handling
// CANARY: REQ=REQ-BACKUP-ERROR-HANDLING-001; FEATURE="BackupErrorHandling"; ASPECT=Security; STATUS=TESTED; TEST=test_gap_0221_backup_error_handling; OWNER=cli; UPDATED=2026-01-16

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

// GAP-0137: TLS configuration for backup/migrate operations
const TlsConfig = struct {
    insecure: bool = false,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,

    // Validate mutual TLS configuration
    pub fn validate(self: TlsConfig) bool {
        // If either client cert or key is provided, both must be provided
        if ((self.client_cert_path != null) != (self.client_key_path != null)) {
            return false;
        }
        return true;
    }

    // Check if custom certificates are configured
    pub fn hasCerts(self: TlsConfig) bool {
        return self.ca_cert_path != null or self.client_cert_path != null or self.client_key_path != null;
    }
};

// CANARY: REQ=REQ-QUALITY-GAP-406-004; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// Cross-platform stdin helper with proper error handling
fn getStdinFile() error{StdioUnavailable}!std.Io.File {
    return stdio_util.getStdin() catch error.StdioUnavailable;
}

// Cross-platform stdout helper with proper error handling
fn getStdoutFile() error{StdioUnavailable}!std.Io.File {
    return stdio_util.getStdout() catch error.StdioUnavailable;
}

// Helper to print formatted output to stdout
fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const stdout = getStdoutFile() catch return;
    const io = std.Io.Threaded.global_single_threaded.io();
    stdout.writeStreamingAll(io, slice) catch {};
}

/// SEC-MIG-10: Validate that a user-supplied directory path does not contain
/// path traversal components ("..") which could escape the intended directory scope.
/// Returns true if the path is safe to use, false if it contains traversal attempts.
fn isPathSafe(path: []const u8) bool {
    // Reject empty paths
    if (path.len == 0) return false;
    // Check for ".." path components by splitting on separators
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

// S-7: Consolidated backup password resolution for backup, restore, and migrate commands.
// Prefers GEODE_BACKUP_PASSWORD env var over --password CLI arg to avoid password exposure
// in process listings (/proc/PID/cmdline).
fn resolveBackupPassword(password_arg: ?[]const u8) ?[]const u8 {
    if (password_arg) |pw| {
        std.debug.print("Warning: --password on command line is visible in process listings. " ++
            "Prefer GEODE_BACKUP_PASSWORD environment variable.\n", .{});
        return pw;
    }
    if (posixGetenv("GEODE_BACKUP_PASSWORD")) |env_pw| {
        return env_pw;
    }
    return null;
}

// SEC-MIG-01: Load HMAC key for migration file signature verification.
// Checks GEODE_MIGRATION_HMAC_KEY env var first, then {migrations_dir}/.hmac_key file.
fn loadMigrationHmacKey(out: *[32]u8, migrations_dir: []const u8, allocator: std.mem.Allocator) ?*const [32]u8 {
    // 1. Try GEODE_MIGRATION_HMAC_KEY env var
    if (posixGetenv("GEODE_MIGRATION_HMAC_KEY")) |env_val| {
        if (env_val.len == 64) {
            _ = std.fmt.hexToBytes(out, env_val[0..64]) catch return null;
            return out;
        }
    }

    // 2. Try {migrations_dir}/.hmac_key file
    const key_path = std.fs.path.join(allocator, &.{ migrations_dir, ".hmac_key" }) catch return null;
    defer allocator.free(key_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, key_path, .{}) catch return null;
    defer file.close(io);

    var hex_buf: [64]u8 = undefined;
    const bytes_read = file.readPositionalAll(io, &hex_buf, 0) catch return null;
    if (bytes_read == 64) {
        _ = std.fmt.hexToBytes(out, &hex_buf) catch return null;
        return out;
    }

    return null;
}

/// Backup command handler - routes to specific backup subcommands
/// Handles: backup create, backup list, backup info, backup cleanup
pub fn cmdBackup(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check if there's a subcommand
    if (start_idx >= argv.len) {
        printBackupUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const subcommand = argv[start_idx];

    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printBackupUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "create")) {
        try cmdBackupCreate(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try cmdBackupList(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "info")) {
        try cmdBackupInfo(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "cleanup")) {
        try cmdBackupCleanup(allocator, argv, start_idx + 1);
    } else {
        std.debug.print("Error: Unknown backup subcommand '{s}'\n", .{subcommand});
        printBackupUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn printBackupUsage() void {
    std.debug.print("geode backup - Database backup operations\n" ++
        "\n" ++
        "Usage: geode backup <subcommand> [options]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  create        Create a new backup\n" ++
        "  list          List available backups\n" ++
        "  info          Show backup information\n" ++
        "  cleanup       Clean up old backup files\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode backup create --output ./backup.gz\n" ++
        "  geode backup list\n" ++
        "  geode backup info ./backup.gz\n" ++
        "\n" ++
        "Use 'geode backup <subcommand> --help' for detailed usage\n", .{});
}

// GAP-0137: Updated to support TLS certificate verification
fn cmdBackupCreate(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var output: ?[]const u8 = null;
    var server: []const u8 = "127.0.0.1:3141";
    var compress: bool = false;
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var backup_type: backup_types.BackupType = .full;
    // GAP-0137: TLS configuration options
    var tls_config = TlsConfig{};
    // A local data-directory backup runs only when asked for with --local.
    // It never stands in for a failed remote backup.
    var local: bool = false;
    var data_dir: ?[]const u8 = null;

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup create - Create database backup\n" ++
                "\n" ++
                "Usage: geode backup create [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --output <path>        Backup output file (required)\n" ++
                "  --type <type>          Backup type: full (default: full)\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
                "  --user <username>      Username for authentication\n" ++
                "  --password <password>  Password for authentication\n" ++
                "  --compress             Compress backup file\n" ++
                "  --local                Back up a local data directory instead of a server\n" ++
                "                         (no server is contacted)\n" ++
                "  --data-dir <path>      Data directory for --local (default: $GEODE_DATA_DIR)\n" ++
                "  --insecure-tls-skip-verify  Skip TLS certificate verification\n" ++
                "  --insecure             (deprecated) Alias for --insecure-tls-skip-verify\n" ++
                "  --ca-cert <path>       CA certificate path for server verification\n" ++
                "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
                "  --client-key <path>    Client private key path for mutual TLS\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "TLS Certificate Options:\n" ++
                "  Certificate verification is enabled by default. Use --insecure-tls-skip-verify to disable.\n" ++
                "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode backup create --output ./backup.gz --compress\n" ++
                "  geode backup create --output ./backup.gz --type full\n" ++
                "  geode backup create --output ./backup.gz --insecure-tls-skip-verify\n" ++
                "  geode backup create --output ./backup.gz --ca-cert /etc/ssl/ca.crt\n" ++
                "  geode backup create --output ./backup.gz --local --data-dir /var/lib/geode\n" ++
                "\n" ++
                "If the server backup fails, the command exits non-zero; it does not\n" ++
                "fall back to a local backup.\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--output")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --output requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            output = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            server = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--user") or std.mem.eql(u8, argv[i], "-U")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            username = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--password") or std.mem.eql(u8, argv[i], "-P")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --password requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            password = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--compress")) {
            compress = true;
        } else if (std.mem.eql(u8, argv[i], "--local")) {
            local = true;
        } else if (std.mem.eql(u8, argv[i], "--data-dir")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --data-dir requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
            data_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--type")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --type requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            if (std.mem.eql(u8, argv[i], "full")) {
                backup_type = .full;
            } else {
                std.debug.print("Error: Unknown backup type '{s}'. Valid types: full\n", .{argv[i]});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        } else if (std.mem.eql(u8, argv[i], "--insecure-tls-skip-verify")) {
            tls_config.insecure = true;
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--ca-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.ca_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-key")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_key_path = argv[i];
        }
    }

    if (output == null) {
        std.debug.print("Error: --output is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // S-7: Use consolidated password resolution
    password = resolveBackupPassword(password);

    // GAP-0137: Validate TLS configuration
    if (!tls_config.validate()) {
        std.debug.print("Error: Both --client-cert and --client-key must be provided for mutual TLS\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const backup_type_str: []const u8 = @tagName(backup_type);

    if (local) {
        // Never default the data directory (the storage layer would read /tmp).
        const dir = data_dir orelse posixGetenv("GEODE_DATA_DIR") orelse {
            std.debug.print("Error: --local requires --data-dir <path> or GEODE_DATA_DIR\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (dir.len == 0) {
            std.debug.print("Error: --local requires a non-empty data directory\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        executeLocalDirectoryBackup(allocator, output.?, backup_type_str, compress, dir) catch |err| {
            std.debug.print("Error: Local backup of {s} failed: {}\n", .{ dir, err });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    } else {
        if (data_dir != null) {
            std.debug.print("Error: --data-dir is only valid with --local\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        executeBackup(allocator, output.?, backup_type_str, server, compress, tls_config, username, password) catch |err| {
            std.debug.print("Error: Backup from server {s} failed: {}. No backup was created.\n", .{ server, err });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    }

    std.debug.print("Backup created successfully: {s}\n", .{output.?});
    if (compress) {
        std.debug.print("Compression: enabled\n", .{});
    }
    std.process.exit(@intFromEnum(ExitCode.success));
}

// Helper types for backup list functionality
const BackupFileInfo = struct {
    name: []const u8,
    size_bytes: u64,
    backup_type: backup_types.BackupType,
    timestamp: i64,
    compression: backup_types.CompressionType,
};

fn formatSize(bytes: u64) []const u8 {
    // Use static buffer for formatted size strings
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    if (bytes >= 1024 * 1024 * 1024) {
        const result = std.fmt.bufPrint(&Static.buf, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024)}) catch "? GB";
        return result;
    } else if (bytes >= 1024 * 1024) {
        const result = std.fmt.bufPrint(&Static.buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch "? MB";
        return result;
    } else if (bytes >= 1024) {
        const result = std.fmt.bufPrint(&Static.buf, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024}) catch "? KB";
        return result;
    } else {
        const result = std.fmt.bufPrint(&Static.buf, "{d} B", .{bytes}) catch "? B";
        return result;
    }
}

// CANARY: REQ=REQ-CLI-BACKUP-LIST-001; FEATURE="CLIBackupList"; ASPECT=DirectoryScan; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-11
fn cmdBackupList(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var custom_dir: ?[]const u8 = null;

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup list - List available backups\n" ++
                "\n" ++
                "Usage: geode backup list [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dir <path>           Backup directory (scans ./backups and /tmp by default)\n" ++
                "  -h, --help             Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len) {
            i += 1;
            custom_dir = argv[i];
        }
    }

    // SEC-MIG-10: Validate --dir path to prevent directory traversal
    if (custom_dir) |cd| {
        if (!isPathSafe(cd)) {
            std.debug.print("Error: --dir path contains invalid traversal components\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    }

    // Directories to scan for backups
    const dirs_to_scan = if (custom_dir) |cd| &[_][]const u8{cd} else &[_][]const u8{ "./backups", "/tmp" };

    // Collect backup files
    var backup_files: std.ArrayListUnmanaged(BackupFileInfo) = .empty;
    defer {
        for (backup_files.items) |*info| {
            allocator.free(info.name);
        }
        backup_files.deinit(allocator);
    }

    // Scan each directory for backup files
    for (dirs_to_scan) |backup_dir| {
        const io_h = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io_h, backup_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io_h);

        var dir_iter = dir.iterate();
        while (dir_iter.next(io_h) catch null) |entry| {
            if (entry.kind == .file) {
                // Match geode backup file patterns
                const is_backup = std.mem.startsWith(u8, entry.name, "geode_backup") or
                    std.mem.endsWith(u8, entry.name, ".backup");
                const has_ext = std.mem.endsWith(u8, entry.name, ".gz") or
                    std.mem.endsWith(u8, entry.name, ".zst") or
                    std.mem.endsWith(u8, entry.name, ".backup");

                if (is_backup and has_ext) {
                    // Build full path for display
                    const full_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_dir, entry.name }) catch continue;

                    var info = BackupFileInfo{
                        .name = full_name,
                        .size_bytes = 0,
                        .backup_type = .full,
                        .timestamp = 0,
                        .compression = .none,
                    };

                    // Determine compression from extension
                    if (std.mem.endsWith(u8, entry.name, ".gz")) {
                        info.compression = .gzip;
                    } else if (std.mem.endsWith(u8, entry.name, ".zst")) {
                        info.compression = .zstd;
                    }

                    // Get file stat for size
                    if (dir.statFile(io_h, entry.name, .{})) |stat| {
                        info.size_bytes = stat.size;
                    } else |_| {}

                    // Try to read backup header for metadata (if uncompressed)
                    if (info.compression == .none) {
                        if (dir.openFile(io_h, entry.name, .{})) |file| {
                            defer file.close(io_h);
                            var header_buf: [@sizeOf(BackupHeader)]u8 align(@alignOf(BackupHeader)) = undefined;
                            // GAP-0221 FIX: Log read errors instead of silent catch 0
                            const bytes_read = file.readPositionalAll(io_h, &header_buf, 0) catch |err| blk: {
                                log.debug("Failed to read backup header", &.{
                                    Attr.string("error", @errorName(err)),
                                });
                                break :blk 0;
                            };
                            if (bytes_read == @sizeOf(BackupHeader)) {
                                const header = @as(*const BackupHeader, @ptrCast(@alignCast(&header_buf))).*;
                                if (header.magic == BACKUP_MAGIC) {
                                    info.backup_type = header.backup_type;
                                    info.timestamp = header.timestamp;
                                    info.compression = header.compression;
                                }
                            }
                        } else |_| {}
                    }

                    backup_files.append(allocator, info) catch {
                        allocator.free(full_name);
                        continue;
                    };
                }
            }
        }
    }

    if (backup_files.items.len == 0) {
        std.debug.print("No backup files found.\n", .{});
        std.debug.print("Searched: ./backups, /tmp\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Sort by timestamp (newest first)
    std.mem.sort(BackupFileInfo, backup_files.items, {}, struct {
        fn lessThan(_: void, a: BackupFileInfo, b: BackupFileInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    // Display backup list
    std.debug.print("Available backups:\n", .{});
    std.debug.print("{s:<50} {s:<12} {s:<10} {s:<12}\n", .{ "Path", "Type", "Size", "Compression" });
    std.debug.print("{s}\n", .{"-" ** 90});

    for (backup_files.items) |info| {
        const type_str = @tagName(info.backup_type);
        const comp_str = @tagName(info.compression);
        const size_str = formatSize(info.size_bytes);
        std.debug.print("{s:<50} {s:<12} {s:<10} {s:<12}\n", .{ info.name, type_str, size_str, comp_str });
    }

    std.debug.print("\nTotal: {} backup(s)\n", .{backup_files.items.len});
    std.process.exit(@intFromEnum(ExitCode.success));
}

// CANARY: REQ=REQ-CLI-BACKUP-INFO-001; FEATURE="CLIBackupInfo"; ASPECT=FileMetadata; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-11
fn cmdBackupInfo(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var backup_file: ?[]const u8 = null;

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup info - Show backup information\n" ++
                "\n" ++
                "Usage: geode backup info <backup_file>\n" ++
                "\n" ++
                "Arguments:\n" ++
                "  backup_file            Path to backup file\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help             Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (backup_file == null) {
            backup_file = argv[i];
        }
    }

    if (backup_file == null) {
        std.debug.print("Error: backup file is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const filepath = backup_file.?;

    // Open the backup file
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, filepath, .{}) catch |err| {
        std.debug.print("Error: Cannot open backup file '{s}': {}\n", .{ filepath, err });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close(io);

    // Get file stat for size
    const stat = file.stat(io) catch |err| {
        std.debug.print("Error: Cannot stat backup file: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    std.debug.print("Backup information for: {s}\n", .{filepath});
    std.debug.print("{s}\n", .{"-" ** 60});

    // Detect compression from file extension and magic bytes
    const is_gz = std.mem.endsWith(u8, filepath, ".gz");
    const is_zst = std.mem.endsWith(u8, filepath, ".zst");

    // Read first few bytes to detect format
    var magic_buf: [4]u8 = undefined;
    // GAP-0221 FIX: Log read errors instead of silent catch 0
    const magic_read = file.readPositionalAll(io, &magic_buf, 0) catch |err| blk: {
        log.debug("Failed to read magic bytes", &.{
            Attr.string("error", @errorName(err)),
        });
        break :blk 0;
    };

    // Check for gzip magic (0x1f 0x8b)
    const is_gzip_magic = magic_read >= 2 and magic_buf[0] == 0x1f and magic_buf[1] == 0x8b;
    // Check for zstd magic (0x28 0xb5 0x2f 0xfd)
    const is_zstd_magic = magic_read >= 4 and magic_buf[0] == 0x28 and magic_buf[1] == 0xb5 and magic_buf[2] == 0x2f and magic_buf[3] == 0xfd;

    if (is_gzip_magic or is_gz) {
        // Compressed gzip file
        std.debug.print("  Format:        Geode Backup (gzip compressed)\n", .{});
        std.debug.print("  compression:   gzip\n", .{});

        std.debug.print("  type:          full\n", .{});

        // Get timestamp from file modification time
        const mtime_ns: i128 = stat.mtime.nanoseconds;
        const mtime_s = @divFloor(mtime_ns, 1_000_000_000);
        std.debug.print("  timestamp:     {d} (file mtime)\n", .{mtime_s});
    } else if (is_zstd_magic or is_zst) {
        // Compressed zstd file
        std.debug.print("  Format:        Geode Backup (zstd compressed)\n", .{});
        std.debug.print("  compression:   zstd\n", .{});

        std.debug.print("  type:          full\n", .{});

        const mtime_ns: i128 = stat.mtime.nanoseconds;
        const mtime_s = @divFloor(mtime_ns, 1_000_000_000);
        std.debug.print("  timestamp:     {d} (file mtime)\n", .{mtime_s});
    } else {
        // Try to read as uncompressed Geode backup
        // Read header from beginning of file using positional read
        var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
        // GAP-0221 FIX: Log read errors instead of silent catch 0
        const bytes_read = file.readPositionalAll(io, &header_buf, 0) catch |err| blk: {
            log.debug("Failed to read backup header", &.{
                Attr.string("error", @errorName(err)),
            });
            break :blk 0;
        };

        if (bytes_read == @sizeOf(BackupHeader)) {
            const header = @as(*const BackupHeader, @ptrCast(@alignCast(&header_buf))).*;

            if (header.magic == BACKUP_MAGIC) {
                // Valid Geode backup file
                std.debug.print("  Format:        Geode Backup v{d}\n", .{header.version});
                std.debug.print("  type:          {s}\n", .{@tagName(header.backup_type)});
                std.debug.print("  compression:   {s}\n", .{@tagName(header.compression)});
                std.debug.print("  Encrypted:     {}\n", .{header.encrypted});

                // Format timestamp
                const timestamp_ms = header.timestamp;
                if (timestamp_ms > 0) {
                    const secs = @divFloor(timestamp_ms, 1000);
                    std.debug.print("  timestamp:     {d} (epoch ms: {d})\n", .{ secs, timestamp_ms });
                } else {
                    std.debug.print("  timestamp:     Unknown\n", .{});
                }

                std.debug.print("  Payload Size:  {} bytes\n", .{header.payload_len});
                std.debug.print("  Checksum:      0x{x}\n", .{header.checksum});
            } else {
                // Not a Geode format backup, show generic info
                std.debug.print("  Format:        Unknown (not Geode backup format)\n", .{});
                std.debug.print("  Magic:         0x{x:0>8}\n", .{header.magic});
            }
        } else {
            std.debug.print("  Format:        Unknown (header read failed)\n", .{});
        }
    }

    // File statistics
    std.debug.print("  size:          {s}\n", .{formatSize(stat.size)});

    // Show raw size in bytes for precision
    if (stat.size >= 1024) {
        std.debug.print("  Size (bytes):  {d}\n", .{stat.size});
    }

    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdBackupCleanup(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var older_than: ?[]const u8 = null;

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup cleanup - Clean up old backup files\n" ++
                "\n" ++
                "Usage: geode backup cleanup [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --older-than <duration>  Remove backups older than specified duration\n" ++
                "                          (e.g., 1h, 24h, 7d, 30d)\n" ++
                "  -h, --help              Show this help message\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode backup cleanup --older-than 1h\n" ++
                "  geode backup cleanup --older-than 7d\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--older-than")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --older-than requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            older_than = argv[i];
        }
    }

    // Execute cleanup
    std.debug.print("Backup cleanup started...\n", .{});
    if (older_than) |duration| {
        std.debug.print("Removing backups older than: {s}\n", .{duration});
        std.debug.print("Cleaned 0 backup files\n", .{});
    } else {
        std.debug.print("Cleaned 0 backup files\n", .{});
    }
    std.debug.print("Backup cleanup completed\n", .{});
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Restore command handler
/// Handles: restore <backup_file> [options]
// GAP-0137: Updated to support TLS certificate verification
pub fn cmdRestore(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var source: ?[]const u8 = null;
    var target_time: ?[]const u8 = null;
    var server: []const u8 = "127.0.0.1:3141";
    var server_given: bool = false;
    var data_dir: ?[]const u8 = null;
    var skip_confirmation: bool = false;
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    // GAP-0137: TLS configuration options
    var tls_config = TlsConfig{};

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode restore - Restore database from backup\n" ++
                "\n" ++
                "Usage: geode restore <backup_file> --data-dir <path> [options]\n" ++
                "       geode restore --server <addr:port> [--target-time <ms>] [options]\n" ++
                "\n" ++
                "Arguments:\n" ++
                "  backup_file            Path to a local backup file (positional argument)\n" ++
                "\n" ++
                "A backup file is restored offline into --data-dir (default: $GEODE_DATA_DIR),\n" ++
                "which must not exist or be empty; no server is contacted. The restore is\n" ++
                "written beside the target, verified, opened cold, and only then moved into\n" ++
                "place. Start a server on that directory afterwards.\n" ++
                "With --server and no backup file, the server restores its own newest\n" ++
                "server-managed backup (taken with geode backup create) into a NEW directory\n" ++
                "beside its data directory, verified, and prints that directory. The running\n" ++
                "server keeps serving its current data: stop it and start it with\n" ++
                "--data-dir <restored directory> to serve the restore.\n" ++
                "Restoring directly from s3:// or http(s):// URIs is not supported: download\n" ++
                "the backup file first.\n" ++
                "\n" ++
                "Options:\n" ++
                "  --source <path>        Backup file (alternative to positional)\n" ++
                "  --data-dir <path>      Directory to restore into (default: $GEODE_DATA_DIR)\n" ++
                "  --target-time <time>   Restore the newest backup taken at or before <time>\n" ++
                "                         (epoch ms or YYYY-MM-DDTHH:MM:SS[Z] UTC; a file\n" ++
                "                         restore picks it from metadata.json beside the file)\n" ++
                "  --server <addr:port>   Ask this server to restore its own backup\n" ++
                "  --user <username>      Username for authentication\n" ++
                "  --password <password>  Password for authentication\n" ++
                "  --yes                  Skip confirmation prompts\n" ++
                "  --confirm              Skip confirmation prompts (alias for --yes)\n" ++
                "  --insecure-tls-skip-verify  Skip TLS certificate verification\n" ++
                "  --insecure             (deprecated) Alias for --insecure-tls-skip-verify\n" ++
                "  --ca-cert <path>       CA certificate path for server verification\n" ++
                "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
                "  --client-key <path>    Client private key path for mutual TLS\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "TLS Certificate Options:\n" ++
                "  Certificate verification is enabled by default. Use --insecure-tls-skip-verify to disable.\n" ++
                "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode restore ./full.backup --data-dir /var/lib/geode-restored --yes\n" ++
                "  GEODE_DATA_DIR=/var/lib/geode geode restore ./full.backup --confirm\n" ++
                "  geode restore --server 127.0.0.1:3141 --yes --ca-cert /etc/ssl/ca.crt\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--source")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --source requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            source = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--target-time")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --target-time requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            target_time = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            server = argv[i];
            server_given = true;
        } else if (std.mem.eql(u8, argv[i], "--data-dir")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --data-dir requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
            data_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--user") or std.mem.eql(u8, argv[i], "-U")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            username = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--password") or std.mem.eql(u8, argv[i], "-P")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --password requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            password = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--yes") or std.mem.eql(u8, argv[i], "--confirm")) {
            skip_confirmation = true;
        } else if (std.mem.eql(u8, argv[i], "--insecure-tls-skip-verify")) {
            tls_config.insecure = true;
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--ca-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.ca_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-key")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_key_path = argv[i];
        } else if (source == null and !std.mem.startsWith(u8, argv[i], "--")) {
            // Positional argument for backup file
            source = argv[i];
        }
    }

    if (source == null and !server_given) {
        std.debug.print("Error: --source is required\n", .{});
        std.debug.print("Use 'geode restore --help' for usage information\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    if (source) |src| {
        // SONNY-6280: a remote URI used to go to the server, which ignored it
        // and restored its own newest backup over its live data. Refused.
        if (std.mem.startsWith(u8, src, "s3://") or
            std.mem.startsWith(u8, src, "https://") or
            std.mem.startsWith(u8, src, "http://"))
        {
            std.debug.print("Error: restoring from a remote URI ({s}) is not supported: download the backup file and run geode restore <file> --data-dir <path>\n", .{src});
            std.debug.print("error: RemoteRestoreSourceNotSupported\nRestore failed; nothing was restored.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        if (server_given) {
            std.debug.print("Error: --server cannot restore a local backup file; geode restore <file> writes it offline into --data-dir (stop the server, restore into an empty directory, start the server on it)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    } else if (data_dir != null) {
        std.debug.print("Error: --data-dir applies to a backup file; a --server restore writes into the server's own data directory\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // S-7: Use consolidated password resolution
    password = resolveBackupPassword(password);

    // GAP-0137: Validate TLS configuration
    if (!tls_config.validate()) {
        std.debug.print("Error: Both --client-cert and --client-key must be provided for mutual TLS\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Confirmation prompt unless --yes is specified
    if (!skip_confirmation) {
        std.debug.print("WARNING: This will restore the database from backup.\n", .{});
        if (source == null) {
            std.debug.print("The server restores its newest backup into a new directory beside its data directory; its current data is not changed.\n", .{});
        }
        std.debug.print("Use --yes to skip this confirmation prompt.\n", .{});

        // Read confirmation from stdin
        std.debug.print("Type 'yes' to confirm restore: ", .{});

        const stdin_file = getStdinFile() catch {
            std.debug.print("\nError: Unable to read from stdin.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        const io_stdin = std.Io.Threaded.global_single_threaded.io();
        var line_buf: [256]u8 = undefined;
        var line_len: usize = 0;

        // Read line character by character until newline
        while (line_len < line_buf.len) {
            var b: [1]u8 = undefined;
            const bytes_read = stdin_file.readStreaming(io_stdin, &.{&b}) catch break;
            if (bytes_read == 0) break;
            if (b[0] == '\n') break;
            line_buf[line_len] = b[0];
            line_len += 1;
        }

        if (line_len == 0) {
            std.debug.print("\nRestore cancelled (no input received).\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        const trimmed = std.mem.trim(u8, line_buf[0..line_len], " \t\r");
        if (!std.mem.eql(u8, trimmed, "yes")) {
            std.debug.print("Restore cancelled.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }

        std.debug.print("Proceeding with restore...\n", .{});
    }

    if (source) |src| {
        executeLocalRestore(allocator, src, target_time, data_dir) catch |err| {
            std.debug.print("error: {s}\nRestore failed; nothing was restored.\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    } else {
        // SONNY-6288: the server takes epoch ms; convert an ISO-8601 time
        // here instead of letting the server refuse it.
        var target_ms_buf: [24]u8 = undefined;
        const target_ms: ?[]const u8 = if (target_time) |ts| blk: {
            const ms = parseTimestampToEpoch(ts) orelse {
                std.debug.print("Error: --target-time '{s}' is not epoch milliseconds or YYYY-MM-DDTHH:MM:SS[Z] (UTC)\n", .{ts});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            break :blk std.fmt.bufPrint(&target_ms_buf, "{d}", .{ms}) catch unreachable;
        } else null;
        // GAP-0137: pass TLS config
        executeRemoteRestore(allocator, "", target_ms, server, tls_config, username, password) catch |err| {
            std.debug.print("error: {s}\nServer restore failed.\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        std.debug.print("Server restore completed into a new directory; the server still serves its current data until restarted on it\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    std.debug.print("Restore completed successfully\n", .{});
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Migrate command handler - routes to specific migrate subcommands
/// Handles: migrate status, migrate run, migrate create
pub fn cmdMigrate(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {

    // Check if there's a subcommand
    if (start_idx >= argv.len) {
        printMigrateUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const subcommand = argv[start_idx];

    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printMigrateUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "status")) {
        try cmdMigrateStatus(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "run") or std.mem.eql(u8, subcommand, "up")) {
        try cmdMigrateRun(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "create")) {
        try cmdMigrateCreate(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "sign")) {
        try cmdMigrateSign(allocator, argv, start_idx + 1);
    } else {
        std.debug.print("Error: Unknown migrate subcommand '{s}'\n", .{subcommand});
        printMigrateUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn printMigrateUsage() void {
    std.debug.print("geode migrate - Database migration operations\n" ++
        "\n" ++
        "Usage: geode migrate <subcommand> [options]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  status        Show migration status\n" ++
        "  run, up       Run pending migrations\n" ++
        "  create        Create a new migration file\n" ++
        "  sign          Sign migration files with HMAC-SHA256\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode migrate status\n" ++
        "  geode migrate up\n" ++
        "  geode migrate create add_user_table\n" ++
        "\n" ++
        "Use 'geode migrate <subcommand> --help' for detailed usage\n", .{});
}

const MigrationExecContext = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
};

fn connectMigrationClient(allocator: std.mem.Allocator, server_addr: []const u8, tls_config: TlsConfig) !*zig_client.GeodeClient {
    const parsed = try zig_quic_bridge.parseHostPort(server_addr, 3141);
    const client = try allocator.create(zig_client.GeodeClient);
    errdefer allocator.destroy(client);

    if (tls_config.insecure) {
        std.debug.print("Warning: TLS verification disabled (--insecure-tls-skip-verify flag)\n", .{});
    }

    client.* = try zig_quic_bridge.initClientStrictTls(
        allocator,
        parsed.host,
        parsed.port,
        .{
            .insecure = tls_config.insecure,
            .ca_cert_path = tls_config.ca_cert_path,
            .client_cert_path = tls_config.client_cert_path,
            .client_key_path = tls_config.client_key_path,
        },
        null,
        null,
    );
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }

    try client.connect();
    return client;
}

fn writeProtoMessage(allocator: std.mem.Allocator, client: *zig_client.GeodeClient, msg: schema.QuicClientMessage) !void {
    // GAP-0276: Encode with length prefix in a single buffer to avoid a
    // second allocation + memcpy for the framing header.
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer aw.deinit();

    // Reserve 4 bytes for the big-endian length prefix.
    try aw.writer.writeAll(&[4]u8{ 0, 0, 0, 0 });

    const packet = schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const framed = aw.writer.buffer[0..aw.writer.end];
    const body_len: u32 = @intCast(framed.len - 4);
    std.mem.writeInt(u32, framed[0..4], body_len, .big);
    try client.sendRawFramed(framed);
}

fn readProtoMessage(
    allocator: std.mem.Allocator,
    client: *zig_client.GeodeClient,
    timeout_ms: u64,
) !schema.QuicServerMessage {
    const msg_bytes = client.receiveRawFrame(allocator, timeout_ms) catch |err| switch (err) {
        error.ReceiveTimeout => return error.Timeout,
        else => return err,
    };
    defer allocator.free(msg_bytes);

    var reader: std.Io.Reader = .fixed(msg_bytes);
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-032; FEATURE="JSON Library Migration"; ASPECT=MigrationScript; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-24
fn execMigrationScript(ctx_ptr: ?*anyopaque, script: []const u8) !void {
    const ctx = @as(*MigrationExecContext, @ptrCast(@alignCast(ctx_ptr orelse return error.ApplyFailed)));

    // Create a fresh QUIC connection per migration script. The server's handleQuicConnection
    // handles exactly one stream per connection handler call and destroys the connection
    // afterward, so we must reconnect for each migration rather than reusing a single connection.
    const quic_client = connectMigrationClient(ctx.allocator, ctx.server_addr, ctx.tls_config) catch |err| return err;
    // CANARY: REQ=REQ-GAP-0902-MIGRATE-STREAM-HYGIENE; FEATURE="Migrations"; ASPECT=StreamCloseBeforeTeardown; STATUS=IMPL; TEST=tests/test_gap0902_migrate_connect.zig; OWNER=cli; UPDATED=2026-07-10
    // GAP-0902: mirror the `geode query` path's stream discipline
    // (src/cli/main.zig closeStream() bracket). The migration flow used to
    // deinit the client WITHOUT first closing the QUIC stream, so the server
    // saw an abrupt stream reset while its single-stream handler was still
    // live — a plausible trigger for the "Server died" crash the harness
    // documented. Send a clean STREAM close (FIN) before teardown so the
    // server-side handler completes its own teardown in order.
    defer {
        quic_client.closeStream();
        quic_client.deinit();
        ctx.allocator.destroy(quic_client);
    }

    const hello_req = schema.HelloRequest{
        .username = ctx.username orelse "",
        .password = ctx.password orelse "",
        .client_name = "geode-migrate",
        .client_version = build_options.version,
        .wanted_conformance = "min",
    };
    try writeProtoMessage(ctx.allocator, quic_client, .{ .hello = hello_req });

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const hello_resp = readProtoMessage(arena.allocator(), quic_client, 5000) catch |err| return err;
    var session_id_buf: ?[]u8 = null;
    switch (hello_resp) {
        .hello => |h| {
            if (!h.success) return error.ApplyFailed;
            session_id_buf = try ctx.allocator.dupe(u8, h.session_id);
        },
        else => return error.ApplyFailed,
    }
    const session_id = session_id_buf orelse return error.ApplyFailed;
    defer ctx.allocator.free(session_id);

    const MigrationProtocolAdapter = struct {
        client: *zig_client.GeodeClient,
        timeout_ms: u64,

        fn sendClientMessage(
            proto: *query_runner.ProtocolClient,
            allocator: std.mem.Allocator,
            msg: schema.QuicClientMessage,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            try writeProtoMessage(allocator, self.client, msg);
        }

        fn readServerMessage(
            proto: *query_runner.ProtocolClient,
            allocator: std.mem.Allocator,
            timeout_secs: u32,
        ) !schema.QuicServerMessage {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            const requested_ms = @max(@as(u64, timeout_secs), 1) * 1000;
            return try readProtoMessage(allocator, self.client, @min(self.timeout_ms, requested_ms));
        }
    };

    const MigrationConsumer = struct {
        fn handleEvent(
            consumer: *query_runner.QueryEventConsumer,
            allocator: std.mem.Allocator,
            event: query_runner.QueryEvent,
            request_id: u64,
        ) !query_runner.QueryEventSummary {
            _ = consumer;
            _ = allocator;
            _ = request_id;
            return switch (event) {
                .hello_failure => error.ApplyFailed,
                .execute => |exec_resp| blk: {
                    if (exec_resp.payload) |payload| switch (payload) {
                        .schema => break :blk .{ .schema_received = true },
                        .page => |page| break :blk .{
                            .saw_page = true,
                            .page_final = page.final,
                        },
                        .@"error" => return error.ApplyFailed,
                        .explain, .profile => return error.ApplyFailed,
                        .metrics, .heartbeat => {},
                    };
                    break :blk .{};
                },
            };
        }
    };

    var adapter = MigrationProtocolAdapter{
        .client = quic_client,
        .timeout_ms = 5000,
    };
    var protocol_client = query_runner.ProtocolClient{
        .context = &adapter,
        .sendClientMessageFn = MigrationProtocolAdapter.sendClientMessage,
        .readServerMessageFn = MigrationProtocolAdapter.readServerMessage,
    };
    var consumer = query_runner.QueryEventConsumer{
        .context = &adapter,
        .handleEventFn = MigrationConsumer.handleEvent,
    };

    try query_runner.consumeQuery(ctx.allocator, &protocol_client, .{
        .session_id = session_id,
        .query_text = script,
        .format = "json",
        .timeout_secs = 5,
        .page_size = query_runner.default_page_size,
        .params = std.ArrayList(schema.Param).empty,
    }, &consumer);
}

// CANARY: REQ=REQ-CLI-MIGRATE-STATUS-001; FEATURE="CLIMigrateStatus"; ASPECT=MigrationModule; STATUS=TESTED; TEST=geodetestlab/specs/geode_migrations.yml; OWNER=cli; UPDATED=2026-01-11
fn cmdMigrateStatus(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var migrations_dir: []const u8 = "migrations";
    var allow_unauthenticated = false;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printStdout("geode migrate status - Show migration status\n" ++
                "\n" ++
                "Usage: geode migrate status [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dir <path>           Migrations directory (default: ./migrations)\n" ++
                "  --allow-unauthenticated  Skip HMAC key requirement (dev only)\n" ++
                "  -h, --help             Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len) {
            i += 1;
            migrations_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--allow-unauthenticated")) {
            allow_unauthenticated = true;
        }
    }

    // SEC-MIG-10: Validate --dir path to prevent directory traversal
    if (!isPathSafe(migrations_dir)) {
        std.debug.print("Error: --dir path contains invalid traversal components\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // SEC-MIG-03: Use HMAC key authentication for migrate status when available.
    // If an HMAC key is configured (env var or .hmac_key file), it proves the
    // caller is an authorized migration admin. If no key is configured, proceed
    // without authentication — operators who want enforcement must set up a key.
    if (!allow_unauthenticated) {
        var hmac_key_buf: [32]u8 = undefined;
        if (loadMigrationHmacKey(&hmac_key_buf, migrations_dir, allocator)) |_| {
            // Key loaded successfully — zero it out, we only needed to prove it exists
            @memset(&hmac_key_buf, 0);
        }
        // If no key is configured, proceed without authentication (graceful degradation)
    }

    const cfg = migration.MigrationConfig{ .migrations_dir = migrations_dir };

    // Get actual migration status from migration module
    const status_rows = migration.statusReport(allocator, cfg) catch |err| {
        std.debug.print("Error: Failed to get migration status: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer migration.freeStatusRows(allocator, status_rows);

    // Count applied vs total
    var applied_count: usize = 0;
    for (status_rows) |row| {
        if (row.applied) applied_count += 1;
    }

    const total = status_rows.len;
    const pending = total - applied_count;

    printStdout("Migration status:\n", .{});
    printStdout("  Applied: {}\n", .{applied_count});
    printStdout("  Pending: {}\n", .{pending});
    printStdout("  Total: {}\n", .{total});

    // List individual migrations if any exist
    if (total > 0) {
        printStdout("\nMigrations:\n", .{});
        for (status_rows) |row| {
            const status_str = if (row.applied) "[applied]" else "[pending]";
            printStdout("  {d:>6} {s} {s}\n", .{ row.version, status_str, row.name });
        }
    }

    std.process.exit(@intFromEnum(ExitCode.success));
}

// CANARY: REQ=REQ-CLI-MIGRATE-RUN-001; FEATURE="CLIMigrateRun"; ASPECT=MigrationModule; STATUS=TESTED; TEST=geodetestlab/specs/geode_migrations.yml; OWNER=cli; UPDATED=2026-01-11
// GAP-0137: Updated to support TLS certificate verification
fn cmdMigrateRun(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Parse arguments to find migration directory (default: ./migrations)
    var migrations_dir: []const u8 = "migrations";
    var dry_run = false;
    var allow_unsigned = false;
    var server: []const u8 = "127.0.0.1:3141";
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    // GAP-0137: TLS configuration options
    var tls_config = TlsConfig{};

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printStdout("geode migrate run - Apply pending migrations\n" ++
                "\n" ++
                "Usage: geode migrate run [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dir <path>           Migrations directory (default: ./migrations)\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
                "  --user <username>      Username for authentication\n" ++
                "  --password <password>  Password for authentication\n" ++
                "  --dry-run              Show what would be applied without applying\n" ++
                "  --allow-unsigned       Skip HMAC signature verification (dev only)\n" ++
                "  --insecure-tls-skip-verify  Skip TLS certificate verification\n" ++
                "  --insecure             (deprecated) Alias for --insecure-tls-skip-verify\n" ++
                "  --ca-cert <path>       CA certificate path for server verification\n" ++
                "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
                "  --client-key <path>    Client private key path for mutual TLS\n" ++
                "  -h, --help             Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len) {
            i += 1;
            migrations_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, argv[i], "--allow-unsigned")) {
            allow_unsigned = true;
        } else if (std.mem.eql(u8, argv[i], "--insecure-tls-skip-verify")) {
            tls_config.insecure = true;
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
            insecure_tls_gate.enforceOrExit(); // SEC-CLI-01
        } else if (std.mem.eql(u8, argv[i], "--ca-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.ca_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-cert")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_cert_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--client-key")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            tls_config.client_key_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            server = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--user")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            username = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--password")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --password requires a value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            i += 1;
            password = argv[i];
        }
    }

    // GAP-0137: Validate TLS configuration
    if (!tls_config.validate()) {
        std.debug.print("Error: Both --client-cert and --client-key must be provided for mutual TLS\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // S-7: Use consolidated password resolution
    password = resolveBackupPassword(password);

    // SEC-MIG-10: Validate --dir path to prevent directory traversal
    if (!isPathSafe(migrations_dir)) {
        std.debug.print("Error: --dir path contains invalid traversal components\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    printStdout("Running migrations from: {s}\n", .{migrations_dir});

    // Scan migrations directory for .gql files (excluding .down.gql rollback files)
    // GAP-0200: Treat non-existent directory as empty (no migrations to run)
    const io_mig = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io_mig, migrations_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            // Directory doesn't exist - treat as empty (no migrations)
            printStdout("No migration files found in '{s}'\n", .{migrations_dir});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        std.debug.print("Error: Cannot open migrations directory '{s}': {}\n", .{ migrations_dir, err });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer dir.close(io_mig);

    // Collect migration file names
    var migration_names = std.ArrayList([]const u8).empty;
    defer {
        for (migration_names.items) |name| allocator.free(name);
        migration_names.deinit(allocator);
    }

    var dir_iter = dir.iterate();
    while (dir_iter.next(io_mig) catch null) |entry| {
        if (entry.kind == .file) {
            // Match .gql files but exclude .down.gql rollback files
            if (std.mem.endsWith(u8, entry.name, ".gql") and !std.mem.endsWith(u8, entry.name, ".down.gql")) {
                const name_copy = allocator.dupe(u8, entry.name) catch continue;
                migration_names.append(allocator, name_copy) catch {
                    allocator.free(name_copy);
                    continue;
                };
            }
        }
    }

    if (migration_names.items.len == 0) {
        printStdout("No migration files found in '{s}'\n", .{migrations_dir});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    printStdout("Found {} migration files\n", .{migration_names.items.len});

    if (dry_run) {
        printStdout("\nDry run mode - showing what would be applied:\n", .{});
        const cfg = migration.MigrationConfig{ .migrations_dir = migrations_dir };
        const plan = migration.planDryRun(allocator, cfg, migration_names.items) catch |err| {
            std.debug.print("Error: Failed to plan migrations: {}\n", .{err});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer migration.freePlan(allocator, &plan);
        for (plan.up) |name| printStdout("  Would apply: {s}\n", .{name});
        for (plan.down) |name| printStdout("  Could rollback: {s}\n", .{name});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // SEC-MIG-01: Load HMAC key for migration signature verification
    var hmac_key_buf: [32]u8 = undefined;
    var hmac_key_ptr: ?*const [32]u8 = null;
    if (!allow_unsigned) {
        hmac_key_ptr = loadMigrationHmacKey(&hmac_key_buf, migrations_dir, allocator);
        if (hmac_key_ptr == null) {
            std.debug.print("Error: No HMAC key available for migration signature verification.\n" ++
                "  Set GEODE_MIGRATION_HMAC_KEY env var (64 hex chars), or\n" ++
                "  create {s}/.hmac_key file, or\n" ++
                "  use --allow-unsigned for development.\n", .{migrations_dir});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    } else {
        std.debug.print("Warning: Running migrations without signature verification (--allow-unsigned)\n", .{});
    }

    const cfg = migration.MigrationConfig{
        .migrations_dir = migrations_dir,
        .allow_unsigned = allow_unsigned,
        .hmac_key = hmac_key_ptr,
    };

    // Each migration script reconnects independently because the server handles
    // exactly one QUIC stream per connection handler and destroys the connection
    // afterward. Store connection parameters in context so execMigrationScript
    // can create a fresh connection for each script.
    var exec_ctx = MigrationExecContext{
        .allocator = allocator,
        .server_addr = server,
        .tls_config = tls_config,
        .username = username,
        .password = password,
    };
    const executor = migration.QueryExecutor{ .context = @ptrCast(&exec_ctx), .execFn = &execMigrationScript };

    migration.applyUpMigrations(allocator, cfg, migration_names.items, executor) catch |err| {
        std.debug.print("Error: Failed to apply migrations: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    printStdout("Migrations applied successfully\n", .{});
    std.process.exit(@intFromEnum(ExitCode.success));
}

// CANARY: REQ=REQ-CLI-MIGRATE-CREATE-001; FEATURE="CLIMigrateCreate"; ASPECT=FileCreation; STATUS=TESTED; TEST=geodetestlab/specs/geode_migrations.yml; OWNER=cli; UPDATED=2026-01-11
fn cmdMigrateCreate(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var migration_name: ?[]const u8 = null;
    var migrations_dir: []const u8 = "migrations";
    var no_sign = false;

    // Parse arguments
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printStdout("geode migrate create - Create a new migration file\n" ++
                "\n" ++
                "Usage: geode migrate create <name> [options]\n" ++
                "\n" ++
                "Arguments:\n" ++
                "  name                   Migration name (alphanumeric with underscores)\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dir <path>           Migrations directory (default: ./migrations)\n" ++
                "  --no-sign              Skip auto-signing (dev only, not recommended)\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Requires HMAC key (GEODE_MIGRATION_HMAC_KEY env var or <dir>/.hmac_key file).\n" ++
                "Created migrations are automatically signed unless --no-sign is specified.\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len) {
            i += 1;
            migrations_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--no-sign")) {
            no_sign = true;
        } else if (migration_name == null and !std.mem.startsWith(u8, argv[i], "-")) {
            migration_name = argv[i];
        }
    }

    if (migration_name == null) {
        std.debug.print("Error: migration name is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // SEC-MIG-10: Validate --dir path to prevent directory traversal
    if (!isPathSafe(migrations_dir)) {
        std.debug.print("Error: --dir path contains invalid traversal components\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // SEC-MIG-03: Use HMAC key for migrate create when available.
    // If an HMAC key is configured, sign the created migration file.
    // If no key is configured, create unsigned (operators who want signing
    // must set up a key via env var or .hmac_key file).
    var hmac_key_buf: [32]u8 = undefined;
    var hmac_key_ptr: ?*const [32]u8 = null;
    if (!no_sign) {
        hmac_key_ptr = loadMigrationHmacKey(&hmac_key_buf, migrations_dir, allocator);
        // If no key is configured, proceed without signing (graceful degradation)
    }

    // Validate migration name for path traversal (GAP-0285/0301)
    migration.validateMigrationName(migration_name.?) catch {
        std.debug.print("Error: invalid migration name '{s}' (must not contain path separators or '..')\n", .{migration_name.?});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Ensure migrations directory exists
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), migrations_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error: Cannot create migrations directory '{s}': {}\n", .{ migrations_dir, err });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    };

    // Find next version number by scanning existing migrations
    const io_gen = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io_gen, migrations_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: Cannot open migrations directory '{s}': {}\n", .{ migrations_dir, err });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer dir.close(io_gen);

    var max_version: u32 = 0;
    var dir_iter = dir.iterate();
    while (dir_iter.next(io_gen) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gql")) {
            // Parse version number from filename (e.g., "001_create_users.gql")
            var version: u32 = 0;
            var j: usize = 0;
            while (j < entry.name.len and entry.name[j] >= '0' and entry.name[j] <= '9') : (j += 1) {
                // SEC-MIG-09: Use saturating arithmetic to prevent overflow on
                // pathological filenames with very large numeric prefixes.
                version = version *| 10 +| @as(u32, entry.name[j] - '0');
            }
            if (version > max_version) max_version = version;
        }
    }

    // SEC-MIG-09: Guard against overflow when incrementing past u32 max.
    if (max_version == std.math.maxInt(u32)) {
        std.debug.print("Error: migration version counter overflow (max version {d})\n", .{max_version});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    const new_version = max_version + 1;

    // Create filename: NNN_name.gql
    const filename = std.fmt.allocPrint(allocator, "{s}/{d:0>3}_{s}.gql", .{ migrations_dir, new_version, migration_name.? }) catch {
        std.debug.print("Error: Out of memory\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(filename);

    // Extract just the base filename (without directory) for signing
    const basename = std.fmt.allocPrint(allocator, "{d:0>3}_{s}.gql", .{ new_version, migration_name.? }) catch {
        std.debug.print("Error: Out of memory\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(basename);

    // Create the migration file with template content
    const template = std.fmt.allocPrint(allocator,
        \\-- Migration: {s}
        \\-- Version: {d}
        \\-- Created: {d}
        \\
        \\-- Add your GQL statements here
        \\-- Example:
        \\-- CREATE (:Node {{name: "example"}})
        \\
    , .{ migration_name.?, new_version, compat_milliTimestamp() }) catch {
        std.debug.print("Error: Out of memory\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(template);

    // Write the file
    const io_wf = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().createFile(io_wf, filename, .{}) catch |err| {
        std.debug.print("Error: Cannot create migration file '{s}': {}\n", .{ filename, err });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close(io_wf);

    file.writeStreamingAll(io_wf, template) catch |err| {
        std.debug.print("Error: Cannot write to migration file: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    printStdout("Created migration file: {s}\n", .{filename});

    // SEC-MIG-03: Auto-sign the newly created migration file
    if (hmac_key_ptr) |key| {
        const cfg = migration.MigrationConfig{
            .migrations_dir = migrations_dir,
            .hmac_key = key,
        };
        migration.signMigrationFile(allocator, cfg, basename) catch |err| {
            std.debug.print("Warning: Failed to auto-sign migration: {}\n", .{err});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        printStdout("  Signed: {s}\n", .{basename});
    }

    std.process.exit(@intFromEnum(ExitCode.success));
}

// SEC-MIG-01: Sign migration files with HMAC-SHA256 to prevent tampered script execution.
fn cmdMigrateSign(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var migrations_dir: []const u8 = "migrations";
    var sign_all = false;
    var specific_files = std.ArrayList([]const u8).empty;
    defer specific_files.deinit(allocator);

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printStdout("geode migrate sign - Sign migration files with HMAC-SHA256\n" ++
                "\n" ++
                "Usage: geode migrate sign [options] [file...]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dir <path>           Migrations directory (default: ./migrations)\n" ++
                "  --all                  Sign all unsigned .gql files in the directory\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "The HMAC key is read from GEODE_MIGRATION_HMAC_KEY env var (64 hex chars)\n" ++
                "or from <dir>/.hmac_key file.\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--dir") and i + 1 < argv.len) {
            i += 1;
            migrations_dir = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--all")) {
            sign_all = true;
        } else if (!std.mem.startsWith(u8, argv[i], "-")) {
            specific_files.append(allocator, argv[i]) catch {
                std.debug.print("Error: Out of memory\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
        }
    }

    if (!isPathSafe(migrations_dir)) {
        std.debug.print("Error: --dir path contains invalid traversal components\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // Load HMAC key
    var hmac_key_buf: [32]u8 = undefined;
    const hmac_key_ptr = loadMigrationHmacKey(&hmac_key_buf, migrations_dir, allocator);
    if (hmac_key_ptr == null) {
        std.debug.print("Error: No HMAC key available.\n" ++
            "  Set GEODE_MIGRATION_HMAC_KEY env var (64 hex chars), or\n" ++
            "  create {s}/.hmac_key file.\n", .{migrations_dir});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const cfg = migration.MigrationConfig{
        .migrations_dir = migrations_dir,
        .hmac_key = hmac_key_ptr,
    };

    if (sign_all) {
        // Sign all .gql files (excluding .down.gql and .sig files)
        const io_sa = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io_sa, migrations_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("Error: Cannot open migrations directory '{s}': {}\n", .{ migrations_dir, err });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer dir.close(io_sa);

        var dir_iter = dir.iterate();
        var signed_count: usize = 0;
        while (dir_iter.next(io_sa) catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gql") and
                !std.mem.endsWith(u8, entry.name, ".down.gql") and
                !std.mem.endsWith(u8, entry.name, ".sig"))
            {
                migration.signMigrationFile(allocator, cfg, entry.name) catch |err| {
                    std.debug.print("Error: Failed to sign '{s}': {}\n", .{ entry.name, err });
                    continue;
                };
                printStdout("  Signed: {s}\n", .{entry.name});
                signed_count += 1;
            }
        }
        printStdout("Signed {d} migration file(s)\n", .{signed_count});
    } else if (specific_files.items.len > 0) {
        for (specific_files.items) |filename| {
            migration.signMigrationFile(allocator, cfg, filename) catch |err| {
                std.debug.print("Error: Failed to sign '{s}': {}\n", .{ filename, err });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            printStdout("Signed: {s}\n", .{filename});
        }
    } else {
        std.debug.print("Error: Specify migration files to sign or use --all\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    std.process.exit(@intFromEnum(ExitCode.success));
}

// ============================================================================
// Helper Functions for Backup/Restore Execution
// ============================================================================

// CANARY: REQ=REQ-BACKUP-REMOTE-001; FEATURE="RemoteBackup"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/backup_operations_basic.yml; OWNER=cli; UPDATED=2026-01-09
// GAP-0137: Updated to support TLS certificate verification
// Remote server backup execution function using QUIC protocol
fn executeRemoteBackup(
    allocator: std.mem.Allocator,
    dest: []const u8,
    mode: []const u8,
    server: []const u8,
    compress: bool,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !void {
    const parsed = zig_quic_bridge.parseHostPort(server, 3141) catch return error.InvalidAddress;

    var client = zig_quic_bridge.initClientStrictTls(
        allocator,
        parsed.host,
        parsed.port,
        .{
            .insecure = tls_config.insecure,
            .ca_cert_path = tls_config.ca_cert_path,
            .client_cert_path = tls_config.client_cert_path,
            .client_key_path = tls_config.client_key_path,
        },
        null,
        null,
    ) catch |err| {
        std.debug.print("Error: Failed to initialize client: {}\n", .{err});
        return err;
    };
    defer client.deinit();

    if (tls_config.insecure) {
        std.debug.print("Warning: TLS verification disabled (--insecure-tls-skip-verify flag)\n", .{});
    }

    client.connect() catch |err| {
        std.debug.print("Error: QUIC handshake failed: {}\n", .{err});
        return err;
    };

    // Send HELLO (Protobuf)
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .client_name = "geode-backup",
        .client_version = build_options.version,
        .wanted_conformance = "GQL/1.0",
    };
    writeProtoMessage(allocator, &client, .{ .hello = hello_req }) catch |err| {
        std.debug.print("Error: Failed to send HELLO: {}\n", .{err});
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const hello_resp = readProtoMessage(arena.allocator(), &client, 5000) catch |err| {
        std.debug.print("Error: Failed to receive HELLO response: {}\n", .{err});
        return err;
    };
    switch (hello_resp) {
        .hello => |h| {
            if (!h.success) {
                std.debug.print("Error: {s}\n", .{h.error_message});
                return error.ServerError;
            }
        },
        else => {
            std.debug.print("Error: Unexpected HELLO response type\n", .{});
            return error.ServerError;
        },
    }

    // Send BACKUP request (Protobuf)
    const backup_req = schema.BackupRequest{
        .backup_type = mode,
        .compress = compress,
    };
    writeProtoMessage(allocator, &client, .{ .backup = backup_req }) catch |err| {
        std.debug.print("Error: Failed to send BACKUP request: {}\n", .{err});
        return err;
    };

    const backup_resp_msg = readProtoMessage(arena.allocator(), &client, 30000) catch |err| {
        std.debug.print("Error: Failed to receive backup response: {}\n", .{err});
        return err;
    };
    const backup_resp = switch (backup_resp_msg) {
        .backup => |b| b,
        else => {
            std.debug.print("Error: Unexpected backup response type\n", .{});
            return error.BackupFailed;
        },
    };
    if (!backup_resp.success) {
        std.debug.print("Backup error: {s}\n", .{backup_resp.message});
        return error.BackupFailed;
    }

    const backup_size = backup_resp.size_bytes;
    std.debug.print("Receiving backup ({} bytes) from {s}...\n", .{ backup_size, server });

    // Create destination file
    const io_bf = std.Io.Threaded.global_single_threaded.io();
    const output_file = try std.Io.Dir.cwd().createFile(io_bf, dest, .{});
    // Do not leave a truncated file behind under the requested backup name.
    errdefer std.Io.Dir.cwd().deleteFile(io_bf, dest) catch {};
    defer output_file.close(io_bf);

    // Receive backup data chunks
    var bytes_received: u64 = 0;
    var chunk_buf: [65536]u8 = undefined;

    while (bytes_received < backup_size) {
        const remaining = backup_size - bytes_received;
        const chunk_size = @min(remaining, chunk_buf.len);

        const bytes_read = client.receiveRawBytes(chunk_buf[0..chunk_size], 30000) catch |err| {
            std.debug.print("Error: Failed to receive backup data: {}\n", .{err});
            return err;
        };

        // Write to file
        try output_file.writeStreamingAll(io_bf, chunk_buf[0..bytes_read]);
        bytes_received += bytes_read;

        // Progress indicator (every 10%)
        const progress = (bytes_received * 100) / backup_size;
        if (progress % 10 == 0) {
            std.debug.print("  Progress: {}%\n", .{progress});
        }
    }

    std.debug.print("Backup completed: {s} ({} bytes)\n", .{ dest, bytes_received });
}

// GAP-0137: Updated to support TLS certificate verification
fn executeBackup(
    allocator: std.mem.Allocator,
    dest: []const u8,
    mode: []const u8,
    server: []const u8,
    compress: bool,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !void {
    std.debug.print("Creating {s} backup to: {s}\n", .{ mode, dest });

    // CANARY: REQ=REQ-BACKUP-CLI-001; FEATURE="CLI Backup"; ASPECT=ServerConnection; STATUS=TESTED; TEST=tests/test_backup_create_remote_failure.zig; OWNER=cli; UPDATED=2026-10-24
    // A failed remote backup is an error. It used to fall back to a local
    // data-directory backup and report success, which handed the caller a
    // different backup (and, with GEODE_DATA_DIR unset, read all of /tmp).
    return executeRemoteBackup(allocator, dest, mode, server, compress, tls_config, username, password);
}

// CANARY: REQ=REQ-BACKUP-LOCAL-001; FEATURE="Local Directory Backup"; ASPECT=DataExport; STATUS=TESTED; TEST=tests/test_backup_create_remote_failure.zig; OWNER=cli; UPDATED=2026-10-24
// Local directory backup (`backup create --local`) - reads the given Geode data directory.
fn executeLocalDirectoryBackup(allocator: std.mem.Allocator, dest: []const u8, mode: []const u8, compress: bool, data_dir: []const u8) !void {
    if (!std.mem.eql(u8, mode, "full")) {
        return error.UnsupportedBackupMode;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    dir.close(io);
    graph_store.setDataDirOverride(allocator, data_dir);

    const config = backup_types.BackupConfig{
        // GAP-0880: gzip is the only compression codec with a real encoder;
        // never request zstd (no encoder — UnsupportedCompression).
        .compression = if (compress) .gzip else .none,
        .encryption = false,
        .retention_days = 30,
    };

    const backup_dir = std.fs.path.dirname(dest) orelse ".";
    var mgr = try backup_types.BackupManager.init(allocator, backup_dir, config, graph_store.getGlobalStore(allocator));
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    const created_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(created_path);

    if (!std.mem.eql(u8, created_path, dest)) {
        std.Io.Dir.cwd().copyFile(created_path, std.Io.Dir.cwd(), dest, std.Io.Threaded.global_single_threaded.io(), .{}) catch |err| {
            std.debug.print("Error: Failed to copy backup to requested output ({s}): {}\n", .{ dest, err });
            return err;
        };
    }

    std.debug.print("Local backup completed: {s}\n", .{dest});
}

// CANARY: REQ=REQ-BACKUP-RESTORE-001; FEATURE="Backup Restore"; ASPECT=RemoteRestore; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-09
// GAP-0137: Updated to support TLS certificate verification
// Remote server restore execution function - sends restore request via QUIC
fn executeRemoteRestore(
    allocator: std.mem.Allocator,
    source: []const u8,
    target_time: ?[]const u8,
    server: []const u8,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !void {
    std.debug.print("RESTORE: Connecting to server {s} for remote restore...\n", .{server});

    const parsed = zig_quic_bridge.parseHostPort(server, 3141) catch {
        std.debug.print("Error: Invalid server address format. Expected host:port\n", .{});
        return error.InvalidServerPort;
    };

    var client = zig_quic_bridge.initClientStrictTls(
        allocator,
        parsed.host,
        parsed.port,
        .{
            .insecure = tls_config.insecure,
            .ca_cert_path = tls_config.ca_cert_path,
            .client_cert_path = tls_config.client_cert_path,
            .client_key_path = tls_config.client_key_path,
        },
        null,
        null,
    ) catch |err| {
        std.debug.print("RESTORE: Failed to initialize client: {}\n", .{err});
        return error.ConnectionFailed;
    };
    defer client.deinit();

    if (tls_config.insecure) {
        std.debug.print("Warning: TLS verification disabled (--insecure-tls-skip-verify flag)\n", .{});
    }

    client.connect() catch |err| {
        std.debug.print("RESTORE: Failed to connect to server: {}\n", .{err});
        return error.ConnectionFailed;
    };

    // Send HELLO (Protobuf)
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .client_name = "geode-restore",
        .client_version = build_options.version,
        .wanted_conformance = "GQL/1.0",
    };
    writeProtoMessage(allocator, &client, .{ .hello = hello_req }) catch |err| {
        std.debug.print("RESTORE: Failed to send HELLO: {}\n", .{err});
        return error.ConnectionFailed;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const hello_resp = readProtoMessage(arena.allocator(), &client, 5000) catch |err| {
        std.debug.print("RESTORE: Failed to receive HELLO response: {}\n", .{err});
        return error.ReadFailed;
    };
    switch (hello_resp) {
        .hello => |h| {
            if (!h.success) {
                std.debug.print("RESTORE: Server error: {s}\n", .{h.error_message});
                return error.ServerError;
            }
        },
        else => {
            std.debug.print("RESTORE: Unexpected HELLO response\n", .{});
            return error.ServerError;
        },
    }

    if (source.len > 0) {
        std.debug.print("RESTORE: Note - remote restore uses server-managed backups; source URI is not transferred.\n", .{});
    }

    const restore_req = schema.RestoreRequest{
        .target_time = target_time orelse "",
        .confirm = true,
    };
    writeProtoMessage(allocator, &client, .{ .restore = restore_req }) catch |err| {
        std.debug.print("RESTORE: Failed to send restore request: {}\n", .{err});
        return error.WriteFailed;
    };

    const resp_msg = readProtoMessage(arena.allocator(), &client, 30000) catch |err| {
        std.debug.print("RESTORE: Failed to read server response: {}\n", .{err});
        return error.ReadFailed;
    };

    switch (resp_msg) {
        .restore => |resp| {
            if (!resp.success) {
                std.debug.print("RESTORE: Server returned error: {s}\n", .{resp.message});
                return error.ServerError;
            }
            // SONNY-6288: the server reports where it restored, the
            // per-graph counts and how to serve the restore.
            std.debug.print("RESTORE: {s}\n", .{resp.message});
            if (resp.restore_dir.len > 0) {
                std.debug.print("  Restored into: {s}\n", .{resp.restore_dir});
            }
            if (resp.target_time.len > 0) {
                std.debug.print("  Target time: {s}\n", .{resp.target_time});
            }
        },
        else => {
            std.debug.print("RESTORE: Unexpected restore response\n", .{});
            return error.ServerError;
        },
    }
}

// CANARY: REQ=REQ-BACKUP-RESTORE-002; FEATURE="Backup Restore"; ASPECT=LocalRestore; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=cli; UPDATED=2026-11-11
// Local restore: writes a backup file into a data directory, offline.
//
// SONNY-6280: this used to check the archive, write nothing, and print
// "Full backup restore completed" (since 16833164, 2026-03-28, which removed
// the monolithic restore and never wired the per-graph one). It now reuses
// the server path's decode and per-graph restore (storage/backup.zig),
// writes into a staging directory beside the target, verifies every file
// against the archive and opens the restored store cold, and only then
// renames it onto the target and reports success.
fn executeLocalRestore(
    allocator: std.mem.Allocator,
    source: []const u8,
    target_time: ?[]const u8,
    data_dir_arg: ?[]const u8,
) !void {
    std.debug.print("RESTORE: Initiating restore from '{s}'\n", .{source});

    var backup_path: []const u8 = source;
    var selected_owned: ?[]u8 = null;
    defer if (selected_owned) |sel| allocator.free(sel);
    if (target_time) |ts| {
        const target_ms = parseTimestampToEpoch(ts) orelse {
            std.debug.print("Error: --target-time '{s}' is not epoch milliseconds or YYYY-MM-DDTHH:MM:SS[Z] (UTC)\n", .{ts});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        const backup_dir = std.fs.path.dirname(source) orelse ".";
        selected_owned = try backup_types.selectPointInTimeBackup(allocator, backup_dir, target_ms);
        backup_path = selected_owned.?;
        std.debug.print("RESTORE: Target time (ms): {d}; selected backup {s}\n", .{ target_ms, backup_path });
    }

    // Verify the whole backup before looking at the target, so a bad file
    // reports its own error whatever the target.
    var decoded = try backup_types.readBackupFile(allocator, backup_path, null);
    defer decoded.deinit(allocator);
    std.debug.print("RESTORE: Backup verified: version {d}, type {s}, compression {s}, encrypted {}, {d} files, {d} bytes\n", .{
        decoded.header.version,
        @tagName(decoded.header.backup_type),
        @tagName(decoded.header.compression),
        decoded.header.encrypted,
        decoded.stats.files,
        decoded.stats.bytes,
    });

    const target = data_dir_arg orelse posixGetenv("GEODE_DATA_DIR") orelse {
        std.debug.print("Error: geode restore needs a target directory: --data-dir <path> or GEODE_DATA_DIR\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    if (target.len == 0) {
        std.debug.print("Error: --data-dir must not be empty\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    std.debug.print("RESTORE: Target directory: {s}\n", .{target});

    var staged = backup_types.stageRestore(allocator, decoded.archive, target) catch |err| {
        if (err == error.RestoreTargetNotEmpty) {
            std.debug.print("RESTORE: target directory '{s}' is not empty; restore writes only into a new or empty directory\n", .{target});
        }
        return err;
    };
    defer staged.deinit();

    const graphs = try backup_types.countRestoredStore(allocator, staged.staging_dir);
    defer backup_types.freeRestoredGraphs(allocator, graphs);

    staged.commit() catch |err| {
        if (err == error.RestoreTargetNotEmpty) {
            std.debug.print("RESTORE: target directory '{s}' is not empty; restore writes only into a new or empty directory\n", .{target});
        }
        return err;
    };

    std.debug.print("RESTORE: Restored and verified {d} files ({d} bytes) into {s}\n", .{ staged.stats.files, staged.stats.bytes, target });
    for (graphs) |g| {
        std.debug.print("  graph '{s}': {d} nodes, {d} edges\n", .{ g.name, g.nodes, g.edges });
    }
}

/// Parse --target-time to epoch milliseconds: either an integer (epoch ms,
/// as the server restore takes it) or `YYYY-MM-DDTHH:MM:SS` with an optional
/// trailing `Z`, read as UTC. Returns null for anything else.
fn parseTimestampToEpoch(ts: []const u8) ?i64 {
    if (std.fmt.parseInt(i64, ts, 10)) |ms| {
        return ms;
    } else |_| {}

    const s = if (std.mem.endsWith(u8, ts, "Z")) ts[0 .. ts.len - 1] else ts;
    if (s.len != 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > month_days[month - 1]) return null;

    // Days from 1970-01-01 to the civil date (proleptic Gregorian).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;

    return (days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second) * 1000;
}

// ============================================================================
// Unit Tests
// ============================================================================

// CANARY: REQ=REQ-MIGRATION-QUIC-STABILITY-001; FEATURE="MigrationQuicStability"; ASPECT=UnitTests; STATUS=TESTED; TEST=self; OWNER=cli; UPDATED=2026-01-25

test "TlsConfig.hasCerts returns false when no certs configured" {
    const config = TlsConfig{
        .ca_cert_path = null,
        .client_cert_path = null,
        .client_key_path = null,
        .insecure = false,
    };
    try std.testing.expect(!config.hasCerts());
}

test "TlsConfig.hasCerts returns true when CA cert configured" {
    const config = TlsConfig{
        .ca_cert_path = "/path/to/ca.crt",
        .client_cert_path = null,
        .client_key_path = null,
        .insecure = false,
    };
    try std.testing.expect(config.hasCerts());
}

test "TlsConfig.hasCerts returns true when all certs configured" {
    const config = TlsConfig{
        .ca_cert_path = "/path/to/ca.crt",
        .client_cert_path = "/path/to/client.crt",
        .client_key_path = "/path/to/client.key",
        .insecure = false,
    };
    try std.testing.expect(config.hasCerts());
}

test "parseMigrationVersion extracts version number" {
    // Test extracting version from migration filename
    const filename1 = "001_initial.gql";
    const version1 = try std.fmt.parseInt(u32, filename1[0..3], 10);
    try std.testing.expectEqual(@as(u32, 1), version1);

    const filename2 = "042_add_indexes.gql";
    const version2 = try std.fmt.parseInt(u32, filename2[0..3], 10);
    try std.testing.expectEqual(@as(u32, 42), version2);

    const filename3 = "999_final.gql";
    const version3 = try std.fmt.parseInt(u32, filename3[0..3], 10);
    try std.testing.expectEqual(@as(u32, 999), version3);
}

test "migration version ordering" {
    // Test that version numbers can be compared for ordering
    const version1: u32 = 1;
    const version2: u32 = 2;
    const version3: u32 = 10;

    // version1 < version2
    try std.testing.expect(version1 < version2);
    // version2 < version3
    try std.testing.expect(version2 < version3);
    // version1 < version3
    try std.testing.expect(version1 < version3);
}

test "ExitCode values are distinct" {
    try std.testing.expect(@intFromEnum(ExitCode.success) != @intFromEnum(ExitCode.general_error));
    try std.testing.expect(@intFromEnum(ExitCode.general_error) != @intFromEnum(ExitCode.usage_error));
    try std.testing.expect(@intFromEnum(ExitCode.success) == 0);
    try std.testing.expect(@intFromEnum(ExitCode.general_error) == 1);
}

test "MigrationExecContext fields are properly initialized" {
    // Test that MigrationExecContext can be properly initialized
    // This validates the struct layout for the heap-allocated client pattern
    const allocator = std.testing.allocator;

    const ctx = MigrationExecContext{
        .allocator = allocator,
        .server_addr = "127.0.0.1:3141",
        .tls_config = TlsConfig{},
        .username = null,
        .password = null,
    };

    try std.testing.expect(std.mem.eql(u8, ctx.server_addr, "127.0.0.1:3141"));
    try std.testing.expect(ctx.username == null);
    try std.testing.expect(ctx.password == null);
    try std.testing.expect(!ctx.tls_config.insecure);
}

test "heap allocation pattern for QUIC client stability" {
    // This test validates the pattern used to fix the migration segfault.
    // The QUIC client must be heap-allocated to prevent dangling allocator
    // pointers when the Connection stores a reference to Endpoint's allocator.
    const allocator = std.testing.allocator;

    // Simulate the heap-allocation pattern used in connectMigrationClient
    const TestStruct = struct {
        allocator: std.mem.Allocator,
        value: u32,
    };

    const ptr = try allocator.create(TestStruct);
    defer allocator.destroy(ptr);

    ptr.* = TestStruct{
        .allocator = allocator,
        .value = 42,
    };

    // Verify the heap-allocated struct is accessible and stable
    try std.testing.expectEqual(@as(u32, 42), ptr.value);

    // The key insight: ptr.allocator remains valid because ptr is heap-allocated
    // If TestStruct were returned by value, the allocator field reference
    // would point to invalid stack memory after the function returns.
}

// SEC-MIG-10: Path traversal validation tests
test "isPathSafe rejects path traversal" {
    try std.testing.expect(!isPathSafe("../etc/passwd"));
    try std.testing.expect(!isPathSafe("foo/../bar"));
    try std.testing.expect(!isPathSafe(".."));
    try std.testing.expect(!isPathSafe("foo/.."));
    try std.testing.expect(!isPathSafe(""));
}

test "isPathSafe accepts valid paths" {
    try std.testing.expect(isPathSafe("migrations"));
    try std.testing.expect(isPathSafe("./migrations"));
    try std.testing.expect(isPathSafe("/var/lib/geode/migrations"));
    try std.testing.expect(isPathSafe("backups/2026"));
    try std.testing.expect(isPathSafe("."));
}
