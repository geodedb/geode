// CANARY: REQ=REQ-SONNY-6422-DEAD-WAL-FALSE-MARKERS; FEATURE="Governance"; ASPECT=NoDeadWalWrapperOrFalseTestedMarkers; STATUS=TESTED; TEST=tests/test_sonny6422_dead_wal_and_false_markers.zig; OWNER=storage; UPDATED=2026-11-12
//
// SONNY-6422 (3, 4, 5):
//   (3) `src/wal.zig` `WriteAheadLog` (the logical CDC WAL: record types,
//       serialization, the global instance and the mutation callback) has no
//       production caller since `initGlobalWal` was removed (SONNY-6325):
//       only tests/test_wal.zig opened one. The server installs only the
//       persistence hooks, with no WAL behind them. Its markers claimed a
//       TESTED delta-persistence WAL and TESTED WAL encryption.
//   (4) tests/test_key_rotation_schedule.zig was built by no step, yet its
//       marker claimed TESTED with the made-up test name
//       TestCANARY_REQ_GQL_SEC_KEYROT_002_Schedule; its two assertions are
//       the ones tests/test_gap0890_rotation_policy.zig runs.
//   (5) the CANARY block of docs/SECURITY_PROGRESS.md cited tests that do
//       not exist (Benchmark_encrypt_pages, TestPageEncryptionRoundTrip,
//       TestWalEncryptedSegment, tests/test_key_rotation.zig, ...) or that
//       no build step compiles.
//
// The contract: the dead wrapper is gone and nothing refers to it; the
// unbuilt duplicate test is gone and nothing cites it; every TEST= in the
// SECURITY_PROGRESS.md CANARY block names a test file that a build step
// compiles, or a `test "<name>"` in one, and a marker with no such test is
// not TESTED.
const std = @import("std");
const options = @import("sonny6422_dw_options");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

fn repoFileExists(allocator: std.mem.Allocator, rel: []const u8) !bool {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    std.Io.Dir.cwd().access(io(), abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Calls `visit` for every .zig file under `rel_dir` (recursively).
fn forEachZig(allocator: std.mem.Allocator, rel_dir: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8, []const u8) anyerror!void) !void {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel_dir });
    defer allocator.free(abs);
    var dir = try std.Io.Dir.cwd().openDir(io(), abs, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = try dir.readFileAlloc(io(), entry.path, allocator, .limited(64 << 20));
        defer allocator.free(text);
        try visit(ctx, entry.path, text);
    }
}

test "SONNY-6422 (3) the WriteAheadLog wrapper and its mutation callback are removed from src/wal.zig" {
    const allocator = testing.allocator;
    const src = try readRepoFile(allocator, "src/wal.zig");
    defer allocator.free(src);
    var bad: usize = 0;
    for ([_][]const u8{ "pub const WriteAheadLog", "pub const WalRecord", "g_wal_storage", "fn mutationCallback", "installMutationCallback", "GEODE_WAL_KEY", "fn loadWalKey", "REQ-TDE-ENFORCE-002", "REQ-PERF-WAL-001" }) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) {
            std.debug.print("SONNY-6422 (3): src/wal.zig still contains {s}\n", .{needle});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

const RefScan = struct {
    bad: usize = 0,
    root: []const u8,

    fn visit(self: *RefScan, path: []const u8, text: []const u8) anyerror!void {
        // This file names what it looks for.
        if (std.mem.eql(u8, std.fs.path.basename(path), "test_sonny6422_dead_wal_and_false_markers.zig")) return;
        for ([_][]const u8{ "wal.WriteAheadLog", "wal_mod.WriteAheadLog", "wal_mod.g_wal", "wal.g_wal", "installMutationCallback" }) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) {
                std.debug.print("SONNY-6422 (3): {s}/{s} still refers to {s}\n", .{ self.root, path, needle });
                self.bad += 1;
            }
        }
    }
};

test "SONNY-6422 (3) nothing in src/ or tests/ refers to the removed WriteAheadLog wrapper" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "src", "tests" }) |root| {
        var scan: RefScan = .{ .root = root };
        try forEachZig(allocator, root, &scan, RefScan.visit);
        bad += scan.bad;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6422 (4) the unbuilt duplicate key-rotation schedule test is gone and nothing cites its made-up test name" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    if (try repoFileExists(allocator, "tests/test_key_rotation_schedule.zig")) {
        std.debug.print("SONNY-6422 (4): tests/test_key_rotation_schedule.zig (built by no step) still exists\n", .{});
        bad += 1;
    }
    for ([_][]const u8{ "docs/status.csv", "tools/canaryscan/status.csv" }) |rel| {
        const text = try readRepoFile(allocator, rel);
        defer allocator.free(text);
        for ([_][]const u8{ "TestCANARY_REQ_GQL_SEC_KEYROT_002_Schedule", "test_key_rotation_schedule" }) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) {
                std.debug.print("SONNY-6422 (4): {s} still cites {s}\n", .{ rel, needle });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

/// Whether `name` is a test file a build step compiles, or the name of a
/// `test "<name>"` declared in such a file.
fn testExists(allocator: std.mem.Allocator, build_zig: []const u8, name: []const u8) !bool {
    // Harness specs live in the separate geode-test-harness repository.
    if (std.mem.startsWith(u8, name, "geodetestlab/")) return true;
    if (std.mem.endsWith(u8, name, ".zig")) {
        if (!try repoFileExists(allocator, name)) return false;
        var quoted_buf: [512]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{name});
        return std.mem.indexOf(u8, build_zig, quoted) != null;
    }
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, "tests" });
    defer allocator.free(abs);
    var dir = try std.Io.Dir.cwd().openDir(io(), abs, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    var decl_buf: [512]u8 = undefined;
    const decl = try std.fmt.bufPrint(&decl_buf, "test \"{s}\"", .{name});
    while (try it.next(io())) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        const text = try dir.readFileAlloc(io(), e.name, allocator, .limited(64 << 20));
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, decl) == null) continue;
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "\"tests/{s}\"", .{e.name});
        if (std.mem.indexOf(u8, build_zig, path) != null) return true;
    }
    return false;
}

fn field(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[start + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " ");
}

test "SONNY-6422 (5) every TESTED marker in the SECURITY_PROGRESS.md CANARY block cites a test a build step compiles" {
    const allocator = testing.allocator;
    const doc = try readRepoFile(allocator, "docs/SECURITY_PROGRESS.md");
    defer allocator.free(doc);
    const build_zig = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_zig);
    var bad: usize = 0;
    var markers: usize = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "CANARY: ")) continue;
        markers += 1;
        const req = field(line, "REQ=") orelse "?";
        const status = field(line, "STATUS=") orelse "";
        const tests = field(line, "TEST=");
        if (!std.mem.eql(u8, status, "TESTED")) continue;
        const list = tests orelse {
            std.debug.print("SONNY-6422 (5): {s} is TESTED with no TEST=\n", .{req});
            bad += 1;
            continue;
        };
        var names = std.mem.splitScalar(u8, list, '|');
        while (names.next()) |n| {
            if (!try testExists(allocator, build_zig, n)) {
                std.debug.print("SONNY-6422 (5): {s} cites {s}, which no build step compiles\n", .{ req, n });
                bad += 1;
            }
        }
    }
    try testing.expect(markers > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}
