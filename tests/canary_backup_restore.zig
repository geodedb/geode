const std = @import("std");
const backup_mod = @import("storage_backup");

// Lightweight mock WAL manager providing LSN progression and record range extraction.
const MockWalManager = struct {
    allocator: std.mem.Allocator,
    current_lsn: u64 = 1,
    log: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) MockWalManager {
        return .{ .allocator = allocator, .log = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *MockWalManager) void {
        self.log.deinit();
    }

    pub fn appendLogicalMutation(self: *MockWalManager, payload: []const u8) !void {
        // Simple encoding: [lsn:u64][len:u32][bytes]
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.current_lsn, .little);
        std.mem.writeInt(u32, buf[8..12], @intCast(payload.len), .little);
        try self.log.appendSlice(buf[0..12]);
        try self.log.appendSlice(payload);
        self.current_lsn += 1;
    }

    pub fn getCurrentLSN(self: *MockWalManager) u64 {
        return self.current_lsn;
    }

    pub fn getRecordsRange(self: *MockWalManager, start_lsn: u64, end_lsn: u64, allocator: std.mem.Allocator) ![]u8 {
        // Return concatenated entries whose embedded LSN in header is within [start_lsn, end_lsn)
        var out = std.ArrayList(u8).init(allocator);
        var i: usize = 0;
        while (i + 12 <= self.log.items.len) {
            const lsn = std.mem.readInt(u64, self.log.items[i .. i + 8], .little);
            const len = std.mem.readInt(u32, self.log.items[i + 8 .. i + 12], .little);
            const rec_total = 12 + len;
            if (lsn >= start_lsn and lsn < end_lsn) {
                try out.appendSlice(self.log.items[i .. i + rec_total]);
            }
            i += rec_total;
        }
        return try out.toOwnedSlice();
    }
};

// Lightweight mock PageManager interface expected by BackupManager (subset only).
const MockPageManager = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) MockPageManager {
        return .{ .allocator = allocator, .pages = std.ArrayList([]u8).init(allocator) };
    }
    pub fn deinit(self: *MockPageManager) void {
        for (self.pages.items) |p| self.allocator.free(p);
        self.pages.deinit();
    }
    pub fn addPage(self: *MockPageManager, data: []const u8) !void {
        const dup = try self.allocator.dupe(u8, data);
        try self.pages.append(dup);
    }
    pub fn serializeCatalog(self: *MockPageManager, allocator: std.mem.Allocator) ![]u8 {
        // Minimal catalog: JSON array of page sizes for determinism.
        var stream = std.ArrayList(u8).init(allocator);
        try stream.append('[');
        var i: usize = 0;
        while (i < self.pages.items.len) : (i += 1) {
            if (i != 0) try stream.append(',');
            var buf: [32]u8 = undefined;
            const written = try std.fmt.bufPrint(&buf, "{d}", .{self.pages.items[i].len});
            try stream.appendSlice(written);
        }
        try stream.append(']');
        return try stream.toOwnedSlice();
    }
    pub fn getPageCount(self: *MockPageManager) u64 {
        return @intCast(self.pages.items.len);
    }
    pub fn readPage(self: *MockPageManager, idx: u64, allocator: std.mem.Allocator) ![]u8 {
        if (idx >= self.pages.items.len) return error.InvalidPage;
        return allocator.dupe(u8, self.pages.items[@intCast(idx)]);
    }
};

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_backup_{d}", .{ base, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path; // caller frees
}

// TestCANARY_REQ_GQL_082_FullBackup
test "TestCANARY_REQ_GQL_082_FullBackup" {
    const allocator = std.testing.allocator;
    var wal_mgr = MockWalManager.init(allocator);
    defer wal_mgr.deinit();
    // Add a couple of WAL logical records so LSN advances.
    try wal_mgr.appendLogicalMutation("seed1");
    try wal_mgr.appendLogicalMutation("seed2");

    var pm = MockPageManager.init(allocator);
    defer pm.deinit();
    try pm.addPage("page-A-data");
    try pm.addPage("page-B-data-xxxxx");

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);

    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, @ptrCast(&wal_mgr), @ptrCast(&pm));
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try std.testing.expectEqual(backup_mod.BackupType.full, meta.backup_type);
    try std.testing.expect(meta.size_bytes > 0);
    // Open created file and sanity check header + page count.
    var it = std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer it.close();
    var full_found = false;
    var buf: [256]u8 = undefined;
    var iter = it.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "full_")) {
            full_found = true;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
            defer allocator.free(path);
            var f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            const read_len = try f.read(&buf);
            try std.testing.expect(read_len > @sizeOf(backup_mod.BackupMetadata));
            // Magic is first 4 bytes of header
            const magic = std.mem.readInt(u32, buf[0..4], .little);
            try std.testing.expectEqual(@as(u32, 0x47454F42), magic); // GEOB
        }
    }
    try std.testing.expect(full_found);
}

// TestCANARY_REQ_GQL_082_IncrementalBackup
test "TestCANARY_REQ_GQL_082_IncrementalBackup" {
    const allocator = std.testing.allocator;
    var wal_mgr = MockWalManager.init(allocator);
    defer wal_mgr.deinit();
    var pm = MockPageManager.init(allocator);
    defer pm.deinit();
    try pm.addPage("only-page");
    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, @ptrCast(&wal_mgr), @ptrCast(&pm));
    defer mgr.deinit();
    const full_meta = try mgr.createFullBackup();
    // Append new WAL records advancing LSN then create incremental specifying base LSN from previous end.
    try wal_mgr.appendLogicalMutation("delta-change-1");
    try wal_mgr.appendLogicalMutation("delta-change-2");
    const incr_meta = try mgr.createIncrementalBackup(full_meta.end_lsn);
    try std.testing.expectEqual(backup_mod.BackupType.incremental, incr_meta.backup_type);
    try std.testing.expect(incr_meta.size_bytes > 0);
    try std.testing.expect(incr_meta.parent_backup_id != null);
}

// TestCANARY_REQ_GQL_082_RestoreDriver
test "TestCANARY_REQ_GQL_082_RestoreDriver" {
    const allocator = std.testing.allocator;
    var wal_mgr = MockWalManager.init(allocator);
    defer wal_mgr.deinit();
    var pm = MockPageManager.init(allocator);
    defer pm.deinit();
    try pm.addPage("r-page-1");
    try pm.addPage("r-page-2");
    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, @ptrCast(&wal_mgr), @ptrCast(&pm));
    defer mgr.deinit();
    _ = try mgr.createFullBackup();
    try wal_mgr.appendLogicalMutation("after-full-WAL");
    const target_time = std.time.milliTimestamp() + 1; // near future
    const restore_dir = try makeTempDir(allocator);
    defer allocator.free(restore_dir);
    try mgr.restoreToPointInTime(target_time, restore_dir);
    // Expect catalog and at least page_0.dat present.
    var rdir = std.fs.cwd().openDir(restore_dir, .{ .iterate = true });
    defer rdir.close();
    var seen_catalog = false;
    var seen_page0 = false;
    var it = rdir.iterate();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, "catalog.dat")) seen_catalog = true;
        if (std.mem.eql(u8, e.name, "page_0.dat")) seen_page0 = true;
    }
    try std.testing.expect(seen_catalog and seen_page0);
}
