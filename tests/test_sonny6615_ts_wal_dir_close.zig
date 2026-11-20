//! SONNY-6615 / SONNY-6623: who closes the time-series WAL directory.
//!
//! timeseries-storage opens `{data_dir}/timeseries` in `Engine.init` and
//! hands it to the wal library, which only borrows it. Up to v0.2.21 nothing
//! closed it, so geode's `Store.deinit` closed it after `Engine.deinit`
//! (SONNY-6619). From v0.2.22 `Engine.deinit` closes it itself. A second
//! close from geode then runs on a descriptor number that is already free:
//! when another thread has just opened the same directory and been given
//! that number, the identity check (same device and inode) passes and geode
//! closes the other thread's descriptor.
//!
//! Here a watcher thread keeps opening the same directory and checks that
//! the descriptor it holds stays its own, while the main thread opens and
//! closes the store. Exactly one owner closes the WAL directory, so the
//! watcher never loses a descriptor.
//!
// CANARY: REQ=REQ-SONNY-6615-TS-WAL-DIR-OWNER; FEATURE="Timeseries"; ASPECT=WalDirClosedOnce; STATUS=TESTED; TEST=tests/test_sonny6615_ts_wal_dir_close.zig; OWNER=storage; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const ts = geode.timeseries;
const linux = std.os.linux;

const Identity = struct { dev: u64, ino: u64 };

fn identity(fd: i32) ?Identity {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .ino = stx.ino };
}

const Watcher = struct {
    path: [:0]const u8,
    stop: std.atomic.Value(bool) = .init(false),
    /// Descriptors this thread opened that were closed or replaced under it.
    lost: std.atomic.Value(u32) = .init(0),
    opens: std.atomic.Value(u64) = .init(0),

    fn run(self: *Watcher) void {
        while (!self.stop.load(.acquire)) {
            const rc = linux.open(self.path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(rc);
            _ = self.opens.fetchAdd(1, .monotonic);
            const mine = identity(fd) orelse {
                _ = self.lost.fetchAdd(1, .monotonic);
                continue;
            };
            var still_mine = true;
            var i: u32 = 0;
            while (i < 256) : (i += 1) {
                const now = identity(fd) orelse {
                    still_mine = false;
                    break;
                };
                if (now.dev != mine.dev or now.ino != mine.ino) {
                    still_mine = false;
                    break;
                }
            }
            if (!still_mine) {
                // Not ours any more: closing it would close someone else's.
                _ = self.lost.fetchAdd(1, .monotonic);
                continue;
            }
            _ = linux.close(fd);
        }
    }
};

fn uniqueNanos() u64 {
    var t: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &t);
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}

test "SONNY-6615: closing a time-series store closes only its own WAL directory descriptor" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = testing.allocator;

    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6615-wal-dir-{d}", .{uniqueNanos()});
    defer allocator.free(data_dir);
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    // The first open creates `{data_dir}/timeseries`, the WAL directory.
    {
        var store = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
        store.deinit();
    }

    const wal_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/timeseries", .{data_dir}, 0);
    defer allocator.free(wal_dir);

    var watcher: Watcher = .{ .path = wal_dir };
    const thread = try std.Thread.spawn(.{}, Watcher.run, .{&watcher});
    var joined = false;
    defer if (!joined) {
        watcher.stop.store(true, .release);
        thread.join();
    };

    var cycles: u32 = 0;
    while (cycles < 400 and watcher.lost.load(.monotonic) == 0) : (cycles += 1) {
        var store = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
        store.deinit();
    }

    watcher.stop.store(true, .release);
    thread.join();
    joined = true;

    const lost = watcher.lost.load(.monotonic);
    if (lost != 0) {
        std.debug.print(
            "SONNY-6615: after {d} store open/close cycles, {d} of the watcher's {d} descriptors on {s} were closed by the store\n",
            .{ cycles, lost, watcher.opens.load(.monotonic), wal_dir },
        );
    }
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(watcher.opens.load(.monotonic) > 0);
}
