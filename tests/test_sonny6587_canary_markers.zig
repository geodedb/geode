// SONNY-6587 item 6: a CANARY marker in src/canary.zig that says TESTED names
// a test that exists.
//
// REQ-GQL-016 "Weighted Path Cost" claimed STATUS=TESTED by a
// TestCANARY_REQ_GQL_016 test name that no source defines; the
// only weighted shortest-path test (tests/test_match_call_integration.zig)
// parses the query and never checks a cost. The checked requirements are
// listed below; each TEST= name of a TESTED marker for them must occur in a
// .zig file under src/ or tests/ other than src/canary.zig.
//
// CANARY: REQ=REQ-SONNY-6587-CANARY-TRUTH; FEATURE="Governance"; ASPECT=CanaryTestExists; STATUS=TESTED; TEST=tests/test_sonny6587_canary_markers.zig; OWNER=governance; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;

const checked = [_][]const u8{"REQ-GQL-016"};

fn defined(a: std.mem.Allocator, io: std.Io, name: []const u8) !bool {
    for ([_][]const u8{ "src", "tests" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.eql(u8, root, "src") and std.mem.eql(u8, entry.path, "canary.zig")) continue;
            // This file names what it looks for.
            if (std.mem.eql(u8, root, "tests") and std.mem.eql(u8, entry.path, "test_sonny6587_canary_markers.zig")) continue;
            const text = dir.readFileAlloc(io, entry.path, a, .limited(64 << 20)) catch continue;
            defer a.free(text);
            if (std.mem.indexOf(u8, text, name) != null) return true;
        }
    }
    return false;
}

test "SONNY-6587: a TESTED marker in src/canary.zig names a test that exists" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "src/canary.zig", a, .limited(1 << 20));
    defer a.free(text);
    var missing: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "STATUS=TESTED") == null) continue;
        const req_at = std.mem.indexOf(u8, line, "REQ=") orelse continue;
        const req_end = std.mem.indexOfScalarPos(u8, line, req_at, ';') orelse continue;
        const req = line[req_at + 4 .. req_end];
        const is_checked = for (checked) |c| {
            if (std.mem.eql(u8, c, req)) break true;
        } else false;
        if (!is_checked) continue;
        const test_at = std.mem.indexOf(u8, line, "TEST=") orelse {
            std.debug.print("{s}: TESTED with no TEST=\n", .{req});
            missing += 1;
            continue;
        };
        const test_end = std.mem.indexOfScalarPos(u8, line, test_at, ';') orelse line.len;
        var names = std.mem.splitScalar(u8, line[test_at + 5 .. test_end], ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (!try defined(a, io, name)) {
                std.debug.print("{s}: claims TESTED by {s}, which no source defines\n", .{ req, name });
                missing += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
