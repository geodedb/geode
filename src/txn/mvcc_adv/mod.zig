const std = @import("std");
pub const early = @import("early_detect.zig");
pub const predictive = @import("predictive_version_check.zig");
pub const repair = @import("conflict_repair_heuristics.zig");
pub const partial = @import("partial_rollback.zig");
pub const bench = @import("repair_throughput_bench.zig");
pub const skew = @import("predictive_skew_filter.zig");

pub const Aggregator = struct {
    allocator: std.mem.Allocator,
    early: early.EarlyDetector,
    summary: predictive.VersionSummary,
    skew: ?skew.PredictiveSkewFilter = null,

    pub fn init(allocator: std.mem.Allocator) !Aggregator {
        return .{ .allocator = allocator, .early = early.EarlyDetector.init(allocator), .summary = predictive.VersionSummary.init(allocator), .skew = null };
    }

    pub fn deinit(self: *Aggregator) void {
        self.early.deinit();
        self.summary.deinit();
        if (self.skew) |*s| s.deinit();
    }

    pub fn noteRead(self: *Aggregator, txn_id: u64, key: []const u8) !void {
        try self.early.noteAccess(txn_id, key, false);
        if (self.skew) |*f| f.noteAccess(key, false);
    }

    pub fn noteWrite(self: *Aggregator, txn_id: u64, key: []const u8, version: u64) !void {
        try self.early.noteAccess(txn_id, key, true);
        const hashed: u64 = std.hash.Wyhash.hash(0, key);
        try self.summary.record(hashed, version);
        if (self.skew) |*f| f.noteAccess(key, true);
    }

    pub fn predictOverlap(self: *Aggregator, a: u64, b: u64) bool {
        return self.early.predictConflict(a, b);
    }

    pub fn enableSkew(self: *Aggregator) void {
        if (self.skew == null) self.skew = skew.PredictiveSkewFilter.init(self.allocator);
    }
};
