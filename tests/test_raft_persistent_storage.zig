const std = @import("std");
const geode = @import("geode");
const PersistentStorage = geode.distributed.raft_consensus.PersistentStorage;

// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Consensus Persistence"; ASPECT=RoundTripTest; STATUS=TESTED; TEST=persistent_storage_roundtrip; OWNER=distributed; UPDATED=2026-04-05

test "PersistentStorage round-trips current_term and voted_for via file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/raft",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    var ps = try PersistentStorage.init(allocator, path);

    // Before any save, getCurrentTerm should be null (file does not exist).
    const initial_term = try ps.getCurrentTerm();
    try std.testing.expect(initial_term == null);

    // Save term=42, read back, assert 42.
    try ps.saveCurrentTerm(42);
    const term42 = try ps.getCurrentTerm();
    try std.testing.expectEqual(@as(u64, 42), term42.?);

    // Save votedFor=7, read back, assert 7.
    try ps.saveVotedFor(7);
    const vf7 = try ps.getVotedFor();
    try std.testing.expectEqual(@as(u64, 7), vf7.?);

    // Save votedFor=null (deletes file), read back, assert null.
    try ps.saveVotedFor(null);
    const vf_null = try ps.getVotedFor();
    try std.testing.expect(vf_null == null);

    // Overwrite term to 100, confirm.
    try ps.saveCurrentTerm(100);
    const term100 = try ps.getCurrentTerm();
    try std.testing.expectEqual(@as(u64, 100), term100.?);
}

test "PersistentStorage getVotedFor returns null when no file exists" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/raft_vf",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    var ps = try PersistentStorage.init(allocator, path);
    const vf = try ps.getVotedFor();
    try std.testing.expect(vf == null);
}
