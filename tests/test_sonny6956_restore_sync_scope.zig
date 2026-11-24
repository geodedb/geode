// SONNY-6956: a durable restore syncs the files and directories it wrote,
// never the whole filesystem.
//
// SONNY-6300 made a staged restore durable with one syncfs(2) of the
// filesystem holding the staging directory, instead of an fsync per file as
// it wrote each one (about 700 for a tiny two-graph store, over 10 s on a
// loaded disk). syncfs writes back every dirty page of that filesystem,
// whoever dirtied it: a restore of a tiny store answered in 0.9 s on an idle
// disk and in 5.6 s with 7.6 GB of another process's writes pending on the
// same filesystem, and on loaded CI runners (sharing the disk with build
// caches) server and CLI restores ran past their 120 s deadlines
// (test-sonny6322-audit-seed-and-hmac-startup, test-sonny6280-cli-restore-
// writes-data). The restore's time must depend on what it wrote, not on the
// machine's other writers.
//
// `graph_archive.writeTree`, the one write path of a staged restore
// (`backup.stageRestore`) and of a Raft snapshot install, writes a 200-file
// archive in nested directories durably:
//   - it syncs every file and every directory it wrote (and the parent
//     holding the restore directory's entry), each exactly once,
//     and nothing else (the returned sync count: one syncfs before the fix),
//     and the tree reads back byte for byte;
//   - the syncs run on several threads for a tree this size
//     (`graph_archive.durableSyncWorkers`), so they are not one fsync after
//     another, which SONNY-6300 measured at over 10 s.
//
// CANARY: REQ=REQ-SONNY-6956-RESTORE-SYNC-SCOPE; FEATURE="Backup Restore"; ASPECT=SyncOwnFilesOnly; STATUS=TESTED; TEST=tests/test_sonny6956_restore_sync_scope.zig; OWNER=storage; UPDATED=2026-11-24

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const graph_archive = geode.graph_archive;
const test_scratch = @import("test_scratch.zig");

const GRAPHS: usize = 4;
const SHARDS: usize = 2;
const FILES: usize = 25;

test "SONNY-6956: a durable restore syncs every file and directory it wrote once, and nothing else" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6956-sync-scope");
    defer root.remove();

    var b = try graph_archive.Builder.init(a);
    errdefer b.deinit(a);
    for (0..GRAPHS) |g| for (0..SHARDS) |s| for (0..FILES) |f| {
        var name_buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "graph{d}/shard{d}/file{d}.store", .{ g, s, f });
        var data_buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "graph {d} shard {d} file {d}", .{ g, s, f });
        try b.appendBytes(a, name, data);
    };
    const payload = try b.finish(a);
    defer a.free(payload);

    const dst = try std.fmt.allocPrint(a, "{s}/restored", .{root.path()});
    defer a.free(dst);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dst);

    const files = GRAPHS * SHARDS * FILES;
    // The restore's directory, its parent (for its entry), each graph's and
    // each shard's.
    const dirs = 2 + GRAPHS + GRAPHS * SHARDS;
    const syncs = try graph_archive.writeTree(a, dst, payload, "", true);
    std.debug.print("SONNY-6956: a durable write of {d} files in {d} directories made {d} syncs\n", .{ files, dirs, syncs });

    try testing.expectEqual(@as(u32, @intCast(files + dirs)), syncs);
    const stats = try graph_archive.verifyTree(a, dst, payload, "");
    try testing.expectEqual(@as(u32, @intCast(files)), stats.files);
}

test "SONNY-6956: the syncs of a large tree run on several threads, of a single file on one" {
    if (comptime !@hasDecl(graph_archive, "durableSyncWorkers")) {
        std.debug.print("SONNY-6956: graph_archive has no durableSyncWorkers: a durable write syncs the filesystem once, whatever it holds\n", .{});
        return error.TestUnexpectedResult;
    } else {
        try testing.expectEqual(@as(usize, 1), graph_archive.durableSyncWorkers(1));
        try testing.expect(graph_archive.durableSyncWorkers(213) > 1);
        try testing.expect(graph_archive.durableSyncWorkers(700) > 1);
    }
}
