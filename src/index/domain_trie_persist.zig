const std = @import("std");
const DomainTrie = @import("domain_trie.zig").DomainTrie;

const DOMAIN_MAGIC = "GDDN";
const DOMAIN_VERSION: u16 = 1;

pub fn persistSnapshot(trie: *DomainTrie, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll(DOMAIN_MAGIC);
    try writer.writeInt(u16, DOMAIN_VERSION, .little);

    const node_count = countNodes(trie.root);
    try writer.writeInt(u64, node_count, .little);

    try writeNodes(writer, trie.root);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, file_path: []const u8) !DomainTrie {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader();

    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, DOMAIN_MAGIC)) return error.InvalidMagic;

    const version = try reader.readInt(u16, .little);
    if (version != DOMAIN_VERSION) return error.UnsupportedVersion;

    const node_count = try reader.readInt(u64, .little);
    _ = node_count;

    var trie = DomainTrie.init(allocator);

    trie.root = try readNodes(allocator, reader);

    return trie;
}

fn countNodes(node: ?*DomainTrie.Node) u64 {
    if (node == null) return 0;
    var count: u64 = 1;
    var iter = node.?.children.iterator();
    while (iter.next()) |entry| {
        count += countNodes(entry.value_ptr.*);
    }
    return count;
}

fn writeNodes(writer: anytype, node: ?*DomainTrie.Node) !void {
    if (node == null) {
        try writer.writeByte(0);
        return;
    }

    try writer.writeByte(1);
    const n = node.?;

    try writer.writeInt(u32, @intCast(n.label.len), .little);
    try writer.writeAll(n.label);
    try writer.writeByte(if (n.is_terminal) 1 else 0);

    if (n.is_terminal) {
        try writer.writeByte(if (n.data != null) 1 else 0);
        if (n.data) |data| {
            try writer.writeInt(usize, data, .little);
        }
    }

    try writer.writeInt(u32, @intCast(n.children.count()), .little);

    var iter = n.children.iterator();
    while (iter.next()) |entry| {
        try writer.writeInt(u32, @intCast(entry.key_ptr.len), .little);
        try writer.writeAll(entry.key_ptr.*);
        try writeNodes(writer, entry.value_ptr.*);
    }
}

fn readNodes(allocator: std.mem.Allocator, reader: anytype) !?*DomainTrie.Node {
    const has_node = try reader.readByte();
    if (has_node == 0) return null;

    const label_len = try reader.readInt(u32, .little);
    const label = try allocator.alloc(u8, label_len);
    try reader.readNoEof(label);

    const node = try DomainTrie.Node.init(allocator, label);
    allocator.free(label);

    node.is_terminal = (try reader.readByte()) != 0;

    if (node.is_terminal) {
        const has_data = (try reader.readByte()) != 0;
        if (has_data) {
            node.data = try reader.readInt(usize, .little);
        }
    }

    const child_count = try reader.readInt(u32, .little);

    for (0..child_count) |_| {
        const key_len = try reader.readInt(u32, .little);
        const key = try allocator.alloc(u8, key_len);
        try reader.readNoEof(key);

        const child = try readNodes(allocator, reader);
        if (child) |c| {
            try node.children.put(key, c);
        } else {
            allocator.free(key);
        }
    }

    return node;
}

test "domain trie persistence" {
    const allocator = std.testing.allocator;
    var trie = DomainTrie.init(allocator);
    defer trie.deinit();

    const domain = try @import("../types/url.zig").Domain.fromString(allocator, "example.com");
    defer domain.deinit(allocator);

    try trie.insert(domain, 456);

    try persistSnapshot(&trie, "/tmp/test_domain.gddn");

    var loaded = try loadSnapshot(allocator, "/tmp/test_domain.gddn");
    defer loaded.deinit();

    const result = loaded.queryExact(domain);
    std.testing.expect(result.? == 456) catch unreachable;
}
