const std = @import("std");

// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PredictiveSkewFilter; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_073_PredictiveSkewFilter; OWNER=txn; UPDATED=2026-11-14
// Predictive Skew Filter
// Heuristic early-abort mechanism for hotspot (skew) detection. Tracks per-key access
// frequencies with exponential decay to avoid unbounded growth. If a key's adjusted
// frequency crosses a threshold and a transaction attempts an exclusive lock while
// another active writer is predicted, we return error.HotSkew.
//
// Strategy:
// - Maintain a small hash map from u64 hash(key) -> entry { freq, last_epoch }
// - Each call advances a global epoch counter every N operations (decay window)
// - Decay formula: freq = freq * decay_factor^(delta_epochs) implemented via shift
// - Threshold and decay parameters are compile-time tunables.
// - Integration point: Manager.acquireLock pre-check to reject high-risk writes.
//
// This is intentionally lightweight; false positives acceptable if they meaningfully
// reduce subsequent lock conflict cascades. Tests validate: (a) some HotSkew aborts
// occur under synthetic hotspot workload, (b) overall lock conflicts reduced vs control.

pub const PredictiveSkewFilter = struct {
    const Self = @This();
    const Entry = struct { freq: f64, last_epoch: u64 };

    allocator: std.mem.Allocator,
    table: std.AutoHashMap(u64, Entry),
    op_count: u64 = 0,
    epoch: u64 = 0,

    // Tunables
    decay_window: u64 = 1024, // operations per epoch
    decay_factor: f64 = 0.5, // applied per epoch of inactivity
    skew_threshold: f64 = 25.0, // frequency threshold

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .table = std.AutoHashMap(u64, Entry).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.table.deinit();
    }

    fn advanceEpoch(self: *Self) void {
        self.op_count += 1;
        if (self.op_count % self.decay_window == 0) self.epoch += 1;
    }

    fn decayUpdate(self: *Self, entry: *Entry) void {
        if (entry.last_epoch == self.epoch) return;
        const delta = self.epoch - entry.last_epoch;
        // approximate pow(decay_factor, delta) by repeated multiplication (delta small)
        var factor: f64 = 1.0;
        var i: u64 = 0;
        while (i < delta) : (i += 1) factor *= self.decay_factor;
        entry.freq *= factor;
        entry.last_epoch = self.epoch;
    }

    pub fn noteAccess(self: *Self, key: []const u8, write: bool) void {
        self.advanceEpoch();
        const h = std.hash.Wyhash.hash(0, key);
        var gop = self.table.getOrPut(h) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .freq = 0, .last_epoch = self.epoch };
        } else {
            self.decayUpdate(gop.value_ptr);
        }
        // Writes count heavier than reads (weight 2 vs 1)
        gop.value_ptr.freq += if (write) 2.0 else 1.0;
    }

    pub fn isHot(self: *Self, key: []const u8) bool {
        const h = std.hash.Wyhash.hash(0, key);
        if (self.table.getPtr(h)) |entry| {
            self.decayUpdate(entry);
            return entry.freq >= self.skew_threshold;
        }
        return false;
    }
};

// SONNY-6463: this test ran in no step and expected 1,000 writes (weight 2,
// all inside one 1,024-operation decay window: frequency 2,000) to stay under
// the threshold of 25. It now checks the documented tunables: a key crosses
// the threshold on its 13th write (26 >= 25), not its 12th (24), and decays
// back under it once enough epochs pass without access.
test "predictive skew filter basic hotspot detection" {
    var filter = PredictiveSkewFilter.init(std.testing.allocator);
    defer filter.deinit();
    var i: usize = 0;
    while (i < 12) : (i += 1) filter.noteAccess("hot", true);
    try std.testing.expect(!filter.isHot("hot"));
    filter.noteAccess("hot", true);
    try std.testing.expect(filter.isHot("hot"));
    // Six decay windows of other traffic halve it six times (26 / 64 < 25).
    i = 0;
    while (i < 6 * filter.decay_window) : (i += 1) filter.noteAccess("cold", false);
    try std.testing.expect(!filter.isHot("hot"));
}
