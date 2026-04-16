// CANARY: REQ=REQ-GAP-0727-AUDIT-SEQ-NO; FEATURE="AuditVerifySeqNo"; ASPECT=TamperDetection; STATUS=TESTED; TEST=tests/test_audit_verify_seq_no.zig; OWNER=security; UPDATED=2026-04-16
//
// Regression test for GAP-0727 / SEC-AUD-01.
//
// The audit verifier in src/cli/geode_audit_verify.zig used to increment
// its own local `seq` counter without ever parsing the record's self-
// declared seq_no field.  That meant an attacker who deleted a middle
// record and recomputed prev_hash links on the trailing records would
// produce a log that still verified cleanly — the tamper would be
// invisible.
//
// The fix: each record's parsed seq_no must equal the expected monotonic
// +1 progression (first record is seq_no=1).  Any gap, duplicate, or
// reordering now surfaces as error.SequenceMonotonicityViolation.
//
// Test strategy:
//   1. Build a 3-record synthetic audit.jsonl by hand, with seq_no 1..3
//      and correct prev_hash / event_hash chain.
//   2. Verify it passes (sanity baseline).
//   3. Produce a tampered copy with the middle record removed and the
//      trailing record's prev_hash rewritten so the hash chain still
//      matches — but seq_no for the last record remains 3, which no
//      longer matches the verifier's expected counter of 2.
//   4. Assert verifyFile returns error.SequenceMonotonicityViolation.

const std = @import("std");
const testing = std.testing;
const audit_verify = @import("audit_verify");

fn hexHash(bytes: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    return out;
}

fn appendRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seq: u64,
    prev_hash: [32]u8,
    event_hash: [32]u8,
    event_type: []const u8,
) !void {
    const prev_hex = hexHash(prev_hash);
    const ev_hex = hexHash(event_hash);
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"stream\":\"geode\",\"seq_no\":{d},\"timestamp\":\"2026-04-16T00:00:00Z\",\"event_type\":\"{s}\",\"prev_hash\":\"{s}\",\"event_hash\":\"{s}\"}}\n",
        .{ seq, event_type, prev_hex, ev_hex },
    );
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

/// Build a synthetic 3-record audit log that passes the verifier's chain
/// check (prev_hash must equal previous record's event_hash; first
/// record's prev_hash is [0]*32 because the verifier initialises
/// last_hash to zeros).  Tests here exercise the seq_no contract only —
/// they don't need to match the audit.zig producer's full hashing scheme.
fn buildValidLog(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Choose arbitrary but distinct 32-byte event hashes.
    const zero: [32]u8 = [_]u8{0} ** 32;
    const ev1: [32]u8 = [_]u8{0x11} ** 32;
    const ev2: [32]u8 = [_]u8{0x22} ** 32;
    const ev3: [32]u8 = [_]u8{0x33} ** 32;

    try appendRecord(allocator, &out, 1, zero, ev1, "ACCESS");
    try appendRecord(allocator, &out, 2, ev1, ev2, "MUTATE");
    try appendRecord(allocator, &out, 3, ev2, ev3, "ACCESS");

    return out.toOwnedSlice(allocator);
}

/// Build a tampered log: drop seq=2 but splice seq=3's prev_hash back to
/// seq=1's event_hash so the chain still matches.  seq_no stays at 3,
/// which is the tell the new verifier catches.
fn buildTamperedLog(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const zero: [32]u8 = [_]u8{0} ** 32;
    const ev1: [32]u8 = [_]u8{0x11} ** 32;
    const ev3: [32]u8 = [_]u8{0x33} ** 32;

    try appendRecord(allocator, &out, 1, zero, ev1, "ACCESS");
    // Attacker deletes seq=2 and rewrites seq=3 so the hash chain still
    // verifies (prev_hash = seq=1's event_hash), leaving only seq_no as
    // evidence of the tampering.
    try appendRecord(allocator, &out, 3, ev1, ev3, "ACCESS");

    return out.toOwnedSlice(allocator);
}

test "GAP-0727: valid monotonic log verifies cleanly" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const log = try buildValidLog(allocator);
    defer allocator.free(log);

    // Write to a temp file.
    const path = "test_audit_verify_seq_no.valid.jsonl";
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, log);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try audit_verify.verifyFile(allocator, path, .sha256, 0, false, null, false);
}

test "GAP-0727: deleted middle record surfaces as SequenceMonotonicityViolation" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tampered = try buildTamperedLog(allocator);
    defer allocator.free(tampered);

    const path = "test_audit_verify_seq_no.tampered.jsonl";
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, tampered);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const res = audit_verify.verifyFile(allocator, path, .sha256, 0, false, null, false);
    try testing.expectError(error.SequenceMonotonicityViolation, res);
}
