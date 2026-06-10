const std = @import("std");
const graph_store = @import("../graph_store.zig");
const backup = @import("storage/backup");
const BackupConfig = backup.BackupConfig;
const BackupMetadata = backup.BackupMetadata;

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

    /// Restore to a point in time using latest full backup before the timestamp.
    pub fn restoreToPointInTime(self: *SimplifiedBackupManager, target_time: i64, restore_dir: []const u8) !void {
        return self.inner.restoreToPointInTime(restore_dir, target_time);
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

test "SimplifiedBackupManager restore loads GraphStore snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const store = graph_store.getGlobalStore(allocator);
    _ = try store.createNode(&.{"RestoreTest"});

    var mgr = try SimplifiedBackupManager.init(allocator, "./test_backups2", .{});
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    try mgr.restoreToPointInTime(meta.timestamp, "./test_restore_dir");
}
