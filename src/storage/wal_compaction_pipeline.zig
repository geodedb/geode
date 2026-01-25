const std = @import("std");
const wal = @import("wal");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=IMPL; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;

// WAL Compaction Pipeline orchestrates periodic checkpoint selection, compaction execution, and archival hook firing.
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CheckpointSelection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_CheckpointSelection; OWNER=storage; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CompactionJob; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_CompactionJob; OWNER=storage; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=ArchivalHook; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_083_ArchivalHook; OWNER=storage; UPDATED=2025-09-23

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    w: *wal.Wal,
    config: Config,
    last_archival_lsn: u64 = 0,

    pub const Config = struct {
        // Minimum number of checkpoints between compactions (mirrors wal.compaction_interval but can override)
        checkpoint_interval_override: ?usize = null,
        // If non-zero, force compaction when total size exceeds bytes.
        size_trigger_bytes: usize = 0,
        // Archival hook threshold (LSN distance)
        archival_window: u64 = 1000,
    };

    pub fn init(allocator: std.mem.Allocator, w: *wal.Wal, cfg: Config) Pipeline {
        return .{ .allocator = allocator, .w = w, .config = cfg };
    }

    /// Decide if a checkpoint should be written now (returns true if criteria satisfied).
    pub fn shouldCheckpoint(self: *Pipeline) bool {
        const stats = self.w.getCompactionStats();
        const goal = if (self.config.checkpoint_interval_override) |o| o else self.w.checkpoint_interval;
        return stats.commits_since_checkpoint >= goal;
    }

    /// Decide if compaction job should run (leverages WAL internal cadence plus size override).
    pub fn shouldCompact(self: *Pipeline) bool {
        const stats = self.w.getCompactionStats();
        if (self.config.size_trigger_bytes > 0 and stats.total_wal_size_bytes >= self.config.size_trigger_bytes) return true;
        return stats.checkpoints_since_compaction >= self.w.compaction_interval;
    }

    /// Execute one pipeline tick: maybe checkpoint, maybe compact, maybe archive.
    pub fn tick(self: *Pipeline) !struct { checkpoint: bool, compacted: bool, archived: bool } {
        var did_ckpt = false;
        var did_compact = false;
        var did_archive = false;
        if (self.shouldCheckpoint()) {
            _ = try self.w.writeCheckpoint();
            did_ckpt = true;
        }
        if (self.shouldCompact()) {
            // Durable horizon = last checkpoint LSN (avoid deleting active tail)
            const horizon = self.w.last_checkpoint_lsn;
            if (horizon > 0) {
                try self.w.compact(horizon);
                did_compact = true;
            }
        }
        if (self.w.last_checkpoint_lsn >= self.last_archival_lsn + self.config.archival_window) {
            self.last_archival_lsn = self.w.last_checkpoint_lsn;
            try self.fireArchivalHook(self.last_archival_lsn);
            did_archive = true;
        }
        return .{ .checkpoint = did_ckpt, .compacted = did_compact, .archived = did_archive };
    }

    /// GAP-0217 FIX: Real WAL archival hook implementation
    /// Archives compacted WAL segments to a backup location
    /// CANARY: REQ=REQ-GQL-WAL-ARCHIVE-001; FEATURE="RealWALArchival"; ASPECT=ColdStorage; STATUS=TESTED; TEST=test_gap_0217_wal_archive; OWNER=storage; UPDATED=2026-01-16
    fn fireArchivalHook(self: *Pipeline, upto_lsn: u64) !void {
        const archive_dir = "wal_archive";
        const timestamp = std.time.milliTimestamp();

        // Create archive directory if it doesn't exist
        std.fs.cwd().makePath(archive_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.err("WAL archival failed: cannot create archive dir", &.{
                    Attr.err("error", err),
                });
                return err;
            },
        };

        // Generate archive filename with LSN and timestamp
        var archive_name_buf: [128]u8 = undefined;
        const archive_name = std.fmt.bufPrint(&archive_name_buf, "{s}/wal_archive_{d}_{d}.bin", .{
            archive_dir,
            upto_lsn,
            timestamp,
        }) catch {
            log.err("WAL archival failed: filename buffer overflow", &.{});
            return error.BufferOverflow;
        };

        // Create archive file and write header
        const archive_file = std.fs.cwd().createFile(archive_name, .{}) catch |err| {
            log.err("WAL archival failed: cannot create archive file", &.{
                Attr.err("error", err),
            });
            return err;
        };
        defer archive_file.close();

        // Write archive header with magic, version, and LSN info
        const ArchiveHeader = extern struct {
            magic: u32 = 0x57414C41, // "WALA" (WAL Archive)
            version: u16 = 1,
            _pad: u16 = 0,
            lsn_start: u64,
            lsn_end: u64,
            timestamp: i64,
            checksum: u32 = 0,
        };

        var header = ArchiveHeader{
            .lsn_start = self.last_archival_lsn - self.config.archival_window,
            .lsn_end = upto_lsn,
            .timestamp = timestamp,
        };

        // Compute simple checksum of header fields
        header.checksum = @truncate(header.lsn_start ^ header.lsn_end ^ @as(u64, @bitCast(header.timestamp)));

        // Write header
        const header_bytes = std.mem.asBytes(&header);
        archive_file.writeAll(header_bytes) catch |err| {
            log.err("WAL archival failed: write header error", &.{
                Attr.err("error", err),
            });
            return err;
        };

        // Get WAL data to archive (read from WAL manager)
        // Archive the compacted WAL segments by reading from the WAL file
        if (self.w.file) |wal_file| {
            // Read WAL data up to the specified LSN
            const current_pos = try wal_file.getPos();
            try wal_file.seekTo(0);

            // Read WAL entries and write to archive
            var buffer: [4096]u8 = undefined;
            var total_archived: usize = 0;
            const max_archive_size = upto_lsn * 64; // Approximate: LSN * avg entry size

            while (total_archived < max_archive_size) {
                const bytes_read = wal_file.read(&buffer) catch break;
                if (bytes_read == 0) break;

                archive_file.writeAll(buffer[0..bytes_read]) catch |err| {
                    log.err("WAL archival failed: write data error", &.{
                        Attr.err("error", err),
                    });
                    return err;
                };
                total_archived += bytes_read;
            }

            // Restore original position
            try wal_file.seekTo(current_pos);

            log.info("WAL archival completed", &.{
                Attr.uint("lsn", upto_lsn),
                Attr.string("file", archive_name),
                Attr.uint("size_bytes", @intCast(total_archived + header_bytes.len)),
            });
        } else {
            // No WAL file available, just write the header as a marker
            log.info("WAL archival marker created (no WAL data)", &.{
                Attr.uint("lsn", upto_lsn),
                Attr.string("file", archive_name),
            });
        }
    }
};
