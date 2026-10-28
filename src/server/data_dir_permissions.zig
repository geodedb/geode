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

/// Look up POSIX permission bits with the host's filesystem implementation.
/// This follows symlinks, matching the subsequent permission update.
fn statMode(path: []const u8) ?u32 {
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = true }) catch return null;
    return @intCast(stat.permissions.toMode() & 0o777);
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
    std.Io.Dir.cwd().setFilePermissions(
        std.Io.Threaded.global_single_threaded.io(),
        data_dir,
        std.Io.File.Permissions.fromMode(0o700),
        .{},
    ) catch return .refuse;
    return .tightened;
}

// Tests live in tests/test_admin_bootstrap_hardening.zig so the helper
// remains a leaf module with no test-time dependency on std.testing's
// tmpDir handle quirks.
