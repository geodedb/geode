// Regression for docs/bugs/2026-06-06-admin-password-only-in-data-dir-file-not-startup-logs.md
//
// On a FRESH data dir, `geode serve` generates an admin password and writes it
// to `<data-dir>/.geode_admin_password` (0600), but emitted NO discoverable,
// secret-free breadcrumb to stdout/stderr — so operators watching the logs and
// log-scraping harnesses had no signal that a password was generated or where
// to find it (the GAP-0104 fix correctly stopped logging the secret but left no
// pointer).
//
// This subprocess test asserts the security-preserving contract:
//   1. first boot emits a secret-free breadcrumb to stdout/stderr that points at
//      `<data-dir>/.geode_admin_password` (visible at all log levels), AND
//   2. the actual generated password NEVER appears in stdout/stderr.
//
// It runs with a CLEAN environment (no GEODE_ADMIN_PASSWORD / GEODE_DEFAULT_PASSWORD)
// so the server takes the generate-and-persist path. Depends on a pre-built
// ./zig-out/bin/geode (SKIPs if missing); Linux-only (non-blocking pipe reads).

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

/// Child env WITHOUT GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD so the server
/// GENERATES a password (the path under test). Keep PATH/HOME/LD_LIBRARY_PATH so
/// the binary + its loader resolve.
fn buildCleanChildEnv(aa: std.mem.Allocator) !*std.process.Environ.Map {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    if (posixGetenv("PATH")) |p| try env_ptr.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env_ptr.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);
    return env_ptr;
}

test "first boot prints a secret-free admin-password breadcrumb (never the secret)" {
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

    // Fresh, empty data dir => first-boot generate path.
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-firstboot-{d}", .{nowMillis()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const args = [_][]const u8{
        BINARY_PATH,  "serve",  "--listen",    "127.0.0.1:31599",
        "--data-dir", data_dir, "--log-level", "error",
    };
    const env_ptr = try buildCleanChildEnv(aa);

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
    // Read until we see the breadcrumb (success), or "server ready" + a short
    // grace (so the assertion fails fast if the breadcrumb is missing), or the
    // deadline.
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
        if (std.mem.indexOf(u8, captured.items, "generated initial admin password written to") != null) break;
        if (std.mem.indexOf(u8, captured.items, "server ready") != null) {
            // Give any trailing line a moment to flush, then stop.
            if (saw_ready) break;
            saw_ready = true;
        }
        if (!progressed) sleepMs(50);
    }

    child.kill(io);
    reaped = true;

    // The generated password must have landed in the 0600 file.
    const pw_path = try std.fmt.allocPrint(aa, "{s}/.geode_admin_password", .{data_dir});
    const pw_file = std.Io.Dir.cwd().readFileAlloc(io, pw_path, aa, .limited(4096)) catch "";
    const pw = std.mem.trim(u8, pw_file, " \t\r\n");

    // (1) Discoverable, secret-free breadcrumb pointing at the file.
    if (std.mem.indexOf(u8, captured.items, "generated initial admin password written to") == null or
        std.mem.indexOf(u8, captured.items, data_dir) == null)
    {
        std.debug.print(
            "FAIL: no secret-free first-boot admin-password breadcrumb pointing at {s} on stdout/stderr.\ncaptured:\n{s}\n",
            .{ data_dir, captured.items },
        );
        return error.NoAdminPasswordBreadcrumb;
    }

    // (2) The actual secret must NEVER appear in stdout/stderr.
    if (pw.len >= 8 and std.mem.indexOf(u8, captured.items, pw) != null) {
        std.debug.print("FAIL: the generated admin password LEAKED into stdout/stderr.\n", .{});
        return error.AdminPasswordLeakedToLogs;
    }
}
