const std = @import("std");
const rtree = @import("rtree.zig");

const MAGIC = "GDRT";

pub const Header = extern struct {
    magic: [4]u8,
    version: u16,
    M: u16,
    count: u64,
    height: u16,
};

pub const NodeRecord = extern struct {
    is_leaf: u8,
    level: u16,
    entry_count: u32,
};

pub const EntryRecord = extern struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
    id: u64,
    has_child: u8,
};

pub const WalOp = enum(u8) {
    INSERT = 1,
    DELETE = 2,
};

pub const WalEntry = struct {
    op: WalOp,
    mbr: rtree.MBR,
    id: u64,
};

pub fn saveSnapshot(tree: *const rtree.RTree, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const header = Header{
        .magic = MAGIC.*,
        .version = 1,
        .M = tree.M,
        .count = tree.count,
        .height = tree.height,
    };

    try file.writeAll(std.mem.asBytes(&header));

    if (tree.root) |root| {
        try writeNode(file, root);
    }
}

fn writeNode(file: std.fs.File, node: *rtree.RTreeNode) !void {
    const record = NodeRecord{
        .is_leaf = if (node.is_leaf) 1 else 0,
        .level = node.level,
        .entry_count = @intCast(node.entries.items.len),
    };

    try file.writeAll(std.mem.asBytes(&record));

    for (node.entries.items) |entry| {
        const entry_record = EntryRecord{
            .min_x = entry.mbr.min_x,
            .min_y = entry.mbr.min_y,
            .max_x = entry.mbr.max_x,
            .max_y = entry.mbr.max_y,
            .id = entry.id,
            .has_child = if (entry.child != null) 1 else 0,
        };

        try file.writeAll(std.mem.asBytes(&entry_record));
    }

    for (node.entries.items) |entry| {
        if (entry.child) |child| {
            try writeNode(file, child);
        }
    }
}

pub fn loadSnapshot(allocator: std.mem.Allocator, path: []const u8) !rtree.RTree {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: Header = undefined;
    _ = try file.read(std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
    if (header.version != 1) return error.InvalidVersion;

    var tree = rtree.RTree.init(allocator, header.M);
    tree.count = header.count;
    tree.height = header.height;

    if (header.height > 0) {
        tree.root = try readNode(allocator, file);
    }

    return tree;
}

fn readNode(allocator: std.mem.Allocator, file: std.fs.File) !*rtree.RTreeNode {
    var record: NodeRecord = undefined;
    _ = try file.read(std.mem.asBytes(&record));

    var node = try allocator.create(rtree.RTreeNode);
    node.* = rtree.RTreeNode.init(allocator, record.is_leaf != 0, record.level);

    var entries = try allocator.alloc(EntryRecord, record.entry_count);
    defer allocator.free(entries);

    for (entries) |*entry| {
        _ = try file.read(std.mem.asBytes(entry));
    }

    for (entries) |entry_record| {
        var entry = rtree.RTreeEntry{
            .mbr = .{
                .min_x = entry_record.min_x,
                .min_y = entry_record.min_y,
                .max_x = entry_record.max_x,
                .max_y = entry_record.max_y,
            },
            .id = entry_record.id,
            .child = null,
        };

        if (entry_record.has_child != 0) {
            entry.child = try readNode(allocator, file);
        }

        try node.entries.append(entry);
    }

    return node;
}

pub fn appendWal(path: []const u8, entry: WalEntry) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);

    try file.writeAll(&[_]u8{@intFromEnum(entry.op)});
    try file.writeAll(std.mem.asBytes(&entry.mbr));
    try file.writeAll(std.mem.asBytes(&entry.id));
}

pub fn replayWal(tree: *rtree.RTree, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    while (true) {
        var op_byte: [1]u8 = undefined;
        if (try file.read(&op_byte) == 0) break;

        const op = std.meta.intToEnum(WalOp, op_byte[0]) catch return error.InvalidWalOp;

        var mbr: rtree.MBR = undefined;
        _ = try file.read(std.mem.asBytes(&mbr));

        var id: u64 = undefined;
        _ = try file.read(std.mem.asBytes(&id));

        switch (op) {
            .INSERT => try tree.insert(mbr, id),
            .DELETE => _ = tree.remove(mbr, id),
        }
    }
}

pub fn checkpoint(tree: *const rtree.RTree, snapshot_path: []const u8, wal_path: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(tree.allocator, "{s}.tmp", .{snapshot_path});
    defer tree.allocator.free(temp_path);

    try saveSnapshot(tree, temp_path);

    try std.fs.cwd().rename(temp_path, snapshot_path);

    if (std.fs.cwd().openFile(wal_path, .{ .mode = .write_only })) |file| {
        file.close();
        try std.fs.cwd().deleteFile(wal_path);
    } else |_| {}

    _ = try std.fs.cwd().createFile(wal_path, .{});
}
