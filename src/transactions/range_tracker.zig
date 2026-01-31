const std = @import("std");

// Simple inclusive range over byte-slice keys (lexicographic ordering)
pub const Range = struct {
    low: []const u8,
    high: []const u8,
};

pub const Entry = struct {
    range: Range,
};

// RangeTracker maintains per-txn registered predicate ranges for phantom detection.
// Implementation uses linear scan; small cardinalities expected (demo scope).
pub const RangeTracker = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, std.ArrayList(Entry)), // txn_id -> ranges

    // CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomPreventionRangeDetection; OWNER=txn; UPDATED=2025-09-26

    pub fn init(allocator: std.mem.Allocator) RangeTracker {
        return .{ .allocator = allocator, .map = std.AutoHashMap(u64, std.ArrayList(Entry)).init(allocator) };
    }

    pub fn deinit(self: *RangeTracker) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr;
            for (list.items) |e| {
                self.allocator.free(e.range.low);
                self.allocator.free(e.range.high);
            }
            list.deinit(self.allocator);
        }
        self.map.deinit();
    }

    fn le(a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) != .gt;
    }

    pub fn register(self: *RangeTracker, txn_id: u64, low: []const u8, high: []const u8) !void {
        std.debug.assert(le(low, high));
        const entry = try self.map.getOrPut(txn_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(Entry).empty;
        }
        // de-duplicate if identical range already present
        for (entry.value_ptr.items) |e| {
            if (std.mem.eql(u8, e.range.low, low) and std.mem.eql(u8, e.range.high, high)) return;
        }
        const dup_low = try self.allocator.dupe(u8, low);
        const dup_high = try self.allocator.dupe(u8, high);
        entry.value_ptr.append(self.allocator, .{ .range = .{ .low = dup_low, .high = dup_high } }) catch {
            self.allocator.free(dup_low);
            self.allocator.free(dup_high);
            return error.OutOfMemory;
        };
    }

    // Returns true if key K is inside any registered range for txn_id
    pub fn keyInRanges(self: *RangeTracker, txn_id: u64, key: []const u8) bool {
        const list_opt = self.map.get(txn_id) orelse return false;
        for (list_opt.items) |e| {
            if (le(e.range.low, key) and le(key, e.range.high)) return true;
        }
        return false;
    }

    pub fn clearTxn(self: *RangeTracker, txn_id: u64) void {
        if (self.map.getPtr(txn_id)) |list| {
            for (list.items) |e| {
                self.allocator.free(e.range.low);
                self.allocator.free(e.range.high);
            }
            list.deinit(self.allocator);
            _ = self.map.remove(txn_id);
        }
    }
};

test "range tracker basic register & query" {
    var rt = RangeTracker.init(std.testing.allocator);
    defer rt.deinit();
    try rt.register(1, "a", "f");
    try rt.register(1, "m", "z");
    try std.testing.expect(rt.keyInRanges(1, "b"));
    try std.testing.expect(!rt.keyInRanges(1, "g"));
    try std.testing.expect(rt.keyInRanges(1, "y"));
}
