//! Portable process-argv holder.
//!
//! Zig 0.16 removed `std.process.argsAlloc` (and `std.os.argv`); the only
//! authoritative source of the process command line is the `std.process.Args`
//! handed to `main` via `std.process.Init.Minimal`. Code paths buried deep in
//! the call stack (`cli_args.parseArgs`, `parseLspBootstrapConfig`) need argv
//! but do not receive `proc_init`, so they previously re-read
//! `/proc/self/cmdline` — a LINUX-ONLY file that does not exist on macOS,
//! Windows, or the BSDs (`openFileAbsolute` -> FileNotFound -> the server
//! refused to start; see the macOS test-unit 2h timeout).
//!
//! This module captures the portable argv vector once at startup (where
//! `proc_init` is in scope) and exposes a `getArgs` accessor. The argv vector
//! is owned by the process's startup arena (it lives for the whole process),
//! so we only need to retain the slice — no copy, no free.
//
// CANARY: REQ=REQ-CLI-PORTABLE-ARGV-001; FEATURE="PortableProcessArgv"; ASPECT=CrossPlatform; STATUS=TESTED; TEST=tests/test_process_args.zig; OWNER=cli; UPDATED=2026-06-12

const std = @import("std");
const builtin = @import("builtin");

/// The process argv vector captured at startup. `null` until `init` runs.
/// `std.process.Args.Vector` is `[]const [*:0]const u8` on POSIX targets
/// (Linux, macOS, the BSDs) and `[]const u16` on Windows; we only support the
/// POSIX form here (the geode server binary targets POSIX), matching the prior
/// `/proc/self/cmdline` capability surface.
var captured: ?[]const [*:0]const u8 = null;

/// Record the process argv from the `std.process.Args` delivered to `main`.
/// Call once, as early as possible in the entry point, before any code path
/// that may need argv (`parseArgs`, `parseLspBootstrapConfig`). Idempotent:
/// a second call is ignored so test harnesses re-entering `main` are safe.
pub fn init(args: std.process.Args) void {
    if (captured == null) captured = args.vector;
}

/// Return the captured argv as an owned slice of `[]const u8` arguments.
/// The returned outer slice is heap-allocated with `allocator` (caller frees
/// it); the inner argument strings borrow the process-lifetime argv storage,
/// so they must NOT be freed individually.
///
/// Returns `error.StdioUnavailable` if argv was never captured (the prior
/// failure mode when `/proc/self/cmdline` could not be read), preserving the
/// exact error contract `parseArgs` callers already handle.
pub fn getArgs(allocator: std.mem.Allocator) error{ StdioUnavailable, OutOfMemory }![]const []const u8 {
    const vector = captured orelse return error.StdioUnavailable;
    if (vector.len == 0) return error.StdioUnavailable;

    const out = try allocator.alloc([]const u8, vector.len);
    for (vector, 0..) |arg, i| {
        out[i] = std.mem.span(arg);
    }
    return out;
}

/// Test-only seam: inject a synthetic argv vector. Used by unit tests so they
/// can exercise `getArgs` without going through process startup.
pub fn setForTesting(vector: []const [*:0]const u8) void {
    captured = vector;
}

/// Test-only seam: clear captured state.
pub fn resetForTesting() void {
    captured = null;
}
