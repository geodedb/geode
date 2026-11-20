//! SONNY-6801: whether /dev/shm has room for a test's persisted store.
//!
//! The write harness (SONNY-6333) and the lazy-hydrate suite (SONNY-6433)
//! keep their stores on tmpfs, where fsync returns at once. They peak at
//! 376 MB (the write suites) and 404 MB (lazy hydrate) there; with less free
//! (a container's default /dev/shm is 64 MB, or other jobs fill a shared one)
//! their writes failed with NoSpaceLeft (MR !84 CI). A test uses /dev/shm only
//! when `shmUsable` says it has `min_free_bytes` free, else its disk tmp dir,
//! which is far slower (every commit fsyncs) but does not fail.

const std = @import("std");
const builtin = @import("builtin");

pub const min_free_bytes: u64 = 512 << 20;

/// Linux `struct statfs` (the generic 64-bit layout: x86_64, aarch64, riscv64).
const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// /dev/shm exists and has `min_free_bytes` free.
pub fn shmUsable() bool {
    if (comptime builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    var st: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr("/dev/shm"), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return false;
    return st.f_bavail * @as(u64, @intCast(st.f_bsize)) >= min_free_bytes;
}
