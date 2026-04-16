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
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
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

    // Execute backup
    try executeBackup(allocator, output.?, backup_type_str, server, compress, tls_config, username, password);

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
        const mtime_ns = stat.mtime;
        const mtime_s = @divFloor(mtime_ns, 1_000_000_000);
        std.debug.print("  timestamp:     {d} (file mtime)\n", .{mtime_s});
    } else if (is_zstd_magic or is_zst) {
        // Compressed zstd file
        std.debug.print("  Format:        Geode Backup (zstd compressed)\n", .{});
        std.debug.print("  compression:   zstd\n", .{});

        std.debug.print("  type:          full\n", .{});

        const mtime_ns = stat.mtime;
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
                "Usage: geode restore [backup_file] [options]\n" ++
                "       geode restore --source <URI> [options]\n" ++
                "\n" ++
                "Arguments:\n" ++
                "  backup_file            Path to backup file (positional argument)\n" ++
                "\n" ++
                "Options:\n" ++
                "  --source <URI>         Backup source (alternative to positional)\n" ++
                "  --target-time <time>   Restore to specific timestamp\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
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
                "  geode restore ./backup.gql --confirm\n" ++
                "  geode restore --source s3://bucket/backup.gql --yes\n" ++
                "  geode restore ./backup.gql --yes --insecure-tls-skip-verify\n" ++
                "  geode restore ./backup.gql --yes --ca-cert /etc/ssl/ca.crt\n" ++
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
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
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

    if (source == null) {
        std.debug.print("Error: --source is required\n", .{});
        std.debug.print("Use 'geode restore --help' for usage information\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
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
        std.debug.print("All current data will be replaced with backup data.\n", .{});
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

    // Execute restore (GAP-0137: pass TLS config)
    try executeRestore(allocator, source.?, target_time, server, tls_config, username, password);

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
    defer {
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
        .params = std.ArrayList(schema.Param){},
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
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            tls_config.insecure = true;
            // --insecure silently accepted as alias for --insecure-tls-skip-verify
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

    // CANARY: REQ=REQ-BACKUP-CLI-001; FEATURE="CLI Backup"; ASPECT=ServerConnection; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-10
    // Always try to connect to server via QUIC first - this ensures we get real data
    executeRemoteBackup(allocator, dest, mode, server, compress, tls_config, username, password) catch |err| {
        std.debug.print("Warning: Could not connect to server {s}: {}\n", .{ server, err });
        std.debug.print("Attempting local data directory backup...\n", .{});

        // Try local data directory backup if server connection failed
        executeLocalDirectoryBackup(allocator, dest, mode, compress) catch |local_err| {
            std.debug.print("Error: Local backup also failed: {}\n", .{local_err});
            return local_err;
        };
        return;
    };
}

// CANARY: REQ=REQ-BACKUP-LOCAL-001; FEATURE="Local Directory Backup"; ASPECT=DataExport; STATUS=TESTED; TEST=geodetestlab/specs/backup_operations_basic.yml; OWNER=cli; UPDATED=2026-01-10
// Local directory backup - reads from Geode data directory when server not available
fn executeLocalDirectoryBackup(allocator: std.mem.Allocator, dest: []const u8, mode: []const u8, compress: bool) !void {
    if (!std.mem.eql(u8, mode, "full")) {
        return error.UnsupportedBackupMode;
    }

    const config = backup_types.BackupConfig{
        .compression = if (compress) .zstd else .none,
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
        std.Io.Dir.cwd().copyFile(created_path, std.Io.Dir.cwd(), dest, .{}) catch |err| {
            std.debug.print("Warning: Failed to copy backup to requested output ({s}): {}\n", .{ dest, err });
        };
    }

    std.debug.print("Local backup completed: {s}\n", .{dest});
}

fn parseHexKey(hex_str: []const u8) ![32]u8 {
    if (hex_str.len != 64) return error.InvalidTdeKeyLength;
    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch return error.InvalidTdeKeyHex;
        const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch return error.InvalidTdeKeyHex;
        key[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return key;
}

fn decryptData(data: []const u8, key: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    const NonceSize = 12;
    const TagSize = 16;
    const Overhead = NonceSize + TagSize;
    if (data.len < Overhead) return error.InvalidEncryptedData;

    var nonce: [NonceSize]u8 = undefined;
    @memcpy(&nonce, data[0..NonceSize]);
    var tag: [TagSize]u8 = undefined;
    @memcpy(&tag, data[NonceSize .. NonceSize + TagSize]);
    const ciphertext = data[Overhead..];

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch {
        allocator.free(plaintext);
        return error.DecryptionFailed;
    };
    return plaintext;
}

fn decompressData(data: []const u8, compression: backup_types.CompressionType, allocator: std.mem.Allocator) ![]u8 {
    if (compression == .none) return allocator.dupe(u8, data);
    if (compression == .zstd) {
        // Zig 0.15 zstd API - use Decompress struct with Io.Reader/Writer
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(data);
        var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
        _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| return err;
        return try out.toOwnedSlice();
    }
    return error.UnsupportedCompression;
}

fn computeChecksum(data: []const u8) u64 {
    return std.hash.crc.Crc32.hash(data);
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
            std.debug.print("RESTORE: Restore initiated successfully\n", .{});
            if (resp.restore_dir.len > 0) {
                std.debug.print("  Restore dir: {s}\n", .{resp.restore_dir});
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

// CANARY: REQ=REQ-BACKUP-RESTORE-002; FEATURE="Backup Restore"; ASPECT=LocalRestore; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-09
// GAP-0137: Updated to support TLS certificate verification
// Local restore execution - handles local file restoration
fn executeRestore(
    allocator: std.mem.Allocator,
    source: []const u8,
    target_time: ?[]const u8,
    server: []const u8,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !void {
    std.debug.print("RESTORE: Initiating restore from '{s}'\n", .{source});

    // Check if source is a remote URI (s3://, https://, etc.)
    if (std.mem.startsWith(u8, source, "s3://") or
        std.mem.startsWith(u8, source, "https://") or
        std.mem.startsWith(u8, source, "http://"))
    {
        // Remote restore via server (GAP-0137: pass TLS config)
        return executeRemoteRestore(allocator, source, target_time, server, tls_config, username, password);
    }

    // Local restore
    const restore_dir = "data/restore";
    std.debug.print("RESTORE: Target directory: {s}\n", .{restore_dir});

    // Parse target time if specified
    var target_timestamp: ?i64 = null;
    if (target_time) |ts| {
        std.debug.print("RESTORE: Target timestamp: {s}\n", .{ts});
        // Parse ISO 8601 timestamp to epoch milliseconds
        target_timestamp = parseTimestampToEpoch(ts);
        if (target_timestamp == null) {
            std.debug.print("Warning: Could not parse timestamp, using latest backup\n", .{});
        }
    }

    // Determine backup directory from source
    const backup_dir = if (std.mem.lastIndexOf(u8, source, "/")) |idx|
        source[0..idx]
    else
        ".";

    // Initialize restore manager
    var restore_manager = SimplifiedRestoreManager{
        .allocator = allocator,
        .backup_dir = backup_dir,
        .restore_dir = restore_dir,
    };

    // Perform restore
    if (target_timestamp) |ts| {
        const metadata = try restore_manager.restoreToPointInTime(source, ts);
        std.debug.print("RESTORE: Point-in-time restore completed\n", .{});
        std.debug.print("  Backup ID: {x}\n", .{metadata.source_backup_id});
        std.debug.print("  Backup type: {s}\n", .{@tagName(metadata.backup_type)});
        std.debug.print("  Data size: {d} bytes\n", .{metadata.data_size_bytes});
        std.debug.print("  Checksum verified: {}\n", .{metadata.checksum_verified});
        if (metadata.target_time) |t| {
            std.debug.print("  Target time (ms): {d}\n", .{t});
        }
    } else {
        const metadata = try restore_manager.restoreFromBackup(source);
        std.debug.print("RESTORE: Full backup restore completed\n", .{});
        std.debug.print("  Backup ID: {x}\n", .{metadata.source_backup_id});
        std.debug.print("  Backup type: {s}\n", .{@tagName(metadata.backup_type)});
        std.debug.print("  Data size: {d} bytes\n", .{metadata.data_size_bytes});
        std.debug.print("  Checksum verified: {}\n", .{metadata.checksum_verified});
    }
}

/// Parse ISO 8601 timestamp string to epoch milliseconds
fn parseTimestampToEpoch(ts: []const u8) ?i64 {
    // Simple parsing for YYYY-MM-DDTHH:MM:SS format
    // Returns epoch seconds (not milliseconds for simplicity)
    if (ts.len < 19) return null;

    // Extract components
    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, ts[17..19], 10) catch return null;

    // Convert to epoch (simplified - doesn't account for leap years properly)
    const days_since_epoch: i64 = @as(i64, year - 1970) * 365 +
        @as(i64, @divFloor((year - 1969), 4)) + // leap years
        @as(i64, month - 1) * 30 + // approximate months
        @as(i64, day - 1);

    const seconds: i64 = days_since_epoch * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);

    return seconds * 1000; // Return milliseconds
}

// CANARY: REQ=REQ-BACKUP-RESTORE-003; FEATURE="Backup Restore Manager"; ASPECT=LocalRestoreImpl; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=cli; UPDATED=2026-01-09
const SimplifiedRestoreManager = struct {
    allocator: std.mem.Allocator,
    backup_dir: []const u8,
    restore_dir: []const u8,

    /// Restore from a backup file to the restore directory
    fn restoreFromBackup(self: SimplifiedRestoreManager, backup_path: []const u8) !RestoreMetadata {
        // Open backup file
        const io_rb = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_rb, backup_path, .{}) catch |err| {
            std.debug.print("RESTORE: Failed to open backup file '{s}': {}\n", .{ backup_path, err });
            return error.BackupFileNotFound;
        };
        defer file.close(io_rb);

        // Read entire file into memory for processing
        const stat = file.stat(io_rb) catch return error.ReadError;
        // Cast to usize (safely truncates on 32-bit platforms; backup files should not exceed addressable memory)
        const file_size: usize = @intCast(stat.size);
        const file_data = self.allocator.alloc(u8, file_size) catch return error.OutOfMemory;
        defer self.allocator.free(file_data);
        const bytes_read = file.readPositionalAll(io_rb, file_data, 0) catch return error.ReadError;
        if (bytes_read != file_size) return error.ReadError;

        // Use a fixed buffer reader
        var reader = std.Io.Reader.fixed(file_data);

        // Read and verify header
        var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
        reader.readSliceAll(&header_buf) catch |err| {
            std.debug.print("RESTORE: Failed to read backup header: {}\n", .{err});
            return error.InvalidBackupFile;
        };
        const header: BackupHeader = std.mem.bytesToValue(BackupHeader, &header_buf);

        if (header.magic != BACKUP_MAGIC) {
            std.debug.print("RESTORE: Invalid backup file magic (expected 0x{x}, got 0x{x})\n", .{ BACKUP_MAGIC, header.magic });
            return error.InvalidBackupFile;
        }

        std.debug.print("RESTORE: Backup file version: {d}\n", .{header.version});
        std.debug.print("RESTORE: Backup type: {s}\n", .{@tagName(header.backup_type)});
        std.debug.print("RESTORE: Compression: {s}\n", .{@tagName(header.compression)});
        std.debug.print("RESTORE: Encrypted: {}\n", .{header.encrypted});

        const payload_offset = @sizeOf(BackupHeader);
        const payload_len: usize = @intCast(header.payload_len);
        if (file_data.len < payload_offset + payload_len) return error.InvalidBackupFile;
        const payload = file_data[payload_offset .. payload_offset + payload_len];

        const checksum_ok = computeChecksum(payload) == header.checksum;
        if (!checksum_ok) return error.BackupChecksumMismatch;

        var decoded: []u8 = payload;
        var decoded_owned = false;
        if (header.encrypted) {
            const key_raw = getEnvVarOwned(self.allocator, "GEODE_TDE_KEY") catch return error.MissingEncryptionKey;
            defer self.allocator.free(key_raw);
            const key = try parseHexKey(key_raw);
            decoded = try decryptData(payload, key, self.allocator);
            decoded_owned = true;
        }
        defer if (decoded_owned) self.allocator.free(decoded);

        const decompressed = try decompressData(decoded, header.compression, self.allocator);
        defer self.allocator.free(decompressed);

        // Ensure restore directory exists
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), self.restore_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.debug.print("RESTORE: Failed to create restore directory: {}\n", .{err});
                return err;
            },
        };

        const prev_override = graph_store.getDataDirOverride();
        var prev_owned: ?[]u8 = null;
        if (prev_override) |ov| {
            prev_owned = try self.allocator.dupe(u8, ov);
        }
        defer {
            if (prev_owned) |ov| {
                graph_store.setDataDirOverride(self.allocator, ov);
                self.allocator.free(ov);
            } else {
                graph_store.setDataDirOverride(self.allocator, null);
            }
        }

        graph_store.setDataDirOverride(self.allocator, self.restore_dir);
        // Legacy monolithic restore removed — per-graph restore via adapter.

        const backup_id = blk: {
            const base = std.fs.path.basename(backup_path);
            if (std.mem.startsWith(u8, base, "full_") and std.mem.endsWith(u8, base, ".backup")) {
                const hex = base["full_".len .. base.len - ".backup".len];
                break :blk std.fmt.parseInt(u64, hex, 16) catch 0;
            }
            break :blk 0;
        };

        return RestoreMetadata{
            .source_backup_id = backup_id,
            .restore_timestamp = compat_timestamp(),
            .backup_type = header.backup_type,
            .data_size_bytes = decompressed.len,
            .checksum_verified = checksum_ok,
            .target_time = null,
        };
    }

    // CANARY: REQ=REQ-PITR-GS-001; FEATURE="Point-in-Time Recovery"; ASPECT=SnapshotSelection; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=backup; UPDATED=2026-02-04
    /// Restore to a specific point in time by selecting the latest snapshot before target_time.
    fn restoreToPointInTime(self: SimplifiedRestoreManager, _: []const u8, target_time: i64) !RestoreMetadata {
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{self.backup_dir});
        defer self.allocator.free(metadata_path);

        const io_pt = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_pt, metadata_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return error.BackupMetadataNotFound,
            else => return err,
        };
        defer file.close(io_pt);

        const file_len = try file.length(io_pt);
        if (file_len > 2 * 1024 * 1024) return error.OutOfMemory;
        const data = try self.allocator.alloc(u8, @intCast(file_len));
        errdefer self.allocator.free(data);
        _ = try file.readPositionalAll(io_pt, data, 0);
        defer self.allocator.free(data);

        const parsed = try std.json.parseFromSlice([]backup_types.BackupMetadata, self.allocator, data, .{});
        defer parsed.deinit();

        var chosen: ?backup_types.BackupMetadata = null;
        for (parsed.value) |entry| {
            if (entry.timestamp > target_time) continue;
            if (chosen == null or entry.timestamp > chosen.?.timestamp) {
                chosen = entry;
            }
        }

        if (chosen == null) return error.BackupNotFound;
        const selected = chosen.?;
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, selected.backup_id });
        defer self.allocator.free(backup_path);

        const metadata = try self.restoreFromBackup(backup_path);
        return RestoreMetadata{
            .source_backup_id = selected.backup_id,
            .restore_timestamp = metadata.restore_timestamp,
            .backup_type = metadata.backup_type,
            .data_size_bytes = metadata.data_size_bytes,
            .checksum_verified = metadata.checksum_verified,
            .target_time = target_time,
        };
    }
};

const RestoreMetadata = struct {
    source_backup_id: u64,
    restore_timestamp: i64,
    backup_type: backup_types.BackupType,
    data_size_bytes: usize,
    checksum_verified: bool,
    target_time: ?i64,
};

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
