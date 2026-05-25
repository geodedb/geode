// CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=RaftCommandOneof; STATUS=TESTED; OWNER=core; UPDATED=2026-05-25
//
// A4b regression cover.  Asserts that `RaftCommand` is a struct-of-optionals
// (protobuf oneof semantics) rather than a `union(enum)` — the latter is
// rejected by the in-tree protobuf-0.1.3 reflection when used as a
// `.submessage` field (RaftLogEntry.command).
//
// These tests pin the new shape so a future refactor that re-introduces
// `union(enum)` for RaftCommand breaks the suite immediately rather than
// silently re-blocking ClusterCoordinator.start().

const std = @import("std");
const raft_schema = @import("raft_schema");
const protobuf = @import("protobuf");

test "RaftCommand defaults to all-null oneof" {
    var cmd: raft_schema.RaftCommand = .{};
    try std.testing.expect(cmd.active() == null);
    try std.testing.expect(cmd.noop == null);
    try std.testing.expect(cmd.write == null);
    try std.testing.expect(cmd.graph_mutation == null);
    try std.testing.expect(cmd.schema_change == null);
    try std.testing.expect(cmd.config_change == null);
    try std.testing.expect(cmd.snapshot_pointer == null);
    try std.testing.expect(cmd.txn_prepare == null);
    try std.testing.expect(cmd.txn_decide == null);
}

test "RaftCommand.ofNoop sets only the noop variant" {
    var cmd = raft_schema.RaftCommand.ofNoop(.{});
    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.noop,
        cmd.active().?,
    );
    try std.testing.expect(cmd.noop != null);
    try std.testing.expect(cmd.write == null);
}

test "RaftCommand.ofWrite sets only the write variant" {
    var cmd = raft_schema.RaftCommand.ofWrite(.{ .data = "hello" });
    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.write,
        cmd.active().?,
    );
    try std.testing.expectEqualStrings("hello", cmd.write.?.data);
}

test "RaftCommand.active returns null when multiple variants are set" {
    var cmd: raft_schema.RaftCommand = .{
        .noop = .{},
        .write = .{ .data = "x" },
    };
    try std.testing.expect(cmd.active() == null);
}

test "RaftCommand.ofGraphMutation sets only the graph_mutation variant" {
    var cmd = raft_schema.RaftCommand.ofGraphMutation(.{
        .graph = "default",
        .mutation_type = .CREATE,
        .data = "payload",
        .txn_id = 42,
    });
    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.graph_mutation,
        cmd.active().?,
    );
    try std.testing.expectEqual(@as(?u64, 42), cmd.graph_mutation.?.txn_id);
}

test "RaftCommand round-trips through protobuf encode/decode (noop)" {
    const a = std.testing.allocator;
    const cmd_in = raft_schema.RaftCommand.ofNoop(.{});

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, cmd_in);

    var reader: std.Io.Reader = .fixed(aw.writer.buffered());
    var cmd_out = try protobuf.decode(raft_schema.RaftCommand, &reader, a);
    defer cmd_out.deinit(a);

    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.noop,
        cmd_out.active().?,
    );
}

test "RaftCommand round-trips through protobuf encode/decode (graph_mutation)" {
    const a = std.testing.allocator;
    const cmd_in = raft_schema.RaftCommand.ofGraphMutation(.{
        .graph = "g1",
        .mutation_type = .UPDATE,
        .data = "bytes",
        .txn_id = 7,
    });

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, cmd_in);

    var reader: std.Io.Reader = .fixed(aw.writer.buffered());
    var cmd_out = try protobuf.decode(raft_schema.RaftCommand, &reader, a);
    defer cmd_out.deinit(a);

    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.graph_mutation,
        cmd_out.active().?,
    );
    try std.testing.expectEqualStrings("g1", cmd_out.graph_mutation.?.graph);
    try std.testing.expectEqual(@as(?u64, 7), cmd_out.graph_mutation.?.txn_id);
}

test "RaftLogEntry can carry a RaftCommand submessage" {
    const a = std.testing.allocator;
    const entry_in: raft_schema.RaftLogEntry = .{
        .term = 1,
        .index = 42,
        .timestamp = 12345,
        .command = raft_schema.RaftCommand.ofNoop(.{}),
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, a, entry_in);

    var reader: std.Io.Reader = .fixed(aw.writer.buffered());
    var entry_out = try protobuf.decode(raft_schema.RaftLogEntry, &reader, a);
    defer entry_out.deinit(a);

    try std.testing.expectEqual(@as(u64, 1), entry_out.term);
    try std.testing.expectEqual(@as(u64, 42), entry_out.index);
    try std.testing.expect(entry_out.command != null);
    try std.testing.expectEqual(
        raft_schema.RaftCommand.ActiveVariant.noop,
        entry_out.command.?.active().?,
    );
}
