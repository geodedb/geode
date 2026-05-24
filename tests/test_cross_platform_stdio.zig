const std = @import("std");
const builtin = @import("builtin");

test "cross-platform stdio handles" {
    // Test that we can correctly create File handles for stdin, stdout,
    // stderr on both Windows and POSIX systems.  Zig 0.16 retired
    // `std.fs.File` in favor of `std.Io.File` (see lib/std/Io/File.zig);
    // the standard helpers `File.stdout()` / `File.stderr()` /
    // `File.stdin()` are cross-platform-correct and avoid having to
    // hand-stitch a File from raw OS handles per branch.  Write is via
    // `writeStreamingAll(io, bytes)` since `Io.File` no longer exposes
    // a direct `writeAll` method.
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    const stdin = std.Io.File.stdin();

    try stdout.writeStreamingAll(io, "Test stdout\n");
    try stderr.writeStreamingAll(io, "Test stderr\n");

    // Verify stdin handle is valid; we don't actually read since there
    // may be no input attached during `zig build cross-test`.
    _ = stdin;
}
