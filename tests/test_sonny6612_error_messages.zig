// SONNY-6612 (3): the errors SONNY-6594 and SONNY-6607 introduced reach the
// client with a SQLSTATE of their class and a message an operator can act
// on.
//
// `proto_util.mapError` (the mapping the QUIC and gRPC transports use)
// answered `StorageReadFailed`, `StorageWriteFailed`, `TenantDropping` and
// `TenantRegistryOrphanParent` through its fallback arm: 58000 and the bare
// error name. Each now starts with the error name, says what happened and
// what to do, and carries no file path:
//   - StorageReadFailed / StorageWriteFailed: 58000 (system error: the
//     storage engine failed), the statement made no change;
//   - TenantDropping: 42501 (access rule violation, as TenantScopeRequired):
//     the session's tenant is being dropped or is not registered;
//   - TenantRegistryOrphanParent: 58000 (a startup refusal; damage).
//
// CANARY: REQ=REQ-SONNY-6612-ERROR-MESSAGES; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6612_error_messages.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const proto_util = geode.proto_util;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Want = struct { err: anyerror, code: []const u8, hint: []const u8 };

test "SONNY-6612 (3): storage and tenant errors carry their SQLSTATE and an operator-facing message" {
    const wants = [_]Want{
        .{ .err = error.StorageReadFailed, .code = "58000", .hint = "server log" },
        .{ .err = error.StorageWriteFailed, .code = "58000", .hint = "server log" },
        .{ .err = error.TenantDropping, .code = "42501", .hint = "tenant" },
        .{ .err = error.TenantNotRegistered, .code = "42501", .hint = "geode.tenant.create" },
        .{ .err = error.TenantRegistryOrphanParent, .code = "58000", .hint = "registry" },
    };
    var failures: usize = 0;
    for (wants) |w| {
        const info = proto_util.mapError(w.err);
        const name = @errorName(w.err);
        std.debug.print("SONNY-6612 (3) {s} -> {s}: {s}\n", .{ name, info.code, info.message });
        const ok = std.mem.eql(u8, info.code, w.code) and
            std.mem.startsWith(u8, info.message, name) and
            info.message.len > name.len + 20 and info.message[name.len] == ':' and
            contains(info.message, w.hint) and
            !contains(info.message, "/");
        if (!ok) failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
