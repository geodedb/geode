const std = @import("std");
const patricia = @import("patricia.zig");
const heap = @import("../storage/heap.zig");

const MAGIC = "GDXP";

pub const Header = extern struct {
    magic: [4]u8,
    version: u16,
    family: u8,
    node_count: u64,
    key_count: u64,
};

pub const NodeRecord = extern struct {
    bit_index: u16,
    prefix_len: u16,
    child0_off: u64,
    child1_off: u64,
    payload_count: u32,
};

pub const WalOp = enum(u8) {
    PUT = 1,
    DEL = 2,
};

pub const WalEntry = struct {
    op: WalOp,
    subnet: heap.Subnet,
    payload: u64,
};

pub fn saveSnapshot(trie: *const patricia.PatriciaTrie, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    const header = Header{
        .magic = MAGIC.*,
        .version = 1,
        .family = @intFromEnum(trie.family),
        .node_count = trie.node_count,
        .key_count = trie.key_count,
    };
    
    try file.writeAll(std.mem.asBytes(&header));
    
    if (trie.root) |root| {
        try writeNode(file, root);
    }
}

fn writeNode(file: std.fs.File, node: *patricia.PatriciaNode) !void {
    const record = NodeRecord{
        .bit_index = node.bit_index,
        .prefix_len = node.prefix_len,
        .child0_off = if (node.child0 != null) 1 else 0,
        .child1_off = if (node.child1 != null) 1 else 0,
        .payload_count = @intCast(node.payload.items.len),
    };
    
    try file.writeAll(std.mem.asBytes(&record));
    
    for (node.payload.items) |payload| {
        try file.writeAll(std.mem.asBytes(&payload));
    }
    
    if (node.child0) |child| try writeNode(file, child);
    if (node.child1) |child| try writeNode(file, child);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, path: []const u8) !patricia.PatriciaTrie {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    var header: Header = undefined;
    _ = try file.read(std.mem.asBytes(&header));
    
    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
    if (header.version != 1) return error.InvalidVersion;
    
    const family = std.meta.intToEnum(patricia.PatriciaTrie.Family, header.family) catch return error.InvalidFamily;
    
    var trie = patricia.PatriciaTrie.init(allocator, family);
    trie.node_count = header.node_count;
    trie.key_count = header.key_count;
    
    if (header.node_count > 0) {
        trie.root = try readNode(allocator, file);
    }
    
    return trie;
}

fn readNode(allocator: std.mem.Allocator, file: std.fs.File) !*patricia.PatriciaNode {
    var record: NodeRecord = undefined;
    _ = try file.read(std.mem.asBytes(&record));
    
    var node = try allocator.create(patricia.PatriciaNode);
    node.* = patricia.PatriciaNode.init(allocator);
    node.bit_index = record.bit_index;
    node.prefix_len = record.prefix_len;
    
    var i: u32 = 0;
    while (i < record.payload_count) : (i += 1) {
        var payload: u64 = undefined;
        _ = try file.read(std.mem.asBytes(&payload));
        try node.payload.append(payload);
    }
    
    if (record.child0_off != 0) {
        node.child0 = try readNode(allocator, file);
    }
    if (record.child1_off != 0) {
        node.child1 = try readNode(allocator, file);
    }
    
    return node;
}

pub fn appendWal(path: []const u8, entry: WalEntry) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    
    try file.writeAll(&[_]u8{@intFromEnum(entry.op)});
    
    const subnet_bytes = try heap.encodeValue(std.heap.page_allocator, .{ .Subnet = entry.subnet });
    defer std.heap.page_allocator.free(subnet_bytes);
    
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(subnet_bytes.len), .little);
    try file.writeAll(&len_buf);
    try file.writeAll(subnet_bytes);
    
    try file.writeAll(std.mem.asBytes(&entry.payload));
}

pub fn replayWal(trie: *patricia.PatriciaTrie, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    while (true) {
        var op_byte: [1]u8 = undefined;
        if (try file.read(&op_byte) == 0) break;
        
        const op = std.meta.intToEnum(WalOp, op_byte[0]) catch return error.InvalidWalOp;
        
        var len_buf: [4]u8 = undefined;
        _ = try file.read(&len_buf);
        const len = std.mem.readInt(u32, &len_buf, .little);
        
        const subnet_bytes = try trie.allocator.alloc(u8, len);
        defer trie.allocator.free(subnet_bytes);
        _ = try file.read(subnet_bytes);
        
        const val = try heap.decodeValue(trie.allocator, subnet_bytes);
        if (val != .Subnet) return error.InvalidWalEntry;
        
        var payload: u64 = undefined;
        _ = try file.read(std.mem.asBytes(&payload));
        
        switch (op) {
            .PUT => try trie.insert(val.Subnet, payload),
            .DEL => _ = trie.remove(val.Subnet, payload),
        }
    }
}

pub fn checkpoint(trie: *const patricia.PatriciaTrie, snapshot_path: []const u8, wal_path: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(trie.allocator, "{s}.tmp", .{snapshot_path});
    defer trie.allocator.free(temp_path);
    
    try saveSnapshot(trie, temp_path);
    
    try std.fs.cwd().rename(temp_path, snapshot_path);
    
    if (std.fs.cwd().openFile(wal_path, .{ .mode = .write_only })) |file| {
        file.close();
        try std.fs.cwd().deleteFile(wal_path);
    } else |_| {}
    
    _ = try std.fs.cwd().createFile(wal_path, .{});
}