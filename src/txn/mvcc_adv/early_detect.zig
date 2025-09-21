const std = @import("std");
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=EarlyConflictDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_EarlyConflictDetection; BENCH=BenchmarkCANARY_REQ_GQL_073_EarlyConflictDetection; OWNER=txn; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=FalsePositiveReduction; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_FalsePositiveReduction; OWNER=txn; UPDATED=2025-09-20

/// Early conflict detector builds a speculative dependency graph between active transactions.
pub const EarlyDetector = struct {
    pub const Access = struct { key: []const u8, write: bool };
    allocator: std.mem.Allocator,
    // txn_id -> list of accesses (tracked order not currently exploited)
    keys: std.AutoHashMap(u64, std.ArrayList(Access)),

    pub fn init(ally: std.mem.Allocator) EarlyDetector {
        return .{ .allocator = ally, .keys = std.AutoHashMap(u64, std.ArrayList(Access)).init(ally) };
    }

    pub fn deinit(self: *EarlyDetector) void {
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.keys.deinit();
    }

    pub fn noteAccess(self: *EarlyDetector, txn_id: u64, key: []const u8, write: bool) !void {
        const got = try self.keys.getOrPut(txn_id);
        if (!got.found_existing) {
            got.value_ptr.* = std.ArrayList(Access).initCapacity(self.allocator, 0) catch @panic("OOM");
        }
        try got.value_ptr.append(self.allocator, .{ .key = key, .write = write });
    }

    /// Returns true if any overlapping key where at least one side may write (reduced false positives vs pure read/read)
    pub fn predictConflict(self: *EarlyDetector, txn_a: u64, txn_b: u64) bool {
        const a = self.keys.get(txn_a) orelse return false;
        const b = self.keys.get(txn_b) orelse return false;
        for (a.items) |ka| {
            for (b.items) |kb| {
                if (std.mem.eql(u8, ka.key, kb.key)) {
                    if (ka.write or kb.write) return true; // require a write intent
                }
            }
        }
        return false;
    }
};

pub fn demoUsage() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var det = EarlyDetector.init(gpa.allocator());
    defer det.deinit();
    try det.noteAccess(1, "row:1", false);
    try det.noteAccess(2, "row:2", false);
    // pure reads overlapping should not trigger now
    try det.noteAccess(2, "row:1", false);
    std.debug.assert(!det.predictConflict(1, 2));
    // introduce a write
    try det.noteAccess(2, "row:1", true);
    std.debug.assert(det.predictConflict(1, 2));
}
