const std = @import("std");
const hnsw = @import("hnsw.zig");

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

pub const WalOp = enum(u8) {
    ADD = 1,
};

pub const WalEntry = struct {
    op: WalOp,
    id: u64,
    vector: []const f32,
};

pub fn saveSnapshot(index: *const hnsw.Hnsw, snapshot_path: []const u8, vec_path: []const u8) !void {
    const snap_file = try std.fs.cwd().createFile(snapshot_path, .{});
    defer snap_file.close();

    const vec_file = try std.fs.cwd().createFile(vec_path, .{});
    defer vec_file.close();

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

    try snap_file.writeAll(std.mem.asBytes(&header));

    var iter = index.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        const record = NodeRecord{
            .id = node.id,
            .level = node.level,
        };
        try snap_file.writeAll(std.mem.asBytes(&record));

        for (node.neighbors, 0..) |neighbors, level| {
            if (level <= node.level) {
                var count: u32 = @intCast(neighbors.items.len);
                try snap_file.writeAll(std.mem.asBytes(&count));
                for (neighbors.items) |neighbor| {
                    try snap_file.writeAll(std.mem.asBytes(&neighbor));
                }
            }
        }

        for (node.vector) |v| {
            var bits: u32 = @bitCast(v);
            try vec_file.writeAll(std.mem.asBytes(&bits));
        }
    }
}

pub fn loadSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8, vec_path: []const u8) !hnsw.Hnsw {
    const snap_file = try std.fs.cwd().openFile(snapshot_path, .{});
    defer snap_file.close();

    const vec_file = try std.fs.cwd().openFile(vec_path, .{});
    defer vec_file.close();

    var header: Header = undefined;
    _ = try snap_file.read(std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
    if (header.version != 1) return error.InvalidVersion;

    var index = hnsw.Hnsw.init(allocator, header.dim, header.M, header.ef);
    index.max_level = header.max_level;
    index.entry_point = if (header.entry_point == 0) null else header.entry_point;

    var i: u64 = 0;
    while (i < header.node_count) : (i += 1) {
        var record: NodeRecord = undefined;
        _ = try snap_file.read(std.mem.asBytes(&record));

        var vector = try allocator.alloc(f32, header.dim);
        for (vector) |*v| {
            var bits: u32 = undefined;
            _ = try vec_file.read(std.mem.asBytes(&bits));
            v.* = @bitCast(bits);
        }

        var node = try hnsw.HnswNode.init(allocator, record.id, vector, record.level);
        allocator.free(vector);

        var level: u8 = 0;
        while (level <= record.level) : (level += 1) {
            var count: u32 = undefined;
            _ = try snap_file.read(std.mem.asBytes(&count));

            var j: u32 = 0;
            while (j < count) : (j += 1) {
                var neighbor: u64 = undefined;
                _ = try snap_file.read(std.mem.asBytes(&neighbor));
                try node.neighbors[level].append(neighbor);
            }
        }

        try index.nodes.put(record.id, node);
    }

    return index;
}

pub fn appendWal(path: []const u8, entry: WalEntry) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);

    try file.writeAll(&[_]u8{@intFromEnum(entry.op)});
    try file.writeAll(std.mem.asBytes(&entry.id));

    var dim: u16 = @intCast(entry.vector.len);
    try file.writeAll(std.mem.asBytes(&dim));

    for (entry.vector) |v| {
        var bits: u32 = @bitCast(v);
        try file.writeAll(std.mem.asBytes(&bits));
    }
}

pub fn replayWal(index: *hnsw.Hnsw, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    while (true) {
        var op_byte: [1]u8 = undefined;
        if (try file.read(&op_byte) == 0) break;

        const op = std.meta.intToEnum(WalOp, op_byte[0]) catch return error.InvalidWalOp;

        var id: u64 = undefined;
        _ = try file.read(std.mem.asBytes(&id));

        var dim: u16 = undefined;
        _ = try file.read(std.mem.asBytes(&dim));

        var vector = try index.allocator.alloc(f32, dim);
        defer index.allocator.free(vector);

        for (vector) |*v| {
            var bits: u32 = undefined;
            _ = try file.read(std.mem.asBytes(&bits));
            v.* = @bitCast(bits);
        }

        switch (op) {
            .ADD => try index.insert(id, vector),
        }
    }
}

pub fn checkpoint(index: *const hnsw.Hnsw, snapshot_path: []const u8, vec_path: []const u8, wal_path: []const u8) !void {
    const temp_snap = try std.fmt.allocPrint(index.allocator, "{s}.tmp", .{snapshot_path});
    defer index.allocator.free(temp_snap);

    const temp_vec = try std.fmt.allocPrint(index.allocator, "{s}.tmp", .{vec_path});
    defer index.allocator.free(temp_vec);

    try saveSnapshot(index, temp_snap, temp_vec);

    try std.fs.cwd().rename(temp_snap, snapshot_path);
    try std.fs.cwd().rename(temp_vec, vec_path);

    if (std.fs.cwd().openFile(wal_path, .{ .mode = .write_only })) |file| {
        file.close();
        try std.fs.cwd().deleteFile(wal_path);
    } else |_| {}

    _ = try std.fs.cwd().createFile(wal_path, .{});
}
