const std = @import("std");
const DomainTrie = @import("domain_trie.zig").DomainTrie;
const tde = @import("../storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=DomainTrie; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

const DOMAIN_MAGIC = "GDDN";
const DOMAIN_VERSION: u16 = 1;

pub fn persistSnapshot(trie: *DomainTrie, file_path: []const u8) !void {
    // Buffer all data to memory first for TDE encryption
    var buffer = try std.ArrayList(u8).initCapacity(trie.allocator, 4096);
    defer buffer.deinit(trie.allocator);

    try buffer.appendSlice(trie.allocator, DOMAIN_MAGIC);

    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, DOMAIN_VERSION, .little);
    try buffer.appendSlice(trie.allocator, &version_buf);

    const node_count = countNodes(trie.root);
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, node_count, .little);
    try buffer.appendSlice(trie.allocator, &count_buf);

    try writeNodesBuffer(trie.allocator, &buffer, trie.root);

    // Encrypt and write to file
    try tde.writeEncryptedFile(trie.allocator, file_path, buffer.items);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, file_path: []const u8) !DomainTrie {
    // Read and decrypt file using TDE
    const data = try tde.readDecryptedFile(allocator, file_path);
    defer allocator.free(data);

    // Create stream to read from decrypted data
    var stream = std.io.fixedBufferStream(data);

    // Read and validate magic number
    var magic: [4]u8 = undefined;
    _ = try stream.reader().readAll(&magic);
    if (!std.mem.eql(u8, &magic, DOMAIN_MAGIC)) return error.InvalidMagic;

    // Read version
    var version_buf: [2]u8 = undefined;
    _ = try stream.reader().readAll(&version_buf);
    const version = std.mem.readInt(u16, &version_buf, .little);
    if (version != DOMAIN_VERSION) return error.UnsupportedVersion;

    // Read node count
    var count_buf: [8]u8 = undefined;
    _ = try stream.reader().readAll(&count_buf);
    const node_count = std.mem.readInt(u64, &count_buf, .little);
    _ = node_count;

    var trie = DomainTrie.init(allocator);

    trie.root = try readNodesStream(allocator, &stream);

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

fn writeNodesBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), node: ?*DomainTrie.Node) !void {
    if (node == null) {
        const zero: [1]u8 = .{0};
        try buffer.appendSlice(allocator, &zero);
        return;
    }

    const one: [1]u8 = .{1};
    try buffer.appendSlice(allocator, &one);
    const n = node.?;

    var label_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &label_len_buf, @intCast(n.label.len), .little);
    try buffer.appendSlice(allocator, &label_len_buf);
    try buffer.appendSlice(allocator, n.label);

    const terminal_byte: [1]u8 = .{if (n.is_terminal) 1 else 0};
    try buffer.appendSlice(allocator, &terminal_byte);

    if (n.is_terminal) {
        const has_data_byte: [1]u8 = .{if (n.data != null) 1 else 0};
        try buffer.appendSlice(allocator, &has_data_byte);
        if (n.data) |node_data| {
            var data_buf: [8]u8 = undefined;
            std.mem.writeInt(usize, &data_buf, node_data, .little);
            try buffer.appendSlice(allocator, &data_buf);
        }
    }

    var child_count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &child_count_buf, @intCast(n.children.count()), .little);
    try buffer.appendSlice(allocator, &child_count_buf);

    var iter = n.children.iterator();
    while (iter.next()) |entry| {
        var key_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &key_len_buf, @intCast(entry.key_ptr.len), .little);
        try buffer.appendSlice(allocator, &key_len_buf);
        try buffer.appendSlice(allocator, entry.key_ptr.*);
        try writeNodesBuffer(allocator, buffer, entry.value_ptr.*);
    }
}

fn readNodesStream(allocator: std.mem.Allocator, stream: anytype) !?*DomainTrie.Node {
    var has_node_buf: [1]u8 = undefined;
    _ = try stream.reader().readAll(&has_node_buf);
    if (has_node_buf[0] == 0) return null;

    // Read label length
    var label_len_buf: [4]u8 = undefined;
    _ = try stream.reader().readAll(&label_len_buf);
    const label_len = std.mem.readInt(u32, &label_len_buf, .little);

    const label = try allocator.alloc(u8, label_len);
    _ = try stream.reader().readAll(label);

    const node = try DomainTrie.Node.init(allocator, label);
    allocator.free(label);

    // Read is_terminal flag
    var terminal_buf: [1]u8 = undefined;
    _ = try stream.reader().readAll(&terminal_buf);
    node.is_terminal = terminal_buf[0] != 0;

    if (node.is_terminal) {
        var has_data_buf: [1]u8 = undefined;
        _ = try stream.reader().readAll(&has_data_buf);
        const has_data = has_data_buf[0] != 0;
        if (has_data) {
            var data_buf: [8]u8 = undefined;
            _ = try stream.reader().readAll(&data_buf);
            node.data = std.mem.readInt(usize, &data_buf, .little);
        }
    }

    // Read child count
    var child_count_buf: [4]u8 = undefined;
    _ = try stream.reader().readAll(&child_count_buf);
    const child_count = std.mem.readInt(u32, &child_count_buf, .little);

    for (0..child_count) |_| {
        // Read key length
        var key_len_buf: [4]u8 = undefined;
        _ = try stream.reader().readAll(&key_len_buf);
        const key_len = std.mem.readInt(u32, &key_len_buf, .little);

        const key = try allocator.alloc(u8, key_len);
        _ = try stream.reader().readAll(key);

        const child = try readNodesStream(allocator, stream);
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
