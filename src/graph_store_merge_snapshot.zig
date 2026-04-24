// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! RCU snapshot type for the merge-prop index. See
//! docs/superpowers/plans/2026-04-24-lock-free-merge-prop-index-snapshot.md
//! for the full correctness argument. This file intentionally has NO
//! reference to `GraphStore` — the snapshot is a pure data-structure
//! primitive that the caller populates and manages.

const std = @import("std");

pub const MergePropSnapshot = struct {
    map: std.StringHashMap(u64),
    key_arena: std.heap.ArenaAllocator,
    refcount: std.atomic.Value(u32),
    parent_allocator: std.mem.Allocator,

    pub fn create(parent_allocator: std.mem.Allocator) !*MergePropSnapshot {
        const self = try parent_allocator.create(MergePropSnapshot);
        errdefer parent_allocator.destroy(self);
        self.* = .{
            .map = std.StringHashMap(u64).init(parent_allocator),
            .key_arena = std.heap.ArenaAllocator.init(parent_allocator),
            .refcount = std.atomic.Value(u32).init(1),
            .parent_allocator = parent_allocator,
        };
        return self;
    }

    /// Increment the refcount and return the same pointer. Safe to call
    /// concurrently with `release`.
    pub fn acquire(self: *MergePropSnapshot) *MergePropSnapshot {
        _ = self.refcount.fetchAdd(1, .monotonic);
        return self;
    }

    /// Decrement the refcount. On last release, frees the map, arena,
    /// and the snapshot struct itself.
    pub fn release(self: *MergePropSnapshot) void {
        const prev = self.refcount.fetchSub(1, .release);
        if (prev == 1) {
            // Last ref: fence to ensure all reads-through-snap complete
            // before we tear down.
            _ = self.refcount.load(.acquire);
            self.map.deinit();
            self.key_arena.deinit();
            const pa = self.parent_allocator;
            pa.destroy(self);
        }
    }

    /// Copy every (key, value) from `live_map` into this snapshot's
    /// private key arena. Must be called on a newly created snapshot
    /// with an empty `map`.
    pub fn populateFromLive(
        self: *MergePropSnapshot,
        live_map: *const std.StringHashMap(u64),
    ) !void {
        try self.map.ensureTotalCapacity(live_map.count());
        const arena_alloc = self.key_arena.allocator();
        var it = live_map.iterator();
        while (it.next()) |entry| {
            const key_copy = try arena_alloc.dupe(u8, entry.key_ptr.*);
            self.map.putAssumeCapacity(key_copy, entry.value_ptr.*);
        }
    }
};

test "MergePropSnapshot create/release zero-entry" {
    const snap = try MergePropSnapshot.create(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), snap.refcount.load(.monotonic));
    snap.release();
    // No assertion — std.testing.allocator will panic on leak.
}

test "MergePropSnapshot acquire/release balances" {
    const snap = try MergePropSnapshot.create(std.testing.allocator);
    const alias = snap.acquire();
    try std.testing.expectEqual(@as(u32, 2), snap.refcount.load(.monotonic));
    try std.testing.expectEqual(snap, alias);
    alias.release();
    try std.testing.expectEqual(@as(u32, 1), snap.refcount.load(.monotonic));
    snap.release();
}

test "MergePropSnapshot populateFromLive copies keys" {
    var live = std.StringHashMap(u64).init(std.testing.allocator);
    defer {
        var it = live.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        live.deinit();
    }
    try live.put(try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00alice"), 42);
    try live.put(try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00bob"), 43);

    const snap = try MergePropSnapshot.create(std.testing.allocator);
    defer snap.release();
    try snap.populateFromLive(&live);

    try std.testing.expectEqual(@as(u32, 2), snap.map.count());
    try std.testing.expectEqual(@as(?u64, 42), snap.map.get("default\x00User\x00name\x00alice"));
    try std.testing.expectEqual(@as(?u64, 43), snap.map.get("default\x00User\x00name\x00bob"));

    // Mutate `live` — snapshot must not see it (keys are arena-owned).
    std.testing.allocator.free(live.fetchRemove("default\x00User\x00name\x00alice").?.key);
    try std.testing.expectEqual(@as(?u64, 42), snap.map.get("default\x00User\x00name\x00alice"));
}
