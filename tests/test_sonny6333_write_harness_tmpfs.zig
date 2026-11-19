// SONNY-6333: the long write suites (test-sonny-write-allowlist,
// test-sonny-write-allowlist-r4b, test-sonny3139-write-shapes, and the other
// tests on tests/sonny738_write_harness.zig) did not finish in 40-60 minutes
// on a loaded host. Each case opens a persisted store, writes, reloads and
// closes it, in three persisted sessions; on the shared ext4 disk the test
// thread sat in jbd2_log_wait_commit (fsync waiting on the journal) at about
// 14% of one core with 5 to 10 threads, and test-sonny3139-write-shapes was
// still running at its 25-minute cap.
//
// The harness now puts a persisted session's store on tmpfs (/dev/shm) when
// the host has one: the storage code paths are the same, and fsync there
// returns at once. Checked here: a persisted session's data directory is on
// /dev/shm when /dev/shm exists, the store really is persisted there (the
// adapter is open and its files are in that directory), and the directory
// is removed when the session ends.
//
// CANARY: REQ=REQ-SONNY-6333-WRITE-HARNESS-TMPFS; FEATURE="Test Infrastructure"; ASPECT=WriteHarnessStoresOnTmpfs; STATUS=TESTED; TEST=tests/test_sonny6333_write_harness_tmpfs.zig; OWNER=storage; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const h = @import("sonny738_write_harness.zig");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

test "SONNY-6333 a persisted write-harness session keeps its store on tmpfs and removes it at the end" {
    // SONNY-6801: the harness uses /dev/shm only when it has room.
    if (builtin.os.tag != .linux or !exists("/dev/shm") or !h.shmUsable()) return error.SkipZigTest;
    for ([_]h.Mode{ .persisted, .tenant_scoped, .rls_policy }) |mode| {
        var dir_copy: [std.fs.max_path_bytes]u8 = undefined;
        var dir_len: usize = 0;
        {
            var s = try h.Session.init(mode);
            defer s.deinit();
            const dir = s.data_dir.?;
            if (!std.mem.startsWith(u8, dir, "/dev/shm/")) {
                std.debug.print("SONNY-6333 [{s}]: the persisted store is at {s}, not on tmpfs (/dev/shm)\n", .{ @tagName(mode), dir });
                return error.TestUnexpectedResult;
            }
            try testing.expect(h.graph_store.getGlobalAdapter() != null);
            try s.seed();
            var d = try std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true });
            defer d.close(io());
            var it = d.iterate();
            try testing.expect((try it.next(io())) != null);
            @memcpy(dir_copy[0..dir.len], dir);
            dir_len = dir.len;
        }
        if (exists(dir_copy[0..dir_len])) {
            std.debug.print("SONNY-6333 [{s}]: {s} is left behind after the session\n", .{ @tagName(mode), dir_copy[0..dir_len] });
            return error.TestUnexpectedResult;
        }
    }
}
