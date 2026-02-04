const std = @import("std");
const hnsw = @import("hnsw");
const tde = @import("tde");

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=HNSWIndex; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

const MAGIC = "GDHW";

pub const Header = extern struct {
    magic: [4]u8,
    version: u16,
    M: u16,
    ef: u16,
    max_level: u8,
    entry_point: u64,
    dim: u16,
    node_count: u64,
};

pub const NodeRecord = extern struct {
    id: u64,
    level: u8,
};

pub fn saveSnapshot(index: *const hnsw.Hnsw, snapshot_path: []const u8, vec_path: []const u8) !void {
    // Buffer all snapshot data to memory first for TDE encryption
    var snap_buffer = try std.ArrayList(u8).initCapacity(index.allocator, 4096);
    defer snap_buffer.deinit(index.allocator);

    var vec_buffer = try std.ArrayList(u8).initCapacity(index.allocator, 4096);
    defer vec_buffer.deinit(index.allocator);

    const header = Header{
        .magic = MAGIC.*,
        .version = 1,
        .M = index.M,
        .ef = index.ef_construction,
        .max_level = index.max_level,
        .entry_point = index.entry_point orelse 0,
        .dim = index.dim,
        .node_count = index.nodes.count(),
    };

    try snap_buffer.appendSlice(index.allocator, std.mem.asBytes(&header));

    var iter = index.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        const record = NodeRecord{
            .id = node.id,
            .level = node.level,
        };
        try snap_buffer.appendSlice(index.allocator, std.mem.asBytes(&record));

        for (node.neighbors, 0..) |neighbors, level| {
            if (level <= node.level) {
                var count: u32 = @intCast(neighbors.items.len);
                try snap_buffer.appendSlice(index.allocator, std.mem.asBytes(&count));
                for (neighbors.items) |neighbor| {
                    try snap_buffer.appendSlice(index.allocator, std.mem.asBytes(&neighbor));
                }
            }
        }

        for (node.vector) |v| {
            var bits: u32 = @bitCast(v);
            try vec_buffer.appendSlice(index.allocator, std.mem.asBytes(&bits));
        }
    }

    // Encrypt and write snapshot file
    try tde.writeEncryptedFile(index.allocator, snapshot_path, snap_buffer.items);

    // Encrypt and write vector file
    try tde.writeEncryptedFile(index.allocator, vec_path, vec_buffer.items);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8, vec_path: []const u8) !hnsw.Hnsw {
    // Read and decrypt snapshot file using TDE
    const snap_data = try tde.readDecryptedFile(allocator, snapshot_path);
    defer allocator.free(snap_data);

    // Read and decrypt vector file using TDE
    const vec_data = try tde.readDecryptedFile(allocator, vec_path);
    defer allocator.free(vec_data);

    // Create streams to read from decrypted data
    var snap_stream = std.io.fixedBufferStream(snap_data);
    var vec_stream = std.io.fixedBufferStream(vec_data);

    // Read header
    var header: Header = undefined;
    _ = try snap_stream.reader().readAll(std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
    if (header.version != 1) return error.InvalidVersion;

    var index = hnsw.Hnsw.init(allocator, header.dim, header.M, header.ef);
    index.max_level = header.max_level;
    index.entry_point = if (header.entry_point == 0) null else header.entry_point;

    var i: u64 = 0;
    while (i < header.node_count) : (i += 1) {
        var record: NodeRecord = undefined;
        _ = try snap_stream.reader().readAll(std.mem.asBytes(&record));

        const vector = try allocator.alloc(f32, header.dim);
        for (vector) |*v| {
            var bits: u32 = undefined;
            _ = try vec_stream.reader().readAll(std.mem.asBytes(&bits));
            v.* = @bitCast(bits);
        }

        var node = try hnsw.HnswNode.init(allocator, record.id, vector, record.level);
        allocator.free(vector);

        var level: u8 = 0;
        while (level <= record.level) : (level += 1) {
            var count: u32 = undefined;
            _ = try snap_stream.reader().readAll(std.mem.asBytes(&count));

            var j: u32 = 0;
            while (j < count) : (j += 1) {
                var neighbor: u64 = undefined;
                _ = try snap_stream.reader().readAll(std.mem.asBytes(&neighbor));
                try node.neighbors[level].append(allocator, neighbor);
            }
        }

        try index.nodes.put(record.id, node);
    }

    return index;
}
