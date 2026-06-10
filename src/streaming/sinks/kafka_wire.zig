//! Minimal Apache Kafka wire-protocol producer (produce-only).
//!
//! Scope: just enough of the Kafka protocol for the CDC Kafka sink to deliver
//! a record (key/value) to a single topic over plain TCP:
//!   * ApiVersions (v0)  — handshake / broker liveness probe
//!   * Metadata    (v1)  — resolve the leader broker for the topic/partition
//!   * Produce     (v3)  — append a RecordBatch (v2 format, acks=1, no compression)
//!
//! All multi-byte integers are big-endian (network order) per the Kafka
//! protocol. Strings are INT16-length-prefixed; nullable bytes are
//! INT32-length-prefixed (-1 = null). The RecordBatch uses the v2 (magic=2)
//! layout with a CRC32C (Castagnoli) over the batch body.
//!
//! Explicitly UNSUPPORTED in this release (honest gating, not silent stubs):
//!   * Compression (gzip/snappy/lz4/zstd) — only `none` is implemented;
//!     a compressed Produce is never emitted.
//!   * SASL authentication — `error.KafkaAuthNotSupported`.
//!   * TLS — `error.KafkaTlsNotSupported` (plain TCP only).
//! These are surfaced as clear errors by the sink, never faked.
//!
//! References: Apache Kafka protocol guide (KIP-98 record batch v2,
//! the ApiVersions/Metadata/Produce request+response schemas).

const std = @import("std");

/// CRC32C (Castagnoli) — the checksum Kafka RecordBatch v2 mandates.
pub const Crc32c = std.hash.crc.Crc32Iscsi;

pub const ApiKey = enum(i16) {
    produce = 0,
    metadata = 3,
    api_versions = 18,
};

pub const WireError = error{
    ShortResponse,
    BadCorrelationId,
    TopicNotFound,
    PartitionNotFound,
    NoLeader,
    KafkaErrorCode,
    KafkaAuthNotSupported,
    KafkaTlsNotSupported,
    OutOfMemory,
};

// ===========================================================================
// Big-endian primitive encoders (append into a growable byte list)
// ===========================================================================

pub const Encoder = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .buf = std.ArrayList(u8).empty, .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn putI8(self: *Encoder, v: i8) !void {
        try self.buf.append(self.allocator, @bitCast(v));
    }

    pub fn putI16(self: *Encoder, v: i16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn putI32(self: *Encoder, v: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn putI64(self: *Encoder, v: i64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn putU32(self: *Encoder, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    /// INT16-length-prefixed string (non-null).
    pub fn putString(self: *Encoder, s: []const u8) !void {
        try self.putI16(@intCast(s.len));
        try self.buf.appendSlice(self.allocator, s);
    }

    /// INT32-length-prefixed bytes; null encoded as length -1.
    pub fn putNullableBytes(self: *Encoder, s: ?[]const u8) !void {
        if (s) |bytes| {
            try self.putI32(@intCast(bytes.len));
            try self.buf.appendSlice(self.allocator, bytes);
        } else {
            try self.putI32(-1);
        }
    }

    pub fn putRaw(self: *Encoder, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// A signed VARINT (zig-zag) — used inside RecordBatch v2 records.
    pub fn putVarint(self: *Encoder, value: i64) !void {
        var zz: u64 = @bitCast((value << 1) ^ (value >> 63));
        while (true) {
            const byte: u8 = @intCast(zz & 0x7f);
            zz >>= 7;
            if (zz != 0) {
                try self.buf.append(self.allocator, byte | 0x80);
            } else {
                try self.buf.append(self.allocator, byte);
                break;
            }
        }
    }
};

// ===========================================================================
// Big-endian primitive decoder (cursor over a fixed buffer)
// ===========================================================================

pub const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Decoder) usize {
        return self.data.len - self.pos;
    }

    pub fn getI8(self: *Decoder) !i8 {
        if (self.remaining() < 1) return WireError.ShortResponse;
        const v: i8 = @bitCast(self.data[self.pos]);
        self.pos += 1;
        return v;
    }

    pub fn getI16(self: *Decoder) !i16 {
        if (self.remaining() < 2) return WireError.ShortResponse;
        const v = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    pub fn getI32(self: *Decoder) !i32 {
        if (self.remaining() < 4) return WireError.ShortResponse;
        const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn getI64(self: *Decoder) !i64 {
        if (self.remaining() < 8) return WireError.ShortResponse;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    pub fn getString(self: *Decoder) ![]const u8 {
        const len = try self.getI16();
        if (len < 0) return &.{};
        const n: usize = @intCast(len);
        if (self.remaining() < n) return WireError.ShortResponse;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn skip(self: *Decoder, n: usize) !void {
        if (self.remaining() < n) return WireError.ShortResponse;
        self.pos += n;
    }
};

// ===========================================================================
// Request framing
// ===========================================================================

/// Build a full request frame: a 4-byte length prefix followed by the request
/// header (api_key, api_version, correlation_id, client_id) and `body`.
/// Caller owns the returned slice.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    api_key: ApiKey,
    api_version: i16,
    correlation_id: i32,
    client_id: []const u8,
    body: []const u8,
) ![]u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // Header (request header v1: api_key, api_version, correlation_id, client_id).
    try enc.putI16(@intFromEnum(api_key));
    try enc.putI16(api_version);
    try enc.putI32(correlation_id);
    try enc.putString(client_id);
    try enc.putRaw(body);

    const payload = enc.buf.items;

    var framed = std.ArrayList(u8).empty;
    errdefer framed.deinit(allocator);
    var lenbuf: [4]u8 = undefined;
    std.mem.writeInt(i32, &lenbuf, @intCast(payload.len), .big);
    try framed.appendSlice(allocator, &lenbuf);
    try framed.appendSlice(allocator, payload);
    return framed.toOwnedSlice(allocator);
}

/// Encode an empty ApiVersions(v0) request body (no fields).
pub fn buildApiVersionsBody(allocator: std.mem.Allocator) ![]u8 {
    _ = allocator;
    return &.{};
}

/// Encode a Metadata(v1) request body asking for a single topic.
/// v1 layout: ARRAY<topic STRING>.
pub fn buildMetadataBody(allocator: std.mem.Allocator, topic: []const u8) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();
    try enc.putI32(1); // 1 topic
    try enc.putString(topic);
    return enc.buf.toOwnedSlice(allocator);
}

/// Build a RecordBatch (v2) containing exactly one record with the given
/// key/value. Caller owns the returned slice.
pub fn buildRecordBatch(allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8, timestamp_ms: i64) ![]u8 {
    // First build the single record (length-prefixed by varint).
    var rec = Encoder.init(allocator);
    defer rec.deinit();
    try rec.putI8(0); // attributes (int8)
    try rec.putVarint(0); // timestampDelta
    try rec.putVarint(0); // offsetDelta
    // key (varint length, -1 = null)
    if (key) |k| {
        try rec.putVarint(@intCast(k.len));
        try rec.putRaw(k);
    } else {
        try rec.putVarint(-1);
    }
    // value (varint length)
    try rec.putVarint(@intCast(value.len));
    try rec.putRaw(value);
    try rec.putVarint(0); // headers count = 0

    var record_body = Encoder.init(allocator);
    defer record_body.deinit();
    try record_body.putVarint(@intCast(rec.buf.items.len)); // record length
    try record_body.putRaw(rec.buf.items);

    // Build the part of the batch AFTER the CRC field (the CRC covers this).
    var post_crc = Encoder.init(allocator);
    defer post_crc.deinit();
    try post_crc.putI16(0); // attributes (int16): no compression, etc.
    try post_crc.putI32(0); // lastOffsetDelta (0 — single record)
    try post_crc.putI64(timestamp_ms); // firstTimestamp
    try post_crc.putI64(timestamp_ms); // maxTimestamp
    try post_crc.putI64(-1); // producerId
    try post_crc.putI16(-1); // producerEpoch
    try post_crc.putI32(-1); // baseSequence
    try post_crc.putI32(1); // record count = 1
    try post_crc.putRaw(record_body.buf.items);

    const crc = Crc32c.hash(post_crc.buf.items);

    // Assemble the full batch: baseOffset, batchLength, partitionLeaderEpoch,
    // magic, crc, then the post-crc body.
    var batch = Encoder.init(allocator);
    errdefer batch.deinit();
    try batch.putI64(0); // baseOffset
    // batchLength = bytes after this field: partitionLeaderEpoch(4) + magic(1)
    //               + crc(4) + post_crc body.
    const batch_length: i32 = @intCast(4 + 1 + 4 + post_crc.buf.items.len);
    try batch.putI32(batch_length);
    try batch.putI32(-1); // partitionLeaderEpoch (unknown)
    try batch.putI8(2); // magic = 2
    try batch.putU32(crc); // crc32c
    try batch.putRaw(post_crc.buf.items);

    return batch.buf.toOwnedSlice(allocator);
}

/// Encode a Produce(v3) request body for a single topic/partition carrying one
/// record batch. acks = 1 (leader ack), timeout 30s, no transactional id.
pub fn buildProduceBody(
    allocator: std.mem.Allocator,
    topic: []const u8,
    partition: i32,
    record_batch: []const u8,
) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();
    try enc.putI16(-1); // transactional_id = null (NULLABLE_STRING)
    try enc.putI16(1); // acks = 1
    try enc.putI32(30_000); // timeout_ms
    try enc.putI32(1); // topic array length = 1
    try enc.putString(topic);
    try enc.putI32(1); // partition array length = 1
    try enc.putI32(partition);
    // The record set rides as NULLABLE_BYTES (int32 length prefix).
    try enc.putI32(@intCast(record_batch.len));
    try enc.putRaw(record_batch);
    return enc.buf.toOwnedSlice(allocator);
}

// ===========================================================================
// Response parsing
// ===========================================================================

/// Read a full response frame (4-byte length prefix + payload) into an
/// allocator-owned buffer. Caller frees.
pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var lenbuf: [4]u8 = undefined;
    try reader.readSliceAll(&lenbuf);
    const len = std.mem.readInt(i32, &lenbuf, .big);
    if (len < 0) return WireError.ShortResponse;
    const n: usize = @intCast(len);
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    try reader.readSliceAll(buf);
    return buf;
}

pub const MetadataResult = struct {
    leader_id: i32,
    /// Whether the requested topic/partition was found.
    found: bool,
};

/// Parse the correlation id at the head of a response payload, validating it.
pub fn parseCorrelationId(dec: *Decoder, expected: i32) !void {
    const cid = try dec.getI32();
    if (cid != expected) return WireError.BadCorrelationId;
}

/// Parse just enough of a Produce(v3) response to confirm the partition
/// succeeded (error_code == 0). Layout after correlation id:
///   topics: ARRAY{ name STRING, partitions: ARRAY{ index I32, error_code I16,
///   base_offset I64, log_append_time I64 } }, throttle_time_ms I32.
pub fn parseProduceResponse(payload: []const u8, expected_cid: i32) !void {
    var dec = Decoder.init(payload);
    try parseCorrelationId(&dec, expected_cid);
    const topic_count = try dec.getI32();
    var t: i32 = 0;
    while (t < topic_count) : (t += 1) {
        _ = try dec.getString(); // topic name
        const part_count = try dec.getI32();
        var p: i32 = 0;
        while (p < part_count) : (p += 1) {
            _ = try dec.getI32(); // partition index
            const error_code = try dec.getI16();
            _ = try dec.getI64(); // base_offset
            _ = try dec.getI64(); // log_append_time
            if (error_code != 0) return WireError.KafkaErrorCode;
        }
    }
}

// ===========================================================================
// Tests — pure encode/decode round-trips (no socket needed)
// ===========================================================================

test "varint zig-zag round-trip via known Kafka values" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    // Kafka zig-zag: 0->0x00, -1->0x01, 1->0x02, 2->0x04
    try enc.putVarint(0);
    try enc.putVarint(-1);
    try enc.putVarint(1);
    try enc.putVarint(2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x04 }, enc.buf.items);
}

test "record batch encodes magic=2 and a CRC32C that validates" {
    const testing = std.testing;
    const batch = try buildRecordBatch(testing.allocator, "k1", "hello-value", 1234);
    defer testing.allocator.free(batch);

    // baseOffset(8) batchLength(4) leaderEpoch(4) magic(1) crc(4) ...
    try testing.expectEqual(@as(u8, 2), batch[16]); // magic byte
    const crc_stored = std.mem.readInt(u32, batch[17..21], .big);
    const crc_recomputed = Crc32c.hash(batch[21..]);
    try testing.expectEqual(crc_stored, crc_recomputed);

    // The value bytes must appear verbatim in the batch.
    try testing.expect(std.mem.indexOf(u8, batch, "hello-value") != null);
    try testing.expect(std.mem.indexOf(u8, batch, "k1") != null);
}

test "produce body carries topic name and embeds the record batch length-prefixed" {
    const testing = std.testing;
    const batch = try buildRecordBatch(testing.allocator, null, "v", 7);
    defer testing.allocator.free(batch);
    const body = try buildProduceBody(testing.allocator, "cdc-events", 0, batch);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "cdc-events") != null);
    // The trailing int32 length + batch must be present.
    var lenbuf: [4]u8 = undefined;
    std.mem.writeInt(i32, &lenbuf, @intCast(batch.len), .big);
    try testing.expect(std.mem.indexOf(u8, body, &lenbuf) != null);
}

test "request framing prefixes a correct big-endian length" {
    const testing = std.testing;
    const body = try buildMetadataBody(testing.allocator, "t");
    defer testing.allocator.free(body);
    const frame = try buildRequest(testing.allocator, .metadata, 1, 99, "geode", body);
    defer testing.allocator.free(frame);

    const declared = std.mem.readInt(i32, frame[0..4], .big);
    try testing.expectEqual(@as(i32, @intCast(frame.len - 4)), declared);
    // correlation id sits at offset 4 (api_key) + ... ; verify it's encoded.
    // header: api_key(2) api_version(2) correlation_id(4)
    const cid = std.mem.readInt(i32, frame[4 + 2 + 2 ..][0..4], .big);
    try testing.expectEqual(@as(i32, 99), cid);
}

test "produce response parser accepts success and rejects error codes" {
    const testing = std.testing;
    // Build a synthetic Produce response: cid=5, 1 topic "t", 1 partition,
    // error_code=0, base_offset=10, log_append_time=-1, throttle=0.
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.putI32(5); // correlation id
    try enc.putI32(1); // topic count
    try enc.putString("t");
    try enc.putI32(1); // partition count
    try enc.putI32(0); // partition index
    try enc.putI16(0); // error_code = 0
    try enc.putI64(10); // base_offset
    try enc.putI64(-1); // log_append_time
    try enc.putI32(0); // throttle
    try parseProduceResponse(enc.buf.items, 5);

    // Now flip error_code to 1 and expect rejection.
    enc.buf.clearRetainingCapacity();
    try enc.putI32(5);
    try enc.putI32(1);
    try enc.putString("t");
    try enc.putI32(1);
    try enc.putI32(0);
    try enc.putI16(1); // error_code = 1 (offset out of range etc.)
    try enc.putI64(0);
    try enc.putI64(-1);
    try enc.putI32(0);
    try testing.expectError(WireError.KafkaErrorCode, parseProduceResponse(enc.buf.items, 5));
}
