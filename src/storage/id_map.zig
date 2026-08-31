// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2025 CodePros
//
// Legacy bidirectional mapping between UUIDv7 external IDs and dense engine
// slot IDs. Active Geode persistence now stores public IDs inside
// graph-storage properties; this codec remains for migration and tests.

const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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
const Allocator = std.mem.Allocator;

/// Magic bytes at the start of legacy id_map.dat for format identification.
const FILE_MAGIC: [8]u8 = "GEODEIDM".*;
/// Current file format version.
const FILE_VERSION: u32 = 1;

/// Header stored at the beginning of the legacy id_map.dat file.
const FileHeader = extern struct {
    magic: [8]u8,
    version: u32,
    entry_count: u32,
};

/// Bidirectional mapping between UUIDv7 external IDs (u128) and dense
/// engine slot IDs (u64).  Supports separate namespaces for nodes and edges.
pub const IdMap = struct {
    /// PHASE 4: read-serving mode. `.resident` = legacy (overlay holds all);
    /// `.mmap_backed` = immutable base snapshot + overlay + tombstones.
    pub const Mode = enum { resident, mmap_backed };

    allocator: Allocator,

    // Mutex protecting the maps below. Required because the per-graph
    // mg.rwlock does NOT cover IdMap (it sits on the GraphStore, not on
    // ManagedGraph), so concurrent bulk-ingest (e.g. test_two_phase_edge_lock
    // 16-thread case) was racing on `std.AutoHashMap.put` and producing
    // `error.EdgeSlotMappingMissing` for edges whose UUID→slot mapping was
    // lost in the race. Reads also lock so they see a consistent snapshot
    // (Zig HashMap is not safe for concurrent readers + writers).
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Node mappings
    node_uuid_to_slot: std.AutoHashMap(u128, u64),
    node_slot_to_uuid: std.AutoHashMap(u64, u128),

    // Edge mappings
    edge_uuid_to_slot: std.AutoHashMap(u128, u64),
    edge_slot_to_uuid: std.AutoHashMap(u64, u128),

    // Next slot IDs (monotonically increasing)
    next_node_slot: u64,
    next_edge_slot: u64,

    // ------------------------------------------------------------------
    // PHASE 4: mmap-in-place mode.
    //
    // `.resident` (default) is the legacy behaviour: the four hashmaps above
    // hold EVERY mapping and the `.resident` arm of every method is the
    // unchanged historical body (crash-safety fallback).
    //
    // `.mmap_backed` keeps a saved snapshot mmap'd as an IMMUTABLE BASE and
    // serves reads in place; only writes-since-open live in the four hashmaps
    // (now the OVERLAY) plus the tombstone sets below. Open becomes O(1) in
    // node count (no eager bulk-load). The merged view is base ⊕ overlay ⊖
    // tombstones; `insertNode`/`insertEdge` MUST consult overlay AND base
    // (minus tombstones) before allocating a new slot or a base-only entry is
    // duplicated (corruption). `node_live_delta`/`edge_live_delta` track the
    // running (insert − remove) so `nodeCount`/`edgeCount` stay O(1).
    mode: Mode = .resident,
    base: ?LoadedIdMapSnapshot = null,

    // Tombstones (overlay deletions of base-resident entries). A uuid present
    // here shadows the base forward lookup; a slot present here shadows the
    // base reverse lookup. Both directions are tracked because slots are never
    // recycled, so a freed slot must stay dead even after its uuid re-adds at a
    // FRESH slot.
    removed_node_uuids: std.AutoHashMap(u128, void),
    removed_node_slots: std.AutoHashMap(u64, void),
    removed_edge_uuids: std.AutoHashMap(u128, void),
    removed_edge_slots: std.AutoHashMap(u64, void),

    // Live-count deltas relative to base.{node,edge}_fwd_count. Resident mode
    // leaves these at 0 and ignores them.
    node_live_delta: i64 = 0,
    edge_live_delta: i64 = 0,

    pub fn init(allocator: Allocator) IdMap {
        return .{
            .allocator = allocator,
            .node_uuid_to_slot = std.AutoHashMap(u128, u64).init(allocator),
            .node_slot_to_uuid = std.AutoHashMap(u64, u128).init(allocator),
            .edge_uuid_to_slot = std.AutoHashMap(u128, u64).init(allocator),
            .edge_slot_to_uuid = std.AutoHashMap(u64, u128).init(allocator),
            .next_node_slot = 0,
            .next_edge_slot = 0,
            .mode = .resident,
            .base = null,
            .removed_node_uuids = std.AutoHashMap(u128, void).init(allocator),
            .removed_node_slots = std.AutoHashMap(u64, void).init(allocator),
            .removed_edge_uuids = std.AutoHashMap(u128, void).init(allocator),
            .removed_edge_slots = std.AutoHashMap(u64, void).init(allocator),
            .node_live_delta = 0,
            .edge_live_delta = 0,
        };
    }

    pub fn deinit(self: *IdMap) void {
        self.node_uuid_to_slot.deinit();
        self.node_slot_to_uuid.deinit();
        self.edge_uuid_to_slot.deinit();
        self.edge_slot_to_uuid.deinit();
        self.removed_node_uuids.deinit();
        self.removed_node_slots.deinit();
        self.removed_edge_uuids.deinit();
        self.removed_edge_slots.deinit();
        if (self.base) |*b| b.deinit();
    }

    /// PHASE 4: adopt a loaded snapshot as the immutable BASE and switch to
    /// `.mmap_backed` mode. Takes ownership of `snap` (deinit unmaps it). The
    /// overlay (the four hashmaps) MUST be empty when this is called — this is
    /// the open path's O(1) replacement for `bulkLoadFromSnapshot`. The
    /// next-slot counters are seeded from the snapshot header so freshly
    /// allocated slots never collide with base slots.
    pub fn adoptSnapshotAsBase(self: *IdMap, snap: LoadedIdMapSnapshot) void {
        self.lockMu();
        defer self.unlockMu();
        self.mode = .mmap_backed;
        self.base = snap;
        self.next_node_slot = snap.next_node_slot;
        self.next_edge_slot = snap.next_edge_slot;
        self.node_live_delta = 0;
        self.edge_live_delta = 0;
    }

    // ------------------------------------------------------------------
    // PHASE 4: merged-view helpers (caller holds the mutex; no locking here).
    // For `.resident` these collapse to the plain overlay lookup (no base, no
    // tombstones). For `.mmap_backed` they implement overlay ⊕ base ⊖
    // tombstone. The MERGE-MISS authority (`mergedNodeSlot`/`mergedEdgeSlot`)
    // is the dedup crux used by the insert paths.
    // ------------------------------------------------------------------

    fn mergedNodeSlot(self: *const IdMap, uuid: u128) ?u64 {
        if (self.node_uuid_to_slot.get(uuid)) |s| return s;
        if (self.removed_node_uuids.contains(uuid)) return null;
        if (self.base) |*b| return b.nodeSlotOf(uuid);
        return null;
    }

    fn mergedNodeUuid(self: *const IdMap, slot: u64) ?u128 {
        if (self.node_slot_to_uuid.get(slot)) |u| return u;
        if (self.removed_node_slots.contains(slot)) return null;
        if (self.base) |*b| return b.nodeUuidAt(slot);
        return null;
    }

    fn mergedEdgeSlot(self: *const IdMap, uuid: u128) ?u64 {
        if (self.edge_uuid_to_slot.get(uuid)) |s| return s;
        if (self.removed_edge_uuids.contains(uuid)) return null;
        if (self.base) |*b| return b.edgeSlotOf(uuid);
        return null;
    }

    fn mergedEdgeUuid(self: *const IdMap, slot: u64) ?u128 {
        if (self.edge_slot_to_uuid.get(slot)) |u| return u;
        if (self.removed_edge_slots.contains(slot)) return null;
        if (self.base) |*b| return b.edgeUuidAt(slot);
        return null;
    }

    // Acquire/release the IdMap mutex using the global single-threaded IO,
    // matching the pattern used by `LabelPosting` (graph_store.zig) and other
    // leaf mutexes in this codebase.
    inline fn lockMu(self: *IdMap) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    inline fn unlockMu(self: *IdMap) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    // ------------------------------------------------------------------
    // Node operations
    // ------------------------------------------------------------------

    /// Insert a new node mapping. Returns the allocated slot ID.
    /// If the UUID already exists, returns the existing slot.
    pub fn insertNode(self: *IdMap, uuid: u128) !u64 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                if (self.node_uuid_to_slot.get(uuid)) |existing| {
                    return existing;
                }
                const slot = self.next_node_slot;
                self.next_node_slot += 1;
                try self.node_uuid_to_slot.put(uuid, slot);
                try self.node_slot_to_uuid.put(slot, uuid);
                return slot;
            },
            .mmap_backed => {
                // MERGE-MISS dedup crux: a base-only entry missed here = a
                // duplicate node = corruption. Consult overlay ⊕ base ⊖
                // tombstone before allocating.
                if (self.mergedNodeSlot(uuid)) |existing| return existing;
                const slot = self.next_node_slot;
                self.next_node_slot += 1;
                try self.node_uuid_to_slot.put(uuid, slot);
                try self.node_slot_to_uuid.put(slot, uuid);
                // Re-add after tombstone: clear the uuid tombstone (its OLD
                // base slot stays tombstoned — slots are never recycled).
                _ = self.removed_node_uuids.remove(uuid);
                self.node_live_delta += 1;
                return slot;
            },
        }
    }

    /// T2b (hydration merge): pre-size the RESIDENT node maps for a bulk load
    /// of `count` mappings so the per-insert path never pays rehash-growth
    /// churn (the dominant single-threaded merge cost at 14.27M rows).
    /// No-op in mmap_backed mode — loop1 inserts are skipped there (the base
    /// serves the mappings in place) and pre-sizing the overlay would defeat
    /// its bounded-RSS purpose.
    pub fn reserveNodes(self: *IdMap, count: u32) !void {
        self.lockMu();
        defer self.unlockMu();
        if (self.mode != .resident) return;
        try self.node_uuid_to_slot.ensureTotalCapacity(count);
        try self.node_slot_to_uuid.ensureTotalCapacity(count);
    }

    /// T2b: edge-side companion of `reserveNodes` (same resident-only rule —
    /// the hydration merge inserts edge mappings only in resident mode).
    pub fn reserveEdges(self: *IdMap, count: u32) !void {
        self.lockMu();
        defer self.unlockMu();
        if (self.mode != .resident) return;
        try self.edge_uuid_to_slot.ensureTotalCapacity(count);
        try self.edge_slot_to_uuid.ensureTotalCapacity(count);
    }

    /// Insert a node mapping with a specific slot ID (used during load).
    pub fn insertNodeWithSlot(self: *IdMap, uuid: u128, slot: u64) !void {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                try self.node_uuid_to_slot.put(uuid, slot);
                try self.node_slot_to_uuid.put(slot, uuid);
                if (slot >= self.next_node_slot) {
                    self.next_node_slot = slot + 1;
                }
            },
            .mmap_backed => {
                const was_live = self.mergedNodeSlot(uuid) != null;
                try self.node_uuid_to_slot.put(uuid, slot);
                try self.node_slot_to_uuid.put(slot, uuid);
                _ = self.removed_node_uuids.remove(uuid);
                _ = self.removed_node_slots.remove(slot);
                if (!was_live) self.node_live_delta += 1;
                if (slot >= self.next_node_slot) {
                    self.next_node_slot = slot + 1;
                }
            },
        }
    }

    /// Look up the slot ID for a node UUID.
    pub fn nodeSlot(self: *IdMap, uuid: u128) ?u64 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => return self.node_uuid_to_slot.get(uuid),
            .mmap_backed => return self.mergedNodeSlot(uuid),
        }
    }

    /// Look up the UUID for a node slot ID.
    pub fn nodeUuid(self: *IdMap, slot: u64) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => return self.node_slot_to_uuid.get(slot),
            .mmap_backed => return self.mergedNodeUuid(slot),
        }
    }

    /// Remove a node mapping by UUID.
    pub fn removeNode(self: *IdMap, uuid: u128) bool {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                const slot = self.node_uuid_to_slot.get(uuid) orelse return false;
                _ = self.node_uuid_to_slot.remove(uuid);
                _ = self.node_slot_to_uuid.remove(slot);
                return true;
            },
            .mmap_backed => {
                const slot = self.mergedNodeSlot(uuid) orelse return false;
                const in_base = if (self.base) |*b| (b.nodeSlotOf(uuid) != null) else false;
                // Tombstone only when the base shadows this uuid/slot. Order so
                // an OOM rolls back cleanly and reports not-removed (bool path
                // cannot propagate error.OutOfMemory).
                if (in_base) {
                    self.removed_node_uuids.put(uuid, {}) catch return false;
                    self.removed_node_slots.put(slot, {}) catch {
                        _ = self.removed_node_uuids.remove(uuid);
                        return false;
                    };
                }
                if (self.node_uuid_to_slot.fetchRemove(uuid)) |kv| {
                    _ = self.node_slot_to_uuid.remove(kv.value);
                }
                self.node_live_delta -= 1;
                return true;
            },
        }
    }

    // ------------------------------------------------------------------
    // Edge operations
    // ------------------------------------------------------------------

    /// Insert a new edge mapping. Returns the allocated slot ID.
    /// If the UUID already exists, returns the existing slot.
    pub fn insertEdge(self: *IdMap, uuid: u128) !u64 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                if (self.edge_uuid_to_slot.get(uuid)) |existing| {
                    return existing;
                }
                const slot = self.next_edge_slot;
                self.next_edge_slot += 1;
                try self.edge_uuid_to_slot.put(uuid, slot);
                try self.edge_slot_to_uuid.put(slot, uuid);
                return slot;
            },
            .mmap_backed => {
                if (self.mergedEdgeSlot(uuid)) |existing| return existing;
                const slot = self.next_edge_slot;
                self.next_edge_slot += 1;
                try self.edge_uuid_to_slot.put(uuid, slot);
                try self.edge_slot_to_uuid.put(slot, uuid);
                _ = self.removed_edge_uuids.remove(uuid);
                self.edge_live_delta += 1;
                return slot;
            },
        }
    }

    /// Insert an edge mapping with a specific slot ID (used during load).
    pub fn insertEdgeWithSlot(self: *IdMap, uuid: u128, slot: u64) !void {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                try self.edge_uuid_to_slot.put(uuid, slot);
                try self.edge_slot_to_uuid.put(slot, uuid);
                if (slot >= self.next_edge_slot) {
                    self.next_edge_slot = slot + 1;
                }
            },
            .mmap_backed => {
                const was_live = self.mergedEdgeSlot(uuid) != null;
                try self.edge_uuid_to_slot.put(uuid, slot);
                try self.edge_slot_to_uuid.put(slot, uuid);
                _ = self.removed_edge_uuids.remove(uuid);
                _ = self.removed_edge_slots.remove(slot);
                if (!was_live) self.edge_live_delta += 1;
                if (slot >= self.next_edge_slot) {
                    self.next_edge_slot = slot + 1;
                }
            },
        }
    }

    /// Look up the slot ID for an edge UUID.
    pub fn edgeSlot(self: *IdMap, uuid: u128) ?u64 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => return self.edge_uuid_to_slot.get(uuid),
            .mmap_backed => return self.mergedEdgeSlot(uuid),
        }
    }

    /// Look up the UUID for an edge slot ID.
    pub fn edgeUuid(self: *IdMap, slot: u64) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => return self.edge_slot_to_uuid.get(slot),
            .mmap_backed => return self.mergedEdgeUuid(slot),
        }
    }

    /// Remove an edge mapping by UUID.
    pub fn removeEdge(self: *IdMap, uuid: u128) bool {
        self.lockMu();
        defer self.unlockMu();
        switch (self.mode) {
            .resident => {
                const slot = self.edge_uuid_to_slot.get(uuid) orelse return false;
                _ = self.edge_uuid_to_slot.remove(uuid);
                _ = self.edge_slot_to_uuid.remove(slot);
                return true;
            },
            .mmap_backed => {
                const slot = self.mergedEdgeSlot(uuid) orelse return false;
                const in_base = if (self.base) |*b| (b.edgeSlotOf(uuid) != null) else false;
                if (in_base) {
                    self.removed_edge_uuids.put(uuid, {}) catch return false;
                    self.removed_edge_slots.put(slot, {}) catch {
                        _ = self.removed_edge_uuids.remove(uuid);
                        return false;
                    };
                }
                if (self.edge_uuid_to_slot.fetchRemove(uuid)) |kv| {
                    _ = self.edge_slot_to_uuid.remove(kv.value);
                }
                self.edge_live_delta -= 1;
                return true;
            },
        }
    }

    // ------------------------------------------------------------------
    // Counts
    // ------------------------------------------------------------------

    pub fn nodeCount(self: *const IdMap) u32 {
        switch (self.mode) {
            .resident => return self.node_uuid_to_slot.count(),
            .mmap_backed => {
                const base_n: i64 = @intCast(self.base.?.node_fwd_count);
                return @intCast(base_n + self.node_live_delta);
            },
        }
    }

    /// Iterator over every public node uuid in this graph's mapping.
    ///
    /// `.resident`: walks the overlay hashmap keys (legacy behaviour).
    /// `.mmap_backed`: streams the merged live set IN PLACE — the base forward
    /// region (skipping tombstoned uuids) followed by overlay-only uuids (those
    /// not present in base, so re-added base uuids are emitted exactly once).
    /// No materialization; safe for the 14.27M-node case.
    pub const NodeUuidIterator = struct {
        map: *const IdMap,
        inner: @TypeOf(@as(IdMap, undefined).node_uuid_to_slot).KeyIterator,
        base_idx: u64 = 0,
        in_base_phase: bool = false,
        pub fn next(it: *NodeUuidIterator) ?u128 {
            if (it.in_base_phase) {
                if (it.map.base) |*b| {
                    while (it.base_idx < b.node_fwd_count) {
                        const idx = it.base_idx;
                        it.base_idx += 1;
                        const uuid = b.nodeFwdUuidAt(idx);
                        if (it.map.removed_node_uuids.contains(uuid)) continue;
                        return uuid;
                    }
                }
                it.in_base_phase = false;
            }
            while (it.inner.next()) |k| {
                const uuid = k.*;
                if (it.map.base) |*b| {
                    if (b.nodeSlotOf(uuid) != null) continue; // emitted in base phase
                }
                return uuid;
            }
            return null;
        }
    };
    pub fn nodeUuidIterator(self: *const IdMap) NodeUuidIterator {
        return .{
            .map = self,
            .inner = self.node_uuid_to_slot.keyIterator(),
            .base_idx = 0,
            .in_base_phase = (self.mode == .mmap_backed and self.base != null),
        };
    }

    /// geode#875 RC-3: race-safe snapshot of every live node uuid in this graph.
    /// Holds the leaf mutex for the whole walk, so it is safe against a concurrent
    /// `insertNode` growing/rehashing `node_uuid_to_slot` (an unlocked
    /// `nodeUuidIterator` walk faults when a writer resizes the map underneath).
    /// Caller owns the returned slice.
    pub fn snapshotNodeUuids(self: *IdMap, allocator: std.mem.Allocator) ![]u128 {
        self.lockMu();
        defer self.unlockMu();
        var list: std.ArrayList(u128) = .empty;
        errdefer list.deinit(allocator);
        var it = self.nodeUuidIterator();
        while (it.next()) |uuid| try list.append(allocator, uuid);
        return list.toOwnedSlice(allocator);
    }

    pub fn edgeCount(self: *const IdMap) u32 {
        switch (self.mode) {
            .resident => return self.edge_uuid_to_slot.count(),
            .mmap_backed => {
                const base_e: i64 = @intCast(self.base.?.edge_fwd_count);
                return @intCast(base_e + self.edge_live_delta);
            },
        }
    }

    /// Iterator over every public edge uuid in this graph's mapping. Mirrors
    /// `NodeUuidIterator` (base forward ⊖ tombstone, then overlay-only).
    pub const EdgeUuidIterator = struct {
        map: *const IdMap,
        inner: @TypeOf(@as(IdMap, undefined).edge_uuid_to_slot).KeyIterator,
        base_idx: u64 = 0,
        in_base_phase: bool = false,
        pub fn next(it: *EdgeUuidIterator) ?u128 {
            if (it.in_base_phase) {
                if (it.map.base) |*b| {
                    while (it.base_idx < b.edge_fwd_count) {
                        const idx = it.base_idx;
                        it.base_idx += 1;
                        const uuid = b.edgeFwdUuidAt(idx);
                        if (it.map.removed_edge_uuids.contains(uuid)) continue;
                        return uuid;
                    }
                }
                it.in_base_phase = false;
            }
            while (it.inner.next()) |k| {
                const uuid = k.*;
                if (it.map.base) |*b| {
                    if (b.edgeSlotOf(uuid) != null) continue;
                }
                return uuid;
            }
            return null;
        }
    };
    pub fn edgeUuidIterator(self: *const IdMap) EdgeUuidIterator {
        return .{
            .map = self,
            .inner = self.edge_uuid_to_slot.keyIterator(),
            .base_idx = 0,
            .in_base_phase = (self.mode == .mmap_backed and self.base != null),
        };
    }

    /// Deep-copy the mapping tables into a new (`.resident`) IdMap owned by
    /// `allocator`. For `.mmap_backed` this MATERIALIZES the merged live view
    /// (base ⊕ overlay ⊖ tombstone) into a plain resident map — clone is an
    /// inherently O(n) snapshot, so an in-place clone would be meaningless.
    pub fn clone(self: *const IdMap, allocator: Allocator) !IdMap {
        var copy = IdMap.init(allocator);
        errdefer copy.deinit();

        copy.next_node_slot = self.next_node_slot;
        copy.next_edge_slot = self.next_edge_slot;

        switch (self.mode) {
            .resident => {
                try copy.node_uuid_to_slot.ensureTotalCapacity(self.node_uuid_to_slot.count());
                try copy.node_slot_to_uuid.ensureTotalCapacity(self.node_slot_to_uuid.count());
                try copy.edge_uuid_to_slot.ensureTotalCapacity(self.edge_uuid_to_slot.count());
                try copy.edge_slot_to_uuid.ensureTotalCapacity(self.edge_slot_to_uuid.count());

                var node_iter = self.node_uuid_to_slot.iterator();
                while (node_iter.next()) |entry| {
                    try copy.node_uuid_to_slot.put(entry.key_ptr.*, entry.value_ptr.*);
                    try copy.node_slot_to_uuid.put(entry.value_ptr.*, entry.key_ptr.*);
                }

                var edge_iter = self.edge_uuid_to_slot.iterator();
                while (edge_iter.next()) |entry| {
                    try copy.edge_uuid_to_slot.put(entry.key_ptr.*, entry.value_ptr.*);
                    try copy.edge_slot_to_uuid.put(entry.value_ptr.*, entry.key_ptr.*);
                }
            },
            .mmap_backed => {
                try copy.node_uuid_to_slot.ensureTotalCapacity(self.nodeCount());
                try copy.node_slot_to_uuid.ensureTotalCapacity(self.nodeCount());
                try copy.edge_uuid_to_slot.ensureTotalCapacity(self.edgeCount());
                try copy.edge_slot_to_uuid.ensureTotalCapacity(self.edgeCount());

                // Nodes: base live forward, then overlay-only (matches the
                // forward-iteration normalization the resident arm performs).
                if (self.base) |*b| {
                    var i: u64 = 0;
                    while (i < b.node_fwd_count) : (i += 1) {
                        const uuid = b.nodeFwdUuidAt(i);
                        if (self.removed_node_uuids.contains(uuid)) continue;
                        const slot = self.mergedNodeSlot(uuid).?;
                        try copy.node_uuid_to_slot.put(uuid, slot);
                        try copy.node_slot_to_uuid.put(slot, uuid);
                    }
                }
                var nit = self.node_uuid_to_slot.iterator();
                while (nit.next()) |e| {
                    const uuid = e.key_ptr.*;
                    if (self.base) |*b| {
                        if (b.nodeSlotOf(uuid) != null) continue;
                    }
                    try copy.node_uuid_to_slot.put(uuid, e.value_ptr.*);
                    try copy.node_slot_to_uuid.put(e.value_ptr.*, uuid);
                }

                if (self.base) |*b| {
                    var i: u64 = 0;
                    while (i < b.edge_fwd_count) : (i += 1) {
                        const uuid = b.edgeFwdUuidAt(i);
                        if (self.removed_edge_uuids.contains(uuid)) continue;
                        const slot = self.mergedEdgeSlot(uuid).?;
                        try copy.edge_uuid_to_slot.put(uuid, slot);
                        try copy.edge_slot_to_uuid.put(slot, uuid);
                    }
                }
                var eit = self.edge_uuid_to_slot.iterator();
                while (eit.next()) |e| {
                    const uuid = e.key_ptr.*;
                    if (self.base) |*b| {
                        if (b.edgeSlotOf(uuid) != null) continue;
                    }
                    try copy.edge_uuid_to_slot.put(uuid, e.value_ptr.*);
                    try copy.edge_slot_to_uuid.put(e.value_ptr.*, uuid);
                }
            },
        }

        return copy;
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    /// Save the id map to a file atomically (write to temp then rename).
    /// `dir` is the directory containing the graph data.
    pub fn save(self: *const IdMap, dir: std.Io.Dir) !void {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const tmp_name = "id_map.dat.tmp";
        const final_name = "id_map.dat";

        // Create temp file
        const file = try dir.createFile(io_fs, tmp_name, .{});
        defer file.close(io_fs);

        const total_entries: u32 = self.node_uuid_to_slot.count() + self.edge_uuid_to_slot.count();

        // Write header
        const header = FileHeader{
            .magic = FILE_MAGIC,
            .version = FILE_VERSION,
            .entry_count = total_entries,
        };
        var offset: u64 = 0;
        try file.writePositionalAll(io_fs, std.mem.asBytes(&header), offset);
        offset += @sizeOf(FileHeader);

        // Write node entries: type_tag(u8=0) | uuid(u128) | slot(u64)
        var node_iter = self.node_uuid_to_slot.iterator();
        while (node_iter.next()) |entry| {
            try file.writePositionalAll(io_fs, &[_]u8{0}, offset);
            offset += 1;
            try file.writePositionalAll(io_fs, std.mem.asBytes(&entry.key_ptr.*), offset);
            offset += @sizeOf(u128);
            try file.writePositionalAll(io_fs, std.mem.asBytes(&entry.value_ptr.*), offset);
            offset += @sizeOf(u64);
        }

        // Write edge entries: type_tag(u8=1) | uuid(u128) | slot(u64)
        var edge_iter = self.edge_uuid_to_slot.iterator();
        while (edge_iter.next()) |entry| {
            try file.writePositionalAll(io_fs, &[_]u8{1}, offset);
            offset += 1;
            try file.writePositionalAll(io_fs, std.mem.asBytes(&entry.key_ptr.*), offset);
            offset += @sizeOf(u128);
            try file.writePositionalAll(io_fs, std.mem.asBytes(&entry.value_ptr.*), offset);
            offset += @sizeOf(u64);
        }

        // Atomic rename
        try dir.rename(tmp_name, dir, final_name, io_fs);
    }

    /// Load an id map from id_map.dat in the given directory.
    pub fn load(allocator: Allocator, dir: std.Io.Dir) !IdMap {
        var self = IdMap.init(allocator);
        errdefer self.deinit();

        const idm_io = std.Io.Threaded.global_single_threaded.io();
        const file = dir.openFile(idm_io, "id_map.dat", .{}) catch |err| {
            if (err == error.FileNotFound) return self;
            return err;
        };
        defer file.close(idm_io);

        // Use positional reads with tracked offset
        var file_offset: u64 = 0;

        // Read and validate header
        var header: FileHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const n = try file.readPositionalAll(idm_io, header_bytes, file_offset);
        file_offset += n;
        if (n < header_bytes.len) return error.UnexpectedEndOfFile;

        if (!std.mem.eql(u8, &header.magic, &FILE_MAGIC)) return error.InvalidFormat;
        if (header.version != FILE_VERSION) return error.UnsupportedVersion;

        // Read entries
        for (0..header.entry_count) |_| {
            var tag_buf: [1]u8 = undefined;
            const tag_n = try file.readPositionalAll(idm_io, &tag_buf, file_offset);
            file_offset += tag_n;
            if (tag_n < 1) return error.UnexpectedEndOfFile;
            const type_tag = tag_buf[0];

            var uuid_bytes: [@sizeOf(u128)]u8 = undefined;
            const uuid_n = try file.readPositionalAll(idm_io, &uuid_bytes, file_offset);
            file_offset += uuid_n;
            if (uuid_n < uuid_bytes.len) return error.UnexpectedEndOfFile;
            const uuid: u128 = @bitCast(uuid_bytes);

            var slot_bytes: [@sizeOf(u64)]u8 = undefined;
            const slot_n = try file.readPositionalAll(idm_io, &slot_bytes, file_offset);
            file_offset += slot_n;
            if (slot_n < slot_bytes.len) return error.UnexpectedEndOfFile;
            const slot: u64 = @bitCast(slot_bytes);

            switch (type_tag) {
                0 => try self.insertNodeWithSlot(uuid, slot),
                1 => try self.insertEdgeWithSlot(uuid, slot),
                else => return error.InvalidFormat,
            }
        }

        return self;
    }

    // ------------------------------------------------------------------
    // mmap-able snapshot (Phase 1a of sub-second startup)
    //
    // A NEW on-disk format, separate from the legacy id_map.dat above. One
    // file holds BOTH namespaces (node + edge). The format is designed so an
    // open path can `mmap` it and answer lookups directly off the bytes with
    // NO O(graph) scan-rebuild:
    //   * reverse (slot -> uuid) = flat u128[next_slot], direct-indexed O(1);
    //     a deleted/absent slot is the sentinel 0 (a real UUIDv7 is never 0).
    //   * forward (uuid -> slot) = sorted (u128 uuid, u64 slot)[count] by uuid,
    //     answered with binary search + FULL-KEY (u128) verify.
    //
    // Layout (all integers little-endian, no native alignment assumed — every
    // field is read/written with std.mem.readInt/writeInt so the mmap'd bytes
    // need no special alignment):
    //   magic "GEOIDMAP" (8)
    //   format_ver        u32   (bumped to 2 for the GAP-0064 FIX B epoch stamp)
    //   checkpoint_epoch  u64   (GAP-0064 FIX B reload gate part 1 — see below)
    //   next_node_slot    u64
    //   next_edge_slot    u64
    //   node_fwd_count    u64
    //   edge_fwd_count    u64
    //   covered_lsn       u64   (GAP-0064 FIX B reload gate part 2)
    //   NODE reverse  u128[next_node_slot]
    //   NODE forward  (u128 uuid, u64 slot)[node_fwd_count]   (sorted by uuid)
    //   EDGE reverse  u128[next_edge_slot]
    //   EDGE forward  (u128 uuid, u64 slot)[edge_fwd_count]   (sorted by uuid)
    //   CRC32 u32  (over EVERYTHING before this trailer)
    //
    // GAP-0064 FIX B: the crash-safety stamp migrated from `manifest.counter` (v1)
    // to the Path-B (checkpoint_epoch, covered_lsn) contract (fa6495bb), because
    // recovery.zig bumps `counter` on ANY committed WAL-tail replay — so a
    // deferred-WAL reopen invalidated a still-valid snapshot and re-scanned the
    // whole graph (loop1/loop2). The epoch is bumped ONLY at checkpoint (never by
    // recovery); covered_lsn is the durable committed frontier. Reload iff
    // `stamped_epoch == current epoch AND stamped_covered == current frontier`
    // ("no checkpoint AND no tail since the snapshot"). VERSION bump 1->2 is the
    // downgrade/upgrade gate: an old v1 (counter-stamped) file loads as null on a
    // new binary -> rebuild (safe); a new v2 file loads as null on an old binary
    // -> rebuild (safe). Never a mis-parse across versions.
    // ------------------------------------------------------------------

    /// Magic for the mmap-able snapshot (distinct from the legacy FILE_MAGIC).
    const SNAP_MAGIC: [8]u8 = "GEOIDMAP".*;
    /// Snapshot format version. v2 = GAP-0064 FIX B (epoch,covered_lsn) stamp.
    const SNAP_VERSION: u32 = 2;
    const SNAP_FILE = "idmap.snapshot";
    const SNAP_TMP = "idmap.snapshot.tmp";

    // Fixed header field offsets.
    const HDR_VER_OFF = 8;
    const HDR_EPOCH_OFF = 12; // checkpoint_epoch (was manifest_counter in v1)
    const HDR_NEXT_NODE_OFF = 20;
    const HDR_NEXT_EDGE_OFF = 28;
    const HDR_NODE_FWD_OFF = 36;
    const HDR_EDGE_FWD_OFF = 44;
    const HDR_COVERED_OFF = 52; // covered_lsn (GAP-0064 FIX B; appended in v2)
    const SNAP_HEADER_SIZE = 60;
    const REV_ENTRY = 16; // u128
    const FWD_ENTRY = 24; // u128 uuid + u64 slot
    const CRC_SIZE = 4;

    const FwdPair = struct { uuid: u128, slot: u64 };
    fn fwdLess(_: void, a: FwdPair, b: FwdPair) bool {
        return a.uuid < b.uuid;
    }

    /// Build the serialized snapshot payload (header + regions + CRC trailer)
    /// into a freshly-allocated buffer owned by the caller. Locks the IdMap so
    /// the captured state is internally consistent.
    fn serializeSnapshot(self: *IdMap, checkpoint_epoch: u64, covered_lsn: u64) ![]u8 {
        const a = self.allocator;
        self.lockMu();
        defer self.unlockMu();

        const nn = self.next_node_slot;
        const ne = self.next_edge_slot;

        // Collect the MERGED live forward pairs (base ⊕ overlay ⊖ tombstone).
        // For `.resident` this collapses to the overlay hashmaps; for
        // `.mmap_backed` it folds base + overlay − tombstones into one set so a
        // later open re-reads exactly the live mapping. O(live) either way.
        const node_pairs = try self.collectMergedForward(a, .node);
        defer a.free(node_pairs);
        const edge_pairs = try self.collectMergedForward(a, .edge);
        defer a.free(edge_pairs);

        const node_fwd_count: u64 = node_pairs.len;
        const edge_fwd_count: u64 = edge_pairs.len;

        const node_rev_off: usize = SNAP_HEADER_SIZE;
        const node_fwd_off: usize = node_rev_off + @as(usize, @intCast(nn)) * REV_ENTRY;
        const edge_rev_off: usize = node_fwd_off + @as(usize, @intCast(node_fwd_count)) * FWD_ENTRY;
        const edge_fwd_off: usize = edge_rev_off + @as(usize, @intCast(ne)) * REV_ENTRY;
        const crc_off: usize = edge_fwd_off + @as(usize, @intCast(edge_fwd_count)) * FWD_ENTRY;
        const total: usize = crc_off + CRC_SIZE;

        const buf = try a.alloc(u8, total);
        errdefer a.free(buf);
        // Zero the whole buffer first: this leaves every reverse-region slot at
        // the sentinel 0 (= hole) unless explicitly filled below.
        @memset(buf, 0);

        // Header.
        @memcpy(buf[0..8], &SNAP_MAGIC);
        std.mem.writeInt(u32, buf[HDR_VER_OFF..][0..4], SNAP_VERSION, .little);
        std.mem.writeInt(u64, buf[HDR_EPOCH_OFF..][0..8], checkpoint_epoch, .little);
        std.mem.writeInt(u64, buf[HDR_NEXT_NODE_OFF..][0..8], nn, .little);
        std.mem.writeInt(u64, buf[HDR_NEXT_EDGE_OFF..][0..8], ne, .little);
        std.mem.writeInt(u64, buf[HDR_NODE_FWD_OFF..][0..8], node_fwd_count, .little);
        std.mem.writeInt(u64, buf[HDR_EDGE_FWD_OFF..][0..8], edge_fwd_count, .little);
        std.mem.writeInt(u64, buf[HDR_COVERED_OFF..][0..8], covered_lsn, .little);

        // NODE reverse (direct-indexed by slot) via the merged view.
        {
            var slot: u64 = 0;
            while (slot < nn) : (slot += 1) {
                if (self.mergedNodeUuid(slot)) |uuid| {
                    const off = node_rev_off + @as(usize, @intCast(slot)) * REV_ENTRY;
                    std.mem.writeInt(u128, buf[off..][0..16], uuid, .little);
                }
            }
        }
        // NODE forward (sorted by uuid).
        writeForwardPairs(buf, node_fwd_off, node_pairs);

        // EDGE reverse.
        {
            var slot: u64 = 0;
            while (slot < ne) : (slot += 1) {
                if (self.mergedEdgeUuid(slot)) |uuid| {
                    const off = edge_rev_off + @as(usize, @intCast(slot)) * REV_ENTRY;
                    std.mem.writeInt(u128, buf[off..][0..16], uuid, .little);
                }
            }
        }
        // EDGE forward.
        writeForwardPairs(buf, edge_fwd_off, edge_pairs);

        // CRC32 over the entire payload preceding the trailer.
        const crc = std.hash.crc.Crc32.hash(buf[0..crc_off]);
        std.mem.writeInt(u32, buf[crc_off..][0..4], crc, .little);

        return buf;
    }

    const Namespace = enum { node, edge };

    /// Collect the merged-live forward (uuid, slot) pairs for one namespace.
    /// Caller owns the returned slice. Caller MUST hold the mutex.
    fn collectMergedForward(self: *const IdMap, a: Allocator, ns: Namespace) ![]FwdPair {
        var list: std.ArrayList(FwdPair) = .empty;
        errdefer list.deinit(a);
        switch (ns) {
            .node => {
                var it = self.nodeUuidIterator();
                while (it.next()) |uuid| {
                    try list.append(a, .{ .uuid = uuid, .slot = self.mergedNodeSlot(uuid).? });
                }
            },
            .edge => {
                var it = self.edgeUuidIterator();
                while (it.next()) |uuid| {
                    try list.append(a, .{ .uuid = uuid, .slot = self.mergedEdgeSlot(uuid).? });
                }
            },
        }
        return list.toOwnedSlice(a);
    }

    fn writeForwardPairs(buf: []u8, base_off: usize, pairs: []FwdPair) void {
        if (pairs.len == 0) return;
        std.mem.sort(FwdPair, pairs, {}, fwdLess);
        for (pairs, 0..) |p, idx| {
            const off = base_off + idx * FWD_ENTRY;
            std.mem.writeInt(u128, buf[off..][0..16], p.uuid, .little);
            std.mem.writeInt(u64, buf[off + 16 ..][0..8], p.slot, .little);
        }
    }

    /// Serialize this IdMap to an mmap-able snapshot in `dir`, stamped with the
    /// GAP-0064 FIX B Path-B contract `(checkpoint_epoch, covered_lsn)` — the
    /// caller's crash-safety reload gate (replaces the recovery-bumped
    /// manifest.counter). Atomic: writes a temp file, fsyncs it, then renames over
    /// the final name (mirrors the legacy `save` atomic discipline).
    pub fn saveSnapshot(self: *IdMap, dir: std.Io.Dir, checkpoint_epoch: u64, covered_lsn: u64) !void {
        const buf = try self.serializeSnapshot(checkpoint_epoch, covered_lsn);
        defer self.allocator.free(buf);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try dir.createFile(io, SNAP_TMP, .{});
        {
            errdefer file.close(io);
            try file.writePositionalAll(io, buf, 0);
            try file.sync(io); // fsync the temp file before publishing it
        }
        file.close(io);
        try dir.rename(SNAP_TMP, dir, SNAP_FILE, io);
    }

    /// PHASE 1b: remove any on-disk IdMap snapshot (and a leftover temp) in
    /// `dir`. Best-effort: a missing file is success. Used by the checkpoint
    /// path to INVALIDATE a stale snapshot for a graph whose resident IdMap is
    /// deferred/empty, so persisting it would stamp an empty snapshot the next
    /// open would adopt as base (silent data loss). After invalidation the next
    /// open re-defers + rebuilds from the durable engine pages. Mirrors
    /// graph_storage_adapter.invalidateExactPropertyIndexFile for the H4 index.
    pub fn deleteSnapshot(dir: std.Io.Dir) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        dir.deleteFile(io, SNAP_FILE) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
        dir.deleteFile(io, SNAP_TMP) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
    }

    /// Load the mmap-able snapshot from `dir`. Returns `null` (caller falls
    /// back to scan-rebuild) when the file is absent, has a bad magic/version,
    /// is the wrong size (torn/truncated), or fails the CRC32 check. On success
    /// the returned handle owns an mmap'd, read-only view of the file; call
    /// `deinit` to unmap.
    pub fn loadSnapshot(dir: std.Io.Dir) !?LoadedIdMapSnapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = dir.openFile(io, SNAP_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };

        const len_u64 = file.length(io) catch {
            file.close(io);
            return null;
        };
        if (len_u64 < SNAP_HEADER_SIZE + CRC_SIZE) {
            file.close(io);
            return null;
        }
        const len: usize = @intCast(len_u64);

        const mapping = std.posix.mmap(
            null,
            len,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        ) catch {
            file.close(io);
            return null;
        };
        // The mapping survives closing the fd.
        file.close(io);
        errdefer std.posix.munmap(mapping);

        // Random-access hint for the binary-search / direct-index regions.
        std.posix.madvise(mapping.ptr, mapping.len, std.posix.MADV.RANDOM) catch {};

        if (!std.mem.eql(u8, mapping[0..8], &SNAP_MAGIC)) {
            std.posix.munmap(mapping);
            return null;
        }
        const ver = std.mem.readInt(u32, mapping[HDR_VER_OFF..][0..4], .little);
        if (ver != SNAP_VERSION) {
            std.posix.munmap(mapping);
            return null;
        }

        const epoch = std.mem.readInt(u64, mapping[HDR_EPOCH_OFF..][0..8], .little);
        const nn = std.mem.readInt(u64, mapping[HDR_NEXT_NODE_OFF..][0..8], .little);
        const ne = std.mem.readInt(u64, mapping[HDR_NEXT_EDGE_OFF..][0..8], .little);
        const node_fwd_count = std.mem.readInt(u64, mapping[HDR_NODE_FWD_OFF..][0..8], .little);
        const edge_fwd_count = std.mem.readInt(u64, mapping[HDR_EDGE_FWD_OFF..][0..8], .little);
        const covered = std.mem.readInt(u64, mapping[HDR_COVERED_OFF..][0..8], .little);

        // Recompute the expected layout with overflow-checked math; any overflow
        // (corrupt counts) or size mismatch (truncation) => treat as invalid.
        const regions = computeRegions(nn, ne, node_fwd_count, edge_fwd_count) orelse {
            std.posix.munmap(mapping);
            return null;
        };
        if (regions.total != len) {
            std.posix.munmap(mapping);
            return null;
        }

        const crc_off = regions.crc_off;
        const stored_crc = std.mem.readInt(u32, mapping[crc_off..][0..4], .little);
        const calc_crc = std.hash.crc.Crc32.hash(mapping[0..crc_off]);
        if (stored_crc != calc_crc) {
            std.posix.munmap(mapping);
            return null;
        }

        return LoadedIdMapSnapshot{
            .mapping = mapping,
            .checkpoint_epoch = epoch,
            .covered_lsn = covered,
            .next_node_slot = nn,
            .next_edge_slot = ne,
            .node_fwd_count = node_fwd_count,
            .edge_fwd_count = edge_fwd_count,
            .node_rev_off = regions.node_rev_off,
            .node_fwd_off = regions.node_fwd_off,
            .edge_rev_off = regions.edge_rev_off,
            .edge_fwd_off = regions.edge_fwd_off,
        };
    }

    const Regions = struct {
        node_rev_off: usize,
        node_fwd_off: usize,
        edge_rev_off: usize,
        edge_fwd_off: usize,
        crc_off: usize,
        total: usize,
    };

    /// Overflow-checked layout computation; returns null on any overflow.
    fn computeRegions(nn: u64, ne: u64, node_fwd: u64, edge_fwd: u64) ?Regions {
        const m = std.math;
        const node_rev_off: usize = SNAP_HEADER_SIZE;
        const node_rev_bytes = m.mul(usize, @as(usize, @intCast(nn)), REV_ENTRY) catch return null;
        const node_fwd_off = m.add(usize, node_rev_off, node_rev_bytes) catch return null;
        const node_fwd_bytes = m.mul(usize, @as(usize, @intCast(node_fwd)), FWD_ENTRY) catch return null;
        const edge_rev_off = m.add(usize, node_fwd_off, node_fwd_bytes) catch return null;
        const edge_rev_bytes = m.mul(usize, @as(usize, @intCast(ne)), REV_ENTRY) catch return null;
        const edge_fwd_off = m.add(usize, edge_rev_off, edge_rev_bytes) catch return null;
        const edge_fwd_bytes = m.mul(usize, @as(usize, @intCast(edge_fwd)), FWD_ENTRY) catch return null;
        const crc_off = m.add(usize, edge_fwd_off, edge_fwd_bytes) catch return null;
        const total = m.add(usize, crc_off, CRC_SIZE) catch return null;
        return .{
            .node_rev_off = node_rev_off,
            .node_fwd_off = node_fwd_off,
            .edge_rev_off = edge_rev_off,
            .edge_fwd_off = edge_fwd_off,
            .crc_off = crc_off,
            .total = total,
        };
    }

    /// PHASE 1b: bulk-populate this (expected-empty) IdMap from a loaded,
    /// counter-gated mmap snapshot WITHOUT any engine reads. Walks the
    /// direct-indexed reverse regions (slot -> uuid) for both namespaces and
    /// inserts every live (non-hole) mapping, then restores the next-slot
    /// counters. This is the fast IdMap path at open (replaces the per-node
    /// `getNodeProperty` engine-read scan, loop1, when a valid snapshot exists).
    /// Locks the map mutex once for the whole load.
    pub fn bulkLoadFromSnapshot(self: *IdMap, snap: *const LoadedIdMapSnapshot) !void {
        self.lockMu();
        defer self.unlockMu();

        try self.node_uuid_to_slot.ensureTotalCapacity(@intCast(snap.node_fwd_count));
        try self.node_slot_to_uuid.ensureTotalCapacity(@intCast(snap.node_fwd_count));
        try self.edge_uuid_to_slot.ensureTotalCapacity(@intCast(snap.edge_fwd_count));
        try self.edge_slot_to_uuid.ensureTotalCapacity(@intCast(snap.edge_fwd_count));

        var slot: u64 = 0;
        while (slot < snap.next_node_slot) : (slot += 1) {
            if (snap.nodeUuidAt(slot)) |uuid| {
                try self.node_uuid_to_slot.put(uuid, slot);
                try self.node_slot_to_uuid.put(slot, uuid);
            }
        }
        slot = 0;
        while (slot < snap.next_edge_slot) : (slot += 1) {
            if (snap.edgeUuidAt(slot)) |uuid| {
                try self.edge_uuid_to_slot.put(uuid, slot);
                try self.edge_slot_to_uuid.put(slot, uuid);
            }
        }
        if (snap.next_node_slot > self.next_node_slot) self.next_node_slot = snap.next_node_slot;
        if (snap.next_edge_slot > self.next_edge_slot) self.next_edge_slot = snap.next_edge_slot;
    }

    /// Largest node public-id (uuid) currently mapped, or null when empty.
    /// Used at open to recover the global next-public-id counter from the
    /// resident IdMaps WITHOUT an engine scan (Phase 1b lazy-hydrate keeps the
    /// per-graph node cache + introspection counters deferred, so the public-id
    /// high-water must be recovered here instead of in the deferred loop2).
    pub fn maxNodeUuid(self: *IdMap) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        var max: ?u128 = null;
        // Overlay keys (writes-since-open in mmap mode; everything in resident).
        var it = self.node_uuid_to_slot.keyIterator();
        while (it.next()) |k| {
            if (max == null or k.* > max.?) max = k.*;
        }
        if (self.mode == .mmap_backed) {
            // Base forward is sorted ascending by uuid, so the largest LIVE
            // base uuid is the tail walked backward past any tombstoned entries
            // (O(1) at open: overlay empty, no tombstones).
            if (self.base) |*b| {
                var i = b.node_fwd_count;
                while (i > 0) {
                    i -= 1;
                    const uuid = b.nodeFwdUuidAt(i);
                    if (self.removed_node_uuids.contains(uuid)) continue;
                    if (max == null or uuid > max.?) max = uuid;
                    break;
                }
            }
        }
        return max;
    }

    /// Largest edge public-id (uuid) currently mapped, or null when empty.
    pub fn maxEdgeUuid(self: *IdMap) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        var max: ?u128 = null;
        var it = self.edge_uuid_to_slot.keyIterator();
        while (it.next()) |k| {
            if (max == null or k.* > max.?) max = k.*;
        }
        if (self.mode == .mmap_backed) {
            if (self.base) |*b| {
                var i = b.edge_fwd_count;
                while (i > 0) {
                    i -= 1;
                    const uuid = b.edgeFwdUuidAt(i);
                    if (self.removed_edge_uuids.contains(uuid)) continue;
                    if (max == null or uuid > max.?) max = uuid;
                    break;
                }
            }
        }
        return max;
    }
};

/// A read-only, mmap-backed view of a saved IdMap snapshot. Lookups read
/// directly from the mapped bytes (no hashmap materialization). Reusable by
/// Phase 1b to bulk-hydrate an in-memory IdMap. Call `deinit` to unmap.
pub const LoadedIdMapSnapshot = struct {
    mapping: []align(std.heap.page_size_min) const u8,
    /// GAP-0064 FIX B Path-B reload gate: the durable checkpoint epoch and covered
    /// LSN this snapshot was stamped at (see the format doc). Caller reloads iff
    /// both match the engine's CURRENT epoch + frontier.
    checkpoint_epoch: u64,
    covered_lsn: u64,
    next_node_slot: u64,
    next_edge_slot: u64,
    node_fwd_count: u64,
    edge_fwd_count: u64,
    node_rev_off: usize,
    node_fwd_off: usize,
    edge_rev_off: usize,
    edge_fwd_off: usize,

    pub fn deinit(self: *LoadedIdMapSnapshot) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    /// slot -> uuid via the direct-indexed reverse region. Returns null when
    /// the slot is out of range or is a hole (sentinel 0).
    pub fn nodeUuidAt(self: *const LoadedIdMapSnapshot, slot: u64) ?u128 {
        return revLookup(self.mapping, self.node_rev_off, self.next_node_slot, slot);
    }

    pub fn edgeUuidAt(self: *const LoadedIdMapSnapshot, slot: u64) ?u128 {
        return revLookup(self.mapping, self.edge_rev_off, self.next_edge_slot, slot);
    }

    /// uuid -> slot via binary search over the sorted forward region with an
    /// exact full-key (u128) verify. Returns null when absent.
    pub fn nodeSlotOf(self: *const LoadedIdMapSnapshot, uuid: u128) ?u64 {
        return fwdSearch(self.mapping, self.node_fwd_off, self.node_fwd_count, uuid);
    }

    pub fn edgeSlotOf(self: *const LoadedIdMapSnapshot, uuid: u128) ?u64 {
        return fwdSearch(self.mapping, self.edge_fwd_off, self.edge_fwd_count, uuid);
    }

    /// uuid at forward-region index (0-based, sorted ascending). PHASE 4: used
    /// by the merged iterator / clone / serialize / maxUuid to enumerate the
    /// base live forward set without materializing it.
    pub fn nodeFwdUuidAt(self: *const LoadedIdMapSnapshot, idx: u64) u128 {
        const off = self.node_fwd_off + @as(usize, @intCast(idx)) * IdMap.FWD_ENTRY;
        return std.mem.readInt(u128, self.mapping[off..][0..16], .little);
    }

    pub fn edgeFwdUuidAt(self: *const LoadedIdMapSnapshot, idx: u64) u128 {
        const off = self.edge_fwd_off + @as(usize, @intCast(idx)) * IdMap.FWD_ENTRY;
        return std.mem.readInt(u128, self.mapping[off..][0..16], .little);
    }

    fn revLookup(mapping: []const u8, base_off: usize, next_slot: u64, slot: u64) ?u128 {
        if (slot >= next_slot) return null;
        const off = base_off + @as(usize, @intCast(slot)) * IdMap.REV_ENTRY;
        const uuid = std.mem.readInt(u128, mapping[off..][0..16], .little);
        if (uuid == 0) return null; // sentinel hole
        return uuid;
    }

    fn fwdSearch(mapping: []const u8, base_off: usize, count: u64, uuid: u128) ?u64 {
        var lo: usize = 0;
        var hi: usize = @intCast(count);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const off = base_off + mid * IdMap.FWD_ENTRY;
            const key = std.mem.readInt(u128, mapping[off..][0..16], .little);
            if (key == uuid) {
                // full-key match verified above; read the slot
                return std.mem.readInt(u64, mapping[off + 16 ..][0..8], .little);
            }
            if (key < uuid) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// UUIDv7 generation
// ---------------------------------------------------------------------------

/// Mutex-protected state for UUIDv7 generation.
/// Uses a mutex instead of 64-bit atomics for 32-bit ARM compatibility
/// (std.atomic.Value(i64) is unsupported on arm-linux-gnueabihf).
var uuid_mutex = std.Io.Mutex.init;
var uuid_counter_val: u16 = 0;
var uuid_last_ms_val: i64 = 0;

/// Generate a UUIDv7 value: 48-bit millisecond timestamp | 4-bit version(7)
/// | 12-bit counter/random | 2-bit variant(10) | 62-bit random.
pub fn generateUuidV7() u128 {
    const ms = compat_milliTimestamp();

    uuid_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    // Reset or increment the sub-ms counter
    if (ms != uuid_last_ms_val) {
        uuid_last_ms_val = ms;
        uuid_counter_val = 0;
    }
    const seq = uuid_counter_val;
    uuid_counter_val +%= 1;
    uuid_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // 62 bits of randomness for the lower portion
    var rand_bytes: [8]u8 = undefined;
    // fips-exempt: non-security UUID v7 random bits (not key/nonce material)
    compat_fillRandom(&rand_bytes);
    const rand_bits: u64 = @bitCast(rand_bytes);

    // Build the 128-bit UUID
    const ts: u48 = @truncate(@as(u64, @bitCast(ms)));

    var uuid: u128 = 0;
    // Bits 127..80: 48-bit timestamp
    uuid |= @as(u128, ts) << 80;
    // Bits 79..76: version = 0b0111 (7)
    uuid |= @as(u128, 0x7) << 76;
    // Bits 75..64: 12-bit sequence (use lower 12 bits of counter)
    uuid |= @as(u128, seq & 0x0FFF) << 64;
    // Bits 63..62: variant = 0b10
    uuid |= @as(u128, 0b10) << 62;
    // Bits 61..0: 62 bits of randomness
    uuid |= @as(u128, rand_bits & 0x3FFF_FFFF_FFFF_FFFF);

    return uuid;
}

/// Extract the millisecond timestamp from a UUIDv7.
pub fn uuidV7Timestamp(uuid: u128) i64 {
    const ts: u48 = @truncate(uuid >> 80);
    return @intCast(ts);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "IdMap: node insert and lookup" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid1: u128 = 0x0191_0000_0000_7000_8000_0000_0000_0001;
    const uuid2: u128 = 0x0191_0000_0000_7000_8000_0000_0000_0002;

    const slot1 = try map.insertNode(uuid1);
    const slot2 = try map.insertNode(uuid2);

    try std.testing.expectEqual(@as(u64, 0), slot1);
    try std.testing.expectEqual(@as(u64, 1), slot2);

    // Forward lookup
    try std.testing.expectEqual(@as(?u64, 0), map.nodeSlot(uuid1));
    try std.testing.expectEqual(@as(?u64, 1), map.nodeSlot(uuid2));

    // Reverse lookup
    try std.testing.expectEqual(@as(?u128, uuid1), map.nodeUuid(0));
    try std.testing.expectEqual(@as(?u128, uuid2), map.nodeUuid(1));

    // Missing lookup
    try std.testing.expectEqual(@as(?u64, null), map.nodeSlot(0xDEAD));
    try std.testing.expectEqual(@as(?u128, null), map.nodeUuid(999));
}

test "IdMap: duplicate insert returns existing slot" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid: u128 = 0x0191_AAAA_BBBB_7CCC_8DDD_EEEE_FFFF_0000;
    const slot1 = try map.insertNode(uuid);
    const slot2 = try map.insertNode(uuid);
    try std.testing.expectEqual(slot1, slot2);
    try std.testing.expectEqual(@as(u32, 1), map.nodeCount());
}

test "IdMap: edge insert and lookup" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid: u128 = 0x0191_0000_0000_7000_8000_0000_0000_00FF;
    const slot = try map.insertEdge(uuid);
    try std.testing.expectEqual(@as(u64, 0), slot);
    try std.testing.expectEqual(@as(?u64, 0), map.edgeSlot(uuid));
    try std.testing.expectEqual(@as(?u128, uuid), map.edgeUuid(0));
    try std.testing.expectEqual(@as(u32, 1), map.edgeCount());
}

test "IdMap: node and edge slots are independent" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid_n: u128 = 1;
    const uuid_e: u128 = 2;

    const ns = try map.insertNode(uuid_n);
    const es = try map.insertEdge(uuid_e);

    // Both start at 0 since they are separate namespaces
    try std.testing.expectEqual(@as(u64, 0), ns);
    try std.testing.expectEqual(@as(u64, 0), es);
}

test "IdMap: remove node" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid: u128 = 42;
    _ = try map.insertNode(uuid);
    try std.testing.expect(map.removeNode(uuid));
    try std.testing.expectEqual(@as(?u64, null), map.nodeSlot(uuid));
    try std.testing.expectEqual(@as(u32, 0), map.nodeCount());

    // Double remove returns false
    try std.testing.expect(!map.removeNode(uuid));
}

test "IdMap: remove edge" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    const uuid: u128 = 99;
    _ = try map.insertEdge(uuid);
    try std.testing.expect(map.removeEdge(uuid));
    try std.testing.expectEqual(@as(?u64, null), map.edgeSlot(uuid));
    try std.testing.expect(!map.removeEdge(uuid));
}

test "IdMap: save and load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Populate and save
    {
        var map = IdMap.init(std.testing.allocator);
        defer map.deinit();

        _ = try map.insertNode(100);
        _ = try map.insertNode(200);
        _ = try map.insertNode(300);
        _ = try map.insertEdge(400);
        _ = try map.insertEdge(500);

        try map.save(tmp.dir);
    }

    // Load and verify
    {
        var map = try IdMap.load(std.testing.allocator, tmp.dir);
        defer map.deinit();

        try std.testing.expectEqual(@as(u32, 3), map.nodeCount());
        try std.testing.expectEqual(@as(u32, 2), map.edgeCount());

        // Verify forward lookups
        try std.testing.expect(map.nodeSlot(100) != null);
        try std.testing.expect(map.nodeSlot(200) != null);
        try std.testing.expect(map.nodeSlot(300) != null);
        try std.testing.expect(map.edgeSlot(400) != null);
        try std.testing.expect(map.edgeSlot(500) != null);

        // Verify reverse lookups
        const slot0_uuid = map.nodeUuid(0).?;
        try std.testing.expect(slot0_uuid == 100 or slot0_uuid == 200 or slot0_uuid == 300);

        // Verify slot counter advanced past loaded slots
        const new_slot = try map.insertNode(999);
        try std.testing.expectEqual(@as(u64, 3), new_slot);
    }
}

test "IdMap: load missing file returns empty map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = try IdMap.load(std.testing.allocator, tmp.dir);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 0), map.nodeCount());
    try std.testing.expectEqual(@as(u32, 0), map.edgeCount());
}

test "generateUuidV7: basic properties" {
    const a = generateUuidV7();
    const b = generateUuidV7();

    // Version nibble (bits 79..76) must be 0x7
    const ver_a: u4 = @truncate(a >> 76);
    const ver_b: u4 = @truncate(b >> 76);
    try std.testing.expectEqual(@as(u4, 7), ver_a);
    try std.testing.expectEqual(@as(u4, 7), ver_b);

    // Variant bits (bits 63..62) must be 0b10
    const var_a: u2 = @truncate(a >> 62);
    const var_b: u2 = @truncate(b >> 62);
    try std.testing.expectEqual(@as(u2, 0b10), var_a);
    try std.testing.expectEqual(@as(u2, 0b10), var_b);

    // UUIDs must be distinct
    try std.testing.expect(a != b);
}

test "generateUuidV7: monotonic timestamps" {
    const a = generateUuidV7();
    const ts_a = uuidV7Timestamp(a);

    // Timestamp must be a reasonable epoch-ms value (after 2020)
    try std.testing.expect(ts_a > 1_577_836_800_000); // 2020-01-01 in ms
}

test "generateUuidV7: multiple calls produce unique values" {
    var seen = std.AutoHashMap(u128, void).init(std.testing.allocator);
    defer seen.deinit();

    for (0..100) |_| {
        const uuid = generateUuidV7();
        try std.testing.expect(!seen.contains(uuid));
        try seen.put(uuid, {});
    }
}

test "IdMap: insertNodeWithSlot advances counter" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    try map.insertNodeWithSlot(0xAABB, 10);
    try std.testing.expectEqual(@as(u64, 11), map.next_node_slot);

    // Insert with lower slot should not regress counter
    try map.insertNodeWithSlot(0xCCDD, 5);
    try std.testing.expectEqual(@as(u64, 11), map.next_node_slot);

    // New auto-insert should use slot 11
    const slot = try map.insertNode(0xEEFF);
    try std.testing.expectEqual(@as(u64, 11), slot);
}
