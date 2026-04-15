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
const graph_store = @import("../graph_store.zig");

// CANARY: REQ=REQ-GRAPHSTORE-SNAP-PIPE-001; FEATURE="SnapshotPipeline"; ASPECT=Maintenance; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-04
// GraphStore snapshot maintenance pipeline: checkpoint scheduling, compaction (rewrite), and archival hooks.

pub const PipelineConfig = struct {
    checkpoint_interval_override: ?usize = null,
    compaction_interval: usize = 2,
    archival_window: usize = 0,
};

pub const TickResult = struct {
    checkpoint: bool = false,
    compacted: bool = false,
    archived: bool = false,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    checkpoint_interval: usize,
    compaction_interval: usize,
    archival_window: usize,
    commit_count: usize = 0,
    checkpoint_count: usize = 0,
    last_checkpoint_id: u64 = 0,
    last_archival_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, store: *graph_store.GraphStore, cfg: PipelineConfig) Pipeline {
        return .{
            .allocator = allocator,
            .store = store,
            .checkpoint_interval = cfg.checkpoint_interval_override orelse 10,
            .compaction_interval = if (cfg.compaction_interval == 0) 1 else cfg.compaction_interval,
            .archival_window = cfg.archival_window,
        };
    }

    /// Record a commit count to drive checkpoint cadence.
    pub fn recordCommit(self: *Pipeline, n: usize) void {
        self.commit_count += n;
    }

    pub fn shouldCheckpoint(self: *Pipeline) bool {
        return self.commit_count >= self.checkpoint_interval;
    }

    pub fn tick(self: *Pipeline) !TickResult {
        var res = TickResult{};
        if (!self.shouldCheckpoint()) return res;

        self.commit_count = 0;
        self.checkpoint_count += 1;
        try self.store.saveToFile();
        self.last_checkpoint_id = @intCast(compat_milliTimestamp());
        res.checkpoint = true;

        if (self.compaction_interval > 0 and (self.checkpoint_count % self.compaction_interval == 0)) {
            // Compaction = snapshot rewrite after enough checkpoints.
            try self.store.saveToFile();
            res.compacted = true;
        }

        if (self.archival_window > 0 and (self.checkpoint_count % self.archival_window == 0)) {
            self.last_archival_id = self.last_checkpoint_id;
            res.archived = true;
        }

        return res;
    }
};
