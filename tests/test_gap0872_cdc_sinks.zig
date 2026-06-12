//! GAP-0872 regression: CDC cloud sinks (Kinesis / PubSub) are NOT implemented
//! and must fail LOUD at construction time instead of silently discarding
//! events. Before this fix, configuring a Kinesis or PubSub sink succeeded and
//! every send() returned success while dropping the events on the floor —
//! silent data loss for any operator who trusted the advertised sink list.
//!
//! Contract pinned here:
//!   * CDCEngine.init with a `.kinesis` or `.pubsub` sink returns
//!     `error.SinkNotImplemented` (fail-fast at config/startup time).
//!   * A mixed sink list containing a stub sink also fails, and the partially
//!     constructed engine leaks nothing (std.testing.allocator enforces this).
//!   * The REAL sinks keep working: memory/webhook/file still construct, and a
//!     FileSink round-trip actually persists events to disk.
//
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CloudSinkFailLoud; STATUS=TESTED; TEST=test_gap0872_cdc_sinks; OWNER=streaming; UPDATED=2026-06-11

const std = @import("std");
const geode = @import("geode");

const cdc = geode.streaming.cdc_enhanced;
const cdc_sinks = geode.streaming.cdc_sinks;

const CDCEngine = cdc.CDCEngine;
const CDCConfig = cdc.CDCConfig;
const CDCSink = cdc.CDCSink;
const ChangeEvent = cdc.ChangeEvent;
const FileSink = cdc_sinks.FileSink;

test "GAP-0872: kinesis sink construction fails loud with SinkNotImplemented" {
    const allocator = std.testing.allocator;

    var sinks: [1]CDCSink = .{.kinesis};
    const config = CDCConfig{
        .enabled = true,
        .sinks = &sinks,
    };

    try std.testing.expectError(error.SinkNotImplemented, CDCEngine.init(allocator, config));
}

test "GAP-0872: pubsub sink construction fails loud with SinkNotImplemented" {
    const allocator = std.testing.allocator;

    var sinks: [1]CDCSink = .{.pubsub};
    const config = CDCConfig{
        .enabled = true,
        .sinks = &sinks,
    };

    try std.testing.expectError(error.SinkNotImplemented, CDCEngine.init(allocator, config));
}

test "GAP-0872: mixed sink list with a stub sink fails loud and leaks nothing" {
    const allocator = std.testing.allocator;

    // A real sink FIRST, then the stub: the partially constructed sink list
    // must be torn down on the error path (std.testing.allocator catches any
    // leak of the already-appended memory sink).
    var sinks: [2]CDCSink = .{ .memory, .kinesis };
    const config = CDCConfig{
        .enabled = true,
        .sinks = &sinks,
    };

    try std.testing.expectError(error.SinkNotImplemented, CDCEngine.init(allocator, config));
}

test "GAP-0872: real sinks (memory, webhook, file) still construct" {
    const allocator = std.testing.allocator;

    var sinks: [3]CDCSink = .{ .memory, .webhook, .file };
    const config = CDCConfig{
        .enabled = true,
        .sinks = &sinks,
    };

    var engine = try CDCEngine.init(allocator, config);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 3), engine.sinks.items.len);
}

test "GAP-0872: file sink round-trip persists events to disk" {
    const allocator = std.testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/gap0872_cdc.log", .{tmp.sub_path});
    defer allocator.free(rel_path);

    var sink = try FileSink.init(allocator, rel_path);
    defer sink.deinit();

    var metadata = std.StringHashMap([]const u8).init(allocator);
    defer metadata.deinit();

    const events = [_]ChangeEvent{
        .{
            .timestamp = 1,
            .transaction_id = 7,
            .sequence = 42,
            .change_type = .insert,
            .entity_type = .node,
            .entity_id = 99,
            .before = null,
            .after = "{\"id\":99}",
            .metadata = metadata,
        },
    };

    try sink.send(&events);

    // Read back and verify the event actually landed on disk.
    const file = try std.Io.Dir.cwd().openFile(io_fs, rel_path, .{});
    defer file.close(io_fs);

    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io_fs, &reader_buf);
    const content = try file_reader.interface.allocRemaining(allocator, .limited(8192));
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"seq\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"insert\"") != null);
}
