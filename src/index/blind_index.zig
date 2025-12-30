const std = @import("std");
const hmac_mod = @import("fle_hmac");

// CANARY: FLE_BLIND_INDEX - Blind Index for Searchable Encrypted Fields
// CANARY: REQ=REQ-FLE-BI-002; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

pub const BlindIndexToken = [32]u8;

/// Blind index entry mapping token to record IDs
const IndexEntry = struct {
    token: BlindIndexToken,
    record_ids: std.ArrayList([]const u8),

    pub fn deinit(self: *IndexEntry, allocator: std.mem.Allocator) void {
        for (self.record_ids.items) |id| {
            allocator.free(id);
        }
        self.record_ids.deinit();
    }
};

/// Blind index for encrypted field equality search
/// Maps HMAC(BIK, normalize(plaintext)) → [record_ids]
pub const BlindIndex = struct {
    allocator: std.mem.Allocator,
    // Map: "schema.field" → Map[token → [record_ids]]
    indices: std.StringHashMap(std.AutoHashMap(BlindIndexToken, std.ArrayList([]const u8))),

    pub fn init(allocator: std.mem.Allocator) BlindIndex {
        return .{
            .allocator = allocator,
            .indices = std.StringHashMap(std.AutoHashMap(BlindIndexToken, std.ArrayList([]const u8))).init(allocator),
        };
    }

    pub fn deinit(self: *BlindIndex) void {
        var it = self.indices.iterator();
        while (it.next()) |entry| {
            // Free the field key (outer StringHashMap key)
            self.allocator.free(entry.key_ptr.*);

            // Free inner AutoHashMap contents
            var token_map_it = entry.value_ptr.iterator();
            while (token_map_it.next()) |token_entry| {
                for (token_entry.value_ptr.items) |id| {
                    self.allocator.free(id);
                }
                token_entry.value_ptr.deinit(self.allocator);
            }
            entry.value_ptr.deinit();
        }
        self.indices.deinit();
    }

    /// Build field key from schema and field name
    fn buildFieldKey(allocator: std.mem.Allocator, schema: []const u8, field: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema, field });
    }

    /// Add or update blind index entry for a field value
    pub fn put(
        self: *BlindIndex,
        schema: []const u8,
        field: []const u8,
        bik: [32]u8,
        plaintext: []const u8,
        record_id: []const u8,
    ) !void {
        const field_key = try buildFieldKey(self.allocator, schema, field);
        defer self.allocator.free(field_key);

        // Normalize and compute token
        const normalized = try hmac_mod.normalizeForBlindIndex(self.allocator, plaintext);
        defer self.allocator.free(normalized);

        var token: BlindIndexToken = undefined;
        hmac_mod.blindIndexHmac256(&token, &bik, normalized);

        // Get or create token map for this field
        const gop = try self.indices.getOrPut(field_key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, field_key);
            gop.value_ptr.* = std.AutoHashMap(BlindIndexToken, std.ArrayList([]const u8)).init(self.allocator);
        }

        var token_map = gop.value_ptr;

        // Get or create record list for this token
        const token_gop = try token_map.getOrPut(token);
        if (!token_gop.found_existing) {
            token_gop.value_ptr.* = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch @panic("OOM");
        }

        // Add record ID (check for duplicates)
        for (token_gop.value_ptr.items) |existing_id| {
            if (std.mem.eql(u8, existing_id, record_id)) {
                return; // Already indexed
            }
        }

        const owned_id = try self.allocator.dupe(u8, record_id);
        try token_gop.value_ptr.append(self.allocator, owned_id);
    }

    /// Lookup record IDs matching a plaintext value
    pub fn lookup(
        self: *BlindIndex,
        schema: []const u8,
        field: []const u8,
        bik: [32]u8,
        plaintext: []const u8,
    ) !?[]const []const u8 {
        const field_key = try buildFieldKey(self.allocator, schema, field);
        defer self.allocator.free(field_key);

        // Get token map for this field
        const token_map = self.indices.get(field_key) orelse return null;

        // Normalize and compute token
        const normalized = try hmac_mod.normalizeForBlindIndex(self.allocator, plaintext);
        defer self.allocator.free(normalized);

        var token: BlindIndexToken = undefined;
        hmac_mod.blindIndexHmac256(&token, &bik, normalized);

        // Lookup token
        if (token_map.get(token)) |record_ids| {
            return record_ids.items;
        }

        return null;
    }

    /// Remove a record from all indices for a field
    pub fn remove(
        self: *BlindIndex,
        schema: []const u8,
        field: []const u8,
        record_id: []const u8,
    ) !void {
        const field_key = try buildFieldKey(self.allocator, schema, field);
        defer self.allocator.free(field_key);

        if (self.indices.getPtr(field_key)) |token_map| {
            var it = token_map.iterator();
            while (it.next()) |entry| {
                var i: usize = 0;
                while (i < entry.value_ptr.items.len) {
                    if (std.mem.eql(u8, entry.value_ptr.items[i], record_id)) {
                        const removed_id = entry.value_ptr.swapRemove(i);
                        self.allocator.free(removed_id);
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }
};

test "BlindIndex put and lookup" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    std.crypto.random.bytes(&bik);

    // Index two records with same email
    try index.put("Person", "email", bik, "alice@example.com", "person1");
    try index.put("Person", "email", bik, "alice@example.com", "person2");
    try index.put("Person", "email", bik, "bob@example.com", "person3");

    // Lookup Alice's email
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 2), results.?.len);

    // Lookup Bob's email
    const results2 = try index.lookup("Person", "email", bik, "bob@example.com");
    try testing.expect(results2 != null);
    try testing.expectEqual(@as(usize, 1), results2.?.len);
    try testing.expectEqualStrings("person3", results2.?[0]);

    // Lookup non-existent email
    const results3 = try index.lookup("Person", "email", bik, "charlie@example.com");
    try testing.expect(results3 == null);
}

test "BlindIndex normalization handles case and whitespace" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    std.crypto.random.bytes(&bik);

    // Index with different casing/whitespace
    try index.put("Person", "email", bik, "  Alice@EXAMPLE.com  ", "person1");

    // Lookup with different format - should still match
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 1), results.?.len);
    try testing.expectEqualStrings("person1", results.?[0]);
}

test "BlindIndex remove" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = BlindIndex.init(allocator);
    defer index.deinit();

    var bik: [32]u8 = undefined;
    std.crypto.random.bytes(&bik);

    try index.put("Person", "email", bik, "alice@example.com", "person1");
    try index.put("Person", "email", bik, "alice@example.com", "person2");

    // Remove one record
    try index.remove("Person", "email", "person1");

    // Should only have person2 now
    const results = try index.lookup("Person", "email", bik, "alice@example.com");
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 1), results.?.len);
    try testing.expectEqualStrings("person2", results.?[0]);
}
