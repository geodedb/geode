// SONNY-6528 (5): the storage corruption errors reach the client with a
// message an operator can act on.
//
// `proto_util.mapError` (the one mapping the QUIC and gRPC transports use)
// answered `error.DataCorruption`, `error.ChecksumMismatch` and
// `error.InvalidData` through its fallback arm: 58000 and the bare error
// name. Those are what a read of a damaged graph fails with, and what every
// statement on a quarantined graph fails with (REQ-GQL-028, SONNY-6523).
// Each now says what happened, that the graph's statements are refused, and
// what to do (restore from a backup, or DROP GRAPH), with the error name
// first (as `GraphQuarantined`'s message). The code stays 58000 (system
// error, the class `GraphQuarantined` and the fallback use). No message
// carries a file path.
//
// CANARY: REQ=REQ-SONNY-6528-CORRUPTION-MESSAGES; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6528_corruption_messages.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const proto_util = geode.proto_util;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "SONNY-6528 (5): DataCorruption, ChecksumMismatch and InvalidData carry an operator-facing message" {
    const errs = [_]anyerror{ error.DataCorruption, error.ChecksumMismatch, error.InvalidData };
    var failures: usize = 0;
    for (errs) |err| {
        const info = proto_util.mapError(err);
        const name = @errorName(err);
        std.debug.print("SONNY-6528 (5) {s} -> {s}: {s}\n", .{ name, info.code, info.message });
        const ok = std.mem.eql(u8, info.code, "58000") and
            !std.mem.eql(u8, info.message, name) and
            std.mem.startsWith(u8, info.message, name) and
            info.message.len > name.len and info.message[name.len] == ':' and
            contains(info.message, "quarantined") and
            contains(info.message, "backup") and
            contains(info.message, "DROP GRAPH") and
            !contains(info.message, "/");
        if (!ok) failures += 1;
    }
    // The fallback is unchanged for an error with no arm of its own.
    const other = proto_util.mapError(error.SomeUnmappedError6528);
    try std.testing.expectEqualStrings("58000", other.code);
    try std.testing.expectEqualStrings("SomeUnmappedError6528", other.message);
    if (failures > 0) return error.CorruptionErrorWithoutMessage;
}
