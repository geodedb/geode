// Raise the process's RLIMIT_NOFILE soft limit to the hard limit at
// startup so geode does not hit EMFILE on systems where the parent shell
// runs with the systemd default (LimitNOFILESoft=1024).
//
// This is standard hygiene for server software — nginx, postgres, redis,
// envoy and every other production server perform the same bump. Without
// it, a fresh `geode serve` spawned from a shell that hasn't done
// `ulimit -n` inherits 1024 FDs, and as few as ~5 CREATE GRAPHs (each
// opening ~177 sharded-storage file handles) exhaust the limit and
// surface as ProcessFdQuotaExceeded.
//
// Backed by tests/test_fd_limit_raise.zig.
const std = @import("std");
const builtin = @import("builtin");

pub const RaiseResult = struct {
    soft_before: u64,
    soft_after: u64,
    hard: u64,
    raised: bool,
};

/// Bump RLIMIT_NOFILE soft limit to the hard limit when room exists.
/// Always best-effort: returns `raised = false` and leaves the limit
/// unchanged on any non-fatal error so that startup is never blocked by
/// a setrlimit failure on a restricted host. No-op on Windows.
pub fn raiseSoftToHard() RaiseResult {
    if (builtin.os.tag == .windows) {
        return .{ .soft_before = 0, .soft_after = 0, .hard = 0, .raised = false };
    }
    const posix = std.posix;
    const before = posix.getrlimit(.NOFILE) catch {
        return .{ .soft_before = 0, .soft_after = 0, .hard = 0, .raised = false };
    };
    if (before.cur >= before.max) {
        return .{
            .soft_before = before.cur,
            .soft_after = before.cur,
            .hard = before.max,
            .raised = false,
        };
    }
    const raised_limits = std.posix.rlimit{ .cur = before.max, .max = before.max };
    posix.setrlimit(.NOFILE, raised_limits) catch {
        return .{
            .soft_before = before.cur,
            .soft_after = before.cur,
            .hard = before.max,
            .raised = false,
        };
    };
    return .{
        .soft_before = before.cur,
        .soft_after = before.max,
        .hard = before.max,
        .raised = true,
    };
}
