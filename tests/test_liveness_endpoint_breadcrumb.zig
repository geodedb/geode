// Regression for docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md
//
// Phase 1 of the fix advertises the out-of-band `/health` liveness endpoint so
// operators/k8s adopt the §9 probe split (cheap off-path liveness; in-band
// `RETURN 1` as readiness only). The original commit (391870d7) logged this via
// structured `log.info`, which — as the CPU-constrained repro harness caught on
// 2026-06-07 — does NOT reach stdout/stderr on the `serve` path (the same sink
// gap that hid the first-boot admin-password breadcrumb). The endpoint worked,
// but nothing in `kubectl logs` / `docker logs` pointed at it, so the
// discoverability feature was ineffective.
//
// This subprocess test asserts the contract: when GEODE_METRICS_PORT is set,
// `geode serve` emits a reliable `[startup]` breadcrumb to stdout/stderr that
// names the out-of-band `GET /health` liveness URL (visible at all log levels).
//
// Depends on a pre-built ./zig-out/bin/geode (SKIPs if missing); Linux-only
// (non-blocking pipe reads).

const std = @import("std");
const builtin = @import("builtin");

const BINARY_PATH = "./zig-out/bin/geode";

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn setNonBlocking(file: std.Io.File) !void {
    if (comptime builtin.os.tag != .linux) return;
    const fd = file.handle;
    const flags = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.FcntlGetFailed;
    const new_flags = flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.os.linux.fcntl(fd, std.posix.F.SETFL, new_flags);
    if (@as(isize, @bitCast(rc)) < 0) return error.FcntlSetFailed;
}

/// Child env WITH GEODE_METRICS_PORT (activates the out-of-band /health server)
/// and a known GEODE_ADMIN_PASSWORD (skip the generate path so the only startup
/// breadcrumb under test is the liveness one). Keep PATH/HOME/LD_LIBRARY_PATH so
/// the binary + its loader resolve.
fn buildChildEnv(aa: std.mem.Allocator, metrics_port: []const u8) !*std.process.Environ.Map {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    if (posixGetenv("PATH")) |p| try env_ptr.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env_ptr.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);
    try env_ptr.put("GEODE_METRICS_PORT", metrics_port);
    try env_ptr.put("GEODE_METRICS_BIND", "127.0.0.1");
    try env_ptr.put("GEODE_ADMIN_PASSWORD", "livenesstest123");
    return env_ptr;
}

test "serve advertises the out-of-band /health liveness endpoint to stdout/stderr" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io = spawn_threaded.io();

    // SKIP cleanly if the binary isn't built yet.
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return error.SkipZigTest;

    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-liveness-{d}", .{nowMillis()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const metrics_port = "31600";
    const args = [_][]const u8{
        BINARY_PATH,  "serve",  "--listen",    "127.0.0.1:31601",
        "--data-dir", data_dir, "--log-level", "error",
    };
    const env_ptr = try buildChildEnv(aa, metrics_port);

    var child = try std.process.spawn(io, .{
        .argv = &args,
        .environ_map = env_ptr,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) {
        child.kill(io);
        reaped = true;
    };

    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);

    var buf: [4096]u8 = undefined;
    const deadline = nowMillis() + 20_000;
    var saw_ready = false;
    // Read until we see the liveness breadcrumb (success), or "server ready" + a
    // short grace (so the assertion fails fast if the breadcrumb is missing), or
    // the deadline.
    while (nowMillis() < deadline) {
        var progressed = false;
        inline for ([_]?std.Io.File{ child.stdout, child.stderr }) |maybe_f| {
            if (maybe_f) |f| {
                const n = f.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                    error.WouldBlock => @as(usize, 0),
                    error.EndOfStream => @as(usize, 0),
                    else => @as(usize, 0),
                };
                if (n > 0) {
                    progressed = true;
                    try captured.appendSlice(gpa, buf[0..n]);
                }
            }
        }
        if (std.mem.indexOf(u8, captured.items, "out-of-band liveness ready") != null) break;
        if (std.mem.indexOf(u8, captured.items, "server ready") != null) {
            if (saw_ready) break;
            saw_ready = true;
        }
        if (!progressed) sleepMs(50);
    }

    child.kill(io);
    reaped = true;

    // The startup breadcrumb must name the out-of-band /health liveness URL on
    // stdout/stderr (reachable in `kubectl logs` / `docker logs`), including the
    // /health path and the configured metrics port.
    if (std.mem.indexOf(u8, captured.items, "out-of-band liveness ready") == null or
        std.mem.indexOf(u8, captured.items, "/health") == null or
        std.mem.indexOf(u8, captured.items, metrics_port) == null)
    {
        std.debug.print(
            "FAIL: no out-of-band /health liveness breadcrumb (naming port {s}) on stdout/stderr.\ncaptured:\n{s}\n",
            .{ metrics_port, captured.items },
        );
        return error.NoLivenessBreadcrumb;
    }
}
