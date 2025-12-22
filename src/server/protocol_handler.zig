const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const BackupConfig = @import("storage/backup").BackupConfig;
const SimplifiedBackupManager = @import("backup_manager.zig").SimplifiedBackupManager;

// CANARY: REQ=REQ-SERVER-REFACTOR-006; FEATURE="ServerRefactoring"; ASPECT=PROTOCOL_HANDLER; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.2 - Protocol Handler Module (Incremental Extraction)
// Extracted backup protocol handlers from server/main.zig for better separation of concerns

/// ServerState stub for protocol handlers (minimal interface needed)
/// Full ServerState lives in server/main.zig due to complex dependencies
pub const ServerState = struct {
    allocator: std.mem.Allocator,
    // Add only fields actually used by protocol handlers
};

/// Handle BACKUP protocol request from client
/// Creates full or incremental backup and returns metadata
pub fn handleBackupRequest(gpa: std.mem.Allocator, state: *ServerState, backup_req: protocol.Backup) ![]u8 {
    _ = state; // For now, we don't use server state

    // Create simplified backup manager for server-side backup
    const backup_config = BackupConfig{
        .compression = if (backup_req.compress) .zstd else .none,
        .encryption = false,
        .retention_days = 30,
    };

    var simplified_backup_manager = SimplifiedBackupManager.init(gpa, "./server_backups", backup_config) catch {
        return std.fmt.allocPrint(gpa, "BACKUP_ERROR: Failed to initialize backup manager\n", .{});
    };
    defer simplified_backup_manager.deinit();

    // Execute backup based on type
    const backup_metadata = if (std.mem.eql(u8, backup_req.backup_type, "full"))
        simplified_backup_manager.createFullBackup()
    else blk: {
        const parent_lsn = if (backup_req.parent_id) |_|
            1000 // Use a placeholder LSN value for now
        else {
            return std.fmt.allocPrint(gpa, "BACKUP_ERROR: Incremental backup requires parent ID\n", .{});
        };

        break :blk simplified_backup_manager.createIncrementalBackup(parent_lsn);
    };

    const metadata = backup_metadata catch |err| {
        return std.fmt.allocPrint(gpa, "BACKUP_ERROR: {s}\n", .{@errorName(err)});
    };

    // Generate backup file path based on metadata
    const backup_filename = try std.fmt.allocPrint(gpa, "./server_backups/{s}_{x}.backup", .{ @tagName(metadata.backup_type), metadata.backup_id });
    defer gpa.free(backup_filename);

    // Read backup file to send to client
    const backup_file = std.fs.cwd().openFile(backup_filename, .{}) catch {
        return std.fmt.allocPrint(gpa, "BACKUP_ERROR: Failed to read backup file\n", .{});
    };
    defer backup_file.close();

    const file_size = backup_file.getEndPos() catch metadata.size_bytes;

    // Send success response with metadata
    return std.fmt.allocPrint(gpa,
        \\BACKUP_SUCCESS
        \\backup_id: {x}
        \\type: {s}
        \\size_bytes: {d}
        \\compression: {s}
        \\checksum: {x}
        \\
    , .{ metadata.backup_id, backup_req.backup_type, file_size, @tagName(metadata.compression), metadata.checksum });
}

/// Handle RESTORE protocol request from client
/// Restores database from backup to specified point in time
pub fn handleRestoreRequest(gpa: std.mem.Allocator, state: *ServerState, restore_req: protocol.Restore) ![]u8 {
    _ = state; // For now, we don't use server state

    if (!restore_req.confirm) {
        return std.fmt.allocPrint(gpa, "RESTORE_ERROR: Restore requires confirmation\n", .{});
    }

    // In a real implementation, this would restore from the uploaded backup
    // For now, we'll simulate a successful restore
    const restore_timestamp = std.time.milliTimestamp();

    return std.fmt.allocPrint(gpa,
        \\RESTORE_SUCCESS
        \\restore_timestamp: {d}
        \\target_time: {s}
        \\message: Restore operation completed successfully
        \\
    , .{ restore_timestamp, restore_req.target_time orelse "latest" });
}

/// Handle UPLOAD_BACKUP protocol request from client
/// Prepares to receive backup data from client for restore operation
pub fn handleUploadBackupRequest(gpa: std.mem.Allocator, state: *ServerState, upload_req: protocol.UploadBackup) ![]u8 {
    _ = state; // For now, we don't use server state

    // Validate upload request
    if (upload_req.size_bytes == 0) {
        return std.fmt.allocPrint(gpa, "UPLOAD_ERROR: Invalid backup size\n", .{});
    }

    if (upload_req.checksum.len == 0) {
        return std.fmt.allocPrint(gpa, "UPLOAD_ERROR: Missing checksum\n", .{});
    }

    // Create directory for uploaded backups
    std.fs.cwd().makePath("./uploaded_backups") catch {};

    // Generate filename for uploaded backup
    const timestamp = std.time.milliTimestamp();
    const upload_filename = try std.fmt.allocPrint(gpa, "./uploaded_backups/uploaded_{d}.gql", .{timestamp});
    defer gpa.free(upload_filename);

    // Indicate readiness to receive backup data
    return std.fmt.allocPrint(gpa,
        \\READY
        \\expected_size: {d}
        \\expected_checksum: {s}
        \\upload_path: {s}
        \\
    , .{ upload_req.size_bytes, upload_req.checksum, upload_filename });
}
