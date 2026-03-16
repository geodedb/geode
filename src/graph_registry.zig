const std = @import("std");
const tde = @import("storage/tde_file_encryption.zig");
const UuidV7 = @import("uuid.zig").UuidV7;
const crc = std.hash.crc;

// CANARY: REQ=REQ-MULTI-GRAPH-REGISTRY-001; FEATURE="PerGraphFileMapping"; ASPECT=GraphRegistry; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-16

/// Magic bytes identifying a graph registry file.
pub const MAGIC = "GEODREG1";
/// File format version.
pub const VERSION: u32 = 1;
/// Header size in bytes: magic(8) + version(4) + reserved(4) + next_node_id(8) + next_edge_id(8) + graph_count(8) + crc(4).
pub const HEADER_SIZE: usize = 44;

/// A single graph entry in the registry, mapping a name to a UUID and tracking counts.
pub const GraphEntry = struct {
    name: []const u8,
    uuid: [16]u8,
    node_count: u64,
    edge_count: u64,
};

/// Registry mapping graph names to UUIDv7 identifiers. Persists to disk with CRC32 validation.
pub const GraphRegistry = struct {
    allocator: std.mem.Allocator,
    next_node_id: u64 = 1,
    next_edge_id: u64 = 1,
    entries: std.ArrayList(GraphEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) GraphRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GraphRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    /// Add a new graph with the given name. Generates a UUIDv7 and returns its bytes.
    pub fn addGraph(self: *GraphRegistry, name: []const u8) ![16]u8 {
        const uuid = UuidV7.new();
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .uuid = uuid.bytes,
            .node_count = 0,
            .edge_count = 0,
        });
        return uuid.bytes;
    }

    /// Remove a graph entry by name. Returns true if found and removed.
    pub fn removeGraph(self: *GraphRegistry, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.allocator.free(entry.name);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Look up a graph entry by name.
    pub fn findByName(self: *const GraphRegistry, name: []const u8) ?GraphEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    /// Persist registry to disk with CRC32 validation and optional TDE encryption.
    pub fn saveToFile(self: *const GraphRegistry, path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // Write to temp file
        {
            const file = try std.fs.cwd().createFile(tmp_path, .{});
            defer file.close();

            var writer = file.deprecatedWriter();

            // Build header (CRC placeholder at offset 40)
            var header: [HEADER_SIZE]u8 = [_]u8{0} ** HEADER_SIZE;
            @memcpy(header[0..8], MAGIC);
            std.mem.writeInt(u32, header[8..12], VERSION, .little);
            std.mem.writeInt(u32, header[12..16], 0, .little); // reserved
            std.mem.writeInt(u64, header[16..24], self.next_node_id, .little);
            std.mem.writeInt(u64, header[24..32], self.next_edge_id, .little);
            std.mem.writeInt(u64, header[32..40], @intCast(self.entries.items.len), .little);
            // header[40..44] = CRC placeholder (patched below)
            try writer.writeAll(&header);

            // Write entries and compute CRC over header[0..40] + entry bytes
            var hasher = crc.Crc32.init();
            hasher.update(header[0..40]);

            for (self.entries.items) |entry| {
                var name_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &name_len_buf, @intCast(entry.name.len), .little);
                try writer.writeAll(&name_len_buf);
                hasher.update(&name_len_buf);

                try writer.writeAll(entry.name);
                hasher.update(entry.name);

                try writer.writeAll(&entry.uuid);
                hasher.update(&entry.uuid);

                var node_count_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &node_count_buf, entry.node_count, .little);
                try writer.writeAll(&node_count_buf);
                hasher.update(&node_count_buf);

                var edge_count_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &edge_count_buf, entry.edge_count, .little);
                try writer.writeAll(&edge_count_buf);
                hasher.update(&edge_count_buf);
            }

            // Patch CRC at offset 40
            const checksum = hasher.final();
            try file.seekTo(40);
            var crc_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &crc_buf, checksum, .little);
            try file.writeAll(&crc_buf);
        }

        // Finalize: TDE encrypt if enabled, otherwise atomic rename
        try finalizeTempFile(self.allocator, tmp_path, path);
    }

    /// Load registry from disk, decrypting with TDE if necessary.
    pub fn loadFromFile(self: *GraphRegistry, path: []const u8) !void {
        const data = tde.readDecryptedFile(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => return, // Fresh database — no registry file yet
            else => return err,
        };
        defer self.allocator.free(data);

        if (data.len < HEADER_SIZE) return error.CorruptedFile;

        // Validate magic
        if (!std.mem.eql(u8, data[0..8], MAGIC)) return error.InvalidMagic;

        // Validate version
        const version = std.mem.readInt(u32, data[8..12], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        // Read header fields
        self.next_node_id = std.mem.readInt(u64, data[16..24], .little);
        self.next_edge_id = std.mem.readInt(u64, data[24..32], .little);
        const graph_count = std.mem.readInt(u64, data[32..40], .little);
        const stored_crc = std.mem.readInt(u32, data[40..44], .little);

        // Verify CRC: hash header[0..40] + all entry bytes
        var hasher = crc.Crc32.init();
        hasher.update(data[0..40]);
        hasher.update(data[HEADER_SIZE..]);
        const computed_crc = hasher.final();
        if (computed_crc != stored_crc) return error.CrcMismatch;

        // Parse entries
        var offset: usize = HEADER_SIZE;
        var i: u64 = 0;
        while (i < graph_count) : (i += 1) {
            if (offset + 4 > data.len) return error.CorruptedFile;
            const name_len = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            if (offset + name_len > data.len) return error.CorruptedFile;
            const name = try self.allocator.dupe(u8, data[offset..][0..name_len]);
            errdefer self.allocator.free(name);
            offset += name_len;

            if (offset + 16 + 8 + 8 > data.len) return error.CorruptedFile;
            var uuid: [16]u8 = undefined;
            @memcpy(&uuid, data[offset..][0..16]);
            offset += 16;

            const node_count = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            const edge_count = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            try self.entries.append(self.allocator, .{
                .name = name,
                .uuid = uuid,
                .node_count = node_count,
                .edge_count = edge_count,
            });
        }
    }

    /// Finalize a temp file: apply TDE encryption if enabled, then atomically
    /// rename to the final path.
    fn finalizeTempFile(allocator: std.mem.Allocator, tmp_path: []const u8, final_path: []const u8) !void {
        if (tde.isEnabled(allocator)) {
            const plaintext = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 30);
            defer allocator.free(plaintext);

            try tde.writeEncryptedFile(allocator, final_path, plaintext);

            // Remove temp file after successful encryption
            std.fs.cwd().deleteFile(tmp_path) catch {};
        } else {
            try std.fs.cwd().rename(tmp_path, final_path);
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "GraphRegistry round-trip save and load" {
    const allocator = std.testing.allocator;

    const path = "test_graph_registry_roundtrip.dat";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile("test_graph_registry_roundtrip.dat.tmp") catch {};

    // Create and populate a registry
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    reg.next_node_id = 42;
    reg.next_edge_id = 99;

    const uuid1 = try reg.addGraph("social");
    const uuid2 = try reg.addGraph("finance");

    // Set some counts
    reg.entries.items[0].node_count = 100;
    reg.entries.items[0].edge_count = 200;
    reg.entries.items[1].node_count = 50;
    reg.entries.items[1].edge_count = 75;

    try reg.saveToFile(path);

    // Load into a fresh registry
    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();

    try reg2.loadFromFile(path);

    try std.testing.expectEqual(@as(u64, 42), reg2.next_node_id);
    try std.testing.expectEqual(@as(u64, 99), reg2.next_edge_id);
    try std.testing.expectEqual(@as(usize, 2), reg2.entries.items.len);

    const e1 = reg2.entries.items[0];
    try std.testing.expectEqualStrings("social", e1.name);
    try std.testing.expectEqualSlices(u8, &uuid1, &e1.uuid);
    try std.testing.expectEqual(@as(u64, 100), e1.node_count);
    try std.testing.expectEqual(@as(u64, 200), e1.edge_count);

    const e2 = reg2.entries.items[1];
    try std.testing.expectEqualStrings("finance", e2.name);
    try std.testing.expectEqualSlices(u8, &uuid2, &e2.uuid);
    try std.testing.expectEqual(@as(u64, 50), e2.node_count);
    try std.testing.expectEqual(@as(u64, 75), e2.edge_count);
}

test "GraphRegistry CRC validation rejects corrupt data" {
    const allocator = std.testing.allocator;

    const path = "test_graph_registry_crc.dat";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile("test_graph_registry_crc.dat.tmp") catch {};

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    _ = try reg.addGraph("test");
    try reg.saveToFile(path);

    // Corrupt a byte in the file
    {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        try file.seekTo(HEADER_SIZE + 2); // corrupt inside entry data
        try file.writeAll("X");
    }

    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();

    const result = reg2.loadFromFile(path);
    try std.testing.expectError(error.CrcMismatch, result);
}

test "GraphRegistry removeGraph" {
    const allocator = std.testing.allocator;

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    _ = try reg.addGraph("alpha");
    _ = try reg.addGraph("beta");
    _ = try reg.addGraph("gamma");

    try std.testing.expectEqual(@as(usize, 3), reg.entries.items.len);

    // Remove middle entry
    try std.testing.expect(reg.removeGraph("beta"));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    try std.testing.expectEqualStrings("alpha", reg.entries.items[0].name);
    try std.testing.expectEqualStrings("gamma", reg.entries.items[1].name);

    // Remove non-existent
    try std.testing.expect(!reg.removeGraph("nonexistent"));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
}

test "GraphRegistry findByName returns null for missing graph" {
    const allocator = std.testing.allocator;

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    _ = try reg.addGraph("exists");

    const found = reg.findByName("exists");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("exists", found.?.name);

    const not_found = reg.findByName("missing");
    try std.testing.expect(not_found == null);
}

test "GraphRegistry empty save and load" {
    const allocator = std.testing.allocator;

    const path = "test_graph_registry_empty.dat";
    defer std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile("test_graph_registry_empty.dat.tmp") catch {};

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    try reg.saveToFile(path);

    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();

    try reg2.loadFromFile(path);

    try std.testing.expectEqual(@as(u64, 1), reg2.next_node_id);
    try std.testing.expectEqual(@as(u64, 1), reg2.next_edge_id);
    try std.testing.expectEqual(@as(usize, 0), reg2.entries.items.len);
}

test "GraphRegistry loadFromFile returns silently on missing file" {
    const allocator = std.testing.allocator;

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    // Should not error — fresh database
    try reg.loadFromFile("nonexistent_registry_file.dat");

    try std.testing.expectEqual(@as(u64, 1), reg.next_node_id);
    try std.testing.expectEqual(@as(usize, 0), reg.entries.items.len);
}
