const std = @import("std");
const DomainTrie = @import("domain_trie.zig").DomainTrie;

const DOMAIN_MAGIC = "GDDN";
const DOMAIN_VERSION: u16 = 1;

pub fn persistSnapshot(trie: *DomainTrie, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(DOMAIN_MAGIC);

    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, DOMAIN_VERSION, .little);
    try file.writeAll(&version_buf);

    const node_count = countNodes(trie.root);
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, node_count, .little);
    try file.writeAll(&count_buf);

    try writeNodes(file, trie.root);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, file_path: []const u8) !DomainTrie {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Read and validate magic number
    var magic: [4]u8 = undefined;
    _ = try file.read(&magic);
    if (!std.mem.eql(u8, &magic, DOMAIN_MAGIC)) return error.InvalidMagic;

    // Read version
    var version_buf: [2]u8 = undefined;
    _ = try file.read(&version_buf);
    const version = std.mem.readInt(u16, &version_buf, .little);
    if (version != DOMAIN_VERSION) return error.UnsupportedVersion;

    // Read node count
    var count_buf: [8]u8 = undefined;
    _ = try file.read(&count_buf);
    const node_count = std.mem.readInt(u64, &count_buf, .little);
    _ = node_count;

    var trie = DomainTrie.init(allocator);

    trie.root = try readNodes(allocator, file);

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

fn writeNodes(file: std.fs.File, node: ?*DomainTrie.Node) !void {
    if (node == null) {
        const zero: [1]u8 = .{0};
        try file.writeAll(&zero);
        return;
    }

    const one: [1]u8 = .{1};
    try file.writeAll(&one);
    const n = node.?;

    var label_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &label_len_buf, @intCast(n.label.len), .little);
    try file.writeAll(&label_len_buf);
    try file.writeAll(n.label);

    const terminal_byte: [1]u8 = .{if (n.is_terminal) 1 else 0};
    try file.writeAll(&terminal_byte);

    if (n.is_terminal) {
        const has_data_byte: [1]u8 = .{if (n.data != null) 1 else 0};
        try file.writeAll(&has_data_byte);
        if (n.data) |data| {
            var data_buf: [8]u8 = undefined;
            std.mem.writeInt(usize, &data_buf, data, .little);
            try file.writeAll(&data_buf);
        }
    }

    var child_count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &child_count_buf, @intCast(n.children.count()), .little);
    try file.writeAll(&child_count_buf);

    var iter = n.children.iterator();
    while (iter.next()) |entry| {
        var key_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &key_len_buf, @intCast(entry.key_ptr.len), .little);
        try file.writeAll(&key_len_buf);
        try file.writeAll(entry.key_ptr.*);
        try writeNodes(file, entry.value_ptr.*);
    }
}

fn readNodes(allocator: std.mem.Allocator, file: std.fs.File) !?*DomainTrie.Node {
    var has_node_buf: [1]u8 = undefined;
    _ = try file.read(&has_node_buf);
    if (has_node_buf[0] == 0) return null;

    // Read label length
    var label_len_buf: [4]u8 = undefined;
    _ = try file.read(&label_len_buf);
    const label_len = std.mem.readInt(u32, &label_len_buf, .little);

    const label = try allocator.alloc(u8, label_len);
    _ = try file.read(label);

    const node = try DomainTrie.Node.init(allocator, label);
    allocator.free(label);

    // Read is_terminal flag
    var terminal_buf: [1]u8 = undefined;
    _ = try file.read(&terminal_buf);
    node.is_terminal = terminal_buf[0] != 0;

    if (node.is_terminal) {
        var has_data_buf: [1]u8 = undefined;
        _ = try file.read(&has_data_buf);
        const has_data = has_data_buf[0] != 0;
        if (has_data) {
            var data_buf: [8]u8 = undefined;
            _ = try file.read(&data_buf);
            node.data = std.mem.readInt(usize, &data_buf, .little);
        }
    }

    // Read child count
    var child_count_buf: [4]u8 = undefined;
    _ = try file.read(&child_count_buf);
    const child_count = std.mem.readInt(u32, &child_count_buf, .little);

    for (0..child_count) |_| {
        // Read key length
        var key_len_buf: [4]u8 = undefined;
        _ = try file.read(&key_len_buf);
        const key_len = std.mem.readInt(u32, &key_len_buf, .little);

        const key = try allocator.alloc(u8, key_len);
        _ = try file.read(key);

        const child = try readNodes(allocator, file);
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
