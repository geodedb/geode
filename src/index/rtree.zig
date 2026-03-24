// CANARY: REQ=REQ-SPATIAL-RTREE-001; FEATURE="RTreeSpatialIndex"; ASPECT=Wrapper; STATUS=TESTED; OWNER=index; UPDATED=2026-03-24

//! Thin compatibility wrapper around the external `rtree` library.
//!
//! Re-exports `MBR`, `RTreeEntry`, and `RTreeNode` directly and provides
//! a `RTree` shim that preserves the legacy API surface (non-failable
//! `init`, two-argument `search`, `bool`-returning `remove`) so that
//! existing consumers compile without modification.

const std = @import("std");
const rtree_lib = @import("rtree_lib");

// ---------------------------------------------------------------------------
// Direct re-exports — identical struct layout, fully compatible.
// ---------------------------------------------------------------------------

pub const MBR = rtree_lib.MBR;
pub const RTreeEntry = rtree_lib.RTreeEntry;
pub const RTreeNode = rtree_lib.RTreeNode;

// ---------------------------------------------------------------------------
// RTree compatibility wrapper
// ---------------------------------------------------------------------------

/// Drop-in replacement for the old hand-rolled `RTree`.
///
/// Field layout is identical to `rtree_lib.RTree` so that consumers
/// which read `.root`, `.count`, `.height`, `.M`, or `.allocator`
/// directly continue to work.  Methods that changed signature in
/// the external library are shimmed here.
pub const RTree = struct {
    allocator: std.mem.Allocator,
    root: ?*RTreeNode,
    M: u16,
    height: u16,
    count: u64,

    // -- Construction / destruction ----------------------------------------

    /// Create a new R-tree.  Unlike the external library this never
    /// returns an error — callers historically did not handle one.
    /// `M` must be >= 2; values below 2 are silently clamped.
    pub fn init(allocator: std.mem.Allocator, M: u16) RTree {
        const safe_M = if (M < 2) 2 else M;
        const inner = rtree_lib.RTree.init(allocator, safe_M) catch unreachable;
        return fromInner(inner);
    }

    pub fn deinit(self: *RTree) void {
        self.asInner().deinit();
    }

    // -- Insertion ----------------------------------------------------------

    pub fn insert(self: *RTree, mbr: MBR, id: u64) !void {
        try self.asInner().insert(mbr, id);
    }

    // -- Search -------------------------------------------------------------

    /// Search for entries whose bounding box intersects `query_mbr`.
    ///
    /// Uses the tree's own allocator for growing the results list, which
    /// matches the old behaviour where the tree owned the allocator used
    /// for result storage.
    pub fn search(self: *const RTree, query_mbr: MBR, results: *std.ArrayList(u64)) !void {
        try self.asInnerConst().search(query_mbr, self.allocator, results);
    }

    // -- Removal ------------------------------------------------------------

    /// Legacy `remove` returns a plain `bool`.  The external library's
    /// version can also fail with `OutOfMemory` during orphan reinsertion
    /// after node condensation; we surface that as `false` to match the
    /// old contract.
    pub fn remove(self: *RTree, mbr: MBR, id: u64) bool {
        return self.asInner().remove(mbr, id) catch false;
    }

    // -- Internal casting ---------------------------------------------------

    /// Interpret `*RTree` as `*rtree_lib.RTree`.  Safe because the two
    /// structs have identical field layout (verified by comptime assert
    /// below).
    inline fn asInner(self: *RTree) *rtree_lib.RTree {
        return @ptrCast(self);
    }

    inline fn asInnerConst(self: *const RTree) *const rtree_lib.RTree {
        return @ptrCast(self);
    }

    inline fn fromInner(inner: rtree_lib.RTree) RTree {
        return @bitCast(inner);
    }
};

// Compile-time check: wrapper and library structs must have the same memory
// layout so that the pointer casts above are sound.
comptime {
    if (@sizeOf(RTree) != @sizeOf(rtree_lib.RTree))
        @compileError("RTree wrapper size mismatch — update wrapper fields");
    if (@alignOf(RTree) != @alignOf(rtree_lib.RTree))
        @compileError("RTree wrapper alignment mismatch — update wrapper fields");
    // Verify every field has the same offset in both structs.
    if (@offsetOf(RTree, "allocator") != @offsetOf(rtree_lib.RTree, "allocator"))
        @compileError("RTree field offset mismatch: allocator");
    if (@offsetOf(RTree, "root") != @offsetOf(rtree_lib.RTree, "root"))
        @compileError("RTree field offset mismatch: root");
    if (@offsetOf(RTree, "M") != @offsetOf(rtree_lib.RTree, "M"))
        @compileError("RTree field offset mismatch: M");
    if (@offsetOf(RTree, "height") != @offsetOf(rtree_lib.RTree, "height"))
        @compileError("RTree field offset mismatch: height");
    if (@offsetOf(RTree, "count") != @offsetOf(rtree_lib.RTree, "count"))
        @compileError("RTree field offset mismatch: count");
}

// ===========================================================================
// Tests
// ===========================================================================

test "MBR contains" {
    const outer = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const inner = MBR{ .min_x = 2, .min_y = 2, .max_x = 8, .max_y = 8 };
    const outside = MBR{ .min_x = 11, .min_y = 11, .max_x = 20, .max_y = 20 };

    try std.testing.expect(outer.contains(inner));
    try std.testing.expect(!inner.contains(outer));
    try std.testing.expect(!outer.contains(outside));
}

test "MBR intersects" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const overlapping = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const disjoint = MBR{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 };

    try std.testing.expect(a.intersects(overlapping));
    try std.testing.expect(!a.intersects(disjoint));
}

test "MBR area" {
    const mbr = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try std.testing.expectEqual(@as(f64, 100.0), mbr.area());

    const point = MBR{ .min_x = 5, .min_y = 5, .max_x = 5, .max_y = 5 };
    try std.testing.expectEqual(@as(f64, 0.0), point.area());
}

test "MBR unionMbr" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const b = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const u = a.unionMbr(b);

    try std.testing.expectEqual(@as(f64, 0.0), u.min_x);
    try std.testing.expectEqual(@as(f64, 0.0), u.min_y);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_x);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_y);
}

test "MBR enlargement" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const b = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const enl = a.enlargement(b);
    try std.testing.expectEqual(@as(f64, 125.0), enl);
}

test "RTree init and deinit empty" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try std.testing.expectEqual(@as(?*RTreeNode, null), tree.root);
    try std.testing.expectEqual(@as(u64, 0), tree.count);
    try std.testing.expectEqual(@as(u16, 0), tree.height);
}

test "RTree insert single" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    try std.testing.expectEqual(@as(u64, 1), tree.count);
    try std.testing.expect(tree.root != null);
}

test "RTree insert and search" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try tree.insert(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, 2);
    try tree.insert(.{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 }, 3);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 7, .min_y = 7, .max_x = 12, .max_y = 12 }, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "RTree search no results" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 50, .min_y = 50, .max_x = 60, .max_y = 60 }, &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "RTree search on empty tree" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "RTree remove" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    const mbr = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try tree.insert(mbr, 1);
    try std.testing.expectEqual(@as(u64, 1), tree.count);

    const removed = tree.remove(mbr, 1);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u64, 0), tree.count);
    try std.testing.expectEqual(@as(?*RTreeNode, null), tree.root);
}

test "RTree remove nonexistent" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    const removed = tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 99);
    try std.testing.expect(!removed);
    try std.testing.expectEqual(@as(u64, 1), tree.count);
}

test "RTree remove from empty" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    const removed = tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try std.testing.expect(!removed);
}

test "RTree split on overflow" {
    var tree = RTree.init(std.testing.allocator, 2);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, 1);
    try tree.insert(.{ .min_x = 2, .min_y = 2, .max_x = 3, .max_y = 3 }, 2);
    try tree.insert(.{ .min_x = 4, .min_y = 4, .max_x = 5, .max_y = 5 }, 3);

    try std.testing.expectEqual(@as(u64, 3), tree.count);
    try std.testing.expect(tree.height >= 2);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = -1, .min_y = -1, .max_x = 6, .max_y = 6 }, &results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
}

test "RTree many inserts and searches" {
    var tree = RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const x: f64 = @floatFromInt(i % 10);
        const y: f64 = @floatFromInt(i / 10);
        try tree.insert(.{
            .min_x = x,
            .min_y = y,
            .max_x = x + 0.5,
            .max_y = y + 0.5,
        }, i);
    }

    try std.testing.expectEqual(@as(u64, 100), tree.count);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, &results);
    try std.testing.expect(results.items.len > 0);
    try std.testing.expect(results.items.len <= 100);
}

test "RTree wrapper layout matches library" {
    // Verify the comptime assertions hold at test time as well.
    try std.testing.expectEqual(@sizeOf(rtree_lib.RTree), @sizeOf(RTree));
    try std.testing.expectEqual(@alignOf(rtree_lib.RTree), @alignOf(RTree));
}
