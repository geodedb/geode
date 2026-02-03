const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("schema");

// CANARY: REQ=REQ-FUZZ-PROTO-001; FEATURE="Protobuf Fuzzing"; ASPECT=HelloRequest; STATUS=TESTED; OWNER=protocol; UPDATED=2026-02-03
// Fuzz target for HelloRequest protobuf parsing

fn encodeToBytes(ally: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(ally, 4096) catch return error.OutOfMemory;
    errdefer aw.deinit();
    try protobuf.encode(&aw.writer, ally, msg);
    const result = try ally.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const stdin = std.io.getStdIn();
    const data = stdin.readToEndAlloc(ally, 1024 * 1024) catch |err| {
        if (err == error.EndOfStream) return;
        return err;
    };
    defer ally.free(data);

    // Try to decode as HelloRequest
    var reader: std.Io.Reader = .fixed(data);
    var decoded = protobuf.decode(schema.HelloRequest, &reader, ally) catch {
        // Invalid protobuf is expected during fuzzing
        return;
    };
    defer decoded.deinit(ally);

    // Verify round-trip
    const encoded = encodeToBytes(ally, decoded) catch return;
    defer ally.free(encoded);

    var reader2: std.Io.Reader = .fixed(encoded);
    var decoded2 = protobuf.decode(schema.HelloRequest, &reader2, ally) catch return;
    defer decoded2.deinit(ally);

    // Verify fields match
    std.debug.assert(std.mem.eql(u8, decoded.username, decoded2.username));
    std.debug.assert(std.mem.eql(u8, decoded.client_name, decoded2.client_name));
}

test "fuzz_hello_basic" {
    const ally = std.testing.allocator;

    // Create a valid HelloRequest
    const req = schema.HelloRequest{
        .username = "fuzz_user",
        .password = "fuzz_pass",
        .client_name = "fuzz_client",
        .client_version = "0.0.1",
        .wanted_conformance = "core",
    };

    // Encode it
    const encoded = try encodeToBytes(ally, req);
    defer ally.free(encoded);

    // Decode and verify
    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.HelloRequest, &reader, ally);
    defer decoded.deinit(ally);

    try std.testing.expectEqualStrings("fuzz_user", decoded.username);
    try std.testing.expectEqualStrings("fuzz_client", decoded.client_name);
}
