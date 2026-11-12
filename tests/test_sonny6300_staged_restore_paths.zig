// CANARY: REQ=REQ-SONNY-6300-STAGED-RESTORE-ONLY; FEATURE="Backup Restore"; ASPECT=NoInPlaceRestoreOneSyncTimeouts; STATUS=TESTED; TEST=tests/test_sonny6300_staged_restore_paths.zig; OWNER=storage; UPDATED=2026-11-12
//
// SONNY-6300:
//   (1) BackupManager.restoreToPointInTime still wrote a backup over the
//       directory it was given (the live data directory included) and then
//       reopened the process-global adapter through deinitGlobalAdapter, which
//       checkpoints the old in-memory state over the restored files.
//       S3BackupManager.restore called it. SONNY-6288 had removed the server
//       callers only.
//   (3) the staged restore fsynced every file it wrote: about 700 files for a
//       tiny two-graph store, over 10 s on a loaded disk, while the CLI waited
//       a fixed 30 s for the server's answer.
//   (2) a live in-place restore (swap the store under a running server) is
//       not implemented; a server restore writes beside the data directory and
//       the server is restarted on it (SONNY-6288). Not tested here: it is a
//       feature, not a defect.
//
// The contract:
//   - BackupManager has no in-place restore; its restore goes through the
//     staged, verified path: into a new or empty directory only, never over a
//     store (the live data directory is refused and left byte for byte);
//   - a staged restore makes the archive durable with a constant number of
//     sync calls (one filesystem sync of the staging copy, one directory sync
//     after the rename), not one per file;
//   - `geode restore --server` and `geode backup create` take --timeout
//     <seconds> for the server's answer; a value that is not a positive
//     number of seconds is a usage error.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const geode_binary = geode_test_bin.geode_exe;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn initAdapterForDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);
}

fn resetGlobalStorage(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, null);
}

/// Every regular file under `root` with its bytes, keyed by relative path.
fn snapshotTree(allocator: std.mem.Allocator, root: []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(allocator);
    errdefer freeSnapshot(allocator, &map);
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), root, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file) continue;
        const path = try join(allocator, root, entry.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path);
        errdefer allocator.free(bytes);
        const key = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(key);
        try map.put(key, bytes);
    }
    return map;
}

fn freeSnapshot(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit();
}

// ===========================================================================
// (1) no in-place restore
// ===========================================================================

test "SONNY-6300 (1) BackupManager has no in-place restore: its restore writes only a new or empty directory and refuses the live data directory" {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6300-inplace");
    defer root.remove();
    // Close the stores before their directories go.
    defer resetGlobalStorage(allocator);

    if (comptime @hasDecl(backup.BackupManager, "restoreToPointInTime")) {
        std.debug.print("SONNY-6300: BackupManager.restoreToPointInTime still writes a backup over the directory it is given and reopens the global adapter over it (src/storage/backup.zig); S3BackupManager.restore calls it\n", .{});
        return error.TestUnexpectedResult;
    } else if (comptime !@hasDecl(backup.BackupManager, "restoreInto")) {
        std.debug.print("SONNY-6300: BackupManager has no staged restore (restoreInto)\n", .{});
        return error.TestUnexpectedResult;
    } else {
        const data_dir = try join(allocator, root.path(), "live");
        defer allocator.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(fsIo(), data_dir);
        try initAdapterForDir(allocator, data_dir);

        var store = try graph_store.GraphStore.init(allocator);
        defer store.deinit();
        store.data_dir = data_dir;
        const n = try store.createNode(&.{"Sonny6300"});
        try store.setNodeProperty(n, "name", .{ .String = "kept" });
        try store.saveToFile();

        const backup_dir = try join(allocator, root.path(), "backups");
        defer allocator.free(backup_dir);
        var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
        defer mgr.deinit();
        const meta = try mgr.createFullBackup();

        // The live data directory: refused, unchanged.
        var before = try snapshotTree(allocator, data_dir);
        defer freeSnapshot(allocator, &before);
        try testing.expectError(error.RestoreTargetNotEmpty, mgr.restoreInto(data_dir, meta.timestamp + 1, .{}));
        var after = try snapshotTree(allocator, data_dir);
        defer freeSnapshot(allocator, &after);
        try testing.expectEqual(before.count(), after.count());
        var it = before.iterator();
        while (it.next()) |e| {
            const now = after.get(e.key_ptr.*) orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, e.value_ptr.*, now);
        }

        // A new directory: restored, opened cold, the node is there.
        const target = try join(allocator, root.path(), "restored");
        defer allocator.free(target);
        var restored = try mgr.restoreInto(target, meta.timestamp + 1, .{});
        defer restored.deinit();
        var nodes: u64 = 0;
        for (restored.graphs) |g| nodes += g.nodes;
        try testing.expect(nodes >= 1);
        const reg = try join(allocator, target, "graph_registry.dat");
        defer allocator.free(reg);
        const reg_bytes = try readFileAlloc(allocator, reg);
        defer allocator.free(reg_bytes);
        try testing.expect(reg_bytes.len > 0);
    }
}

// ===========================================================================
// (3) one sync, not one per file
// ===========================================================================

test "SONNY-6300 (3) a staged restore of 700 files makes them durable with a constant number of syncs, not one per file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6300-sync");
    defer root.remove();
    // Close the stores before their directories go.
    defer resetGlobalStorage(allocator);

    const data_dir = try join(allocator, root.path(), "data");
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), data_dir);
    try initAdapterForDir(allocator, data_dir);
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try store.createNode(&.{"Sonny6300"});
    try store.saveToFile();
    // The shape of a small sharded store: many small files in nested
    // directories (16 shards x ~20 files per graph).
    var g: usize = 0;
    while (g < 2) : (g += 1) {
        var s: usize = 0;
        while (s < 16) : (s += 1) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const shard = try std.fmt.bufPrint(&path_buf, "{s}/sonny6300-graph{d}/graphs/shard{d}", .{ data_dir, g, s });
            try std.Io.Dir.cwd().createDirPath(fsIo(), shard);
            var f: usize = 0;
            while (f < 22) : (f += 1) {
                var fbuf: [std.fs.max_path_bytes]u8 = undefined;
                const fp = try std.fmt.bufPrint(&fbuf, "{s}/file{d}.store", .{ shard, f });
                var content: [64]u8 = undefined;
                const c = try std.fmt.bufPrint(&content, "graph {d} shard {d} file {d}", .{ g, s, f });
                try writeFile(fp, c);
            }
        }
    }

    const backup_dir = try join(allocator, root.path(), "backups");
    defer allocator.free(backup_dir);
    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    const bpath = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(bpath);
    var decoded = try backup.readBackupFile(allocator, bpath, null);
    defer decoded.deinit(allocator);
    try testing.expect(decoded.stats.files >= 700);

    const target = try join(allocator, root.path(), "restored");
    defer allocator.free(target);
    var staged = try backup.stageRestore(allocator, decoded.archive, target);
    defer staged.deinit();
    try staged.commit();

    if (comptime !@hasField(backup.StagedRestore, "syncs")) {
        std.debug.print("SONNY-6300: a staged restore of {d} files syncs each file it writes (src/storage/backup.zig restorePerGraphPayload: out.sync per file); there is no count of its syncs\n", .{decoded.stats.files});
        return error.TestUnexpectedResult;
    } else {
        if (staged.syncs > 4) {
            std.debug.print("SONNY-6300: a staged restore of {d} files issued {d} sync calls\n", .{ decoded.stats.files, staged.syncs });
            return error.TestUnexpectedResult;
        }
        // Every file is there (the restore is not weakened).
        var restored = try snapshotTree(allocator, target);
        defer freeSnapshot(allocator, &restored);
        try testing.expectEqual(@as(usize, decoded.stats.files), restored.count());
    }
}

// ===========================================================================
// (3) configurable client timeouts
// ===========================================================================

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6300 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

test "SONNY-6300 (3) geode restore --server and geode backup create take --timeout <seconds> for the server's answer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6300-timeout");
    defer root.remove();
    const cwd = root.path();

    const help_cases = [_][]const []const u8{
        &.{ geode_binary, "restore", "--help" },
        &.{ geode_binary, "backup", "create", "--help" },
    };
    for (help_cases) |argv| {
        const r = try runGeode(argv, cwd);
        defer r.deinit();
        if (!r.output("--timeout")) {
            r.dump("help without --timeout");
            std.debug.print("SONNY-6300: 'geode {s}{s}{s} --help' lists no --timeout: the wait for the server's answer is a fixed 30 s (src/cli/backup_cli.zig readProtoMessage(..., 30000))\n", .{ argv[1], if (argv.len > 3) " " else "", if (argv.len > 3) argv[2] else "" });
            return error.TestUnexpectedResult;
        }
    }

    // Not a positive number of seconds: a usage error naming --timeout,
    // before any server is contacted (port 1 has none).
    const bad = [_][]const u8{ "0", "-5", "abc", "" };
    for (bad) |v| {
        const cases = [_][]const []const u8{
            &.{ geode_binary, "restore", "--server", "127.0.0.1:1", "--yes", "--timeout", v },
            &.{ geode_binary, "backup", "create", "--output", "x.backup", "--server", "127.0.0.1:1", "--timeout", v },
        };
        for (cases) |argv| {
            const r = try runGeode(argv, cwd);
            defer r.deinit();
            if (r.code != @as(?u8, 2) or !r.output("--timeout")) {
                r.dump("bad --timeout");
                return error.TestUnexpectedResult;
            }
        }
    }
    // Nothing was written by the refused backup.
    const x = try join(testing.allocator, cwd, "x.backup");
    defer testing.allocator.free(x);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(fsIo(), x, .{}));
}
