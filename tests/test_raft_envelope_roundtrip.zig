// CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=RaftEnvelopeWire; STATUS=TESTED; OWNER=core; UPDATED=2026-05-25
//
// A6d regression cover.  Asserts that `RaftEnvelope` encodes and decodes
// without colliding field numbers between the parent struct's `term` field
// and the `RaftMessage` oneof's `request_vote` field.  Both were originally
// declared as field number 1, which produced wire payloads the in-tree
// protobuf-0.1.3 decoder rejected with `error.InvalidInput`: the first
// length-delimited field 1 on the wire was matched against `RaftEnvelope.term`
// (which expects wire-type varint), tripping the wire-type guard at
// `wire.zig:727`.
//
// These tests pin the corrected field numbering so a future schema edit that
// re-introduces a collision between RaftEnvelope's scalar fields and the
// inner RaftMessage oneof's submessage field numbers breaks the suite at
// this test rather than silently re-blocking 3-node leader election.

const std = @import("std");
const raft_schema = @import("raft_schema");
const protobuf = @import("protobuf");

test "RaftEnvelope encodes and decodes a RequestVote round-trip" {
    const a = std.testing.allocator;

    const envelope_in = raft_schema.RaftEnvelope{
        .term = 1,
        .from = 3,
        .nonce = 0xdeadbeefcafef00d,
        .message = .{
            .request_vote = .{
                .term = 1,
                .candidate_id = 3,
                .last_log_index = 0,
                .last_log_term = 0,
                .pre_vote = false,
            },
        },
        .auth_token = "test-subprocess-cluster",
    };
    // NB: do not call envelope_in.deinit — the auth_token is a string
    // literal (read-only), not allocator-owned.  The protobuf generic
    // deinit would attempt to free it and panic.

    // Encode
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, envelope_in);
    const encoded = aw.writer.buffered();
    std.debug.print("encoded {d} bytes:", .{encoded.len});
    for (encoded) |b| std.debug.print(" {x:0>2}", .{b});
    std.debug.print("\n", .{});

    // Decode
    var reader: std.Io.Reader = .fixed(encoded);
    var envelope_out = try protobuf.decode(raft_schema.RaftEnvelope, &reader, a);
    defer envelope_out.deinit(a);

    try std.testing.expectEqual(@as(u64, 1), envelope_out.term);
    try std.testing.expectEqual(@as(u64, 3), envelope_out.from);
    try std.testing.expectEqual(@as(u64, 0xdeadbeefcafef00d), envelope_out.nonce);
    try std.testing.expectEqualStrings("test-subprocess-cluster", envelope_out.auth_token);
    try std.testing.expect(envelope_out.message != null);
    switch (envelope_out.message.?) {
        .request_vote => |rv| {
            try std.testing.expectEqual(@as(u64, 1), rv.term);
            try std.testing.expectEqual(@as(u64, 3), rv.candidate_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "RaftEnvelope round-trips with term=0 (default-elided on the wire)" {
    const a = std.testing.allocator;

    const envelope_in = raft_schema.RaftEnvelope{
        .term = 0,
        .from = 3,
        .nonce = 0xdeadbeefcafef00d,
        .message = .{
            .request_vote = .{
                .term = 1,
                .candidate_id = 3,
            },
        },
        .auth_token = "test-subprocess-cluster",
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, envelope_in);
    const encoded = aw.writer.buffered();

    var reader: std.Io.Reader = .fixed(encoded);
    var envelope_out = try protobuf.decode(raft_schema.RaftEnvelope, &reader, a);
    defer envelope_out.deinit(a);

    try std.testing.expectEqual(@as(u64, 0), envelope_out.term);
    try std.testing.expectEqual(@as(u64, 3), envelope_out.from);
    try std.testing.expect(envelope_out.message != null);
}

test "RaftEnvelope round-trips a RequestVoteResponse with vote_granted=true" {
    const a = std.testing.allocator;

    const envelope_in = raft_schema.RaftEnvelope{
        .term = 7,
        .from = 1,
        .nonce = 0xdeadbeefcafef00d,
        .message = .{
            .request_vote_response = .{
                .term = 7,
                .vote_granted = true,
                .voter_id = 1,
            },
        },
        .auth_token = "tkn",
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, envelope_in);
    const encoded = aw.writer.buffered();

    var reader: std.Io.Reader = .fixed(encoded);
    var envelope_out = try protobuf.decode(raft_schema.RaftEnvelope, &reader, a);
    defer envelope_out.deinit(a);

    try std.testing.expectEqual(@as(u64, 7), envelope_out.term);
    try std.testing.expectEqual(@as(u64, 1), envelope_out.from);
    try std.testing.expect(envelope_out.message != null);
    switch (envelope_out.message.?) {
        .request_vote_response => |rvr| {
            try std.testing.expectEqual(@as(u64, 7), rvr.term);
            try std.testing.expectEqual(true, rvr.vote_granted);
            try std.testing.expectEqual(@as(u64, 1), rvr.voter_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "RaftEnvelope pre-A6d wire encoding is genuinely ambiguous and rejected" {
    // This is the exact 43-byte payload captured on the wire during the
    // A6 live-fire run, encoded against the PRE-A6d schema:
    //   term = fd(1, .uint64)       — varint
    //   from = fd(2, .uint64)       — varint
    //   nonce = fd(10, .uint64)     — varint
    //   message = oneof RaftMessage — RaftMessage fields 1..6 are LEN
    //   auth_token = fd(11, .string) — LEN
    //
    // The collision between term=fd(1) varint and request_vote=fd(1)
    // submessage (LEN) made the pre-fix wire encoding inherently
    // ambiguous: a single byte sequence cannot encode both "term=1
    // varint" and "request_vote submessage of length 1" at the same wire
    // field number, and the decoder cannot disambiguate without
    // out-of-band schema context.  This test pins the rejection: the
    // post-fix decoder must fail with error.InvalidInput on the pre-fix
    // encoding (rather than silently producing wrong values).
    const a = std.testing.allocator;
    const captured = [_]u8{
        0x10, 0x03,
        0x50, 0xdf,
        0xfe, 0xf0,
        0xa6, 0x96,
        0xd3, 0xca,
        0xf6, 0x25,
        0x0a, 0x04,
        0x08, 0x01,
        0x10, 0x03,
        0x5a, 0x17,
        't',  'e',
        's',  't',
        '-',  's',
        'u',  'b',
        'p',  'r',
        'o',  'c',
        'e',  's',
        's',  '-',
        'c',  'l',
        'u',  's',
        't',  'e',
        'r',
    };

    var reader: std.Io.Reader = .fixed(&captured);
    const result = protobuf.decode(raft_schema.RaftEnvelope, &reader, a);
    try std.testing.expectError(error.InvalidInput, result);
}
