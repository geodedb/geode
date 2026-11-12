const std = @import("std");
const graph_store = @import("../graph_store.zig");
const backup = @import("storage/backup");
const BackupConfig = backup.BackupConfig;
const BackupMetadata = backup.BackupMetadata;
const cluster = @import("../distributed/cluster.zig");
const audit = @import("../security/audit.zig");
const logging = @import("logging");
const log = logging.scoped("backup");
const Attr = logging.Attr;
// SONNY-6322: spawns this binary's offline auth-chain verifier (no
// signal-handler swap, the process environment; see spawn_io).
const spawn_io = @import("spawn_io");
const builtin = @import("builtin");

// CANARY: REQ=REQ-SERVER-REFACTOR-002; FEATURE="ServerRefactoring"; ASPECT=BACKUP_MANAGER; STATUS=EXEMPT; OWNER=refactor; UPDATED=2026-01-10
// CANARY: REQ=REQ-BACKUP-REAL-DATA-001; FEATURE="BackupRealData"; ASPECT=DataIntegrity; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=backup; UPDATED=2026-01-10
// GraphStore-backed backup manager wrapper for server integration.

/// Where servers before SONNY-6299 kept their backups: relative to the
/// server's working directory. Still read by a server restore (one
/// release); never written.
pub const legacy_backup_dir = "./server_backups";

/// Overrides the server's backup directory: an absolute path outside the
/// data directory (SONNY-6299).
pub const backup_dir_env = "GEODE_BACKUP_DIR";

fn hasUnsafeComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return true;
    }
    return std.mem.indexOfScalar(u8, path, 0) != null;
}

// CANARY: REQ=REQ-BACKUP-SECRETS-001; FEATURE="Backup Restore"; ASPECT=ServerBackupDir; STATUS=TESTED; TEST=tests/test_sonny6299_backup_excludes_secrets.zig; OWNER=storage; UPDATED=2026-11-11
/// The server's backup directory for the data directory `data_dir` (the one
/// the storage engine has open): `override` (GEODE_BACKUP_DIR) when set,
/// else `<data_dir>/backups`, which a backup never archives. The override
/// must be absolute, without `.`, `..` or empty components, and must not be
/// the data directory or inside it (it would be archived into the next
/// backup) except `<data_dir>/backups` itself; anything else is
/// error.InvalidBackupDir, never a fallback. Caller owns the result.
pub fn resolveServerBackupDir(allocator: std.mem.Allocator, data_dir: []const u8, override: ?[]const u8) ![]u8 {
    const data = std.mem.trimEnd(u8, data_dir, "/");
    if (data.len == 0) return error.StorageAdapterUnavailable;
    const default = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data, backup.server_backup_dir_name });
    const raw = override orelse return default;
    errdefer allocator.free(default);
    if (raw.len == 0) return default;

    const dir = std.mem.trimEnd(u8, raw, "/");
    if (dir.len == 0 or !std.fs.path.isAbsolute(dir) or hasUnsafeComponent(dir)) return error.InvalidBackupDir;
    if (std.mem.eql(u8, dir, default)) return default;
    if (std.mem.eql(u8, dir, data) or
        (std.mem.startsWith(u8, dir, data) and dir.len > data.len and dir[data.len] == '/') or
        (std.mem.startsWith(u8, data, dir) and data.len > dir.len and data[dir.len] == '/'))
    {
        return error.InvalidBackupDir;
    }
    const owned = try allocator.dupe(u8, dir);
    allocator.free(default);
    return owned;
}

/// `resolveServerBackupDir` for the running server (the storage engine's
/// open data directory and GEODE_BACKUP_DIR), created mode 0700 when absent
/// (its parent must exist). Caller owns the result.
pub fn serverBackupDir(allocator: std.mem.Allocator) ![]u8 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.StorageAdapterUnavailable;
    const override: ?[]const u8 = if (std.c.getenv(backup_dir_env)) |v| std.mem.span(v) else null;
    const dir = resolveServerBackupDir(allocator, adapter.data_dir, override) catch |err| {
        if (err == error.InvalidBackupDir) {
            log.err("GEODE_BACKUP_DIR must be an absolute path outside the data directory; backup refused", &.{
                Attr.string("data_dir", adapter.data_dir),
            });
        }
        return err;
    };
    errdefer allocator.free(dir);
    const io = std.Io.Threaded.global_single_threaded.io();
    const perms: std.Io.File.Permissions = if (comptime @import("builtin").os.tag == .windows) .default_dir else std.Io.File.Permissions.fromMode(0o700);
    std.Io.Dir.cwd().createDir(io, dir, perms) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
            d.close(io);
        },
        else => return err,
    };
    return dir;
}

/// Simplified backup manager for server integration (GraphStore only).
/// SONNY-6355: whether server backups are encrypted (GEODE_TDE_KEY set).
pub const encryptionFromEnv = backup.encryptionFromEnv;

pub const SimplifiedBackupManager = struct {
    inner: backup.BackupManager,

    /// Initialize backup manager with directory and configuration.
    pub fn init(allocator: std.mem.Allocator, backup_dir: []const u8, config: BackupConfig) !SimplifiedBackupManager {
        const store = graph_store.getGlobalStore(allocator);
        const mgr = try backup.BackupManager.init(allocator, backup_dir, config, store);
        return .{ .inner = mgr };
    }

    /// `init` on the running server's backup directory (`serverBackupDir`).
    pub fn initForServer(allocator: std.mem.Allocator, config: BackupConfig) !SimplifiedBackupManager {
        const dir = try serverBackupDir(allocator);
        defer allocator.free(dir);
        return init(allocator, dir, config);
    }

    /// The directory backups are written to.
    pub fn backupDir(self: *const SimplifiedBackupManager) []const u8 {
        return self.inner.backup_dir;
    }

    /// Clean up resources.
    pub fn deinit(self: *SimplifiedBackupManager) void {
        self.inner.deinit();
    }

    /// Create a full backup and return metadata.
    pub fn createFullBackup(self: *SimplifiedBackupManager) !BackupMetadata {
        return self.inner.createFullBackup();
    }

    /// Ingest an uploaded backup artifact (header + payload bytes), verify
    /// integrity, persist it into the backup directory, and register it in
    /// the durable metadata log (GAP-0880).
    pub fn ingestUploadedBackup(self: *SimplifiedBackupManager, file_bytes: []const u8, expected_checksum: ?u64) !BackupMetadata {
        return self.inner.ingestUploadedBackup(file_bytes, expected_checksum);
    }

    /// Load metadata log from disk.
    pub fn loadMetadata(self: *SimplifiedBackupManager) !void {
        _ = try self.inner.loadMetadata();
    }
};

/// Outcome of a server restore request, for the QUIC and gRPC handlers'
/// RestoreResponse. `message` and `restore_dir` are owned by the caller.
pub const ServerRestoreResult = struct {
    success: bool,
    message: []u8,
    restore_dir: []u8,
};

fn refused(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ServerRestoreResult {
    return .{ .success = false, .message = try std.fmt.allocPrint(allocator, fmt, args), .restore_dir = try allocator.dupe(u8, "") };
}

/// The server restore request (QUIC `restore`, gRPC Restore), after the
/// caller has authorized an Admin and checked `confirm`. SONNY-6288: the
/// handlers used to restore into GEODE_DATA_DIR or ./data, in place, over
/// a live store, and answer "Restore completed" while still serving the old
/// data. A running server cannot swap its store under open engines, so it
/// never writes the restore into its data directory: it restores its newest
/// backup in `backup_dir` taken at or before `target_time` (epoch ms; empty
/// = now) into a new directory beside the data directory the storage engine
/// has open (`backup.restoreBesideDataDir`: staged, compared byte for byte,
/// opened as a store and counted per graph, then renamed), and reports that
/// directory and how to serve it. Refused in cluster mode (no replication
/// slice). Audited, success or failure.
// CANARY: REQ=REQ-BACKUP-RESTORE-003; FEATURE="Backup Restore"; ASPECT=ServerRestoreRequest; STATUS=TESTED; TEST=tests/test_sonny6288_server_restore_target.zig; OWNER=storage; UPDATED=2026-11-11
pub fn restoreForServer(allocator: std.mem.Allocator, backup_dirs: []const []const u8, target_time: []const u8, username: []const u8) !ServerRestoreResult {
    const result = try restoreForServerInner(allocator, backup_dirs, target_time);
    audit.logSecurityGraphEvent(allocator, .{
        .event_type = .configuration_change,
        .action = "SERVER_RESTORE",
        .username = username,
        .details = result.message,
        .result_failure = !result.success,
    });
    return result;
}

/// `restoreForServer` from the running server's backup directory
/// (`serverBackupDir`) and, for one release, the pre-SONNY-6299
/// ./server_backups of its working directory: the newest backup in either.
pub fn restoreForServerDefault(allocator: std.mem.Allocator, target_time: []const u8, username: []const u8) !ServerRestoreResult {
    const dir = serverBackupDir(allocator) catch |err| {
        const result = try refused(allocator, "Restore refused: {s}: the server's backup directory is unavailable (GEODE_BACKUP_DIR must be an absolute path outside the data directory)", .{@errorName(err)});
        audit.logSecurityGraphEvent(allocator, .{
            .event_type = .configuration_change,
            .action = "SERVER_RESTORE",
            .username = username,
            .details = result.message,
            .result_failure = true,
        });
        return result;
    };
    defer allocator.free(dir);
    const legacy_present = if (std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), legacy_backup_dir, .{})) |_| true else |_| false;
    const both = [_][]const u8{ dir, legacy_backup_dir };
    return restoreForServer(allocator, if (legacy_present) &both else both[0..1], target_time, username);
}

fn restoreForServerInner(allocator: std.mem.Allocator, backup_dirs: []const []const u8, target_time: []const u8) !ServerRestoreResult {
    cluster.gateUnreplicatedWrite() catch |err| {
        return refused(allocator, "Restore refused: {s}: a server restore is not replicated; restore offline with geode restore <file> --data-dir <path> on each node", .{@errorName(err)});
    };

    const target_ms: i64 = if (target_time.len == 0)
        realtimeMs()
    else
        std.fmt.parseInt(i64, target_time, 10) catch {
            return refused(allocator, "Restore refused: target_time must be epoch milliseconds", .{});
        };

    const adapter = graph_store.getGlobalAdapter() orelse {
        return refused(allocator, "Restore refused: StorageAdapterUnavailable: the server has no open data directory", .{});
    };
    const live_dir = adapter.data_dir;

    var restored = backup.restoreBesideDataDir(allocator, backup_dirs, live_dir, target_ms, verifyStagedAuthChain) catch |err| {
        if (err == error.AuthChainVerificationFailed) {
            return refused(allocator, "Restore failed: AuthChainVerificationFailed: the backup's __geode_security auth records do not verify with this server's HMAC key (sealed under another key?); nothing was restored and the data directory {s} was not changed. Restore it offline with geode restore <file> --data-dir <dir> --hmac-key-file <the source server's .geode_hmac_key>", .{live_dir});
        }
        return refused(allocator, "Restore failed: {s}; nothing was restored and the data directory {s} was not changed", .{ @errorName(err), live_dir });
    };
    defer restored.deinit();

    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(allocator);
    try msg.print(allocator, "Backup {s} restored and verified into {s} ({d} files, {d} bytes;", .{
        std.fs.path.basename(restored.backup_path), restored.target_dir, restored.stats.files, restored.stats.bytes,
    });
    for (restored.graphs, 0..) |g, i| {
        try msg.print(allocator, "{s} graph '{s}': {d} nodes, {d} edges", .{ if (i == 0) "" else ";", g.name, g.nodes, g.edges });
    }
    try msg.print(allocator, "). This server still serves {s}; to serve the restored data, stop it and start it with --data-dir {s}", .{ live_dir, restored.target_dir });
    if (std.mem.startsWith(u8, restored.backup_path, legacy_backup_dir)) {
        try msg.print(allocator, ". The backup came from the legacy {s} directory; new backups are written to {s}", .{ legacy_backup_dir, backup_dirs[0] });
    }
    if (restored.copied_hmac_key) {
        try msg.appendSlice(allocator, ". This server's HMAC key file was copied in; the restored auth chain, if any, was verified with this server's key before the restore was kept");
    }
    if (restored.key_material.any()) {
        var names_buf: [128]u8 = undefined;
        try msg.print(allocator, ". WARNING: the backup was made by an older geode and holds key material ({s}), restored mode 0600; treat that backup as secret", .{restored.key_material.names(&names_buf)});
    }

    const dir = try allocator.dupe(u8, restored.target_dir);
    errdefer allocator.free(dir);
    return .{ .success = true, .message = try msg.toOwnedSlice(allocator), .restore_dir = dir };
}

// CANARY: REQ=REQ-SONNY-6322-SERVER-RESTORE-CHAIN; FEATURE="Backup Restore"; ASPECT=ChildVerifier; STATUS=TESTED; TEST=tests/test_sonny6322_audit_seed_and_hmac_startup.zig; OWNER=storage; UPDATED=2026-11-11
/// SONNY-6322: verify a restored store's `__geode_security` chain the way
/// a server starting on it would: the key from GEODE_AUTH_HMAC_KEY or
/// GEODE_TDE_KEY, else the directory's `.geode_hmac_key` (this server's,
/// copied in by `restoreBesideDataDir`, or an older archive's). The running
/// server cannot open a second store in this process (the store is a process
/// global), so this runs its own binary's offline verifier, `geode auth
/// verify --data-dir <dir>`, as a child with the server's environment; it
/// prints no key bytes. A non-zero exit is error.AuthChainVerificationFailed.
/// Fails closed where the binary cannot be located (non-Linux). SONNY-6348:
/// opening the store writes to it (and starts an audit key epoch), so `restored_dir`
/// is the restore's throwaway check copy (`backup.ProbeCopy`), never the
/// staged copy that is committed.
fn verifyStagedAuthChain(allocator: std.mem.Allocator, restored_dir: []const u8) anyerror!void {
    if (comptime builtin.os.tag != .linux) return error.AuthChainVerificationUnavailable;
    var threaded = spawn_io.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    // The verifier takes the directory's lock; a restored copy has no lock
    // file of its own (an archive's is never written), so remove the one
    // the child leaves.
    const lock_path = try std.fs.path.join(allocator, &.{ restored_dir, backup.lock_file_name });
    defer allocator.free(lock_path);
    const fs_io = std.Io.Threaded.global_single_threaded.io();
    const lock_existed = if (std.Io.Dir.cwd().access(fs_io, lock_path, .{})) |_| true else |_| false;
    defer if (!lock_existed) std.Io.Dir.cwd().deleteFile(fs_io, lock_path) catch {};

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "/proc/self/exe", "auth", "verify", "--data-dir", restored_dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = result.term == .exited and result.term.exited == 0;
    if (!ok) {
        const tail = if (result.stderr.len > 512) result.stderr[result.stderr.len - 512 ..] else result.stderr;
        log.err("restored __geode_security chain does not verify", &.{
            Attr.string("restored_dir", restored_dir),
            Attr.string("verifier_output", tail),
        });
        return error.AuthChainVerificationFailed;
    }
}

fn realtimeMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.REALTIME, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    if (rc != 0) return std.math.maxInt(i64);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "SimplifiedBackupManager creates backup with GraphStore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const store = graph_store.getGlobalStore(allocator);
    _ = try store.createNode(&.{"Person"});

    var mgr = try SimplifiedBackupManager.init(allocator, "./test_backups", .{});
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    try std.testing.expect(meta.backup_type == .full);
}
