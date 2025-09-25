const std = @import("std");
const testing = std.testing;
const backup = @import("../src/storage/backup.zig");

// CANARY: REQ=REQ-GQL-018; FEATURE="Backup/Restore"; ASPECT=RoundTrip; STATUS=TESTED; TEST=e2e_backup_restore_roundtrip; OWNER=storage; UPDATED=2025-09-25

test "Full backup with CRC verification" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Perform full backup
    const backup_path = "test_backup_full.dat";
    try backup.performBackup(.Full, backup_path);
    defer std.fs.cwd().deleteFile(backup_path) catch {};
    
    // Expected output:
    // BACKUP_OK type=full crc=true
    
    // Restore and verify CRC
    try backup.performRestore(backup_path);
    // Expected output:
    // RESTORE_OK lsn=*
}

test "Incremental backup with CRC verification" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Perform incremental backup
    const backup_path = "test_backup_inc.dat";
    try backup.performBackup(.Incremental, backup_path);
    defer std.fs.cwd().deleteFile(backup_path) catch {};
    
    // Expected output:
    // BACKUP_OK type=incremental crc=true
    
    // Restore and verify CRC
    try backup.performRestore(backup_path);
    // Expected output:
    // RESTORE_OK lsn=*
}

test "CRC mismatch detection" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Create a backup with valid CRC
    const backup_path = "test_backup_corrupt.dat";
    try backup.performBackup(.Full, backup_path);
    defer std.fs.cwd().deleteFile(backup_path) catch {};
    
    // Corrupt the backup file
    {
        const file = try std.fs.cwd().openFile(backup_path, .{ .mode = .read_write });
        defer file.close();
        
        // Corrupt a byte in the middle
        try file.seekTo(10);
        try file.writer().writeByte(0xFF);
    }
    
    // Restore should fail with CRC mismatch
    const result = backup.performRestore(backup_path);
    try testing.expectError(error.CrcMismatch, result);
}

test "Round-trip data integrity" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Backup -> Restore -> Backup -> Compare
    const backup1_path = "test_roundtrip1.dat";
    const backup2_path = "test_roundtrip2.dat";
    defer std.fs.cwd().deleteFile(backup1_path) catch {};
    defer std.fs.cwd().deleteFile(backup2_path) catch {};
    
    // First backup
    try backup.performBackup(.Full, backup1_path);
    
    // Restore
    try backup.performRestore(backup1_path);
    
    // Second backup after restore
    try backup.performBackup(.Full, backup2_path);
    
    // Compare file contents (should be identical)
    const file1 = try std.fs.cwd().openFile(backup1_path, .{});
    defer file1.close();
    const content1 = try file1.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content1);
    
    const file2 = try std.fs.cwd().openFile(backup2_path, .{});
    defer file2.close();
    const content2 = try file2.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content2);
    
    try testing.expectEqualSlices(u8, content1, content2);
}