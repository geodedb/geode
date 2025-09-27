const std = @import("std");
const builtin = @import("builtin");

pub const Recorder = struct {
    dir_sync_calls: usize = 0,
    durable_renames: usize = 0,
};

pub var test_recorder: ?*Recorder = null;

pub fn registerRecorder(r: *Recorder) void {
    test_recorder = r;
}

pub fn fsyncParent(path: []const u8) !void {
    if (builtin.os.tag == .windows) return; // no-op on Windows
    _ = path; // avoid EINVAL on directory fsync in some environments; fall back to global sync
    std.posix.sync();
    if (test_recorder) |rec| rec.dir_sync_calls += 1;
}

pub fn durableRename(old_path: []const u8, new_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        try durableRenameWindows(old_path, new_path);
    } else {
        try std.fs.cwd().rename(old_path, new_path);
        try fsyncParent(new_path);
    }
    if (test_recorder) |rec| rec.durable_renames += 1;
}

fn durableRenameWindows(old_path: []const u8, new_path: []const u8) !void {
    const windows = std.os.windows;
    const k32 = windows.kernel32;
    const utf16Old = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, old_path);
    defer std.heap.page_allocator.free(utf16Old);
    const utf16New = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, new_path);
    defer std.heap.page_allocator.free(utf16New);
    const flags: windows.DWORD = windows.MOVEFILE_REPLACE_EXISTING | windows.MOVEFILE_WRITE_THROUGH;
    if (k32.MoveFileExW(@ptrCast(utf16Old.ptr), @ptrCast(utf16New.ptr), flags) == 0) return error.RenameFailed;
}
