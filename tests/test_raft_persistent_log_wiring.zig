const std = @import("std");
const geode = @import("geode");
const PersistentStorage = geode.distributed.raft_consensus.PersistentStorage;
const LogEntry = geode.distributed.raft_consensus.LogEntry;
const Command = geode.distributed.raft_consensus.Command;

// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=PersistentStorageWiring; STATUS=TESTED; TEST=persistent_log_wiring; OWNER=distributed; UPDATED=2026-04-09

test "PersistentStorage: appendLogEntry persists across reinit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/raft_wiring",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    // Phase 1: init, append two entries, close
    {
        var ps = try PersistentStorage.init(allocator, path);
        defer ps.close();

        try ps.appendLogEntry(.{
            .term = 1,
            .index = 1,
            .command = .noop,
            .timestamp = 1000,
            .client_id = 10,
            .serial_number = 20,
        });

        try ps.appendLogEntry(.{
            .term = 2,
            .index = 2,
            .command = .{ .write = "CREATE GRAPH g1" },
            .timestamp = 2000,
            .client_id = null,
            .serial_number = null,
        });
    }

    // Phase 2: reinit from same directory, read back and verify
    {
        var ps = try PersistentStorage.init(allocator, path);
        defer ps.close();

        const entries = (try ps.getLogEntries(allocator)) orelse
            return error.ExpectedEntries;
        defer {
            for (entries) |e| {
                switch (e.command) {
                    .write => |data| allocator.free(data),
                    else => {},
                }
            }
            allocator.free(entries);
        }

        try std.testing.expectEqual(@as(usize, 2), entries.len);

        // First entry
        try std.testing.expectEqual(@as(u64, 1), entries[0].term);
        try std.testing.expectEqual(@as(u64, 1), entries[0].index);
        try std.testing.expectEqual(@as(i64, 1000), entries[0].timestamp);
        try std.testing.expectEqual(@as(?u64, 10), entries[0].client_id);
        try std.testing.expectEqual(@as(?u64, 20), entries[0].serial_number);
        try std.testing.expectEqual(Command.noop, entries[0].command);

        // Second entry
        try std.testing.expectEqual(@as(u64, 2), entries[1].term);
        try std.testing.expectEqual(@as(u64, 2), entries[1].index);
        try std.testing.expectEqual(@as(i64, 2000), entries[1].timestamp);
        switch (entries[1].command) {
            .write => |data| try std.testing.expectEqualStrings("CREATE GRAPH g1", data),
            else => return error.UnexpectedCommand,
        }
    }
}

test "PersistentStorage: getLogEntries returns null on empty log" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/raft_empty",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    var ps = try PersistentStorage.init(allocator, path);
    defer ps.close();

    const result = try ps.getLogEntries(allocator);
    try std.testing.expect(result == null);
}
