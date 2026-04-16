const std = @import("std");
const patricia = @import("patricia.zig");
const tde = @import("../storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=PatriciaTrie; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

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

pub fn saveSnapshot(trie: *const patricia.PatriciaTrie, path: []const u8) !void {
    // Buffer all data to memory first for TDE encryption
    var buffer = try std.ArrayList(u8).initCapacity(trie.allocator, 4096);
    defer buffer.deinit(trie.allocator);

    const header = Header{
        .magic = MAGIC.*,
        .version = 1,
        .family = @intFromEnum(trie.family),
        .node_count = trie.node_count,
        .key_count = trie.key_count,
    };

    try buffer.appendSlice(trie.allocator, std.mem.asBytes(&header));

    if (trie.root) |root| {
        try writeNodeBuffer(trie.allocator, &buffer, root);
    }

    // Encrypt and write to file
    try tde.writeEncryptedFile(trie.allocator, path, buffer.items);
}

fn writeNodeBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), node: *patricia.PatriciaNode) !void {
    const record = NodeRecord{
        .bit_index = node.bit_index,
        .prefix_len = node.prefix_len,
        .child0_off = if (node.child0 != null) 1 else 0,
        .child1_off = if (node.child1 != null) 1 else 0,
        .payload_count = @intCast(node.payload.items.len),
    };

    try buffer.appendSlice(allocator, std.mem.asBytes(&record));

    for (node.payload.items) |payload| {
        try buffer.appendSlice(allocator, std.mem.asBytes(&payload));
    }

    if (node.child0) |child| try writeNodeBuffer(allocator, buffer, child);
    if (node.child1) |child| try writeNodeBuffer(allocator, buffer, child);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, path: []const u8) !patricia.PatriciaTrie {
    // Read and decrypt file using TDE
    const data = try tde.readDecryptedFile(allocator, path);
    defer allocator.free(data);

    // Create stream to read from decrypted data
    var stream = std.Io.fixedBufferStream(data);

    var header: Header = undefined;
    _ = try stream.reader().readAll(std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
    if (header.version != 1) return error.InvalidVersion;

    const family = std.meta.intToEnum(patricia.PatriciaTrie.Family, header.family) catch return error.InvalidFamily;

    var trie = patricia.PatriciaTrie.init(allocator, family);
    trie.node_count = header.node_count;
    trie.key_count = header.key_count;

    if (header.node_count > 0) {
        trie.root = try readNodeStream(allocator, &stream);
    }

    return trie;
}

fn readNodeStream(allocator: std.mem.Allocator, stream: anytype) !*patricia.PatriciaNode {
    var record: NodeRecord = undefined;
    _ = try stream.reader().readAll(std.mem.asBytes(&record));

    var node = try allocator.create(patricia.PatriciaNode);
    node.* = patricia.PatriciaNode.init(allocator);
    node.bit_index = record.bit_index;
    node.prefix_len = record.prefix_len;

    var i: u32 = 0;
    while (i < record.payload_count) : (i += 1) {
        var payload: u64 = undefined;
        _ = try stream.reader().readAll(std.mem.asBytes(&payload));
        try node.payload.append(payload);
    }

    if (record.child0_off != 0) {
        node.child0 = try readNodeStream(allocator, stream);
    }
    if (record.child1_off != 0) {
        node.child1 = try readNodeStream(allocator, stream);
    }

    return node;
}

pub fn checkpoint(trie: *const patricia.PatriciaTrie, snapshot_path: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(trie.allocator, "{s}.tmp", .{snapshot_path});
    defer trie.allocator.free(temp_path);

    try saveSnapshot(trie, temp_path);

    try std.Io.Dir.cwd().rename(temp_path, snapshot_path);
}
