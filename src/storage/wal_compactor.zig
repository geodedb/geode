const std = @import("std");
const Allocator = std.mem.Allocator;

// Automatic WAL compaction based on configurable thresholds
pub const WalCompactor = struct {
    allocator: Allocator,
    wal_dir: []const u8,
    config: CompactionConfig,
    stats: CompactionStats,
    
    pub const CompactionConfig = struct {
        // Compact when WAL size exceeds this threshold
        size_threshold_mb: usize = 100,
        // Compact when number of segments exceeds this
        segment_count_threshold: usize = 10,
        // Compact when ratio of dead to live records exceeds this
        dead_record_ratio: f32 = 0.5,
        // Minimum time between compactions
        min_interval_ms: u64 = 60000, // 1 minute
        // Maximum time between compactions
        max_interval_ms: u64 = 3600000, // 1 hour
        // Enable automatic compaction
        auto_compact: bool = true,
    };
    
    pub const CompactionStats = struct {
        last_compaction_time: i64 = 0,
        total_compactions: u64 = 0,
        bytes_reclaimed: u64 = 0,
        records_compacted: u64 = 0,
        failed_compactions: u64 = 0,
    };
    
    pub const WalSegment = struct {
        id: u64,
        path: []const u8,
        size: u64,
        created_time: i64,
        last_modified: i64,
        live_records: u64,
        dead_records: u64,
        
        pub fn deadRecordRatio(self: WalSegment) f32 {
            const total = self.live_records + self.dead_records;
            if (total == 0) return 0;
            return @as(f32, @floatFromInt(self.dead_records)) / @as(f32, @floatFromInt(total));
        }
    };
    
    pub fn init(allocator: Allocator, wal_dir: []const u8, config: CompactionConfig) WalCompactor {
        return .{
            .allocator = allocator,
            .wal_dir = wal_dir,
            .config = config,
            .stats = .{},
        };
    }
    
    pub fn shouldCompact(self: *WalCompactor) !bool {
        if (!self.config.auto_compact) return false;
        
        const now = std.time.milliTimestamp();
        const time_since_last = @as(u64, @intCast(now - self.stats.last_compaction_time));
        
        // Check minimum interval
        if (time_since_last < self.config.min_interval_ms) {
            return false;
        }
        
        // Force compaction if maximum interval exceeded
        if (time_since_last >= self.config.max_interval_ms) {
            return true;
        }
        
        // Check size threshold
        const total_size = try self.getTotalWalSize();
        if (total_size > self.config.size_threshold_mb * 1024 * 1024) {
            return true;
        }
        
        // Check segment count threshold
        const segments = try self.getSegments();
        defer self.allocator.free(segments);
        if (segments.len > self.config.segment_count_threshold) {
            return true;
        }
        
        // Check dead record ratio
        var total_dead: u64 = 0;
        var total_live: u64 = 0;
        for (segments) |segment| {
            total_dead += segment.dead_records;
            total_live += segment.live_records;
        }
        
        const total = total_dead + total_live;
        if (total > 0) {
            const ratio = @as(f32, @floatFromInt(total_dead)) / @as(f32, @floatFromInt(total));
            if (ratio > self.config.dead_record_ratio) {
                return true;
            }
        }
        
        return false;
    }
    
    pub fn compact(self: *WalCompactor) !void {
        const start_time = std.time.milliTimestamp();
        
        // Get all segments sorted by creation time
        const segments = try self.getSegments();
        defer self.allocator.free(segments);
        
        if (segments.len <= 1) return; // Nothing to compact
        
        // Create new compacted segment
        const compact_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/wal_compact_{}.seg",
            .{ self.wal_dir, start_time },
        );
        defer self.allocator.free(compact_path);
        
        var compact_file = try std.fs.createFileAbsolute(compact_path, .{});
        defer compact_file.close();
        
        var writer = compact_file.writer();
        var records_written: u64 = 0;
        var bytes_before: u64 = 0;
        var bytes_after: u64 = 0;
        
        // Track which records we've seen to eliminate duplicates
        var seen_lsns = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_lsns.deinit();
        
        // Process segments from newest to oldest (to keep latest version of records)
        var i = segments.len;
        while (i > 0) {
            i -= 1;
            const segment = segments[i];
            bytes_before += segment.size;
            
            // Read and process segment
            var file = try std.fs.openFileAbsolute(segment.path, .{});
            defer file.close();
            
            var reader = file.reader();
            while (true) {
                // Read record header
                const lsn = reader.readInt(u64, .little) catch break;
                const record_size = reader.readInt(u32, .little) catch break;
                const record_type = reader.readInt(u8, .little) catch break;
                
                // Check if we've already seen this LSN
                if (seen_lsns.contains(lsn)) {
                    // Skip this record
                    try reader.skipBytes(record_size, .{});
                    continue;
                }
                
                // Read record data
                const record_data = try self.allocator.alloc(u8, record_size);
                defer self.allocator.free(record_data);
                _ = try reader.read(record_data);
                
                // Write to compacted file
                try writer.writeInt(u64, lsn, .little);
                try writer.writeInt(u32, record_size, .little);
                try writer.writeInt(u8, record_type, .little);
                try writer.writeAll(record_data);
                
                try seen_lsns.put(lsn, {});
                records_written += 1;
                bytes_after += 8 + 4 + 1 + record_size;
            }
        }
        
        // Sync compacted file
        try compact_file.sync();
        
        // Atomically replace old segments with compacted one
        try self.replaceSegments(segments, compact_path);
        
        // Update stats
        self.stats.last_compaction_time = start_time;
        self.stats.total_compactions += 1;
        self.stats.bytes_reclaimed += bytes_before - bytes_after;
        self.stats.records_compacted += records_written;
        
        std.log.info("WAL compaction completed: {} segments -> 1, {} MB -> {} MB, {} records", .{
            segments.len,
            bytes_before / 1024 / 1024,
            bytes_after / 1024 / 1024,
            records_written,
        });
    }
    
    pub fn startAutoCompaction(self: *WalCompactor) !void {
        if (!self.config.auto_compact) return;
        
        const thread = try std.Thread.spawn(.{}, compactionThread, .{self});
        thread.detach();
    }
    
    fn compactionThread(self: *WalCompactor) void {
        while (self.config.auto_compact) {
            if (self.shouldCompact() catch false) {
                self.compact() catch |err| {
                    std.log.err("WAL compaction failed: {}", .{err});
                    self.stats.failed_compactions += 1;
                };
            }
            
            // Sleep for a bit before checking again
            std.time.sleep(10 * std.time.ns_per_s);
        }
    }
    
    fn getTotalWalSize(self: *WalCompactor) !u64 {
        var dir = try std.fs.openDirAbsolute(self.wal_dir, .{ .iterate = true });
        defer dir.close();
        
        var total_size: u64 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
            
            const stat = try dir.statFile(entry.name);
            total_size += stat.size;
        }
        
        return total_size;
    }
    
    fn getSegments(self: *WalCompactor) ![]WalSegment {
        var segments = std.ArrayList(WalSegment).init(self.allocator);
        defer segments.deinit();
        
        var dir = try std.fs.openDirAbsolute(self.wal_dir, .{ .iterate = true });
        defer dir.close();
        
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
            
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.wal_dir, entry.name });
            const stat = try dir.statFile(entry.name);
            
            // Parse segment ID from filename
            const id = try parseSegmentId(entry.name);
            
            // Count live and dead records (simplified - in reality would scan the segment)
            const live_records = stat.size / 100; // Rough estimate
            const dead_records = stat.size / 200; // Rough estimate
            
            try segments.append(.{
                .id = id,
                .path = path,
                .size = stat.size,
                .created_time = stat.ctime,
                .last_modified = stat.mtime,
                .live_records = live_records,
                .dead_records = dead_records,
            });
        }
        
        // Sort by creation time
        std.mem.sort(WalSegment, segments.items, {}, struct {
            fn lessThan(_: void, a: WalSegment, b: WalSegment) bool {
                return a.created_time < b.created_time;
            }
        }.lessThan);
        
        return try segments.toOwnedSlice();
    }
    
    fn parseSegmentId(filename: []const u8) !u64 {
        // Extract ID from filename like "wal_1234567890.seg"
        const start = std.mem.indexOf(u8, filename, "_") orelse return error.InvalidFilename;
        const end = std.mem.indexOf(u8, filename, ".") orelse return error.InvalidFilename;
        const id_str = filename[start + 1 .. end];
        return try std.fmt.parseInt(u64, id_str, 10);
    }
    
    fn replaceSegments(self: *WalCompactor, old_segments: []WalSegment, new_path: []const u8) !void {
        _ = self;
        
        // In a real implementation, this would:
        // 1. Create a manifest file listing the new segment
        // 2. Atomically update the manifest
        // 3. Delete old segments
        // 4. Handle crash recovery
        
        // For now, just delete old segments
        for (old_segments) |segment| {
            std.fs.deleteFileAbsolute(segment.path) catch |err| {
                std.log.warn("Failed to delete old segment {s}: {}", .{ segment.path, err });
            };
        }
        
        _ = new_path;
    }
};