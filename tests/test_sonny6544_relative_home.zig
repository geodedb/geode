// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6544 item 2: a relative or empty HOME never panics the CLI and never
// puts session state under the current directory.
//
// src/cli/security/session_storage.zig built `<HOME>/.geode` and passed it
// to std.Io.Dir.createDirAbsolute, which asserts an absolute path: a Debug
// `HOME=relhome geode query` panicked ("reached unreachable code"). The same
// assert sat behind every other HOME user of the CLI (`auth login
// --save-session`, `auth token`, `session info`, the `apikey` / `session` /
// `authn` / `mtls` state directory), and the state directory was first
// created relative to the current directory (`relhome/.local/state/geode`,
// or `.local/state/geode` for an empty HOME, or `relstate/geode` for a
// relative XDG_STATE_HOME). A relative HOME is now refused with a message;
// a relative XDG_STATE_HOME is ignored (XDG Base Directory specification).
//
// Real built `geode` binary, run in a scratch working directory.
//
// CANARY: REQ=REQ-SONNY-6544-HOME-ABSOLUTE; FEATURE="CLI home directory"; ASPECT=RelativeHomeRefused; STATUS=TESTED; TEST=tests/test_sonny6544_relative_home.zig; OWNER=cli; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    /// Exit code; null when the process died on a signal (a panic aborts)
    /// or was killed at the deadline.
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6544 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }
};

const Env = struct { name: []const u8, value: []const u8 };

/// Run `argv` in `cwd` with PATH plus `env` only; past 60 s the child is
/// killed.
fn runGeode(cwd: []const u8, argv: []const []const u8, env: []const Env) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH", "USER" }) |name| {
        if (std.c.getenv(name)) |v| try map.put(name, std.mem.span(v));
    }
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try map.put("GEODE_ALLOW_INSECURE_TLS", "1");
    for (env) |e| try map.put(e.name, e.value);

    var out_dir = try test_scratch.ScratchDir.create("sonny6544-home-out");
    defer out_dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{out_dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());

    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &map,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= 60_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 50;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// The working directory must still be empty: nothing (no `.geode`, no
/// state directory) was created relative to it.
fn expectCwdUntouched(cwd: []const u8, label: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), cwd, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    if (try it.next(fsIo())) |entry| {
        std.debug.print("SONNY-6544 {s}: '{s}' was created in the working directory\n", .{ label, entry.name });
        return error.CreatedUnderWorkingDirectory;
    }
}

const refused = "HOME is empty or not an absolute path";

/// The run ended by itself (no panic, no signal), said why, and created
/// nothing under the working directory.
fn expectRefused(cwd: []const u8, r: Run, label: []const u8) !void {
    if (r.code == null or r.has("panic") or r.has("unreachable") or !r.has(refused)) {
        r.dump(label);
        return error.TestUnexpectedResult;
    }
    try expectCwdUntouched(cwd, label);
}

test "SONNY-6544: geode query with a relative or empty HOME says so and does not panic" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try util.getRandomPort(); // nothing listens: the query fails after the HOME check
    var buf: [32]u8 = undefined;
    const server = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
    for ([_][]const u8{ "relhome", "", "." }) |home| {
        var cwd = try test_scratch.ScratchDir.create("sonny6544-home-cwd");
        defer cwd.remove();
        const r = try runGeode(cwd.path(), &.{
            geode_test_bin.geode_exe,     "query",     "--server", server,
            "--insecure-tls-skip-verify", "--timeout", "2",        "RETURN 1",
        }, &.{.{ .name = "HOME", .value = home }});
        defer r.deinit();
        try expectRefused(cwd.path(), r, "query");
    }
}

// SONNY-6554: `session rotate` and `authn config` are refused as not
// supported before they read HOME, and no command uses the CLI state
// directory any more (its relative-XDG_STATE_HOME case went with it).
test "SONNY-6544: auth token and session info refuse a relative HOME" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const commands = [_][]const []const u8{
        &.{ geode_test_bin.geode_exe, "auth", "token" },
        &.{ geode_test_bin.geode_exe, "session", "info" },
    };
    for (commands) |argv| {
        for ([_][]const u8{ "relhome", "" }) |home| {
            var cwd = try test_scratch.ScratchDir.create("sonny6544-home-cwd");
            defer cwd.remove();
            const r = try runGeode(cwd.path(), argv, &.{.{ .name = "HOME", .value = home }});
            defer r.deinit();
            try expectRefused(cwd.path(), r, argv[1]);
        }
    }
}

test "SONNY-6544: auth login --save-session with a relative HOME refuses to write the token" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();
    var cwd = try test_scratch.ScratchDir.create("sonny6544-home-cwd");
    defer cwd.remove();
    const r = try runGeode(cwd.path(), &.{
        geode_test_bin.geode_exe, "auth",                 "login", "--server",             server.getAddr(),
        "-U",                     util.defaultUsername(), "-P",    util.defaultPassword(), "--insecure-tls-skip-verify",
        "--save-session",
    }, &.{.{ .name = "HOME", .value = "relhome" }});
    defer r.deinit();
    try expectRefused(cwd.path(), r, "auth login --save-session");
    if (r.code.? == 0) {
        r.dump("auth login --save-session");
        return error.TestUnexpectedResult;
    }
}
