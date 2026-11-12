// CANARY: REQ=REQ-SONNY-6323-LOCAL-BACKUP-ONCE; FEATURE="Local Directory Backup"; ASPECT=WrittenOnceAtOutput; STATUS=TESTED; TEST=tests/test_sonny6323_local_backup_written_once.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6323:
//   (1) `geode backup create --local` wrote the backup as
//       full_<id>.backup plus metadata.json in the --output file's directory
//       and then copied it to --output: every local backup was written twice
//       and left two extra files behind;
//   (3) BackupManager.runRetention called deleteFile without its io argument
//       (it could not compile) and was reached only through
//       SimplifiedBackupManager.runRetention, which nothing calls: dead code.
//       tests/test_server_backup_api_integration.zig (and the other backup
//       test files that called the removed in-place restore) were never built.
//   (2) createFullBackup's /tmp data-directory fallback was removed by
//       SONNY-6325 (error.BackupDataDirUnknown); asserted again here.
//   (4) QuicProtoClient.backup's fixed 10 s reply deadline became a soft
//       deadline extended while the server is alive by SONNY-6301
//       (test-sonny6301-test-ports-and-timeouts).
//
// The contract:
//   - a local backup is written once, at --output (0600), and nothing else
//     is created in that directory; it restores;
//   - BackupManager and SimplifiedBackupManager have no runRetention;
//   - createFullBackup with no data directory is refused.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const geode_binary = geode_test_bin.geode_exe;
const admin_pw = "Correct horse battery staple sonny";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn listNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6323 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, env_kv: []const [2][]const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(300), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

test "SONNY-6323 (1) geode backup create --local writes the backup once, at --output, and nothing else beside it; it restores" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6323-local");
    defer root.remove();
    const cwd = root.path();

    // A real store: the offline auth bootstrap writes __geode_security and
    // the HMAC key.
    const d = try join(allocator, cwd, "D");
    defer allocator.free(d);
    try std.Io.Dir.cwd().createDirPath(fsIo(), d);
    {
        const r = try runGeode(&.{ geode_binary, "auth", "init", "--data-dir", d }, cwd, &.{.{ "GEODE_ADMIN_PASSWORD", admin_pw }});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("auth init");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }

    const out_dir = try join(allocator, cwd, "out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), out_dir);
    const out = try join(allocator, out_dir, "nightly.backup");
    defer allocator.free(out);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", out }, cwd, &.{});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("backup create --local");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }

    const names = try listNames(allocator, out_dir);
    defer freeNames(allocator, names);
    if (names.len != 1 or !std.mem.eql(u8, names[0], "nightly.backup")) {
        std.debug.print("SONNY-6323: backup create --local left {d} entries in {s}:", .{ names.len, out_dir });
        for (names) |n| std.debug.print(" {s}", .{n});
        std.debug.print(" (written as full_<id>.backup + metadata.json, then copied: src/cli/backup_cli.zig executeLocalDirectoryBackup)\n", .{});
        return error.TestUnexpectedResult;
    }
    const st = try std.Io.Dir.cwd().statFile(fsIo(), out, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));

    // It is a complete backup: it decodes and restores.
    var decoded = try backup.readBackupFile(allocator, out, null);
    defer decoded.deinit(allocator);
    try testing.expect(decoded.stats.files > 0);
    const t = try join(allocator, cwd, "T");
    defer allocator.free(t);
    const hk = try join(allocator, d, ".geode_hmac_key");
    defer allocator.free(hk);
    {
        const r = try runGeode(&.{ geode_binary, "restore", out, "--data-dir", t, "--yes", "--hmac-key-file", hk }, cwd, &.{});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("restore of the local backup");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    const reg_src = try join(allocator, d, "graph_registry.dat");
    defer allocator.free(reg_src);
    const reg_dst = try join(allocator, t, "graph_registry.dat");
    defer allocator.free(reg_dst);
    const a = try readFileAlloc(allocator, reg_src);
    defer allocator.free(a);
    const b = try readFileAlloc(allocator, reg_dst);
    defer allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "SONNY-6323 (3) the dead retention code is gone" {
    var failures: usize = 0;
    if (@hasDecl(backup.BackupManager, "runRetention")) {
        std.debug.print("SONNY-6323: BackupManager.runRetention is still there (it calls deleteFile without io and cannot compile; nothing reaches it)\n", .{});
        failures += 1;
    }
    const allocator = testing.allocator;
    const src = try readFileAlloc(allocator, "src/server/backup_manager.zig");
    defer allocator.free(src);
    if (std.mem.indexOf(u8, src, "fn runRetention(") != null) {
        std.debug.print("SONNY-6323: SimplifiedBackupManager.runRetention is still there (src/server/backup_manager.zig); nothing calls it\n", .{});
        failures += 1;
    }
    // Backup test files no build step compiles, which called the removed
    // in-place restore and retention.
    for ([_][]const u8{
        "tests/test_server_backup_api_integration.zig",
        "tests/test_server_backup_api_unit.zig",
        "tests/test_backup_e2e.zig",
        "tests/test_backup_comprehensive_integration.zig",
        "tests/canary_backup_restore.zig",
    }) |path| {
        if (std.Io.Dir.cwd().access(fsIo(), path, .{})) |_| {
            std.debug.print("SONNY-6323: {s} is still in the tree; no build step compiles it\n", .{path});
            failures += 1;
        } else |_| {}
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6323 (2) createFullBackup with no data directory is refused, never /tmp" {
    const allocator = testing.allocator;
    if (std.c.getenv("GEODE_DATA_DIR") != null) return error.SkipZigTest;
    graph_store.setDataDirOverride(allocator, null);
    var root = try test_scratch.ScratchDir.create("sonny6323-nodir");
    defer root.remove();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try backup.BackupManager.init(allocator, root.path(), .{}, &store);
    defer mgr.deinit();
    try testing.expectError(error.BackupDataDirUnknown, mgr.createFullBackup());
}
