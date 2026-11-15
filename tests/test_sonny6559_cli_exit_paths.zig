// CANARY: REQ=REQ-SONNY-6559-CLI-EXIT-PATHS; FEATURE="CliExitPaths"; ASPECT=ReturnThroughMain; STATUS=TESTED; TEST=tests/test_sonny6559_cli_exit_paths.zig; OWNER=cli; UPDATED=2026-11-14
//
// SONNY-6559 items 7, 8 and 11 (the geode CLI):
//
//   7. The audit configuration's strings (GEODE_AUDIT_SYSLOG_HOST,
//      GEODE_AUDIT_FILE_PATH, --audit-file, --audit-syslog, ...) were
//      duplicated and never freed (src/cli/cli_dispatcher.zig), so a Debug
//      command that returns through main with audit settings printed a leak
//      report; a --audit-file given with GEODE_AUDIT_FILE_PATH set leaked the
//      environment's copy as well.
//   8. `geode completion` wrote the completion script to stderr
//      (std.debug.print), so `geode completion --shell bash > file` wrote
//      nothing.
//  11. `audit`, `login`/`logout`, `session`, `authn`, `mtls` and `tenant`
//      ended the process with std.process.exit(0) on success, before main's
//      DebugAllocator check (and before the audit logger was closed).
//
// The contract: a command that succeeds returns through main, so its Debug
// run reports any leak and the CLI audit log records the command's success
// ("outcome":"success" for the command, written when the dispatcher gets the
// command back); a Debug command run with every audit setting reports no
// leak; the completion script is on stdout and stderr is empty.
//
// Spawns this build's geode (and a server for login and tenant).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const exe = geode_test_bin.geode_exe;
const password = "Geode Test Admin Passphrase";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    out: []u8,
    err: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.err);
    }

    fn dump(self: Run, argv: []const []const u8) void {
        std.debug.print("\n$ geode", .{});
        for (argv) |a| std.debug.print(" {s}", .{a});
        std.debug.print("\nexit={?d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n--- end ---\n", .{ self.code, self.out, self.err });
    }
};

const leak_markers = [_][]const u8{ "leaked", "Invalid free", "Double free", "panic" };

fn reportsLeak(err: []const u8) bool {
    for (leak_markers) |m| {
        if (std.mem.indexOf(u8, err, m) != null) return true;
    }
    return false;
}

/// Run `geode <argv...>` with HOME, cwd and GEODE_DATA_DIR under `root` and
/// `extra_env` ("NAME=value") added.
fn runGeode(root: []const u8, argv: []const []const u8, extra_env: []const []const u8) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    const data_dir = try std.fmt.allocPrint(a, "{s}/cli-data", .{root});
    defer a.free(data_dir);
    try env.put("HOME", root);
    try env.put("GEODE_DATA_DIR", data_dir);
    try env.put("GEODE_LSP_PORT", "0");
    for (extra_env) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadEnv;
        try env.put(kv[0..eq], kv[eq + 1 ..]);
    }
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(a);
    try full.append(a, exe);
    try full.appendSlice(a, argv);
    const res = try std.process.run(a, threaded.io(), .{
        .argv = full.items,
        .environ_map = &env,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(4 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
    });
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .out = res.stdout, .err = res.stderr };
}

test "SONNY-6559 (8) geode completion writes the script to stdout, nothing to stderr" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6559-completion");
    defer root.remove();

    const cases = [_][]const []const u8{
        &.{"completion"},
        &.{ "completion", "--shell", "bash" },
        &.{ "completion", "--shell", "zsh" },
        &.{ "completion", "--shell", "fish" },
        &.{ "completion", "--shell", "powershell" },
        &.{ "completion", "-s", "pwsh" },
        &.{ "completions", "--shell", "bash" },
    };
    for (cases) |argv| {
        const r = try runGeode(root.path(), argv, &.{});
        defer r.deinit();
        errdefer r.dump(argv);
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(r.out.len > 100);
        try testing.expect(std.mem.indexOf(u8, r.out, "geode") != null);
        try testing.expectEqual(@as(usize, 0), r.err.len);
    }
    // The shell named as an argument is the one generated (it was ignored,
    // so `geode completion zsh` printed the bash script).
    const bash = try runGeode(root.path(), &.{ "completion", "bash" }, &.{});
    defer bash.deinit();
    const zsh = try runGeode(root.path(), &.{ "completion", "zsh" }, &.{});
    defer zsh.deinit();
    const zsh_opt = try runGeode(root.path(), &.{ "completion", "--shell", "zsh" }, &.{});
    defer zsh_opt.deinit();
    try testing.expectEqual(@as(?u8, 0), zsh.code);
    try testing.expectEqualStrings(zsh_opt.out, zsh.out);
    try testing.expect(!std.mem.eql(u8, bash.out, zsh.out));
}

test "SONNY-6559 (7) a Debug command run with every audit setting reports no leak" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6559-audit-leak");
    defer root.remove();
    const a = testing.allocator;

    const env_file = try std.fmt.allocPrint(a, "GEODE_AUDIT_FILE_PATH={s}/env-audit.log", .{root.path()});
    defer a.free(env_file);
    const flag_file = try std.fmt.allocPrint(a, "{s}/flag-audit.log", .{root.path()});
    defer a.free(flag_file);
    const audit_env = [_][]const u8{
        "GEODE_AUDIT_ENABLED=1",
        "GEODE_AUDIT_FILE_ENABLED=1",
        env_file,
        "GEODE_AUDIT_SYSLOG_ENABLED=1",
        "GEODE_AUDIT_SYSLOG_HOST=127.0.0.1:9",
        "GEODE_AUDIT_WINDOWS_EVENTLOG_SOURCE=Geode6559",
        "GEODE_AUDIT_WINDOWS_EVENTLOG_LOG=Application",
    };

    const runs = [_][]const []const u8{
        &.{ "completion", "--shell", "bash" },
        &.{ "--audit-file", flag_file, "completion", "--shell", "bash" },
        &.{ "--audit-syslog", "127.0.0.1:9", "--audit-file", flag_file, "--audit-eventlog", "Geode6559b", "completion" },
    };
    for (runs) |argv| {
        const r = try runGeode(root.path(), argv, &audit_env);
        defer r.deinit();
        errdefer r.dump(argv);
        try testing.expectEqual(@as(?u8, 0), r.code);
        if (reportsLeak(r.err)) return error.LeakReported;
    }
}

fn readAuditLog(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, testing.allocator, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => try testing.allocator.dupe(u8, ""),
        else => err,
    };
}

test "SONNY-6559 (11) audit, login, logout, session, authn, mtls and tenant return through main on success" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6559-return");
    defer root.remove();
    var server = try util.spawnServerRandom(testing.allocator, util.TestEnv.standard());
    defer server.deinit();
    const a = testing.allocator;

    const audit_file = try std.fmt.allocPrint(a, "{s}/cli-audit.log", .{root.path()});
    defer a.free(audit_file);
    const addr = server.getAddr();

    const Case = struct { argv: []const []const u8, command: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{ "audit", "verify" }, .command = "audit" },
        .{ .argv = &.{ "login", "--server", addr, "--insecure-tls-skip-verify", "-U", util.defaultUsername(), "-P", password }, .command = "login" },
        .{ .argv = &.{"logout"}, .command = "logout" },
        .{ .argv = &.{ "session", "--help" }, .command = "session" },
        .{ .argv = &.{ "authn", "--help" }, .command = "authn" },
        .{ .argv = &.{ "mtls", "--help" }, .command = "mtls" },
        .{ .argv = &.{ "tenant", "list", "--server", addr, "--insecure-tls-skip-verify", "--user", util.defaultUsername(), "--password", password }, .command = "tenant" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.appendSlice(a, &.{ "--audit-file", audit_file });
        try argv.appendSlice(a, c.argv);
        const r = try runGeode(root.path(), argv.items, &.{});
        defer r.deinit();
        const log = try readAuditLog(audit_file);
        defer a.free(log);
        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\"category\":\"command\",\"action\":\"{s}\",\"outcome\":\"success\"", .{c.command});
        const returned = std.mem.indexOf(u8, log, needle) != null;
        if (r.code != 0 or !returned or reportsLeak(r.err)) {
            r.dump(argv.items);
            std.debug.print("SONNY-6559 (11): geode {s}: exit {?d}, success recorded on return: {}, leak report: {}\n--- audit log ---\n{s}\n", .{ c.command, r.code, returned, reportsLeak(r.err), log });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
