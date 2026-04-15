const std = @import("std");
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=EarlyConflictDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_EarlyConflictDetection; BENCH=BenchmarkCANARY_REQ_GQL_073_EarlyConflictDetection; OWNER=txn; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=FalsePositiveReduction; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_FalsePositiveReduction; OWNER=txn; UPDATED=2025-09-20

/// Early conflict detector builds a speculative dependency graph between active transactions.
pub const EarlyDetector = struct {
    pub const Access = struct { key: []const u8, write: bool };
    allocator: std.mem.Allocator,
    // txn_id -> list of accesses (tracked order not currently exploited)
    keys: std.AutoHashMap(u64, std.ArrayList(Access)),

    pub fn init(allocator: std.mem.Allocator) EarlyDetector {
        return .{ .allocator = allocator, .keys = std.AutoHashMap(u64, std.ArrayList(Access)).init(allocator) };
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
            got.value_ptr.* = std.ArrayList(Access).empty;
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
    var gpa = std.heap.DebugAllocator(.{}){};
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

// ==================== Unit Tests (GAP-0237) ====================
// CANARY: REQ=REQ-GAP-0237; FEATURE="MVCCAdvancedUnitTests"; ASPECT=EarlyDetect; STATUS=TESTED; TEST=test_early_detector; OWNER=txn; UPDATED=2026-01-25

test "EarlyDetector init and deinit" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();
    // Should be empty initially
    try std.testing.expectEqual(@as(usize, 0), det.keys.count());
}

test "EarlyDetector noteAccess tracks transaction accesses" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", false);
    try det.noteAccess(1, "key2", true);

    const accesses = det.keys.get(1);
    try std.testing.expect(accesses != null);
    try std.testing.expectEqual(@as(usize, 2), accesses.?.items.len);
}

test "EarlyDetector predictConflict returns false for non-overlapping reads" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", false);
    try det.noteAccess(2, "key2", false);

    try std.testing.expect(!det.predictConflict(1, 2));
}

test "EarlyDetector predictConflict returns false for overlapping reads" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", false);
    try det.noteAccess(2, "key1", false); // Same key, both reads

    try std.testing.expect(!det.predictConflict(1, 2));
}

test "EarlyDetector predictConflict returns true for read-write conflict" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", false); // read
    try det.noteAccess(2, "key1", true); // write

    try std.testing.expect(det.predictConflict(1, 2));
}

test "EarlyDetector predictConflict returns true for write-write conflict" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", true); // write
    try det.noteAccess(2, "key1", true); // write

    try std.testing.expect(det.predictConflict(1, 2));
}

test "EarlyDetector predictConflict returns false for unknown transaction" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", true);

    try std.testing.expect(!det.predictConflict(1, 99)); // txn 99 doesn't exist
    try std.testing.expect(!det.predictConflict(99, 1));
}

test "EarlyDetector multiple keys per transaction" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", false);
    try det.noteAccess(1, "key2", false);
    try det.noteAccess(1, "key3", true);

    const accesses = det.keys.get(1).?;
    try std.testing.expectEqual(@as(usize, 3), accesses.items.len);
}

test "EarlyDetector multiple transactions" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key_a", false);
    try det.noteAccess(2, "key_b", false);
    try det.noteAccess(3, "key_c", false);

    try std.testing.expectEqual(@as(usize, 3), det.keys.count());
}

test "EarlyDetector no conflict between independent transactions" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key_a", true);
    try det.noteAccess(2, "key_b", true);
    try det.noteAccess(3, "key_c", true);

    // All different keys, no conflicts
    try std.testing.expect(!det.predictConflict(1, 2));
    try std.testing.expect(!det.predictConflict(2, 3));
    try std.testing.expect(!det.predictConflict(1, 3));
}

test "EarlyDetector predictConflict is symmetric" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "shared", true);
    try det.noteAccess(2, "shared", false);

    // Should detect conflict in both directions
    try std.testing.expect(det.predictConflict(1, 2));
    try std.testing.expect(det.predictConflict(2, 1));
}

test "EarlyDetector Access struct" {
    const access = EarlyDetector.Access{ .key = "test", .write = true };
    try std.testing.expectEqualStrings("test", access.key);
    try std.testing.expect(access.write);
}

test "EarlyDetector self-conflict check" {
    var det = EarlyDetector.init(std.testing.allocator);
    defer det.deinit();

    try det.noteAccess(1, "key1", true);
    try det.noteAccess(1, "key1", false);

    // Same transaction checking against itself
    try std.testing.expect(det.predictConflict(1, 1));
}
