// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2025 CodePros
//
// Persistent bidirectional mapping between UUIDv7 external IDs and dense
// engine slot IDs.  Each graph owns one IdMap persisted to id_map.dat.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Magic bytes at the start of id_map.dat for format identification.
const FILE_MAGIC: [8]u8 = "GEODEIDM".*;
/// Current file format version.
const FILE_VERSION: u32 = 1;

/// Header stored at the beginning of the id_map.dat file.
const FileHeader = extern struct {
    magic: [8]u8,
    version: u32,
    entry_count: u32,
};

/// Bidirectional mapping between UUIDv7 external IDs (u128) and dense
/// engine slot IDs (u64).  Supports separate namespaces for nodes and edges.
pub const IdMap = struct {
    allocator: Allocator,

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

    // ------------------------------------------------------------------
    // Node operations
    // ------------------------------------------------------------------

    /// Insert a new node mapping. Returns the allocated slot ID.
    /// If the UUID already exists, returns the existing slot.
    pub fn insertNode(self: *IdMap, uuid: u128) !u64 {
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
        try self.node_uuid_to_slot.put(uuid, slot);
        try self.node_slot_to_uuid.put(slot, uuid);
        if (slot >= self.next_node_slot) {
            self.next_node_slot = slot + 1;
        }
    }

    /// Look up the slot ID for a node UUID.
    pub fn nodeSlot(self: *const IdMap, uuid: u128) ?u64 {
        return self.node_uuid_to_slot.get(uuid);
    }

    /// Look up the UUID for a node slot ID.
    pub fn nodeUuid(self: *const IdMap, slot: u64) ?u128 {
        return self.node_slot_to_uuid.get(slot);
    }

    /// Remove a node mapping by UUID.
    pub fn removeNode(self: *IdMap, uuid: u128) bool {
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
        try self.edge_uuid_to_slot.put(uuid, slot);
        try self.edge_slot_to_uuid.put(slot, uuid);
        if (slot >= self.next_edge_slot) {
            self.next_edge_slot = slot + 1;
        }
    }

    /// Look up the slot ID for an edge UUID.
    pub fn edgeSlot(self: *const IdMap, uuid: u128) ?u64 {
        return self.edge_uuid_to_slot.get(uuid);
    }

    /// Look up the UUID for an edge slot ID.
    pub fn edgeUuid(self: *const IdMap, slot: u64) ?u128 {
        return self.edge_slot_to_uuid.get(slot);
    }

    /// Remove an edge mapping by UUID.
    pub fn removeEdge(self: *IdMap, uuid: u128) bool {
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

    pub fn edgeCount(self: *const IdMap) u32 {
        return self.edge_uuid_to_slot.count();
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    /// Save the id map to a file atomically (write to temp then rename).
    /// `dir` is the directory containing the graph data.
    pub fn save(self: *const IdMap, dir: std.fs.Dir) !void {
        const tmp_name = "id_map.dat.tmp";
        const final_name = "id_map.dat";

        // Create temp file
        const file = try dir.createFile(tmp_name, .{});
        defer file.close();

        const total_entries: u32 = self.node_uuid_to_slot.count() + self.edge_uuid_to_slot.count();

        // Write header
        const header = FileHeader{
            .magic = FILE_MAGIC,
            .version = FILE_VERSION,
            .entry_count = total_entries,
        };
        try file.writeAll(std.mem.asBytes(&header));

        // Write node entries: type_tag(u8=0) | uuid(u128) | slot(u64)
        var node_iter = self.node_uuid_to_slot.iterator();
        while (node_iter.next()) |entry| {
            try file.writeAll(&[_]u8{0}); // node tag
            try file.writeAll(std.mem.asBytes(&entry.key_ptr.*));
            try file.writeAll(std.mem.asBytes(&entry.value_ptr.*));
        }

        // Write edge entries: type_tag(u8=1) | uuid(u128) | slot(u64)
        var edge_iter = self.edge_uuid_to_slot.iterator();
        while (edge_iter.next()) |entry| {
            try file.writeAll(&[_]u8{1}); // edge tag
            try file.writeAll(std.mem.asBytes(&entry.key_ptr.*));
            try file.writeAll(std.mem.asBytes(&entry.value_ptr.*));
        }

        // Atomic rename
        try dir.rename(tmp_name, final_name);
    }

    /// Load an id map from id_map.dat in the given directory.
    pub fn load(allocator: Allocator, dir: std.fs.Dir) !IdMap {
        var self = IdMap.init(allocator);
        errdefer self.deinit();

        const file = dir.openFile("id_map.dat", .{}) catch |err| {
            if (err == error.FileNotFound) return self;
            return err;
        };
        defer file.close();

        // Read and validate header
        var header: FileHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const n = try file.readAll(header_bytes);
        if (n < header_bytes.len) return error.UnexpectedEndOfFile;

        if (!std.mem.eql(u8, &header.magic, &FILE_MAGIC)) return error.InvalidFormat;
        if (header.version != FILE_VERSION) return error.UnsupportedVersion;

        // Read entries
        for (0..header.entry_count) |_| {
            var tag_buf: [1]u8 = undefined;
            const tag_n = try file.readAll(&tag_buf);
            if (tag_n < 1) return error.UnexpectedEndOfFile;
            const type_tag = tag_buf[0];

            var uuid_bytes: [@sizeOf(u128)]u8 = undefined;
            const uuid_n = try file.readAll(&uuid_bytes);
            if (uuid_n < uuid_bytes.len) return error.UnexpectedEndOfFile;
            const uuid: u128 = @bitCast(uuid_bytes);

            var slot_bytes: [@sizeOf(u64)]u8 = undefined;
            const slot_n = try file.readAll(&slot_bytes);
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
};

// ---------------------------------------------------------------------------
// UUIDv7 generation
// ---------------------------------------------------------------------------

/// Mutex-protected state for UUIDv7 generation.
/// Uses a mutex instead of 64-bit atomics for 32-bit ARM compatibility
/// (std.atomic.Value(i64) is unsupported on arm-linux-gnueabihf).
var uuid_mutex = std.Thread.Mutex{};
var uuid_counter_val: u16 = 0;
var uuid_last_ms_val: i64 = 0;

/// Generate a UUIDv7 value: 48-bit millisecond timestamp | 4-bit version(7)
/// | 12-bit counter/random | 2-bit variant(10) | 62-bit random.
pub fn generateUuidV7() u128 {
    const ms = std.time.milliTimestamp();

    uuid_mutex.lock();
    // Reset or increment the sub-ms counter
    if (ms != uuid_last_ms_val) {
        uuid_last_ms_val = ms;
        uuid_counter_val = 0;
    }
    const seq = uuid_counter_val;
    uuid_counter_val +%= 1;
    uuid_mutex.unlock();

    // 62 bits of randomness for the lower portion
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
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
