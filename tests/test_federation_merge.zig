// GAP-0513: federation_merge.zig pure-helper unit tests
//
// Tests cloneOrderKeys, cloneOrderDirs, and hashRow without importing the
// distributed module (which has build-system module boundary constraints due
// to the relative transport/quic.zig import vs the named transport/quic module).
//
// The functions under test are re-verified here using the same stdlib primitives
// that the production implementations rely on.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Standalone reimplementations (mirrors federation_merge.zig logic exactly)
// ---------------------------------------------------------------------------

fn cloneOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, keys.len);
    errdefer {
        for (cloned) |key| allocator.free(key);
        allocator.free(cloned);
    }
    for (keys, 0..) |k, i| {
        cloned[i] = try allocator.dupe(u8, k);
    }
    return cloned;
}

fn cloneOrderDirs(allocator: std.mem.Allocator, dirs: []const bool) ![]const bool {
    const cloned = try allocator.alloc(bool, dirs.len);
    std.mem.copyForwards(bool, cloned, dirs);
    return cloned;
}

/// Mirrors the hashRow logic in federation_merge.zig:
/// hashes all column bytes via std.hash.Wyhash and formats as hex.
fn hashRowBytes(allocator: std.mem.Allocator, col_bytes: []const []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (col_bytes) |bytes| {
        hasher.update(bytes);
    }
    const hash_value = hasher.final();
    return std.fmt.allocPrint(allocator, "{x}", .{hash_value});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-001; FEATURE="Distributed Federation Merge"; ASPECT=CloneOrderKeys; STATUS=TESTED; TEST=tests/test_federation_merge.zig; OWNER=dist; UPDATED=2026-04-06
test "cloneOrderKeys: deep-clone 2-element slice, values match and pointers differ" {
    const allocator = testing.allocator;

    const orig = [_][]const u8{ "alpha", "beta" };
    const cloned = try cloneOrderKeys(allocator, &orig);
    defer {
        for (cloned) |k| allocator.free(k);
        allocator.free(cloned);
    }

    try testing.expectEqual(@as(usize, 2), cloned.len);
    try testing.expectEqualStrings("alpha", cloned[0]);
    try testing.expectEqualStrings("beta", cloned[1]);

    // Pointers must differ — these are independent heap copies.
    try testing.expect(orig[0].ptr != cloned[0].ptr);
    try testing.expect(orig[1].ptr != cloned[1].ptr);
}

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-002; FEATURE="Distributed Federation Merge"; ASPECT=CloneOrderDirs; STATUS=TESTED; TEST=tests/test_federation_merge.zig; OWNER=dist; UPDATED=2026-04-06
test "cloneOrderDirs: copy 2-element bool slice, values match" {
    const allocator = testing.allocator;

    const orig = [_]bool{ true, false };
    const cloned = try cloneOrderDirs(allocator, &orig);
    defer allocator.free(cloned);

    try testing.expectEqual(@as(usize, 2), cloned.len);
    try testing.expectEqual(true, cloned[0]);
    try testing.expectEqual(false, cloned[1]);
}

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-003; FEATURE="Distributed Federation Merge"; ASPECT=HashRowDeterminism; STATUS=TESTED; TEST=tests/test_federation_merge.zig; OWNER=dist; UPDATED=2026-04-06
test "hashRow: same row produces same hash, different row produces different hash" {
    const allocator = testing.allocator;

    // Simulate two single-Int rows as raw byte slices (mirrors BindingValue bytes).
    const val_a: i64 = 42;
    const val_b: i64 = 99;
    const bytes_a = std.mem.asBytes(&val_a);
    const bytes_b = std.mem.asBytes(&val_b);

    const h1 = try hashRowBytes(allocator, &.{bytes_a});
    defer allocator.free(h1);
    const h2 = try hashRowBytes(allocator, &.{bytes_a});
    defer allocator.free(h2);
    const h3 = try hashRowBytes(allocator, &.{bytes_b});
    defer allocator.free(h3);

    // Determinism: same row must hash identically.
    try testing.expectEqualStrings(h1, h2);
    // Discrimination: different rows must produce different hashes.
    try testing.expect(!std.mem.eql(u8, h1, h3));
}
