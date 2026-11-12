const std = @import("std");
const graph_store = @import("../graph_store.zig");
const backup = @import("storage/backup");
const BackupConfig = backup.BackupConfig;
const BackupMetadata = backup.BackupMetadata;
const cluster = @import("../distributed/cluster.zig");
const audit = @import("../security/audit.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-002; FEATURE="ServerRefactoring"; ASPECT=BACKUP_MANAGER; STATUS=EXEMPT; OWNER=refactor; UPDATED=2026-01-10
// CANARY: REQ=REQ-BACKUP-REAL-DATA-001; FEATURE="BackupRealData"; ASPECT=DataIntegrity; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; OWNER=backup; UPDATED=2026-01-10
// GraphStore-backed backup manager wrapper for server integration.

/// Simplified backup manager for server integration (GraphStore only).
pub const SimplifiedBackupManager = struct {
    inner: backup.BackupManager,

    /// Initialize backup manager with directory and configuration.
    pub fn init(allocator: std.mem.Allocator, backup_dir: []const u8, config: BackupConfig) !SimplifiedBackupManager {
        const store = graph_store.getGlobalStore(allocator);
        const mgr = try backup.BackupManager.init(allocator, backup_dir, config, store);
        return .{ .inner = mgr };
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

    /// Apply retention policy.
    pub fn runRetention(self: *SimplifiedBackupManager) !void {
        return self.inner.runRetention();
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
pub fn restoreForServer(allocator: std.mem.Allocator, backup_dir: []const u8, target_time: []const u8, username: []const u8) !ServerRestoreResult {
    const result = try restoreForServerInner(allocator, backup_dir, target_time);
    audit.logSecurityGraphEvent(allocator, .{
        .event_type = .configuration_change,
        .action = "SERVER_RESTORE",
        .username = username,
        .details = result.message,
        .result_failure = !result.success,
    });
    return result;
}

fn restoreForServerInner(allocator: std.mem.Allocator, backup_dir: []const u8, target_time: []const u8) !ServerRestoreResult {
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

    var restored = backup.restoreBesideDataDir(allocator, backup_dir, live_dir, target_ms) catch |err| {
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

    const dir = try allocator.dupe(u8, restored.target_dir);
    errdefer allocator.free(dir);
    return .{ .success = true, .message = try msg.toOwnedSlice(allocator), .restore_dir = dir };
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
