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

    pub fn init(allocator: Allocator) IdMap {
        return .{
            .allocator = allocator,
            .node_uuid_to_slot = std.AutoHashMap(u128, u64).init(allocator),
            .node_slot_to_uuid = std.AutoHashMap(u64, u128).init(allocator),
            .edge_uuid_to_slot = std.AutoHashMap(u128, u64).init(allocator),
            .edge_slot_to_uuid = std.AutoHashMap(u64, u128).init(allocator),
            .next_node_slot = 0,
            .next_edge_slot = 0,
        };
    }

    pub fn deinit(self: *IdMap) void {
        self.node_uuid_to_slot.deinit();
        self.node_slot_to_uuid.deinit();
        self.edge_uuid_to_slot.deinit();
        self.edge_slot_to_uuid.deinit();
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
        if (self.node_uuid_to_slot.get(uuid)) |existing| {
            return existing;
        }
        const slot = self.next_node_slot;
        self.next_node_slot += 1;
        try self.node_uuid_to_slot.put(uuid, slot);
        try self.node_slot_to_uuid.put(slot, uuid);
        return slot;
    }

    /// Insert a node mapping with a specific slot ID (used during load).
    pub fn insertNodeWithSlot(self: *IdMap, uuid: u128, slot: u64) !void {
        self.lockMu();
        defer self.unlockMu();
        try self.node_uuid_to_slot.put(uuid, slot);
        try self.node_slot_to_uuid.put(slot, uuid);
        if (slot >= self.next_node_slot) {
            self.next_node_slot = slot + 1;
        }
    }

    /// Look up the slot ID for a node UUID.
    pub fn nodeSlot(self: *IdMap, uuid: u128) ?u64 {
        self.lockMu();
        defer self.unlockMu();
        return self.node_uuid_to_slot.get(uuid);
    }

    /// Look up the UUID for a node slot ID.
    pub fn nodeUuid(self: *IdMap, slot: u64) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        return self.node_slot_to_uuid.get(slot);
    }

    /// Remove a node mapping by UUID.
    pub fn removeNode(self: *IdMap, uuid: u128) bool {
        self.lockMu();
        defer self.unlockMu();
        const slot = self.node_uuid_to_slot.get(uuid) orelse return false;
        _ = self.node_uuid_to_slot.remove(uuid);
        _ = self.node_slot_to_uuid.remove(slot);
        return true;
    }

    // ------------------------------------------------------------------
    // Edge operations
    // ------------------------------------------------------------------

    /// Insert a new edge mapping. Returns the allocated slot ID.
    /// If the UUID already exists, returns the existing slot.
    pub fn insertEdge(self: *IdMap, uuid: u128) !u64 {
        self.lockMu();
        defer self.unlockMu();
        if (self.edge_uuid_to_slot.get(uuid)) |existing| {
            return existing;
        }
        const slot = self.next_edge_slot;
        self.next_edge_slot += 1;
        try self.edge_uuid_to_slot.put(uuid, slot);
        try self.edge_slot_to_uuid.put(slot, uuid);
        return slot;
    }

    /// Insert an edge mapping with a specific slot ID (used during load).
    pub fn insertEdgeWithSlot(self: *IdMap, uuid: u128, slot: u64) !void {
        self.lockMu();
        defer self.unlockMu();
        try self.edge_uuid_to_slot.put(uuid, slot);
        try self.edge_slot_to_uuid.put(slot, uuid);
        if (slot >= self.next_edge_slot) {
            self.next_edge_slot = slot + 1;
        }
    }

    /// Look up the slot ID for an edge UUID.
    pub fn edgeSlot(self: *IdMap, uuid: u128) ?u64 {
        self.lockMu();
        defer self.unlockMu();
        return self.edge_uuid_to_slot.get(uuid);
    }

    /// Look up the UUID for an edge slot ID.
    pub fn edgeUuid(self: *IdMap, slot: u64) ?u128 {
        self.lockMu();
        defer self.unlockMu();
        return self.edge_slot_to_uuid.get(slot);
    }

    /// Remove an edge mapping by UUID.
    pub fn removeEdge(self: *IdMap, uuid: u128) bool {
        self.lockMu();
        defer self.unlockMu();
        const slot = self.edge_uuid_to_slot.get(uuid) orelse return false;
        _ = self.edge_uuid_to_slot.remove(uuid);
        _ = self.edge_slot_to_uuid.remove(slot);
        return true;
    }

    // ------------------------------------------------------------------
    // Counts
    // ------------------------------------------------------------------

    pub fn nodeCount(self: *const IdMap) u32 {
        return self.node_uuid_to_slot.count();
    }

    /// Iterator over every public node uuid in this graph's mapping. The IdMap
    /// stays fully resident (~24 B/entry) independent of the bounded node cache,
    /// so this enumerates ALL nodes of the graph even after node-cache eviction.
    /// Used by full-graph "all node ids" paths so they don't miss evicted nodes.
    pub const NodeUuidIterator = struct {
        inner: @TypeOf(@as(IdMap, undefined).node_uuid_to_slot).KeyIterator,
        pub fn next(it: *NodeUuidIterator) ?u128 {
            if (it.inner.next()) |k| return k.* else return null;
        }
    };
    pub fn nodeUuidIterator(self: *const IdMap) NodeUuidIterator {
        return .{ .inner = self.node_uuid_to_slot.keyIterator() };
    }

    pub fn edgeCount(self: *const IdMap) u32 {
        return self.edge_uuid_to_slot.count();
    }

    /// Iterator over every public edge uuid in this graph's mapping. Like
    /// `NodeUuidIterator`, the IdMap edge map stays fully resident (~24 B/entry)
    /// independent of the bounded EDGE cache, so this enumerates ALL edges of
    /// the graph even after edge-cache eviction. Used by full-graph "all edge
    /// ids" paths (tenant-drop cascade, edge-type derivation, index rebuild) so
    /// they don't miss evicted edges. (PHASE 1: edge-engine-direct.)
    pub const EdgeUuidIterator = struct {
        inner: @TypeOf(@as(IdMap, undefined).edge_uuid_to_slot).KeyIterator,
        pub fn next(it: *EdgeUuidIterator) ?u128 {
            if (it.inner.next()) |k| return k.* else return null;
        }
    };
    pub fn edgeUuidIterator(self: *const IdMap) EdgeUuidIterator {
        return .{ .inner = self.edge_uuid_to_slot.keyIterator() };
    }

    /// Deep-copy the mapping tables into a new IdMap owned by `allocator`.
    pub fn clone(self: *const IdMap, allocator: Allocator) !IdMap {
        var copy = IdMap.init(allocator);
        errdefer copy.deinit();

        copy.next_node_slot = self.next_node_slot;
        copy.next_edge_slot = self.next_edge_slot;

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
    //   format_ver        u32
    //   manifest_counter  u64   (caller's crash-safety gate; gate logic = 1b)
    //   next_node_slot    u64
    //   next_edge_slot    u64
    //   node_fwd_count    u64
    //   edge_fwd_count    u64
    //   NODE reverse  u128[next_node_slot]
    //   NODE forward  (u128 uuid, u64 slot)[node_fwd_count]   (sorted by uuid)
    //   EDGE reverse  u128[next_edge_slot]
    //   EDGE forward  (u128 uuid, u64 slot)[edge_fwd_count]   (sorted by uuid)
    //   CRC32 u32  (over EVERYTHING before this trailer)
    // ------------------------------------------------------------------

    /// Magic for the mmap-able snapshot (distinct from the legacy FILE_MAGIC).
    const SNAP_MAGIC: [8]u8 = "GEOIDMAP".*;
    /// Snapshot format version.
    const SNAP_VERSION: u32 = 1;
    const SNAP_FILE = "idmap.snapshot";
    const SNAP_TMP = "idmap.snapshot.tmp";

    // Fixed header field offsets.
    const HDR_VER_OFF = 8;
    const HDR_MANIFEST_OFF = 12;
    const HDR_NEXT_NODE_OFF = 20;
    const HDR_NEXT_EDGE_OFF = 28;
    const HDR_NODE_FWD_OFF = 36;
    const HDR_EDGE_FWD_OFF = 44;
    const SNAP_HEADER_SIZE = 52;
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
    fn serializeSnapshot(self: *IdMap, manifest_counter: u64) ![]u8 {
        const a = self.allocator;
        self.lockMu();
        defer self.unlockMu();

        const nn = self.next_node_slot;
        const ne = self.next_edge_slot;
        const node_fwd_count: u64 = self.node_uuid_to_slot.count();
        const edge_fwd_count: u64 = self.edge_uuid_to_slot.count();

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
        std.mem.writeInt(u64, buf[HDR_MANIFEST_OFF..][0..8], manifest_counter, .little);
        std.mem.writeInt(u64, buf[HDR_NEXT_NODE_OFF..][0..8], nn, .little);
        std.mem.writeInt(u64, buf[HDR_NEXT_EDGE_OFF..][0..8], ne, .little);
        std.mem.writeInt(u64, buf[HDR_NODE_FWD_OFF..][0..8], node_fwd_count, .little);
        std.mem.writeInt(u64, buf[HDR_EDGE_FWD_OFF..][0..8], edge_fwd_count, .little);

        // NODE reverse (direct-indexed by slot).
        {
            var it = self.node_slot_to_uuid.iterator();
            while (it.next()) |e| {
                const slot = e.key_ptr.*;
                if (slot < nn) {
                    const off = node_rev_off + @as(usize, @intCast(slot)) * REV_ENTRY;
                    std.mem.writeInt(u128, buf[off..][0..16], e.value_ptr.*, .little);
                }
            }
        }
        // NODE forward (sorted by uuid).
        try serializeForward(a, buf, node_fwd_off, &self.node_uuid_to_slot);

        // EDGE reverse.
        {
            var it = self.edge_slot_to_uuid.iterator();
            while (it.next()) |e| {
                const slot = e.key_ptr.*;
                if (slot < ne) {
                    const off = edge_rev_off + @as(usize, @intCast(slot)) * REV_ENTRY;
                    std.mem.writeInt(u128, buf[off..][0..16], e.value_ptr.*, .little);
                }
            }
        }
        // EDGE forward.
        try serializeForward(a, buf, edge_fwd_off, &self.edge_uuid_to_slot);

        // CRC32 over the entire payload preceding the trailer.
        const crc = std.hash.crc.Crc32.hash(buf[0..crc_off]);
        std.mem.writeInt(u32, buf[crc_off..][0..4], crc, .little);

        return buf;
    }

    fn serializeForward(
        a: Allocator,
        buf: []u8,
        base_off: usize,
        map: *std.AutoHashMap(u128, u64),
    ) !void {
        const count = map.count();
        if (count == 0) return;
        const pairs = try a.alloc(FwdPair, count);
        defer a.free(pairs);
        var i: usize = 0;
        var it = map.iterator();
        while (it.next()) |e| {
            pairs[i] = .{ .uuid = e.key_ptr.*, .slot = e.value_ptr.* };
            i += 1;
        }
        std.mem.sort(FwdPair, pairs, {}, fwdLess);
        for (pairs, 0..) |p, idx| {
            const off = base_off + idx * FWD_ENTRY;
            std.mem.writeInt(u128, buf[off..][0..16], p.uuid, .little);
            std.mem.writeInt(u64, buf[off + 16 ..][0..8], p.slot, .little);
        }
    }

    /// Serialize this IdMap to an mmap-able snapshot in `dir`, stamped with
    /// `manifest_counter` (the caller's crash-safety gate). Atomic: writes a
    /// temp file, fsyncs it, then renames over the final name (mirrors the
    /// legacy `save` atomic discipline).
    pub fn saveSnapshot(self: *IdMap, dir: std.Io.Dir, manifest_counter: u64) !void {
        const buf = try self.serializeSnapshot(manifest_counter);
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

        const manifest = std.mem.readInt(u64, mapping[HDR_MANIFEST_OFF..][0..8], .little);
        const nn = std.mem.readInt(u64, mapping[HDR_NEXT_NODE_OFF..][0..8], .little);
        const ne = std.mem.readInt(u64, mapping[HDR_NEXT_EDGE_OFF..][0..8], .little);
        const node_fwd_count = std.mem.readInt(u64, mapping[HDR_NODE_FWD_OFF..][0..8], .little);
        const edge_fwd_count = std.mem.readInt(u64, mapping[HDR_EDGE_FWD_OFF..][0..8], .little);

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
            .manifest_counter = manifest,
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
};

/// A read-only, mmap-backed view of a saved IdMap snapshot. Lookups read
/// directly from the mapped bytes (no hashmap materialization). Reusable by
/// Phase 1b to bulk-hydrate an in-memory IdMap. Call `deinit` to unmap.
pub const LoadedIdMapSnapshot = struct {
    mapping: []align(std.heap.page_size_min) const u8,
    manifest_counter: u64,
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
