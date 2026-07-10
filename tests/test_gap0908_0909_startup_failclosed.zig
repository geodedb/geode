// CANARY: REQ=REQ-GAP-0908-AUDIT-SINK-FAILCLOSED; FEATURE="AuditStartup"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0908_0909_startup_failclosed.zig:1; OWNER=security; UPDATED=2026-07-10
//
// Regression tests for:
//
//   GAP-0908 — "unwritable audit sink at startup crashes the server". The
//   serve path did `try gpa.create(AuditLogger)` + `try AuditLogger.init(...)`
//   back-to-back: an EACCES from the sink's createFile unwound the process
//   with an unhandled error AND leaked the heap allocation. The new
//   `AuditLogger.createHeap` propagates the typed error with the allocation
//   released, and src/server/main.zig turns it into a logged fail-closed
//   refusal (`error.AuditSinkUnavailable`).
//
//   GAP-0909 — "missing --data-dir crashes the server at startup". The new
//   `graph_store.ensureDataDir` (called from src/server/main.zig before any
//   consumer) creates the directory (mkdir -p) and only errors when creation
//   is impossible, which main turns into a clean `error.DataDirUnavailable`
//   refusal.
//
// The leak check is implicit: testing.allocator fails any test that leaks,
// which is exactly the GAP-0908 leak-on-error-path artifact.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");

const audit = geode.security.audit;
const graph_store = geode.graph_store;

fn tmpAbsPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{sub_path});
}

// chmod via the parent dir + sub_path (fchmodat); the tmp dir handle itself
// lacks the rights fchmod needs on Zig 0.16 std.Io.
fn chmodSub(dir: std.Io.Dir, sub_path: []const u8, mode: std.posix.mode_t) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.setFilePermissions(io, sub_path, std.Io.File.Permissions.fromMode(mode), .{});
}

test "GAP-0908: unwritable audit sink is a typed error with no leak" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The register's exact repro: chmod 000 the audit sink FILE. (A 0o000
    // file blocks the open while keeping the directory traversable, so the
    // build runner's cache scanning is unaffected.)
    const io = std.Io.Threaded.global_single_threaded.io();
    var f = try tmp.dir.createFile(io, "audit.jsonl", .{});
    f.close(io);
    chmodSub(tmp.dir, "audit.jsonl", 0o000) catch return error.SkipZigTest;
    defer chmodSub(tmp.dir, "audit.jsonl", 0o600) catch {};

    const sink_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/audit.jsonl",
        .{&tmp.sub_path},
    );
    defer testing.allocator.free(sink_path);

    const result = audit.AuditLogger.createHeap(testing.allocator, .{
        .enabled = true,
        .file_path = sink_path,
    });
    // EACCES surfaces as error.AccessDenied (or a sibling open error on some
    // kernels); the contract under test is: typed error out, no allocation
    // leaked, no unhandled-error crash.
    try testing.expect(std.meta.isError(result));
}

test "GAP-0908: disabled audit config never touches the sink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const logger = try audit.AuditLogger.createHeap(testing.allocator, .{
        .enabled = false,
        .file_path = "/nonexistent/dir/audit.jsonl",
    });
    defer {
        logger.deinit();
        testing.allocator.destroy(logger);
    }
    try testing.expect(logger.file == null);
}

test "GAP-0909: ensureDataDir creates a missing nested path (mkdir -p)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/does/not/exist/yet",
        .{&tmp.sub_path},
    );
    defer testing.allocator.free(missing);

    try graph_store.ensureDataDir(missing);

    // The directory must now exist (statable via open).
    const io = std.Io.Threaded.global_single_threaded.io();
    var d = try std.Io.Dir.cwd().openDir(io, missing, .{});
    d.close(io);

    // Idempotent: calling again on the now-existing path succeeds.
    try graph_store.ensureDataDir(missing);
}

test "GAP-0909: ensureDataDir under an unwritable parent errors cleanly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.createDirPath(io, "sealed");
    chmodSub(tmp.dir, "sealed", 0o500) catch return error.SkipZigTest;
    defer chmodSub(tmp.dir, "sealed", 0o700) catch {};

    const target = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/sealed/child",
        .{&tmp.sub_path},
    );
    defer testing.allocator.free(target);

    try testing.expect(std.meta.isError(graph_store.ensureDataDir(target)));
}
