const std = @import("std");

// CANARY: REQ=REQ-GQL-NET-TYPES-003; FEATURE="Mac Address Type"; ASPECT=Types; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_NET_TYPES_003_Mac; OWNER=types; UPDATED=2025-01-03

/// MAC address (EUI-48) implementation
/// Stores 6-byte hardware addresses with format validation and OUI extraction
pub const Mac = struct {
    octets: [6]u8,

    pub fn fromString(mac_str: []const u8) !Mac {
        // Support multiple formats: AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, AABBCCDDEEFF
        const clean_str = if (std.mem.indexOf(u8, mac_str, ":") != null or
            std.mem.indexOf(u8, mac_str, "-") != null)
        blk: {
            // Remove separators for consistent parsing
            var clean_buf: [12]u8 = undefined;
            var clean_idx: usize = 0;
            for (mac_str) |c| {
                if (c != ':' and c != '-') {
                    if (clean_idx >= 12) return error.InvalidMacFormat;
                    clean_buf[clean_idx] = c;
                    clean_idx += 1;
                }
            }
            if (clean_idx != 12) return error.InvalidMacFormat;
            break :blk clean_buf[0..12];
        } else if (mac_str.len == 12) mac_str else return error.InvalidMacFormat;

        if (clean_str.len != 12) return error.InvalidMacFormat;

        var octets: [6]u8 = undefined;
        for (0..6) |i| {
            const hex_pair = clean_str[i * 2 .. i * 2 + 2];
            octets[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return error.InvalidMacFormat;
        }

        return Mac{ .octets = octets };
    }

    pub fn toString(self: Mac, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.octets[0], self.octets[1], self.octets[2],
            self.octets[3], self.octets[4], self.octets[5],
        });
    }

    pub fn toStringUppercase(self: Mac, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            self.octets[0], self.octets[1], self.octets[2],
            self.octets[3], self.octets[4], self.octets[5],
        });
    }

    pub fn toStringCompact(self: Mac, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            self.octets[0], self.octets[1], self.octets[2],
            self.octets[3], self.octets[4], self.octets[5],
        });
    }

    /// Extract OUI (Organizationally Unique Identifier) from first 3 octets
    pub fn getOui(self: Mac) [3]u8 {
        return [3]u8{ self.octets[0], self.octets[1], self.octets[2] };
    }

    /// Get NIC-specific part (last 3 octets)
    pub fn getNicSpecific(self: Mac) [3]u8 {
        return [3]u8{ self.octets[3], self.octets[4], self.octets[5] };
    }

    /// Check if this is a unicast address (not multicast)
    pub fn isUnicast(self: Mac) bool {
        return (self.octets[0] & 0x01) == 0;
    }

    /// Check if this is a multicast address
    pub fn isMulticast(self: Mac) bool {
        return (self.octets[0] & 0x01) == 1;
    }

    /// Check if this is a locally administered address
    pub fn isLocallyAdministered(self: Mac) bool {
        return (self.octets[0] & 0x02) == 0x02;
    }

    /// Check if this is a globally unique address (not locally administered)
    pub fn isGloballyUnique(self: Mac) bool {
        return (self.octets[0] & 0x02) == 0;
    }

    /// Check if this is a broadcast address (FF:FF:FF:FF:FF:FF)
    pub fn isBroadcast(self: Mac) bool {
        for (self.octets) |octet| {
            if (octet != 0xFF) return false;
        }
        return true;
    }

    /// Check if this is a null address (00:00:00:00:00:00)
    pub fn isNull(self: Mac) bool {
        for (self.octets) |octet| {
            if (octet != 0x00) return false;
        }
        return true;
    }

    /// Generate a random MAC address with specified OUI
    pub fn randomWithOui(oui: [3]u8, rng: std.Random) Mac {
        var octets: [6]u8 = undefined;
        octets[0] = oui[0];
        octets[1] = oui[1];
        octets[2] = oui[2];
        octets[3] = rng.int(u8);
        octets[4] = rng.int(u8);
        octets[5] = rng.int(u8);
        return Mac{ .octets = octets };
    }

    /// Binary encoding for storage
    pub fn encode(self: Mac, writer: anytype) !void {
        try writer.writeByte(0x08); // MAC address tag
        try writer.writeAll(&self.octets);
    }

    pub fn decode(reader: anytype) !Mac {
        const tag = try reader.readByte();
        if (tag != 0x08) return error.InvalidMacTag;

        var octets: [6]u8 = undefined;
        try reader.readNoEof(&octets);
        return Mac{ .octets = octets };
    }

    /// Compare two MAC addresses for equality
    pub fn eql(self: Mac, other: Mac) bool {
        return std.mem.eql(u8, &self.octets, &other.octets);
    }

    /// Compare MAC addresses for ordering (lexicographic)
    pub fn order(self: Mac, other: Mac) std.math.Order {
        return std.mem.order(u8, &self.octets, &other.octets);
    }
};

// Test suite
test "MAC address parsing and formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test colon-separated format
    const mac1 = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    try testing.expectEqual([6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, mac1.octets);

    // Test hyphen-separated format
    const mac2 = try Mac.fromString("aa-bb-cc-dd-ee-ff");
    try testing.expectEqual([6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, mac2.octets);

    // Test compact format
    const mac3 = try Mac.fromString("AABBCCDDEEFF");
    try testing.expectEqual([6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, mac3.octets);

    // Test string representation
    const mac_str = try mac1.toString(allocator);
    defer allocator.free(mac_str);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", mac_str);

    const mac_str_upper = try mac1.toStringUppercase(allocator);
    defer allocator.free(mac_str_upper);
    try testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", mac_str_upper);

    const mac_str_compact = try mac1.toStringCompact(allocator);
    defer allocator.free(mac_str_compact);
    try testing.expectEqualStrings("aabbccddeeff", mac_str_compact);
}

test "MAC address properties" {
    const testing = std.testing;

    // Test unicast/multicast detection
    const unicast_mac = try Mac.fromString("00:11:22:33:44:55");
    const multicast_mac = try Mac.fromString("01:11:22:33:44:55");

    try testing.expect(unicast_mac.isUnicast());
    try testing.expect(!unicast_mac.isMulticast());
    try testing.expect(!multicast_mac.isUnicast());
    try testing.expect(multicast_mac.isMulticast());

    // Test locally administered detection
    const global_mac = try Mac.fromString("00:11:22:33:44:55");
    const local_mac = try Mac.fromString("02:11:22:33:44:55");

    try testing.expect(global_mac.isGloballyUnique());
    try testing.expect(!global_mac.isLocallyAdministered());
    try testing.expect(!local_mac.isGloballyUnique());
    try testing.expect(local_mac.isLocallyAdministered());

    // Test special addresses
    const broadcast_mac = try Mac.fromString("FF:FF:FF:FF:FF:FF");
    const null_mac = try Mac.fromString("00:00:00:00:00:00");

    try testing.expect(broadcast_mac.isBroadcast());
    try testing.expect(null_mac.isNull());
}

test "MAC address OUI extraction" {
    const testing = std.testing;

    const mac = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const oui = mac.getOui();
    const nic = mac.getNicSpecific();

    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);
    try testing.expectEqual([3]u8{ 0xDD, 0xEE, 0xFF }, nic);
}

test "MAC address comparison" {
    const testing = std.testing;

    const mac1 = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac2 = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac3 = try Mac.fromString("AA:BB:CC:DD:EE:FE");

    try testing.expect(mac1.eql(mac2));
    try testing.expect(!mac1.eql(mac3));

    try testing.expectEqual(std.math.Order.eq, mac1.order(mac2));
    try testing.expectEqual(std.math.Order.gt, mac1.order(mac3));
    try testing.expectEqual(std.math.Order.lt, mac3.order(mac1));
}

test "MAC address encoding/decoding" {
    const testing = std.testing;
    var buffer: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test round-trip encoding
    const original_mac = try Mac.fromString("12:34:56:78:9A:BC");
    try original_mac.encode(fbs.writer());

    fbs.pos = 0;
    const decoded_mac = try Mac.decode(fbs.reader());
    try testing.expect(original_mac.eql(decoded_mac));
}

test "MAC address random generation" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const oui = [3]u8{ 0x00, 0x50, 0x56 }; // VMware OUI
    const mac = Mac.randomWithOui(oui, rng);

    try testing.expectEqual(oui, mac.getOui());
    try testing.expect(mac.isGloballyUnique()); // VMware OUI is globally unique
}

test "MAC address error handling" {
    const testing = std.testing;

    // Test invalid formats
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("invalid"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AA:BB:CC:DD:EE"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AA:BB:CC:DD:EE:FF:00"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("GG:BB:CC:DD:EE:FF"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AABBCCDDEEFFGG"));
}
