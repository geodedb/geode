// CANARY: REQ=REQ-ADMIN-BOOTSTRAP-HARDEN-002; FEATURE="AdminBootstrapHardening"; ASPECT=DataDirPermissionsHelper; STATUS=TESTED; TEST=tests/test_admin_bootstrap_hardening.zig; OWNER=security; UPDATED=2026-05-15
//! Issue #819 (CWE-538 file/dir info exposure, CWE-732 incorrect permissions).
//!
//! Pure permission-check helper used by `server_init.zig` before persisting
//! the auto-generated admin password to `<data_dir>/.geode_admin_password`.
//!
//! Lives in its own file (with no dependency on the heavy `geode` /
//! `logging` modules) so it can be exercised by lightweight unit tests
//! without dragging in the whole server module graph.

const std = @import("std");
const builtin = @import("builtin");

/// Result of a data-directory permission check.
pub const DataDirPermissionResult = enum {
    /// Directory mode was already 0o700 or stricter; no change made.
    ok,
    /// Directory was more permissive than 0o700; we successfully chmod'd
    /// it to 0o700.  Caller SHOULD log a warning so this is visible in
    /// audit trails.
    tightened,
    /// Directory was more permissive than 0o700 AND chmod failed; the
    /// caller MUST refuse to write any secrets to this directory.
    refuse,
    /// Platform does not have POSIX permission bits (e.g. Windows); the
    /// caller may proceed without further hardening.
    not_applicable,
    /// Directory could not be opened or stat'd; we could not assert
    /// anything about its mode.  Caller MAY proceed (write may still fail
    /// at the file-creation step).
    unknown,
};

// libc bindings: Zig 0.16's std.Io.Dir.setPermissions calls fchmod on the
// open-dir fd, which panics with BADF on Linux when the dir was opened
// via standard path lookup (the fd lacks the rights fchmod needs).  We
// therefore use POSIX path-based chmod / stat directly, which is what
// `chmod`/`stat` would do anyway.  Avoids the stdlib bug while remaining
// cross-platform.
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

/// Look up the POSIX permission bits for `path`.  Returns null on any
/// stat failure (treated as `.unknown` by the caller).
///
/// On Linux we go through the raw `fstatat` syscall via std.os.linux
/// because libc symbols are versioned (`__xstat`/`fstatat64`) and the
/// plain `stat` libc shim is missing from the Zig 0.16 stdlib on Linux.
/// On other POSIX targets we use the libc `stat()` via std.c.
fn statMode(path: []const u8) ?u32 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf[0]);

    if (comptime builtin.os.tag == .linux) {
        var sx: std.os.linux.Statx = undefined;
        const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true };
        const rc = std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            path_z,
            0, // flags: follow symlinks
            mask,
            &sx,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return @as(u32, @intCast(sx.mode & 0o777));
    } else {
        // BSD / macOS: use libc stat() through std.c.  (std.c.stat is only
        // wired up on these platforms; on linux the symbol resolves to
        // `private.stat` which is undefined, hence the comptime branch.)
        var sb: std.c.Stat = undefined;
        if (std.c.stat(path_z, &sb) != 0) return null;
        return @as(u32, @intCast(sb.mode & 0o777));
    }
}

/// Stat `data_dir_opt` (or `"."` if null) and ensure it is mode 0o700 or
/// stricter.  When the dir is more permissive (group/world read/write/exec),
/// attempts to chmod it down to 0o700.  Returns one of the
/// `DataDirPermissionResult` variants; the caller is responsible for
/// emitting structured log lines based on the result.
///
/// Pure -- performs no logging -- so it is fully unit-testable.
pub fn ensureSecureDataDirPermissions(data_dir_opt: ?[]const u8) DataDirPermissionResult {
    if (builtin.os.tag == .windows) return .not_applicable;

    const data_dir: []const u8 = data_dir_opt orelse ".";

    const mode_bits = statMode(data_dir) orelse return .unknown;

    // Permissive = any bit outside the owner triplet (i.e. group or other
    // has any read / write / execute) is set.
    const permissive = (mode_bits & 0o077) != 0;
    if (!permissive) return .ok;

    // Tighten in place to 0o700.  On failure (e.g. NFS, read-only mount,
    // foreign uid) we refuse to write the secret and let the operator
    // resolve the permission state out-of-band.
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (data_dir.len >= buf.len) return .refuse;
    @memcpy(buf[0..data_dir.len], data_dir);
    buf[data_dir.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf[0]);

    if (chmod(path_z, 0o700) != 0) return .refuse;
    return .tightened;
}

// Tests live in tests/test_admin_bootstrap_hardening.zig so the helper
// remains a leaf module with no test-time dependency on std.testing's
// tmpDir handle quirks.
