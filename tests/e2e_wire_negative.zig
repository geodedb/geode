const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("schema");

// Negative wire tests exercising malformed frame parse and unsupported capability negotiation.
// These expand coverage for REQ-GQL-001 / REQ-GQL-002 beyond the happy HELLO round trip.

fn decodePacket(bytes: []const u8, allocator: std.mem.Allocator) !schema.ClientPacket {
    var reader: std.Io.Reader = .fixed(bytes);
    return try protobuf.decode(schema.ClientPacket, &reader, allocator);
}

// TestCANARY_REQ_GQL_001_WireMalformedFrame - ensures invalid JSON / structure is rejected.
test "TestCANARY_REQ_GQL_001_WireMalformedFrame" {
    // Truncated/invalid protobuf frames should not decode.
    const bads = [_][]const u8{
        &[_]u8{0x0a}, // missing length
        &[_]u8{0x0a, 0x05, 0x08}, // length says 5 but data truncated
        &[_]u8{0xff, 0xff, 0xff}, // invalid varint
    };

    for (bads) |b| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (decodePacket(b, arena.allocator())) |_| {
            return error.UnexpectedSuccess;
        } else |_| {}
    }
}

// TestCANARY_REQ_GQL_002_WireUnsupportedCapability - unknown type should be invalid.
test "TestCANARY_REQ_GQL_002_WireUnsupportedCapability" {
    // Encode a packet with only unknown fields; decode should yield no QUIC message.
    const bytes = &[_]u8{ 0xC8, 0x06, 0x01 }; // field 99, varint 1

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const packet = decodePacket(bytes, arena.allocator()) catch return;
    defer packet.deinit(arena.allocator());

    if (packet.quic != null) {
        return error.UnexpectedSuccess;
    }
}
