const std = @import("std");
const builtin = @import("builtin");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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

const geode = @import("geode");
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;

// CANARY: REQ=REQ-BACKUP-HEX-001; FEATURE="SecureHexKeyParsing"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=storage; UPDATED=2026-01-13
// GAP-0148 SECURITY FIX: Proper error handling for hex key parsing instead of silent catch 0

/// Parse a 64-character hex string into a 32-byte key with proper error handling.
/// GAP-0148: Replaces unsafe `catch 0` pattern that could corrupt encryption keys.
fn parseHexKey(hex_str: []const u8) ![32]u8 {
    if (hex_str.len != 64) {
        log.err("SECURITY: GEODE_TDE_KEY must be exactly 64 hex characters", &.{
            Attr.uint("expected_len", 64),
            Attr.uint("actual_len", @intCast(hex_str.len)),
        });
        return error.InvalidTdeKeyLength;
    }

    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_TDE_KEY", &.{
                Attr.uint("position", i * 2),
            });
            return error.InvalidTdeKeyHex;
        };
        const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_TDE_KEY", &.{
                Attr.uint("position", i * 2 + 1),
            });
            return error.InvalidTdeKeyHex;
        };
        key[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return key;
}

/// Backup configuration
pub const BackupConfig = struct {
    /// Compression for backup files. Only `.none` and `.gzip` have encoders
    /// wired in this release; requesting `.zstd`/`.lz4` fails with
    /// `error.UnsupportedCompression` (GAP-0880: never record a codec that
    /// was not actually applied). Default is `.none`; callers opt into
    /// `.gzip` explicitly (the server maps the wire `compress=true` flag to
    /// `.gzip`).
    compression: CompressionType = .none,

    /// Encryption for backup files
    encryption: bool = false,

    /// Retention policy in days
    retention_days: u32 = 30,
};

pub const CompressionType = enum(u32) {
    none = 0,
    zstd = 1,
    lz4 = 2,
    gzip = 3,
};

/// Backup metadata
pub const BackupMetadata = struct {
    backup_id: u64,
    timestamp: i64,
    backup_type: BackupType,
    size_bytes: u64,
    compression: CompressionType,
    encrypted: bool,
    checksum: u64,

    pub fn toJSON(self: BackupMetadata, writer: anytype) !void {
        try std.json.stringify(self, .{}, writer);
    }

    pub fn fromJSON(reader: anytype, allocator: std.mem.Allocator) !BackupMetadata {
        const json_str = try reader.readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(BackupMetadata, allocator, json_str, .{});
        defer parsed.deinit();

        return parsed.value;
    }
};

pub const BackupType = enum(u32) {
    full = 0,
};

/// Point-in-time recovery information
pub const RecoveryPoint = struct {
    timestamp: i64,
    backup_chain: []const u64, // Backup IDs needed for recovery
};

pub const BACKUP_MAGIC: u32 = 0x47454F42; // "GEOB"
pub const BACKUP_VERSION: u16 = 4;

/// Mode for backup files and their metadata: a backup holds every graph's
/// data, so only the owner may read it (SONNY-6299; was 0664).
const backup_file_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600);

// CANARY: REQ=REQ-BACKUP-SECRETS-001; FEATURE="Backup Restore"; ASPECT=ExcludeKeyMaterialAndLock; STATUS=TESTED; TEST=tests/test_sonny6299_backup_excludes_secrets.zig; OWNER=storage; UPDATED=2026-11-11
/// Top-level data-directory files a backup never holds (SONNY-6299):
/// `.geode.lock` is the running process's data-directory lock;
/// `.geode_hmac_key` authenticates the `__geode_security` chain (whoever
/// holds it beside a backup can re-seal forged auth records);
/// `.geode_admin_password` is the generated first-boot admin password;
/// `server.key`/`server.crt` are the server's auto-generated TLS identity
/// (the certificate goes with its key: a server regenerates the pair only
/// when the certificate is missing). A restore of auth state takes the HMAC
/// key from the operator instead.
pub const excluded_data_dir_files = [_][]const u8{ lock_file_name, hmac_key_file_name, ".geode_admin_password", "server.key", "server.crt" };
pub const lock_file_name = ".geode.lock";
pub const hmac_key_file_name = ".geode_hmac_key";

/// The server's backup directory inside its data directory (SONNY-6299).
/// Never archived, so a backup does not hold the previous backups.
pub const server_backup_dir_name = "backups";

/// Whether the top-level data-directory entry `name` stays out of a backup.
pub fn isExcludedFromBackup(name: []const u8, kind: std.Io.File.Kind) bool {
    switch (kind) {
        .file => {
            for (excluded_data_dir_files) |f| {
                if (std.mem.eql(u8, name, f)) return true;
            }
            return std.mem.endsWith(u8, name, ".backup") or std.mem.eql(u8, name, "backup_metadata.log");
        },
        .directory => return std.mem.eql(u8, name, server_backup_dir_name),
        else => return true,
    }
}

/// Which of the excluded files an archive holds: an archive written before
/// SONNY-6299 holds them all. A restore still writes the key files (0600)
/// so such a backup restores as before, warns, and never writes the lock.
pub const KeyMaterial = struct {
    hmac_key: bool = false,
    tls_key: bool = false,
    tls_cert: bool = false,
    admin_password: bool = false,
    lock: bool = false,

    pub fn any(self: KeyMaterial) bool {
        return self.hmac_key or self.tls_key or self.tls_cert or self.admin_password;
    }

    /// The key-material file names present, comma separated, into `buf`.
    pub fn names(self: KeyMaterial, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        const items = [_]struct { bool, []const u8 }{
            .{ self.hmac_key, hmac_key_file_name },
            .{ self.tls_key, "server.key" },
            .{ self.tls_cert, "server.crt" },
            .{ self.admin_password, ".geode_admin_password" },
        };
        for (items) |it| {
            if (!it[0]) continue;
            w.print("{s}{s}", .{ if (first) "" else ", ", it[1] }) catch break;
            first = false;
        }
        return w.buffered();
    }
};

/// The excluded files present at the top level of a (validated) archive.
pub fn archiveKeyMaterial(archive: []const u8) !KeyMaterial {
    var km: KeyMaterial = .{};
    var it = try ArchiveIterator.init(archive);
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, hmac_key_file_name)) km.hmac_key = true;
        if (std.mem.eql(u8, entry.name, "server.key")) km.tls_key = true;
        if (std.mem.eql(u8, entry.name, "server.crt")) km.tls_cert = true;
        if (std.mem.eql(u8, entry.name, ".geode_admin_password")) km.admin_password = true;
        if (std.mem.eql(u8, entry.name, lock_file_name)) km.lock = true;
    }
    return km;
}

// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=BackupNeedsDataDir; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
/// The data directory a backup archives: the store's data-directory override
/// (set by the server and the CLI), else GEODE_DATA_DIR. With neither it is
/// error.BackupDataDirUnknown. SONNY-6325: it used to fall back to /tmp,
/// so a backup archived every top-level entry of the shared temp directory.
/// Caller frees.
pub fn backupSourceDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (graph_store.getDataDirOverride()) |ov| return allocator.dupe(u8, ov);
    if (getEnvVarOwned(allocator, "GEODE_DATA_DIR")) |dir| {
        if (dir.len > 0) return dir;
        allocator.free(dir);
    } else |_| {}
    log.err("backup refused: no data directory is configured (no --data-dir and no GEODE_DATA_DIR)", &.{});
    return error.BackupDataDirUnknown;
}

// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=PrivateTempDir; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6325: create a private temporary directory
/// `<parent>/.<tag>-<random>`, mode 0700, exclusively (a name that exists is
/// never reused), and return its path (caller frees and removes it). `parent`
/// must be a real directory, not a symbolic link. Replaces fixed or
/// predictable temp paths such as S3 restore's /tmp/geode_s3_restore_<id>.
pub fn makePrivateTempDir(allocator: std.mem.Allocator, parent: []const u8, tag: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const pst = try std.Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = false });
    if (pst.kind != .directory) return error.TempDirParentNotDirectory;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
        } else {
            std.c.arc4random_buf(&rnd, rnd.len);
        }
        const path = try std.fmt.allocPrint(allocator, "{s}/.{s}-{x:0>16}", .{ std.mem.trimEnd(u8, parent, "/"), tag, std.mem.readInt(u64, &rnd, .little) });
        std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.fromMode(0o700)) catch |err| {
            allocator.free(path);
            if (err == error.PathAlreadyExists and attempt < 8) continue;
            return err;
        };
        errdefer allocator.free(path);
        if (comptime builtin.os.tag == .linux) {
            // The umask may have narrowed 0700; a new directory of ours is set exactly.
            var zbuf: [std.fs.max_path_bytes]u8 = undefined;
            const z = try std.fmt.bufPrintZ(&zbuf, "{s}", .{path});
            if (std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, z, 0o700)) != .SUCCESS) return error.AccessDenied;
        }
        return path;
    }
}

/// Backup header with payload length for GraphStore snapshots.
pub const BackupHeader = extern struct {
    magic: u32,
    version: u16,
    backup_type: BackupType,
    timestamp: i64,
    compression: CompressionType,
    encrypted: bool = false,
    _padding: [2]u8 = .{0} ** 2,
    payload_len: u64 = 0,
    checksum: u64 = 0,
};

/// Backup manager for managing database backups (GraphStore-only)
pub const BackupManager = struct {
    allocator: std.mem.Allocator,
    config: BackupConfig,
    backup_dir: []const u8,
    metadata_log: std.ArrayList(BackupMetadata),
    store: *graph_store.GraphStore,
    enc_key: [32]u8,

    /// Initialize backup manager with directory and configuration
    pub fn init(
        allocator: std.mem.Allocator,
        backup_dir: []const u8,
        config: BackupConfig,
        store: *graph_store.GraphStore,
    ) !BackupManager {
        // Ensure backup directory exists
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var enc_key: [32]u8 = [_]u8{0} ** 32;
        if (config.encryption) {
            if (getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |raw| {
                defer allocator.free(raw);
                enc_key = try parseHexKey(raw);
            } else |err| {
                log.err("SECURITY: Backup encryption enabled but GEODE_TDE_KEY missing", &.{
                    Attr.string("error", @errorName(err)),
                });
                return error.MissingEncryptionKey;
            }
        }

        return .{
            .allocator = allocator,
            .config = config,
            .backup_dir = try allocator.dupe(u8, backup_dir),
            .metadata_log = .empty,
            .store = store,
            .enc_key = enc_key,
        };
    }

    /// Clean up backup manager resources
    pub fn deinit(self: *BackupManager) void {
        self.metadata_log.deinit(self.allocator);
        self.allocator.free(self.backup_dir);
    }

    /// Create a full backup and return metadata.
    pub fn createFullBackup(self: *BackupManager) !BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = compat_milliTimestamp();

        // Persist via adapter checkpoint (no-op for file-based — adapter owns storage).
        try self.store.saveToFile();

        // Read the current per-graph storage layout (`graph_registry.dat` plus
        // the recursive `graphs/<uuid>/...` tree).
        const data_dir = try backupSourceDataDir(self.allocator);
        defer self.allocator.free(data_dir);

        const payload = try readPerGraphStoragePayload(self.allocator, data_dir);
        defer self.allocator.free(payload);

        const compress_result = try compressData(payload, self.config.compression, self.allocator);
        const compressed = compress_result.data;
        defer self.allocator.free(compressed);
        // GAP-0862: persist the compression actually applied, not the requested
        // type — otherwise restore tries to decompress raw bytes and fails.
        const effective_compression = compress_result.effective;

        const final_payload = if (self.config.encryption)
            try encryptData(compressed, self.enc_key, self.allocator)
        else
            try self.allocator.dupe(u8, compressed);
        defer self.allocator.free(final_payload);

        const checksum = computeChecksum(final_payload);

        // Write backup file (header + payload)
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const io_bf = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_bf, backup_path, .{ .permissions = backup_file_perms });
        defer file.close(io_bf);

        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .full,
            .timestamp = timestamp,
            .compression = effective_compression,
            .encrypted = self.config.encryption,
            .payload_len = final_payload.len,
            .checksum = checksum,
        };
        const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
        try file.writePositionalAll(io_bf, header_bytes, 0);
        try file.writePositionalAll(io_bf, final_payload, header_bytes.len);

        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .full,
            .size_bytes = @as(u64, @intCast(@sizeOf(BackupHeader) + final_payload.len)),
            .compression = effective_compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
        };

        try self.metadata_log.append(self.allocator, metadata);
        try self.writeMetadata();
        return metadata;
    }

    /// Ingest an uploaded backup artifact (the complete bytes of a
    /// `full_*.backup` file: BackupHeader + payload) into this manager's
    /// backup_dir and register it durably in the metadata log so it becomes
    /// restorable via `restoreToPointInTime`.
    ///
    /// Verification BEFORE anything is written (GAP-0880: no empty-file
    /// fake-success path):
    ///   - header magic / version / backup_type must match this engine
    ///   - header.payload_len must equal the actual payload byte count
    ///   - header.checksum must match a recomputed CRC32 of the payload
    ///   - if `expected_checksum` is provided (client-asserted, from the
    ///     original BackupResponse), it must match the header checksum
    // CANARY: REQ=REQ-BACKUP-UPLOAD-001; FEATURE="BackupUploadIngestion"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=storage; UPDATED=2026-06-10
    pub fn ingestUploadedBackup(self: *BackupManager, file_bytes: []const u8, expected_checksum: ?u64) !BackupMetadata {
        if (file_bytes.len < @sizeOf(BackupHeader)) return error.InvalidBackupFile;

        const header = try decodeBackupHeader(file_bytes[0..@sizeOf(BackupHeader)]);

        const payload = file_bytes[@sizeOf(BackupHeader)..];
        if (header.payload_len != payload.len) return error.InvalidBackupFile;
        if (computeChecksum(payload) != header.checksum) return error.BackupChecksumMismatch;
        if (expected_checksum) |expected| {
            if (expected != header.checksum) return error.BackupChecksumMismatch;
        }

        // Merge with any registry already on disk before appending, so the
        // persisted metadata log never loses prior entries.
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }

        const backup_id = generateBackupId();
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const io_ub = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_ub, backup_path, .{ .permissions = backup_file_perms });
        defer file.close(io_ub);
        try file.writeStreamingAll(io_ub, file_bytes);
        try file.sync(io_ub);

        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = header.timestamp,
            .backup_type = header.backup_type,
            .size_bytes = file_bytes.len,
            .compression = header.compression,
            .encrypted = header.encrypted,
            .checksum = header.checksum,
        };
        try self.metadata_log.append(self.allocator, metadata);
        try self.writeMetadata();
        return metadata;
    }

    /// Restore to a point in time using the latest full backup before the timestamp.
    pub fn restoreToPointInTime(self: *BackupManager, restore_dir: []const u8, target_time: i64) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        const reload_live_store = self.store.data_dir.len > 0 and std.mem.eql(u8, self.store.data_dir, restore_dir);
        const recovery = try self.findRecoveryPoint(target_time);
        defer self.allocator.free(recovery.backup_chain);

        const backup_id = recovery.backup_chain[recovery.backup_chain.len - 1];
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        var decoded = try readBackupFile(self.allocator, backup_path, self.enc_key);
        defer decoded.deinit(self.allocator);

        // Write snapshot to restore directory and load store.
        const prev_override = graph_store.getDataDirOverride();
        var prev_override_owned: ?[]u8 = null;
        if (prev_override) |ov| {
            prev_override_owned = try self.allocator.dupe(u8, ov);
        }
        defer {
            if (prev_override_owned) |ov| {
                graph_store.setDataDirOverride(self.allocator, ov);
                self.allocator.free(ov);
            } else {
                graph_store.setDataDirOverride(self.allocator, null);
            }
        }

        graph_store.setDataDirOverride(self.allocator, restore_dir);

        try restorePerGraphPayload(self.allocator, restore_dir, decoded.archive);

        if (reload_live_store) {
            // Reopen the adapter on the restored directory before rebuilding the
            // compatibility cache so reads reflect the restored graph-storage files.
            graph_store.deinitGlobalAdapter();
            _ = try graph_store.initGlobalAdapter(self.allocator, restore_dir);
            try self.store.loadFromFile();
        }
    }

    /// Apply retention policy and remove old backups.
    pub fn runRetention(self: *BackupManager) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        if (self.metadata_log.items.len == 0) return;

        const cutoff = compat_milliTimestamp() - @as(i64, @intCast(self.config.retention_days)) * 24 * 60 * 60 * 1000;
        var kept: std.ArrayList(BackupMetadata) = .{};

        for (self.metadata_log.items) |entry| {
            if (entry.timestamp >= cutoff) {
                try kept.append(self.allocator, entry);
                continue;
            }
            const path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, entry.backup_id });
            defer self.allocator.free(path);
            std.Io.Dir.cwd().deleteFile(path) catch |err| {
                log.warn("Failed to delete expired backup", &.{
                    Attr.string("path", path),
                    Attr.string("error", @errorName(err)),
                });
            };
        }

        self.metadata_log.deinit(self.allocator);
        self.metadata_log = kept;
        try self.writeMetadata();
    }

    /// Load metadata log from disk.
    pub fn loadMetadata(self: *BackupManager) ![]BackupMetadata {
        const path = try self.metadataPath();
        defer self.allocator.free(path);

        const io_ml = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_ml, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return self.metadata_log.items,
            else => return err,
        };
        defer file.close(io_ml);

        const stat_ml = try file.stat(io_ml);
        const size_ml: usize = @intCast(@min(stat_ml.size, 2 * 1024 * 1024));
        const data = try self.allocator.alloc(u8, size_ml);
        defer self.allocator.free(data);
        _ = try file.readPositionalAll(io_ml, data, 0);

        const parsed = try std.json.parseFromSlice([]BackupMetadata, self.allocator, data, .{});
        defer parsed.deinit();

        self.metadata_log.deinit(self.allocator);
        self.metadata_log = .empty;
        for (parsed.value) |entry| {
            try self.metadata_log.append(self.allocator, entry);
        }
        return self.metadata_log.items;
    }

    fn writeMetadata(self: *BackupManager) !void {
        const path = try self.metadataPath();
        defer self.allocator.free(path);
        const io_wm = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_wm, path, .{ .permissions = backup_file_perms });
        defer file.close(io_wm);
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, self.metadata_log.items, .{});
        defer self.allocator.free(json_str);
        try file.writeStreamingAll(io_wm, json_str);
    }

    fn metadataPath(self: *BackupManager) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{self.backup_dir});
    }

    fn findRecoveryPoint(self: *BackupManager, target_time: i64) !RecoveryPoint {
        var chosen: ?BackupMetadata = null;
        for (self.metadata_log.items) |entry| {
            if (entry.backup_type != .full) continue;
            if (entry.timestamp <= target_time) {
                if (chosen == null or entry.timestamp > chosen.?.timestamp) {
                    chosen = entry;
                }
            }
        }
        if (chosen == null) return error.NoBackupFound;

        var chain: std.ArrayList(u64) = .empty;
        try chain.append(self.allocator, chosen.?.backup_id);
        const chain_slice = try chain.toOwnedSlice(self.allocator);
        return .{
            .timestamp = chosen.?.timestamp,
            .backup_chain = chain_slice,
        };
    }
};

fn generateBackupId() u64 {
    var rng = std.Random.DefaultPrng.init(@bitCast(compat_milliTimestamp()));
    return rng.random().int(u64);
}

/// Append a single file entry (name + data) into the archive buffer.
fn appendFileEntry(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, file_path: []const u8, archive_name: []const u8) !void {
    const io_ae = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io_ae, file_path, .{ .mode = .read_only });
    defer file.close(io_ae);
    const stat = try file.stat(io_ae);
    const sz_ae: usize = @intCast(stat.size);
    const data = try allocator.alloc(u8, sz_ae);
    defer allocator.free(data);
    _ = try file.readPositionalAll(io_ae, data, 0);

    // name_len (u32) + name + data_len (u64) + data
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(archive_name.len))));
    try buffer.appendSlice(allocator, archive_name);
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u64, @intCast(data.len))));
    try buffer.appendSlice(allocator, data);
}

fn appendDirectoryTree(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    root_path: []const u8,
    archive_prefix: []const u8,
) !u32 {
    var file_count: u32 = 0;

    const io_dt = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io_dt, root_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close(io_dt);

    var iter = dir.iterate();
    while (try iter.next(io_dt)) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, entry.name });
        defer allocator.free(full_path);

        const archive_name = if (archive_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archive_prefix, entry.name });
        defer allocator.free(archive_name);

        switch (entry.kind) {
            .file => {
                try appendFileEntry(buffer, allocator, full_path, archive_name);
                file_count += 1;
            },
            .directory => {
                file_count += try appendDirectoryTree(buffer, allocator, full_path, archive_name);
            },
            else => {},
        }
    }

    return file_count;
}

/// Read all per-graph storage files (`graph_registry.dat` plus the full
/// recursive `graphs/<uuid>/...` tree) into a simple archive payload:
///   magic "GEODBAK1" (8 bytes) | version u32 | file_count u32 |
///   (name_len u32 | name [name_len]u8 | data_len u64 | data [data_len]u8)*
// CANARY: REQ=REQ-BACKUP-PER-GRAPH-001; FEATURE="PerGraphBackup"; ASPECT=Storage; STATUS=TESTED; OWNER=storage; UPDATED=2026-03-16
fn readPerGraphStoragePayload(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    // Archive header: magic + version placeholder + file_count placeholder.
    // We will overwrite file_count once we know it.
    try buffer.appendSlice(allocator, "GEODBAK1");
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1))); // version = 1

    // Reserve space for file_count; we'll patch it after collecting files.
    const file_count_offset = buffer.items.len;
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 0)));

    var file_count: u32 = 0;

    // Archive every top-level entry under data_dir: `graph_registry.dat` plus
    // each per-graph storage directory (`{data_dir}/<graph_uuid>/...`, the
    // canonical sharded-engine layout — see graph_storage_adapter.zig). The
    // legacy code archived a `{data_dir}/graphs/` subtree that DOES NOT EXIST
    // at the data_dir level (the real per-graph dirs are direct children of
    // data_dir), so backups captured only the registry and never any graph
    // data — making every restore produce an empty store (GAP-0862).
    const io_rp = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd().openDir(io_rp, data_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return buffer.toOwnedSlice(allocator);
        return err;
    };
    defer root.close(io_rp);

    var root_iter = root.iterate();
    while (try root_iter.next(io_rp)) |entry| {
        // SONNY-6299: no key material, lock, or backups (prior backup
        // artifacts and the server's backup directory).
        if (isExcludedFromBackup(entry.name, entry.kind)) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                try appendFileEntry(&buffer, allocator, full_path, entry.name);
                file_count += 1;
            },
            .directory => {
                file_count += try appendDirectoryTree(&buffer, allocator, full_path, entry.name);
            },
            else => {},
        }
    }

    // Patch file_count into the header.
    const count_bytes = std.mem.toBytes(file_count);
    @memcpy(buffer.items[file_count_offset .. file_count_offset + 4], &count_bytes);

    return buffer.toOwnedSlice(allocator);
}

/// A backup file read from disk and verified: its header, and the GEODBAK1
/// archive it carries (decrypted and decompressed, structure and entry names
/// checked). `archive` is owned.
pub const DecodedBackup = struct {
    header: BackupHeader,
    archive: []u8,
    stats: ArchiveStats,

    pub fn deinit(self: *DecodedBackup, allocator: std.mem.Allocator) void {
        allocator.free(self.archive);
        self.* = undefined;
    }
};

/// Number of files and data bytes in a GEODBAK1 archive.
pub const ArchiveStats = struct {
    files: u32 = 0,
    bytes: u64 = 0,
};

// CANARY: REQ=REQ-BACKUP-HEADER-001; FEATURE="Backup Restore"; ASPECT=RangeCheckedHeaderDecode; STATUS=TESTED; TEST=tests/test_sonny6289_backup_cleanup_info.zig; OWNER=storage; UPDATED=2026-11-11
/// Decode a backup header from its raw bytes, checking every field before
/// it is typed: magic and version, and the enum and bool fields in range (a
/// damaged header must never put an out-of-range value into an enum or a
/// bool, which is illegal behaviour and crashed `backup info` and `backup
/// list`, SONNY-6289). The one header decode for restore, upload, info,
/// list and cleanup.
pub fn decodeBackupHeader(header_buf: *const [@sizeOf(BackupHeader)]u8) !BackupHeader {
    const endian = builtin.cpu.arch.endian();
    if (std.mem.readInt(u32, header_buf[@offsetOf(BackupHeader, "magic")..][0..4], endian) != BACKUP_MAGIC) return error.InvalidBackupFile;
    if (std.mem.readInt(u16, header_buf[@offsetOf(BackupHeader, "version")..][0..2], endian) != BACKUP_VERSION) return error.InvalidBackupFile;
    if (header_buf[@offsetOf(BackupHeader, "encrypted")] > 1) return error.InvalidBackupFile;
    const raw_compression = std.mem.readInt(u32, header_buf[@offsetOf(BackupHeader, "compression")..][0..4], endian);
    if (std.enums.fromInt(CompressionType, raw_compression) == null) return error.InvalidBackupFile;
    const raw_type = std.mem.readInt(u32, header_buf[@offsetOf(BackupHeader, "backup_type")..][0..4], endian);
    if (std.enums.fromInt(BackupType, raw_type) == null) return error.InvalidBackupFile;
    return @bitCast(header_buf.*);
}

/// A backup file's decoded header and its size on disk.
pub const BackupFileHeader = struct {
    header: BackupHeader,
    file_size: u64,
};

/// Read and decode only the header of the backup file `sub_path` in `dir`
/// (`decodeBackupHeader`), and check the payload it declares fits in the
/// file. Reads 48 bytes; no checksum, decryption or archive check (that is
/// `readBackupFile`). With `follow_symlinks = false` a symbolic link is
/// refused, never followed.
pub fn readBackupHeaderAt(dir: std.Io.Dir, sub_path: []const u8, follow_symlinks: bool) !BackupFileHeader {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = dir.openFile(io, sub_path, .{ .mode = .read_only, .follow_symlinks = follow_symlinks }) catch |err| switch (err) {
        error.FileNotFound => return error.BackupFileNotFound,
        else => return err,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file) return error.InvalidBackupFile;
    var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
    const n = try file.readPositionalAll(io, &header_buf, 0);
    if (n != header_buf.len) return error.InvalidBackupFile;
    const header = try decodeBackupHeader(&header_buf);
    if (header.payload_len > st.size -| header_buf.len) return error.InvalidBackupFile;
    return .{ .header = header, .file_size = st.size };
}

/// `readBackupHeaderAt` for a path relative to the working directory.
pub fn readBackupHeader(path: []const u8) !BackupFileHeader {
    return readBackupHeaderAt(std.Io.Dir.cwd(), path, true);
}

/// Read and verify the backup file at `path`: header magic, version and
/// type, payload length, CRC32, decryption, decompression, and the archive
/// structure and entry names. Nothing is written. `enc_key` decrypts an
/// encrypted payload; when null, the key comes from GEODE_TDE_KEY (never
/// logged). The one decode path for the server restore and `geode restore`.
// CANARY: REQ=REQ-BACKUP-RESTORE-002; FEATURE="Backup Restore"; ASPECT=SharedBackupDecode; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=storage; UPDATED=2026-11-11
pub fn readBackupFile(allocator: std.mem.Allocator, path: []const u8, enc_key: ?[32]u8) !DecodedBackup {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.BackupFileNotFound,
        else => return err,
    };
    defer file.close(io);

    var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
    const hdr_n = try file.readPositionalAll(io, &header_buf, 0);
    if (hdr_n != header_buf.len) return error.InvalidBackupFile;
    const header = try decodeBackupHeader(&header_buf);

    const file_len = (try file.stat(io)).size;
    if (header.payload_len > file_len -| header_buf.len) return error.InvalidBackupFile;
    const payload_len: usize = @intCast(header.payload_len);
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    const pl_n = try file.readPositionalAll(io, payload, header_buf.len);
    if (pl_n != payload_len) return error.InvalidBackupFile;

    if (header.checksum != computeChecksum(payload)) return error.BackupChecksumMismatch;

    var decrypted: []u8 = payload;
    var decrypted_owned = false;
    if (header.encrypted) {
        const key = enc_key orelse blk: {
            const raw = getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch return error.MissingEncryptionKey;
            defer allocator.free(raw);
            break :blk try parseHexKey(raw);
        };
        decrypted = try decryptData(payload, key, allocator);
        decrypted_owned = true;
    }
    defer if (decrypted_owned) allocator.free(decrypted);

    const archive = try decompressData(decrypted, header.compression, allocator);
    errdefer allocator.free(archive);
    if (archive.len < 8 or !std.mem.eql(u8, archive[0..8], "GEODBAK1")) return error.UnsupportedBackupFormat;
    const stats = try validateArchive(allocator, archive);

    return .{ .header = header, .archive = archive, .stats = stats };
}

/// An archive entry name is a relative path under the restore directory:
/// not empty, not absolute, no `.`/`..`/empty components, no backslash or
/// NUL. Anything else could write outside the target (SONNY-6280).
fn isSafeArchiveEntryName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    if (std.mem.indexOfAny(u8, name, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

const ArchiveEntry = struct {
    name: []const u8,
    data: []const u8,
};

const ArchiveIterator = struct {
    payload: []const u8,
    offset: usize = 16,
    remaining: u32,

    fn init(payload: []const u8) !ArchiveIterator {
        if (payload.len < 16) return error.InvalidBackupFile;
        if (!std.mem.eql(u8, payload[0..8], "GEODBAK1")) return error.InvalidBackupFile;
        // version (u32) at offset 8 — currently ignored.
        return .{ .payload = payload, .remaining = std.mem.readInt(u32, payload[12..16], .little) };
    }

    fn next(self: *ArchiveIterator) !?ArchiveEntry {
        if (self.remaining == 0) {
            if (self.offset != self.payload.len) return error.InvalidBackupFile;
            return null;
        }
        self.remaining -= 1;
        const p = self.payload;
        if (p.len - self.offset < 4) return error.InvalidBackupFile;
        const name_len = std.mem.readInt(u32, p[self.offset..][0..4], .little);
        self.offset += 4;
        if (p.len - self.offset < name_len) return error.InvalidBackupFile;
        const name = p[self.offset .. self.offset + name_len];
        self.offset += name_len;
        if (p.len - self.offset < 8) return error.InvalidBackupFile;
        const data_len = std.mem.readInt(u64, p[self.offset..][0..8], .little);
        self.offset += 8;
        if (data_len > p.len - self.offset) return error.InvalidBackupFile;
        const data_size: usize = @intCast(data_len);
        const data = p[self.offset .. self.offset + data_size];
        self.offset += data_size;
        return .{ .name = name, .data = data };
    }
};

/// Check a whole archive before anything is written: well-formed, no
/// trailing bytes, every entry name safe and unique.
fn validateArchive(allocator: std.mem.Allocator, payload: []const u8) !ArchiveStats {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var stats: ArchiveStats = .{};
    var it = try ArchiveIterator.init(payload);
    while (try it.next()) |entry| {
        if (!isSafeArchiveEntryName(entry.name)) {
            log.err("backup archive entry name is not a safe relative path; restore refused", &.{
                Attr.uint("name_len", @intCast(entry.name.len)),
            });
            return error.UnsafeArchiveEntryName;
        }
        const gop = try seen.getOrPut(entry.name);
        if (gop.found_existing) return error.InvalidBackupFile;
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        stats.files += 1;
        stats.bytes += entry.data.len;
    }
    return stats;
}

/// Restore a per-graph archive payload into restore_dir, recreating
/// `graph_registry.dat` and every per-graph directory. The whole archive is
/// validated first (names cannot escape restore_dir). Files are created
/// 0600 — the archive keeps no modes, and one written before SONNY-6299
/// holds key material (server.key, .geode_hmac_key) — and synced before the
/// restore reports success. A `.geode.lock` entry (such an archive's) is
/// never written: it is the source process's lock, not data.
// CANARY: REQ=REQ-BACKUP-PER-GRAPH-002; FEATURE="PerGraphRestore"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=storage; UPDATED=2026-11-11
fn restorePerGraphPayload(allocator: std.mem.Allocator, restore_dir: []const u8, payload: []const u8) !void {
    _ = try validateArchive(allocator, payload);

    const io_ef = std.Io.Threaded.global_single_threaded.io();
    const file_perms: std.Io.File.Permissions = if (comptime builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600);
    var it = try ArchiveIterator.init(payload);
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        // Build the destination path and ensure parent directories exist.
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ restore_dir, entry.name });
        defer allocator.free(full_path);

        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
            // error-policy: A — ensure-parent-dirs is best-effort (the dir may
            // already exist); a real failure surfaces as a proper error on the
            // createFile immediately below.
            std.Io.Dir.cwd().createDirPath(io_ef, full_path[0..last_slash]) catch {};
        }

        const out = try std.Io.Dir.cwd().createFile(io_ef, full_path, .{ .permissions = file_perms });
        defer out.close(io_ef);
        try out.writeStreamingAll(io_ef, entry.data);
        try out.sync(io_ef);
    }
}

/// Re-read every file the archive names under `dir` and compare it byte for
/// byte with the archive.
fn verifyRestoredArchive(allocator: std.mem.Allocator, dir: []const u8, payload: []const u8) !ArchiveStats {
    const io = std.Io.Threaded.global_single_threaded.io();
    var stats: ArchiveStats = .{};
    var it = try ArchiveIterator.init(payload);
    var buf: [64 * 1024]u8 = undefined;
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
        defer allocator.free(full_path);
        const f = try std.Io.Dir.cwd().openFile(io, full_path, .{ .mode = .read_only });
        defer f.close(io);
        if ((try f.stat(io)).size != entry.data.len) return error.RestoreVerificationFailed;
        var off: usize = 0;
        while (off < entry.data.len) {
            const want = @min(buf.len, entry.data.len - off);
            const n = try f.readPositionalAll(io, buf[0..want], off);
            if (n != want or !std.mem.eql(u8, buf[0..want], entry.data[off .. off + want])) return error.RestoreVerificationFailed;
            off += want;
        }
        stats.files += 1;
        stats.bytes += entry.data.len;
    }
    return stats;
}

/// A restore written into a private staging directory next to the target,
/// verified file by file against the archive. `commit` renames it onto the
/// target (absent or empty); `discard` deletes it. Nothing appears at the
/// target path until `commit`, so a failed restore leaves no store there.
pub const StagedRestore = struct {
    allocator: std.mem.Allocator,
    staging_dir: []u8,
    target_dir: []u8,
    stats: ArchiveStats,
    committed: bool = false,

    pub fn commit(self: *StagedRestore) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().rename(self.staging_dir, std.Io.Dir.cwd(), self.target_dir, io) catch |err| switch (err) {
            error.DirNotEmpty => return error.RestoreTargetNotEmpty,
            else => return err,
        };
        self.committed = true;
    }

    /// Deletes the staging directory unless committed, and frees.
    pub fn deinit(self: *StagedRestore) void {
        if (!self.committed) {
            // error-policy: A — best-effort removal of our own staging dir;
            // the caller already reports the restore as failed.
            std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), self.staging_dir) catch {};
        }
        self.allocator.free(self.staging_dir);
        self.allocator.free(self.target_dir);
        self.* = undefined;
    }
};

/// Write `archive` (from `readBackupFile`) into a fresh mode-0700 staging
/// directory beside `target_dir` and verify it. `target_dir` must not exist
/// or be an empty directory (error.RestoreTargetNotEmpty otherwise); its
/// parent must exist. Never merges into or overwrites an existing store.
// CANARY: REQ=REQ-BACKUP-RESTORE-002; FEATURE="Backup Restore"; ASPECT=StagedRestoreIntoEmptyTarget; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=storage; UPDATED=2026-11-11
pub fn stageRestore(allocator: std.mem.Allocator, archive: []const u8, target_dir: []const u8) !StagedRestore {
    const io = std.Io.Threaded.global_single_threaded.io();
    const target = std.mem.trimEnd(u8, target_dir, "/");
    if (target.len == 0) return error.InvalidRestoreTarget;

    if (std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var dir_it = dir.iterate();
        if (try dir_it.next(io) != null) return error.RestoreTargetNotEmpty;
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir => return error.RestoreTargetNotEmpty,
        else => return err,
    }

    var rnd: [8]u8 = undefined;
    compat_fillRandom(&rnd);
    const staging = try std.fmt.allocPrint(allocator, "{s}.restore-{x}", .{ target, std.mem.readInt(u64, &rnd, .little) });
    errdefer allocator.free(staging);
    const target_owned = try allocator.dupe(u8, target);
    errdefer allocator.free(target_owned);

    const dir_perms: std.Io.File.Permissions = if (comptime builtin.os.tag == .windows) .default_dir else std.Io.File.Permissions.fromMode(0o700);
    try std.Io.Dir.cwd().createDir(io, staging, dir_perms);
    // error-policy: A — best-effort removal of our own staging dir on failure.
    errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    try restorePerGraphPayload(allocator, staging, archive);
    const stats = try verifyRestoredArchive(allocator, staging, archive);

    return .{ .allocator = allocator, .staging_dir = staging, .target_dir = target_owned, .stats = stats };
}

/// Node and edge count of one graph in a restored store.
pub const RestoredGraph = struct {
    name: []u8,
    nodes: u64,
    edges: u64,
};

pub fn freeRestoredGraphs(allocator: std.mem.Allocator, graphs: []RestoredGraph) void {
    for (graphs) |g| allocator.free(g.name);
    allocator.free(graphs);
}

/// Open the restored store in `dir` as a server would (its own storage
/// adapter, never the process-global one, so a running server can call it)
/// and count every graph's nodes and edges from its storage engine. Fails
/// if any graph in the restored registry cannot be opened. Shared by
/// `geode restore` and the server restore (SONNY-6280, SONNY-6288).
// CANARY: REQ=REQ-BACKUP-RESTORE-003; FEATURE="Backup Restore"; ASPECT=OpenAndCountRestoredStore; STATUS=TESTED; TEST=tests/test_sonny6288_server_restore_target.zig; OWNER=storage; UPDATED=2026-11-11
pub fn countRestoredStore(allocator: std.mem.Allocator, dir: []const u8) ![]RestoredGraph {
    const adapter = try graph_store.openDetachedAdapter(allocator, dir);
    defer adapter.deinit();

    const names = try adapter.listGraphNames(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var out: std.ArrayList(RestoredGraph) = .empty;
    errdefer {
        for (out.items) |g| allocator.free(g.name);
        out.deinit(allocator);
    }
    for (names) |name| {
        const nodes = try adapter.nodeCount(name);
        const edges = try adapter.edgeCount(name);
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        try out.append(allocator, .{ .name = name_owned, .nodes = nodes, .edges = edges });
    }
    return out.toOwnedSlice(allocator);
}

/// The newest full backup in `backup_dir/metadata.json` taken at or before
/// `target_time` (epoch ms). Reads only. Caller owns the returned path.
// CANARY: REQ=REQ-PITR-GS-001; FEATURE="Point-in-Time Recovery"; ASPECT=SnapshotSelection; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=backup; UPDATED=2026-11-11
pub fn selectPointInTimeBackup(allocator: std.mem.Allocator, backup_dir: []const u8, target_time: i64) ![]u8 {
    return selectPointInTimeBackupIn(allocator, &.{backup_dir}, target_time);
}

/// `selectPointInTimeBackup` across several backup directories (a server's
/// own and the pre-SONNY-6299 ./server_backups): the newest full backup at
/// or before `target_time` in any of them. A directory without
/// metadata.json is skipped; with none at all, error.BackupMetadataNotFound.
pub fn selectPointInTimeBackupIn(allocator: std.mem.Allocator, backup_dirs: []const []const u8, target_time: i64) ![]u8 {
    var chosen: ?BackupMetadata = null;
    var chosen_dir: []const u8 = "";
    var any_metadata = false;
    for (backup_dirs) |backup_dir| {
        const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{backup_dir});
        defer allocator.free(metadata_path);

        const io_pt = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_pt, metadata_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io_pt);
        any_metadata = true;

        const file_len = try file.length(io_pt);
        if (file_len > 2 * 1024 * 1024) return error.OutOfMemory;
        const data = try allocator.alloc(u8, @intCast(file_len));
        defer allocator.free(data);
        _ = try file.readPositionalAll(io_pt, data, 0);

        const parsed = try std.json.parseFromSlice([]BackupMetadata, allocator, data, .{});
        defer parsed.deinit();

        for (parsed.value) |entry| {
            if (entry.backup_type != .full) continue;
            if (entry.timestamp > target_time) continue;
            if (chosen == null or entry.timestamp > chosen.?.timestamp) {
                chosen = entry;
                chosen_dir = backup_dir;
            }
        }
    }
    if (!any_metadata) return error.BackupMetadataNotFound;

    const selected = chosen orelse return error.BackupNotFound;
    return std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ chosen_dir, selected.backup_id });
}

/// A server restore written into a new directory beside the server's data
/// directory and verified. Owns its strings.
pub const SideRestore = struct {
    allocator: std.mem.Allocator,
    /// The new directory holding the restored store.
    target_dir: []u8,
    /// The backup file restored.
    backup_path: []u8,
    stats: ArchiveStats,
    graphs: []RestoredGraph,
    /// Key material the archive held (an archive from before SONNY-6299).
    key_material: KeyMaterial = .{},
    /// The live data directory's `.geode_hmac_key` was copied in.
    copied_hmac_key: bool = false,

    pub fn deinit(self: *SideRestore) void {
        self.allocator.free(self.target_dir);
        self.allocator.free(self.backup_path);
        freeRestoredGraphs(self.allocator, self.graphs);
        self.* = undefined;
    }
};

/// Copy `<from_dir>/.geode_hmac_key` into `to_dir` (a fresh staging
/// directory), mode 0600, never overwriting. Returns false when `from_dir`
/// has no key file (the key comes from GEODE_AUTH_HMAC_KEY/GEODE_TDE_KEY).
/// The key bytes are never logged.
fn copyHmacKeyFile(allocator: std.mem.Allocator, from_dir: []const u8, to_dir: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from_dir, hmac_key_file_name });
    defer allocator.free(src);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ to_dir, hmac_key_file_name });
    defer allocator.free(dst);
    const out = try std.Io.Dir.cwd().createFile(io, dst, .{ .exclusive = true, .permissions = backup_file_perms });
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
    try out.sync(io);
    return true;
}

/// Restore the newest backup in `backup_dirs` taken at or before
/// `target_time` into a NEW directory beside `live_data_dir`, named
/// `<live_data_dir>.restored-<backup id>-<ms>` (SONNY-6288). The live data
/// directory is never written: a running server cannot swap its store under
/// open engines, so the caller tells the operator to restart on the result.
///
/// Same sequence as `geode restore` (SONNY-6280): decode and verify the
/// backup (`readBackupFile`), write it into a mode-0700 staging directory
/// beside the target and compare it byte for byte with the archive
/// (`stageRestore`), open it as a store and count every graph
/// (`countRestoredStore`), then rename it into place. Any failure leaves
/// neither the target nor the staging directory behind.
///
/// SONNY-6299: backups no longer hold `.geode_hmac_key`. This server
/// restores its own backups, so its key file (when it has one) is copied
/// into the restored directory; the restored `__geode_security` chain is
/// then verified with this server's key when a server starts on it, and a
/// backup sealed under another key fails that check (AuthChainTampered).
// CANARY: REQ=REQ-BACKUP-RESTORE-003; FEATURE="Backup Restore"; ASPECT=ServerRestoreBesideDataDir; STATUS=TESTED; TEST=tests/test_sonny6288_server_restore_target.zig; OWNER=storage; UPDATED=2026-11-11
pub fn restoreBesideDataDir(allocator: std.mem.Allocator, backup_dirs: []const []const u8, live_data_dir: []const u8, target_time: i64) !SideRestore {
    const live = std.mem.trimEnd(u8, live_data_dir, "/");
    const base = std.fs.path.basename(live);
    if (live.len == 0 or base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidRestoreTarget;
    }

    const backup_path = try selectPointInTimeBackupIn(allocator, backup_dirs, target_time);
    errdefer allocator.free(backup_path);

    var decoded = try readBackupFile(allocator, backup_path, null);
    defer decoded.deinit(allocator);
    const key_material = try archiveKeyMaterial(decoded.archive);

    const backup_name = std.fs.path.basename(backup_path);
    const id_hex = if (std.mem.startsWith(u8, backup_name, "full_") and std.mem.endsWith(u8, backup_name, ".backup"))
        backup_name["full_".len .. backup_name.len - ".backup".len]
    else
        "backup";
    const target = try std.fmt.allocPrint(allocator, "{s}.restored-{s}-{d}", .{ live, id_hex, compat_milliTimestamp() });
    errdefer allocator.free(target);
    if (std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), target, .{})) |_| {
        return error.RestoreTargetNotEmpty;
    } else |_| {}

    var staged = try stageRestore(allocator, decoded.archive, target);
    defer staged.deinit();

    const copied_hmac_key = if (key_material.hmac_key) false else try copyHmacKeyFile(allocator, live, staged.staging_dir);

    const graphs = try countRestoredStore(allocator, staged.staging_dir);
    errdefer freeRestoredGraphs(allocator, graphs);

    try staged.commit();

    return .{
        .allocator = allocator,
        .target_dir = target,
        .backup_path = backup_path,
        .stats = staged.stats,
        .graphs = graphs,
        .key_material = key_material,
        .copied_hmac_key = copied_hmac_key,
    };
}

/// Result of compressData: the compressed payload plus the compression type
/// that was ACTUALLY applied to it. The caller MUST persist `effective` into
/// the backup header, never the requested type. Recording the requested type
/// while storing raw bytes was GAP-0862: it produced backups that could not
/// be restored (decompress saw raw bytes -> error.BadMagic).
///
/// GAP-0880: `.gzip` now has a real encoder (stdlib DEFLATE,
/// `std.compress.flate.Compress` with the gzip container). `.zstd`/`.lz4`
/// have no encoder in this toolchain and are rejected with
/// `error.UnsupportedCompression` instead of silently falling back — a
/// caller that asked for zstd must never receive a raw artifact labeled
/// as anything it didn't get.
const CompressResult = struct {
    data: []u8,
    effective: CompressionType,
};

// CANARY: REQ=REQ-BACKUP-COMPRESS-001; FEATURE="BackupGzipCompression"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=storage; UPDATED=2026-06-10
fn compressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) !CompressResult {
    switch (compression) {
        .none => return .{ .data = try allocator.dupe(u8, data), .effective = .none },
        .gzip => {
            var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
            defer out.deinit();

            const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(window);

            var compress: std.compress.flate.Compress = try .init(&out.writer, window, .gzip, .default);
            try compress.writer.writeAll(data);
            try compress.finish();

            return .{ .data = try out.toOwnedSlice(), .effective = .gzip };
        },
        .zstd, .lz4 => {
            log.err("requested compression codec has no encoder", &.{
                Attr.string("requested", @tagName(compression)),
                Attr.string("supported", "none, gzip"),
            });
            return error.UnsupportedCompression;
        },
    }
}

fn decompressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    switch (compression) {
        .none => return allocator.dupe(u8, data),
        .gzip => {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var in: std.Io.Reader = .fixed(data);
            var flate_stream: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            _ = flate_stream.reader.streamRemaining(&out.writer) catch |err| return err;
            return try out.toOwnedSlice();
        },
        .zstd => {
            // Decompress-only support: no zstd encoder exists in this
            // toolchain, but restore must still read any artifact whose
            // header honestly records `.zstd`.
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var in: std.Io.Reader = .fixed(data);
            var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
            _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| return err;
            return try out.toOwnedSlice();
        },
        .lz4 => return error.UnsupportedCompression,
    }
}

fn encryptData(data: []const u8, key: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    const NonceSize = 12;
    const TagSize = 16;

    var nonce: [NonceSize]u8 = undefined;
    try cb.Csprng.bytes(&nonce);

    var tag: [TagSize]u8 = undefined;
    const ciphertext = try allocator.alloc(u8, data.len);
    errdefer allocator.free(ciphertext);

    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, "", data, ciphertext, &tag);

    const result = try allocator.alloc(u8, NonceSize + TagSize + data.len);
    @memcpy(result[0..NonceSize], &nonce);
    @memcpy(result[NonceSize .. NonceSize + TagSize], &tag);
    @memcpy(result[NonceSize + TagSize ..], ciphertext);

    allocator.free(ciphertext);
    return result;
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

    // The errdefer above frees `plaintext`; freeing it here too was a double
    // free that crashed every restore with the wrong key (SONNY-6280).
    cb.Aead.open(.aes_256_gcm, &key, &nonce, "", ciphertext, &tag, plaintext) catch return error.DecryptionFailed;

    return plaintext;
}

fn computeChecksum(data: []const u8) u64 {
    return std.hash.crc.Crc32.hash(data);
}

// ============================================================================
// Unit Tests for GAP-0148: Secure Hex Key Parsing
// CANARY: REQ=REQ-BACKUP-HEX-001; FEATURE="SecureHexKeyParsing"; ASPECT=TEST; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-13
// ============================================================================

test "parseHexKey: valid 64-char hex string" {
    const valid_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const key = try parseHexKey(valid_hex);

    // Verify first and last bytes
    try std.testing.expectEqual(@as(u8, 0x01), key[0]);
    try std.testing.expectEqual(@as(u8, 0x23), key[1]);
    try std.testing.expectEqual(@as(u8, 0xef), key[31]);
}

test "parseHexKey: uppercase hex is valid" {
    const valid_hex = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
    const key = try parseHexKey(valid_hex);

    try std.testing.expectEqual(@as(u8, 0xAB), key[5]);
    try std.testing.expectEqual(@as(u8, 0xCD), key[6]);
}
