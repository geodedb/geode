const std = @import("std");
const geode = @import("geode");
const raft_consensus = geode.distributed.raft_consensus;
const LogEntry = raft_consensus.LogEntry;
const Command = raft_consensus.Command;
const LogStorage = geode.distributed.raft_log_storage.LogStorage;

// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=RoundTripTest; STATUS=TESTED; TEST=log_storage_roundtrip; OWNER=distributed; UPDATED=2026-04-09

test "LogStorage: appendEntry writes entry, readAllEntries reads it back with matching fields" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    // Write an entry
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        const entry = LogEntry{
            .term = 3,
            .index = 1,
            .command = .noop,
            .timestamp = 1712678400000,
            .client_id = 42,
            .serial_number = 7,
        };

        try storage.appendEntry(entry);
    }

    // Reopen and read back
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        const entries = try storage.readAllEntries(allocator);
        defer {
            for (entries) |e| {
                switch (e.command) {
                    .write => |data| allocator.free(data),
                    else => {},
                }
            }
            allocator.free(entries);
        }

        try std.testing.expectEqual(@as(usize, 1), entries.len);
        const e = entries[0];
        try std.testing.expectEqual(@as(u64, 3), e.term);
        try std.testing.expectEqual(@as(u64, 1), e.index);
        try std.testing.expectEqual(@as(i64, 1712678400000), e.timestamp);
        try std.testing.expectEqual(@as(?u64, 42), e.client_id);
        try std.testing.expectEqual(@as(?u64, 7), e.serial_number);
        try std.testing.expectEqual(Command.noop, e.command);
    }
}

test "LogStorage: lastIndex returns 0 when empty, correct index after append" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_last.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    var storage = try LogStorage.init(allocator, file_path);
    defer storage.deinit();

    // Empty log
    const idx0 = try storage.lastIndex(allocator);
    try std.testing.expectEqual(@as(u64, 0), idx0);

    // Append two entries
    try storage.appendEntry(.{
        .term = 1,
        .index = 5,
        .command = .noop,
        .timestamp = 100,
        .client_id = null,
        .serial_number = null,
    });
    try storage.appendEntry(.{
        .term = 1,
        .index = 10,
        .command = .noop,
        .timestamp = 200,
        .client_id = null,
        .serial_number = null,
    });

    const idx10 = try storage.lastIndex(allocator);
    try std.testing.expectEqual(@as(u64, 10), idx10);
}

test "LogStorage: truncateAfter removes entries beyond last_index" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_trunc.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    var storage = try LogStorage.init(allocator, file_path);
    defer storage.deinit();

    // Append 3 entries with indices 1, 2, 3
    for (1..4) |i| {
        try storage.appendEntry(.{
            .term = 1,
            .index = @intCast(i),
            .command = .noop,
            .timestamp = @intCast(i * 100),
            .client_id = null,
            .serial_number = null,
        });
    }

    // Truncate after index 1 — should keep only index 1
    try storage.truncateAfter(1, allocator);

    const entries = try storage.readAllEntries(allocator);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 1), entries[0].index);
    try std.testing.expectEqual(@as(u64, 1), try storage.lastIndex(allocator));
}

test "LogStorage: write command round-trip preserves payload" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_write.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    var storage = try LogStorage.init(allocator, file_path);
    defer storage.deinit();

    const payload = "CREATE GRAPH mydb";

    try storage.appendEntry(.{
        .term = 2,
        .index = 1,
        .command = .{ .write = payload },
        .timestamp = 999,
        .client_id = null,
        .serial_number = 42,
    });

    const entries = try storage.readAllEntries(allocator);
    defer {
        for (entries) |e| {
            switch (e.command) {
                .write => |data| allocator.free(data),
                else => {},
            }
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    switch (entries[0].command) {
        .write => |data| {
            try std.testing.expectEqualStrings(payload, data);
        },
        else => return error.UnexpectedCommand,
    }
}

test "LogStorage: multi-entry ordering preserved across 10 entries with increasing term/index" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_order.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    // Write 10 entries with monotonically increasing term and index
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        for (1..11) |i| {
            try storage.appendEntry(.{
                .term = @intCast(i),
                .index = @intCast(i * 10),
                .command = .noop,
                .timestamp = @intCast(i * 1000),
                .client_id = @intCast(i + 100),
                .serial_number = @intCast(i + 200),
            });
        }
    }

    // Reopen and verify ordering + field values
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        const entries = try storage.readAllEntries(allocator);
        defer allocator.free(entries);

        try std.testing.expectEqual(@as(usize, 10), entries.len);

        for (entries, 1..) |e, i| {
            try std.testing.expectEqual(@as(u64, @intCast(i)), e.term);
            try std.testing.expectEqual(@as(u64, @intCast(i * 10)), e.index);
            try std.testing.expectEqual(@as(i64, @intCast(i * 1000)), e.timestamp);
            try std.testing.expectEqual(@as(?u64, @intCast(i + 100)), e.client_id);
            try std.testing.expectEqual(@as(?u64, @intCast(i + 200)), e.serial_number);
            try std.testing.expectEqual(Command.noop, e.command);
        }
    }
}

test "LogStorage: readAllEntries on fresh empty log returns empty slice" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_empty.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    var storage = try LogStorage.init(allocator, file_path);
    defer storage.deinit();

    const entries = try storage.readAllEntries(allocator);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "LogStorage: CRC corruption detected on read" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/raft_log_crc.bin",
        .{dir_path},
    );
    defer allocator.free(file_path);

    // Write a valid entry
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        try storage.appendEntry(.{
            .term = 1,
            .index = 1,
            .command = .noop,
            .timestamp = 100,
            .client_id = null,
            .serial_number = null,
        });
    }

    // Corrupt a byte in the record (flip a bit in the term field, which is at offset 4)
    {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.cwd().openFile(io_fs, file_path, .{ .mode = .read_write });
        defer f.close(io_fs);
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io_fs, &byte, 4);
        byte[0] ^= 0xFF;
        try f.writePositionalAll(io_fs, &byte, 4);
    }

    // Reading should detect CRC mismatch
    {
        var storage = try LogStorage.init(allocator, file_path);
        defer storage.deinit();

        const result = storage.readAllEntries(allocator);
        try std.testing.expectError(error.CrcMismatch, result);
    }
}
