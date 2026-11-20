// CANARY: REQ=REQ-SONNY-6442-SERVE-UNKNOWN-OPTION; FEATURE="ServerCli"; ASPECT=UnknownOptionRefused; STATUS=TESTED; TEST=tests/test_sonny6442_serve_unknown_options.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6442 (4): `geode serve` silently ignored any option it did not know
// (src/server/cli_args.zig), so a misspelt `--data-dri /srv/geode` or a
// removed flag started a server with the defaults instead. `geode backup
// create` / `geode restore` already refuse unknown options (exit 2).
//
// The contract:
//   - an unknown option, a stray positional argument, or a known option
//     given without its value is refused by the parser
//     (error.UnknownServeOption / error.MissingArgument);
//   - every option `geode serve --help` documents still parses;
//   - the built `geode serve` with an unknown option exits 2, names the
//     option, and never starts listening.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const cli_args = @import("cli_args");
const options = @import("sonny6442_serve_options");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn parse(argv: []const []const u8) !void {
    var cfg = (try cli_args.parseArgsFromSlice(testing.allocator, argv)) orelse return;
    cfg.deinit(testing.allocator);
}

test "SONNY-6442 (4) the serve parser refuses an unknown option, a positional argument and a value option without its value" {
    try testing.expectError(error.UnknownServeOption, parse(&.{ "geode", "serve", "--data-dri", "/tmp/x" }));
    try testing.expectError(error.UnknownServeOption, parse(&.{ "geode", "serve", "--gpu-acceleration" }));
    try testing.expectError(error.UnknownServeOption, parse(&.{ "geode", "serve", "--listen", "127.0.0.1:0", "--insecure" }));
    try testing.expectError(error.UnknownServeOption, parse(&.{ "geode", "serve", "stray" }));
    try testing.expectError(error.UnknownServeOption, parse(&.{ "geode", "--bogus" }));
    try testing.expectError(error.MissingArgument, parse(&.{ "geode", "serve", "--data-dir" }));
    try testing.expectError(error.MissingArgument, parse(&.{ "geode", "serve", "--listen" }));
    try testing.expectError(error.MissingArgument, parse(&.{ "geode", "serve", "--peers" }));
}

/// Every option `geode serve --help` lists, with a value where it takes one.
/// (SONNY-6836: listen ports are 0; only the parser sees them, and the
/// SONNY-6332 check flags literal listen ports in a file that spawns geode.)
const documented = [_]struct { flag: []const u8, argv: []const []const u8 }{
    .{ .flag = "--listen", .argv = &.{ "--listen", "127.0.0.1:0" } },
    .{ .flag = "--listen-grpc", .argv = &.{ "--listen-grpc", "127.0.0.1:0" } },
    .{ .flag = "--lsp-port", .argv = &.{"--lsp-port=0"} },
    .{ .flag = "--lsp-bind-all", .argv = &.{"--lsp-bind-all"} },
    .{ .flag = "--cert", .argv = &.{ "--cert", "/tls/tls.crt" } },
    .{ .flag = "--key", .argv = &.{ "--key", "/tls/tls.key" } },
    .{ .flag = "--data_dir", .argv = &.{ "--data_dir", "/srv/geode" } },
    .{ .flag = "--data-dir", .argv = &.{ "--data-dir", "/srv/geode" } },
    .{ .flag = "--order-keys", .argv = &.{ "--order-keys", "expr" } },
    .{ .flag = "--log-level", .argv = &.{ "--log-level", "warn" } },
    .{ .flag = "--idle-timeout", .argv = &.{ "--idle-timeout", "1000" } },
    .{ .flag = "--idle-in-transaction-timeout", .argv = &.{ "--idle-in-transaction-timeout", "1000" } },
    .{ .flag = "--grpc-session-idle-timeout", .argv = &.{ "--grpc-session-idle-timeout", "1000" } },
    .{ .flag = "--grpc-max-sessions-per-principal", .argv = &.{ "--grpc-max-sessions-per-principal", "8" } },
    .{ .flag = "--max-connections", .argv = &.{ "--max-connections", "10" } },
    .{ .flag = "--persist-interval", .argv = &.{ "--persist-interval", "100" } },
    .{ .flag = "--cluster-port", .argv = &.{ "--cluster-port", "8300" } },
    .{ .flag = "--peers", .argv = &.{ "--peers", "a:1,b:2" } },
    .{ .flag = "--insecure-allow-all", .argv = &.{"--insecure-allow-all"} },
    .{ .flag = "--strict-tenancy", .argv = &.{"--strict-tenancy"} },
    .{ .flag = "--require-capability-profile", .argv = &.{ "--require-capability-profile", "/etc/geode/profile.json" } },
    .{ .flag = "--auth-lockout-attempts", .argv = &.{ "--auth-lockout-attempts", "5" } },
    .{ .flag = "--auth-lockout-secs", .argv = &.{ "--auth-lockout-secs", "60" } },
    .{ .flag = "--auth-lockout-ip-attempts", .argv = &.{ "--auth-lockout-ip-attempts", "50" } },
    // `--config` (it loads the file) and `--help` (it prints) are covered
    // by test-capability-gate and the help path; listed so the scan below
    // accounts for them.
    .{ .flag = "--config", .argv = &.{} },
    .{ .flag = "--help", .argv = &.{} },
};

test "SONNY-6442 (4) every option geode serve --help documents still parses" {
    for (documented) |d| {
        if (d.argv.len == 0) continue;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "geode", "serve" });
        try argv.appendSlice(testing.allocator, d.argv);
        parse(argv.items) catch |err| {
            std.debug.print("SONNY-6442 (4): documented option {s} does not parse: {s}\n", .{ d.flag, @errorName(err) });
            return err;
        };
    }
    // `--name=value` spellings, and every documented option together.
    try parse(&.{ "geode", "serve", "--listen=127.0.0.1:3141", "--data-dir=/srv/geode", "--log-level=info", "--cert=/a.crt", "--key=/a.key" });
    // Compatibility no-ops stay accepted.
    try parse(&.{ "geode", "serve", "--enable-auth", "--enable-fle", "--enable-tde", "--tde-provider", "default" });
}

test "SONNY-6442 (4) the documented-option table matches geode serve --help" {
    const path = try std.fs.path.join(testing.allocator, &.{ options.repo_root, "src/server/cli_args.zig" });
    defer testing.allocator.free(path);
    const src = try std.Io.Dir.cwd().readFileAlloc(fsIo(), path, testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(src);
    const start = std.mem.indexOf(u8, src, "pub fn printHelp() void {") orelse return error.PrintHelpMissing;
    const end = std.mem.indexOfPos(u8, src, start, "\n}\n") orelse return error.PrintHelpMissing;
    var lines = std.mem.splitScalar(u8, src[start..end], '\n');
    var bad: usize = 0;
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "print(\"  -") orelse continue;
        const text = line[at + "print(\"  ".len ..];
        var words = std.mem.tokenizeAny(u8, text, " ,");
        while (words.next()) |w| {
            if (!std.mem.startsWith(u8, w, "--")) break;
            const flag = w[0 .. std.mem.indexOfScalar(u8, w, '=') orelse w.len];
            var found = false;
            for (documented) |d| found = found or std.mem.eql(u8, d.flag, flag);
            if (!found) {
                std.debug.print("SONNY-6442 (4): geode serve --help documents {s}, which this test does not parse\n", .{flag});
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

const Run = struct { code: ?u8, started: bool, text: []u8 };

/// Run the built `geode serve` with `extra` arguments; a server still running
/// after 30 s is stopped and reported as `started`.
fn runServe(extra: []const []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var root = try test_scratch.ScratchDir.create("sonny6442-serve");
    defer root.remove();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6442-Admin-pw1");
    try env.put("GEODE_LSP_PORT", "0");
    const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{root.path()});
    defer testing.allocator.free(data_dir);
    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/serve.out", .{root.path()});
    defer testing.allocator.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer out.close(fsIo());

    var addr_buf: [32]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{try test_ports.freeUdpPort()});
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir });
    try argv.appendSlice(testing.allocator, extra);
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv.items,
        .environ_map = &env,
        .cwd = .{ .path = root.path() },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: u32 = 0;
    while (waited_ms < 30_000) : (waited_ms += 100) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
    }
    if (!exited) {
        posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .started = !exited, .text = text };
}

test "SONNY-6442 (4) geode serve with an unknown option exits 2 and names it" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try runServe(&.{"--data-dri"});
    defer testing.allocator.free(r.text);
    if (r.code != 2) std.debug.print("SONNY-6442 (4): exit={?d} started={}\n{s}\n", .{ r.code, r.started, r.text });
    try testing.expect(!r.started);
    try testing.expectEqual(@as(?u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.text, "unknown option '--data-dri'") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "QUIC transport listening") == null);
}

test "SONNY-6442 (4) geode serve with an option missing its value exits 2" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try runServe(&.{"--log-level"});
    defer testing.allocator.free(r.text);
    if (r.code != 2) std.debug.print("SONNY-6442 (4): exit={?d} started={}\n{s}\n", .{ r.code, r.started, r.text });
    try testing.expect(!r.started);
    try testing.expectEqual(@as(?u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.text, "'--log-level' requires a value") != null);
}
