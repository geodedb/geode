// CANARY: REQ=REQ-ADMIN-BOOTSTRAP-HARDEN-003; FEATURE="AdminBootstrapHardening"; ASPECT=Tests; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-15
// Issue #819 (CWE-538 file/dir info exposure, CWE-732 incorrect permissions):
// regression coverage for the data-dir permission check that runs before
// the server writes the auto-generated admin password file.
//
// Acceptance criteria (from issue #819 close-out plan):
//   - 0o700 dir is accepted as-is (no chmod).
//   - 0o755 dir is tightened to 0o700 in place (or refused if chmod fails).
//   - 0o777 dir is tightened to 0o700 in place (or refused if chmod fails).
//   - A dir we cannot stat returns a defined enum value, not a crash.
//   - Null arg (defaults to ".") returns a defined enum value.

const std = @import("std");
const testing = std.testing;

const data_dir_permissions = @import("data_dir_permissions");
const ensureSecureDataDirPermissions = data_dir_permissions.ensureSecureDataDirPermissions;
const DataDirPermissionResult = data_dir_permissions.DataDirPermissionResult;

const builtin = @import("builtin");

fn tmpAbsPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{sub_path});
}

// `tmp.dir.setPermissions` panics with BADF on Zig 0.16's std.Io because
// the tmp dir handle is opened without the rights needed by fchmod; chmod
// via the parent dir + sub_path works because that path uses fchmodat
// internally.  We must therefore re-derive the parent and apply the mode
// via setFilePermissions.
fn chmodTmpDir(tmp: *testing.TmpDir, mode: std.posix.mode_t) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.parent_dir.setFilePermissions(
        io,
        &tmp.sub_path,
        std.Io.File.Permissions.fromMode(mode),
        .{},
    );
}

test "0o700 data dir is accepted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    chmodTmpDir(&tmp, 0o700) catch return error.SkipZigTest;

    const path = try tmpAbsPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(path);

    try testing.expectEqual(DataDirPermissionResult.ok, ensureSecureDataDirPermissions(path));
}

test "0o755 data dir is tightened to 0o700" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    chmodTmpDir(&tmp, 0o755) catch return error.SkipZigTest;

    const path = try tmpAbsPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(path);

    const result = ensureSecureDataDirPermissions(path);
    // Acceptance: either tightened (preferred) or refuse (fail-closed) --
    // the API contract is that we never leave the secret-bearing dir at
    // 0o755 once this function returns.
    try testing.expect(result == .tightened or result == .refuse);

    if (result == .tightened) {
        var reopened = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer reopened.close(io);
        const stat = try reopened.stat(io);
        const mode_after: u32 = @intCast(stat.permissions.toMode() & 0o777);
        try testing.expectEqual(@as(u32, 0o700), mode_after);
    }
}

test "0o777 data dir is tightened to 0o700" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    chmodTmpDir(&tmp, 0o777) catch return error.SkipZigTest;

    const path = try tmpAbsPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(path);

    const result = ensureSecureDataDirPermissions(path);
    try testing.expect(result == .tightened or result == .refuse);

    if (result == .tightened) {
        var reopened = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer reopened.close(io);
        const stat = try reopened.stat(io);
        const mode_after: u32 = @intCast(stat.permissions.toMode() & 0o777);
        try testing.expectEqual(@as(u32, 0o700), mode_after);
    }
}

test "0o740 (group-readable only) is also tightened" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    chmodTmpDir(&tmp, 0o740) catch return error.SkipZigTest;

    const path = try tmpAbsPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(path);

    const result = ensureSecureDataDirPermissions(path);
    try testing.expect(result == .tightened or result == .refuse);
}

test "missing data dir returns .unknown (does not crash)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const missing = "/tmp/geode-no-such-dir-issue819-test";
    try testing.expectEqual(DataDirPermissionResult.unknown, ensureSecureDataDirPermissions(missing));
}

test "null arg yields a defined result" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = ensureSecureDataDirPermissions(null);
    try testing.expect(result == .ok or result == .tightened or
        result == .unknown or result == .not_applicable);
}
