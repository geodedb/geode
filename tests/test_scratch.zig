//! Scratch directories for tests (SONNY-2413).
//!
//! Every scratch dir a test process makes through this file lives under ONE
//! per-process root, `/tmp/geode-test-<pid>-<random>`. The root is created
//! exclusively (never reused, nothing pre-existing is ever deleted) and is
//! removed when the process exits, however it exits: a reaper process
//! (`/bin/sh`) blocks reading a pipe whose only write end this process holds,
//! close-on-exec so spawned servers do not inherit it. The kernel closes that
//! end when this process exits, even on SIGKILL, and the reaper then removes
//! the root. Removal never follows a symlink (`rm -rf` on the root path).
//!
//! `ScratchDir.create` makes a dir under the root for one test; `remove` (run
//! it from a `defer`, registered BEFORE the server that uses the dir is
//! spawned, so the server is stopped first) deletes it eagerly and fails the
//! running test, through an error log, if the dir survives.
const std = @import("std");
const builtin = @import("builtin");

pub const temp_root = "/tmp";
pub const root_prefix = "geode-test-";

const RootState = enum(u8) { uninit, busy, ready, failed };

var root_state = std.atomic.Value(RootState).init(.uninit);
var root_buf: [128]u8 = undefined;
var root_len: usize = 0;
var reaper_threaded: std.Io.Threaded = undefined;
var reaper_child: ?std.process.Child = null;
var scratch_serial = std.atomic.Value(u32).init(0);
var live_scratch = std.atomic.Value(u32).init(0);

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn getPid() i64 {
    return if (comptime builtin.os.tag == .linux)
        @as(i64, std.os.linux.getpid())
    else
        @as(i64, std.c.getpid());
}

fn randomU64() u64 {
    var rnd: [8]u8 = undefined;
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    } else {
        std.c.arc4random_buf(&rnd, rnd.len);
    }
    return std.mem.readInt(u64, &rnd, .little);
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

/// Starts the process that removes `dir` once this process has exited, and
/// returns it. The caller keeps `child.stdin` (the pipe's only write end)
/// open; closing it, or exiting, triggers the removal.
pub fn startReaper(io: std.Io, dir: []const u8) !std.process.Child {
    var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(std.heap.smp_allocator);
    defer env.deinit();
    return std.process.spawn(io, .{
        // Ignore the terminal's ^C and hangups: the reaper shares the test
        // process's group and must outlive it to do its job.
        .argv = &.{ "/bin/sh", "-c", "trap '' INT HUP TERM; while read -r _l; do :; done; exec rm -rf -- \"$1\"", "geode-test-reaper", dir },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn initRoot() !void {
    const pid = getPid();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const p = try std.fmt.bufPrint(&root_buf, temp_root ++ "/" ++ root_prefix ++ "{d}-{x:0>16}", .{ pid, randomU64() });
        std.Io.Dir.cwd().createDir(fsIo(), p, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 8) continue else return err,
            else => return err,
        };
        root_len = p.len;
        break;
    }
    reaper_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    reaper_child = startReaper(reaper_threaded.io(), root_buf[0..root_len]) catch |err| {
        // Without a reaper the root outlives the process (the pre-SONNY-2413
        // behaviour); the tests themselves are unaffected.
        std.debug.print("test_scratch: no reaper for {s}: {t}\n", .{ root_buf[0..root_len], err });
        return;
    };
}

/// This process's scratch root, created (with its reaper) on first use.
pub fn processRoot() ![]const u8 {
    while (true) {
        switch (root_state.load(.acquire)) {
            .ready => return root_buf[0..root_len],
            .failed => return error.ScratchRootUnavailable,
            .busy => std.atomic.spinLoopHint(),
            .uninit => if (root_state.cmpxchgStrong(.uninit, .busy, .acq_rel, .acquire) == null) {
                initRoot() catch |err| {
                    std.debug.print("test_scratch: cannot create a scratch root under " ++ temp_root ++ ": {t}\n", .{err});
                    root_state.store(.failed, .release);
                    return err;
                };
                root_state.store(.ready, .release);
            },
        }
    }
}

/// Scratch dirs created and not yet removed by this process.
pub fn liveCount() u32 {
    return live_scratch.load(.monotonic);
}

pub const ScratchDir = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,
    removed: bool = false,

    /// Creates `<process root>/<tag>-<n>`, unique in this process.
    pub fn create(tag: []const u8) !ScratchDir {
        const root = try processRoot();
        var self: ScratchDir = .{};
        const serial = scratch_serial.fetchAdd(1, .monotonic);
        const p = try std.fmt.bufPrint(&self.buf, "{s}/{s}-{d}", .{ root, tag, serial });
        try std.Io.Dir.cwd().createDir(fsIo(), p, .default_dir);
        self.len = p.len;
        _ = live_scratch.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn path(self: *const ScratchDir) []const u8 {
        return self.buf[0..self.len];
    }

    /// Deletes the dir. Stop every server using it first. Fails the running
    /// test (error log) when the dir cannot be removed.
    pub fn remove(self: *ScratchDir) void {
        if (self.removed) return;
        self.removed = true;
        _ = live_scratch.fetchSub(1, .monotonic);
        const p = self.path();
        std.Io.Dir.cwd().deleteTree(fsIo(), p) catch |err| {
            std.log.err("SONNY-2413: cannot remove scratch dir {s}: {t}", .{ p, err });
            return;
        };
        if (pathExists(p)) std.log.err("SONNY-2413: scratch dir {s} survived its removal", .{p});
    }
};
