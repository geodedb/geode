// SONNY-6596 item 5: no dead spill-limit plumbing.
//
// The server read GEODE_SPILL_THRESHOLD_BYTES / GEODE_QUERY_MEM_LIMIT_BYTES
// at startup (src/server/server_init.zig processEnvironmentVariables) and
// copied the value through main.zig into every QUIC and gRPC session's
// `ServerState.query_mem_limit_bytes`, which nothing read: the executor
// never spills and never limits a query's memory (SONNY-6562). The docs said
// the variables were "read, changes nothing". The plumbing is removed and
// the docs say the variables are not read; this keeps it from coming back
// as a setting that looks like it does something.
//
// CANARY: REQ=REQ-SONNY-6596-NO-SPILL-PLUMBING; FEATURE="ServerConfig"; ASPECT=NoDeadSpillLimit; STATUS=TESTED; TEST=tests/test_sonny6596_spill_plumbing.zig; OWNER=server; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

test "SONNY-6596: no session field holds a query memory limit nothing enforces" {
    try testing.expect(!@hasField(geode.server_state.ServerState, "query_mem_limit_bytes"));
}

/// The files of `dir` (recursively) whose text contains `needle`.
fn countMentions(a: std.mem.Allocator, io: std.Io, dir_path: []const u8, needle: []const u8, ext: []const u8, found: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ext)) continue;
        const text = dir.readFileAlloc(io, entry.path, a, .limited(64 << 20)) catch continue;
        defer a.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) {
            try found.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.path }));
        }
    }
}

test "SONNY-6596: no server source reads GEODE_SPILL_THRESHOLD_BYTES or GEODE_QUERY_MEM_LIMIT_BYTES" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |f| a.free(f);
        found.deinit(a);
    }
    for ([_][]const u8{ "GEODE_SPILL_THRESHOLD_BYTES", "GEODE_QUERY_MEM_LIMIT_BYTES" }) |name| {
        try countMentions(a, io, "src", name, ".zig", &found);
    }
    for (found.items) |f| std.debug.print("still mentions the spill variables: {s}\n", .{f});
    try testing.expectEqual(@as(usize, 0), found.items.len);
}
