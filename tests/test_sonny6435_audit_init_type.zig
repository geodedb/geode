// SONNY-6435 (4): since SONNY-6430 every failure of
// `StorageAdapter.initAuditForGraph` is an error and it never returns null,
// but its type still said `!?*AuditLogger`, so a caller could read a null
// as "no audit logger" again. The contract: the type has no optional, and a
// real call on a fresh graph directory returns the logger.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const test_scratch = @import("test_scratch.zig");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;
const AuditLogger = geode.security.audit.AuditLogger;

test "SONNY-6435 (4) initAuditForGraph returns an audit logger, never an optional" {
    const ret = @typeInfo(@TypeOf(StorageAdapter.initAuditForGraph)).@"fn".return_type.?;
    const payload = @typeInfo(ret).error_union.payload;
    try testing.expect(payload == *AuditLogger);
}

test "SONNY-6435 (4) initAuditForGraph opens the security graph's audit log" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    const allocator = testing.allocator;
    var scratch = try test_scratch.ScratchDir.create("sonny6435-audit-init");
    defer scratch.remove();
    const uuid = [_]u8{0x64} ** 16;
    const al = try StorageAdapter.initAuditForGraph(allocator, scratch.path(), uuid);
    defer {
        al.deinit();
        allocator.destroy(al);
    }
}
