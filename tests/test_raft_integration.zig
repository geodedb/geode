const std = @import("std");
const geode = @import("geode");
const raft_consensus = geode.distributed.raft_consensus;
const PersistentStorage = raft_consensus.PersistentStorage;
const LogEntry = raft_consensus.LogEntry;
const Command = raft_consensus.Command;

// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Persistence"; ASPECT=LifecycleIntegration; STATUS=TESTED; TEST=raft_lifecycle_integration; OWNER=distributed; UPDATED=2026-04-09

test "Raft lifecycle: propose, commit, persist, restart, recover" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    // Phase 1: Create storage, append entries, save term, close
    {
        var storage = try PersistentStorage.init(allocator, dir_path);
        defer storage.close();

        // Append 3 log entries (term=1, index=1,2,3, noop commands)
        for (1..4) |i| {
            try storage.appendLogEntry(LogEntry{
                .term = 1,
                .index = @intCast(i),
                .command = .noop,
                .timestamp = @as(i64, @intCast(1712678400000 + i)),
                .client_id = null,
                .serial_number = null,
            });
        }

        // Save current term
        try storage.saveCurrentTerm(1);
    }

    // Phase 2: Reopen storage and verify recovery
    {
        var storage = try PersistentStorage.init(allocator, dir_path);
        defer storage.close();

        // Verify: getCurrentTerm() == 1
        const term = try storage.getCurrentTerm();
        try std.testing.expectEqual(@as(?u64, 1), term);

        // Verify: getLogEntries() returns 3 entries with correct indexes
        const entries = (try storage.getLogEntries(allocator)).?;
        defer {
            for (entries) |e| {
                switch (e.command) {
                    .write => |data| allocator.free(data),
                    else => {},
                }
            }
            allocator.free(entries);
        }

        try std.testing.expectEqual(@as(usize, 3), entries.len);

        for (entries, 0..) |e, i| {
            try std.testing.expectEqual(@as(u64, 1), e.term);
            try std.testing.expectEqual(@as(u64, @intCast(i + 1)), e.index);
            try std.testing.expectEqual(Command.noop, e.command);
        }
    }
}
