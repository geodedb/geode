const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");

// CANARY: REQ=REQ-LIB-MIGRATION-PROTOBUF-001; FEATURE="Protobuf Wire Protocol"; ASPECT=WireProtocolCompatibility; STATUS=TESTED; OWNER=protocol; UPDATED=2026-02-03
// Wire protocol compatibility tests for Protobuf encoding
// These tests validate that protobuf encoding produces correct output

const schema = @import("schema");

fn encodeToBytes(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    errdefer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const result = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return result;
}

test "protobuf: HelloRequest roundtrip" {
    const allocator = testing.allocator;

    const req = schema.HelloRequest{
        .username = "testuser",
        .password = "secret",
        .client_name = "test-client",
        .client_version = "1.0.0",
        .wanted_conformance = "full",
    };

    // Encode
    const encoded = try encodeToBytes(allocator, req);
    defer allocator.free(encoded);

    // Decode
    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.HelloRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("testuser", decoded.username);
    try testing.expectEqualStrings("test-client", decoded.client_name);
}

test "protobuf: ExecuteRequest roundtrip" {
    const allocator = testing.allocator;

    var params = std.ArrayList(schema.Param).empty;
    defer {
        for (params.items) |*param| {
            param.deinit(allocator);
        }
        params.deinit(allocator);
    }
    try params.append(allocator, .{
        .name = try allocator.dupe(u8, "id"),
        .value = .{ .kind = .{ .int_val = .{ .value = 42, .kind = .INT } } },
    });

    const req = schema.ExecuteRequest{
        .session_id = "session-123",
        .query = "MATCH (n) RETURN n",
        .params = params,
    };

    const encoded = try encodeToBytes(allocator, req);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.ExecuteRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("session-123", decoded.session_id);
    try testing.expectEqualStrings("MATCH (n) RETURN n", decoded.query);
}

test "protobuf: PullRequest roundtrip" {
    const allocator = testing.allocator;

    const req = schema.PullRequest{
        .request_id = 42,
        .page_size = 1000,
        .session_id = "session-456",
    };

    const encoded = try encodeToBytes(allocator, req);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.PullRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(u64, 42), decoded.request_id);
    try testing.expectEqual(@as(u32, 1000), decoded.page_size);
}

test "protobuf: ColumnDefinition encoding" {
    const allocator = testing.allocator;

    const col = schema.ColumnDefinition{
        .name = "id",
        .type = "INTEGER",
    };

    const encoded = try encodeToBytes(allocator, col);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.ColumnDefinition, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("id", decoded.name);
    try testing.expectEqualStrings("INTEGER", decoded.type);
}

test "protobuf: IntValue encoding" {
    const allocator = testing.allocator;

    const val = schema.IntValue{
        .value = 12345,
        .kind = .INT,
    };

    const encoded = try encodeToBytes(allocator, val);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.IntValue, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(i64, 12345), decoded.value);
    try testing.expectEqual(schema.IntKind.INT, decoded.kind);
}

test "protobuf: StringValue encoding" {
    const allocator = testing.allocator;

    const val = schema.StringValue{
        .value = "hello world",
        .kind = .STRING,
    };

    const encoded = try encodeToBytes(allocator, val);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.StringValue, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("hello world", decoded.value);
    try testing.expectEqual(schema.StringKind.STRING, decoded.kind);
}

test "protobuf: Status encoding" {
    const allocator = testing.allocator;

    var additional = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer additional.deinit(allocator);
    var findings = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer findings.deinit(allocator);

    const status = schema.Status{
        .status_class = "00000",
        .status_subclass = "",
        .additional_statuses = additional,
        .flagger_findings = findings,
    };

    const encoded = try encodeToBytes(allocator, status);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.Status, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("00000", decoded.status_class);
}
