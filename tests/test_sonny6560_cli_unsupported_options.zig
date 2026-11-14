// CANARY: REQ=REQ-SONNY-6560-CLI-UNSUPPORTED-OPTIONS; FEATURE="CliOptions"; ASPECT=RefuseWhatIsNotSupported; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-14
//
// SONNY-6560: the geode CLI silently ignored what it did not support.
//
//   1. `geode query --format <fmt>` stored any value; the renderer handled
//      json, csv and table and returned success for anything else, so
//      `--format txt` printed nothing and exited 0. `--format dot|mermaid`
//      dropped an error result (exit 1, no message), an EXPLAIN plan and
//      every path, and wrote a node name holding `"` into DOT unescaped.
//   2. An option a command does not know was skipped (exit 0): `geode query`
//      and the user, role, policy, grant, revoke, auth, fle, apikey, session,
//      authn, tenant, audit, completion, mcp, migrate and backup list/info
//      argument loops had no branch for it (`geode serve` refuses one since
//      SONNY-6442), and a value option given last without its value was
//      skipped too.
//   3. `geode query --help` documented --begin, --commit and --rollback, which
//      nothing read: `--begin --rollback` committed the write. Other help
//      texts documented options nothing read: the global --config, --json and
//      -v/--verbose, `geode role create --permissions`, `geode auth logout
//      --token`.
//
// The contract: an option a command does not support, a format it does not
// render, and a value option without its value are refused with exit 2 and
// a message naming them, before anything runs; a format that is accepted
// renders every result shape (or says what it left out); the help documents
// only options that are read. An explicit transaction from the CLI is
// `--batch` with BEGIN / ... / ROLLBACK (or COMMIT) lines, which run on one
// connection.
//
// Spawns this build's geode (server and CLI) with a scratch HOME, working
// directory and data directory.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const exe = geode_test_bin.geode_exe;
const password = "Geode Test Admin Passphrase";
const bogus = "--no-such-opt-6560";

/// Names each run's output files apart.
var run_seq = std.atomic.Value(u64).init(0);

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

/// A scratch HOME / cwd / CLI data directory and a running `geode serve`.
const Env = struct {
    root: test_scratch.ScratchDir,
    server: util.ServerHandle,

    fn start() !Env {
        var root = try test_scratch.ScratchDir.create("sonny6560-cli");
        errdefer root.remove();
        const server = try util.spawnServerRandom(testing.allocator, util.TestEnv.standard());
        return .{ .root = root, .server = server };
    }

    fn stop(self: *Env) void {
        self.server.deinit();
        self.root.remove();
    }

    /// Run `geode <argv...>`, stdin `input` (closed after it is written).
    fn run(self: *Env, argv: []const []const u8, input: ?[]const u8) !Run {
        const a = testing.allocator;
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        const data_dir = try std.fmt.allocPrint(a, "{s}/cli-data", .{self.root.path()});
        defer a.free(data_dir);
        try env.put("HOME", self.root.path());
        try env.put("GEODE_DATA_DIR", data_dir);
        try env.put("GEODE_SERVER_ADDRESS", self.server.getAddr());
        try env.put("GEODE_LSP_PORT", "0");

        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(a);
        try full.append(a, exe);
        try full.appendSlice(a, argv);

        const tag = run_seq.fetchAdd(1, .monotonic);
        const out_path = try std.fmt.allocPrint(a, "{s}/out-{x}", .{ self.root.path(), tag });
        defer a.free(out_path);
        const err_path = try std.fmt.allocPrint(a, "{s}/err-{x}", .{ self.root.path(), tag });
        defer a.free(err_path);
        const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
        defer out.close(fsIo());
        const errf = try std.Io.Dir.cwd().createFile(fsIo(), err_path, .{ .read = true, .truncate = true });
        defer errf.close(fsIo());

        var child = try std.process.spawn(io, .{
            .argv = full.items,
            .environ_map = &env,
            .cwd = .{ .path = self.root.path() },
            .stdin = .pipe,
            .stdout = .{ .file = out },
            .stderr = .{ .file = errf },
        });
        if (child.stdin) |stdin| {
            if (input) |bytes| stdin.writeStreamingAll(io, bytes) catch {};
            stdin.close(io);
            child.stdin = null;
        }
        const pid = child.id.?;
        var status: u32 = 0;
        var exited = false;
        var waited_ms: u64 = 0;
        while (true) {
            const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
            if (rc == @as(usize, @intCast(pid))) {
                exited = true;
                break;
            }
            if (waited_ms >= 90_000) {
                std.posix.kill(pid, .KILL) catch {};
                _ = linux.waitpid(pid, &status, 0);
                break;
            }
            fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
            waited_ms += 50;
        }
        const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
        const stdout = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(4 << 20));
        errdefer a.free(stdout);
        const stderr = try std.Io.Dir.cwd().readFileAlloc(fsIo(), err_path, a, .limited(4 << 20));
        return .{ .code = code, .out = stdout, .err = stderr };
    }

    /// `geode query <args...> --server <addr> --insecure-tls-skip-verify -U geode -P <pw>`.
    fn query(self: *Env, args: []const []const u8, input: ?[]const u8) !Run {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.append(testing.allocator, "query");
        try argv.appendSlice(testing.allocator, args);
        try argv.appendSlice(testing.allocator, &.{ "--server", self.server.getAddr(), "--insecure-tls-skip-verify", "-U", util.defaultUsername(), "-P", password });
        return self.run(argv.items, input);
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Exit 2 with stderr naming `opt`: quoted ('--x'), or as "--x requires".
fn expectRefused(env: *Env, argv: []const []const u8, opt: []const u8) !void {
    const r = try env.run(argv, null);
    defer r.deinit();
    var quoted_buf: [96]u8 = undefined;
    var requires_buf: [96]u8 = undefined;
    const quoted = try std.fmt.bufPrint(&quoted_buf, "'{s}'", .{opt});
    const requires = try std.fmt.bufPrint(&requires_buf, "{s} requires", .{opt});
    const needle = opt;
    if (r.code != 2 or !(contains(r.err, quoted) or contains(r.err, requires))) {
        r.dump(argv);
        std.debug.print("SONNY-6560: expected exit 2 naming '{s}'\n", .{needle});
        return error.NotRefused;
    }
}

/// Every command's argument loop, each with the arguments it needs to get
/// past its own positional checks.
const command_prefixes = [_][]const []const u8{
    &.{ "query", "RETURN 1 AS x" },
    &.{ "shell", "--plain" },
    &.{"lsp"},
    &.{ "backup", "create" },
    &.{ "backup", "list" },
    &.{ "backup", "info", "x.backup" },
    &.{ "backup", "cleanup", "--dir", "bk", "--older-than", "1d" },
    &.{"restore"},
    &.{ "migrate", "status" },
    &.{ "migrate", "run", "--dry-run" },
    &.{ "migrate", "create", "m1", "--no-sign" },
    &.{ "migrate", "sign", "--all" },
    &.{ "user", "list" },
    &.{ "user", "show", "geode" },
    &.{ "user", "create", "sonny6560u", "u@example.com", "--generate-password" },
    &.{ "user", "delete", "nobody6560" },
    &.{ "role", "list" },
    &.{ "role", "create", "sonny6560r" },
    &.{ "policy", "list" },
    &.{ "policy", "create", "p6560" },
    &.{ "grant", "READ", "--to", "nobody6560" },
    &.{ "revoke", "READ", "--from", "nobody6560" },
    &.{ "auth", "login", "-U", "geode", "-P", "wrong" },
    &.{ "auth", "logout" },
    &.{ "auth", "validate", "--token", "t" },
    &.{ "auth", "token" },
    &.{ "auth", "verify" },
    &.{"logout"},
    &.{ "fle", "show-policy", "Person" },
    &.{ "storage", "verify" },
    &.{ "apikey", "list", "--user", "geode" },
    &.{ "apikey", "validate", "gk_x" },
    &.{ "session", "validate", "--token", "t" },
    &.{ "session", "info" },
    &.{ "session", "invalidate-all", "--user", "nobody6560" },
    &.{ "session", "check-idle" },
    &.{ "authn", "config", "--allow-anonymous-path", "/health" },
    &.{ "authn", "test-access", "--path", "/x" },
    &.{ "authn", "stepup-check", "--action", "read" },
    &.{ "authn", "stepup-mark" },
    &.{ "mtls", "status" },
    &.{ "tenant", "list" },
    &.{ "tenant", "create", "t6560" },
    &.{ "audit", "verify" },
    &.{ "completion", "--shell", "bash" },
    &.{ "mcp", "--stdio", "--no-auth" },
};

test "SONNY-6560 (2) every command refuses an option it does not know (exit 2, the option named)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    var failures: usize = 0;
    for (command_prefixes) |prefix| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, prefix);
        try argv.append(testing.allocator, bogus);
        expectRefused(&env, argv.items, bogus) catch {
            failures += 1;
        };
    }
    // Before the subcommand too.
    expectRefused(&env, &.{ bogus, "query", "RETURN 1" }, bogus) catch {
        failures += 1;
    };
    if (failures > 0) std.debug.print("SONNY-6560 (2): {d} command(s) accepted {s}\n", .{ failures, bogus });
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6560 (2) a value option given last without its value is refused (exit 2)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    const cases = [_]struct { argv: []const []const u8, opt: []const u8 }{
        .{ .argv = &.{ "query", "RETURN 1", "--format" }, .opt = "--format" },
        .{ .argv = &.{ "query", "RETURN 1", "--server" }, .opt = "--server" },
        .{ .argv = &.{ "completion", "--shell" }, .opt = "--shell" },
        .{ .argv = &.{ "mcp", "--stdio", "--no-auth", "--port" }, .opt = "--port" },
        .{ .argv = &.{ "mcp", "--stdio", "--no-auth", "--endpoint" }, .opt = "--endpoint" },
        .{ .argv = &.{ "audit", "verify", "--file" }, .opt = "--file" },
        .{ .argv = &.{ "user", "create", "sonny6560v", "v@example.com", "--password" }, .opt = "--password" },
        .{ .argv = &.{ "apikey", "list", "--user" }, .opt = "--user" },
        .{ .argv = &.{ "session", "validate", "--token" }, .opt = "--token" },
        .{ .argv = &.{ "authn", "stepup-check", "--action" }, .opt = "--action" },
        .{ .argv = &.{ "tenant", "create", "t6560", "--parent" }, .opt = "--parent" },
        .{ .argv = &.{ "policy", "create", "p6560", "--table" }, .opt = "--table" },
        .{ .argv = &.{ "backup", "list", "--dir" }, .opt = "--dir" },
        .{ .argv = &.{ "migrate", "status", "--dir" }, .opt = "--dir" },
        .{ .argv = &.{
            "--audit-file",
        }, .opt = "--audit-file" },
        .{ .argv = &.{"--audit-syslog"}, .opt = "--audit-syslog" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        expectRefused(&env, c.argv, c.opt) catch {
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6560 (2) geode mcp refuses a --port that is not a port (exit 2)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();
    for ([_][]const u8{ "abc", "99999", "-1", "" }) |port| {
        try expectRefused(&env, &.{ "mcp", "--stdio", "--no-auth", "--port", port }, "--port");
    }
}

test "SONNY-6560 (1) geode query refuses a format it does not render and lists the ones it does" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    for ([_][]const u8{ "txt", "text", "JSON", "yaml", "" }) |fmt| {
        const r = try env.query(&.{ "RETURN 1 AS x", "--format", fmt }, null);
        defer r.deinit();
        errdefer r.dump(&.{ "query", "RETURN 1 AS x", "--format", fmt });
        try testing.expectEqual(@as(?u8, 2), r.code);
        for ([_][]const u8{ "json", "table", "csv", "dot", "mermaid" }) |supported| {
            try testing.expect(contains(r.err, supported));
        }
        try testing.expectEqual(@as(usize, 0), r.out.len);
    }
    // Every supported format renders a scalar row.
    for ([_][]const u8{ "json", "table", "csv" }) |fmt| {
        const r = try env.query(&.{ "RETURN 1 AS x", "--format", fmt }, null);
        defer r.deinit();
        errdefer r.dump(&.{ "query", "RETURN 1 AS x", "--format", fmt });
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(contains(r.out, "1"));
    }
}

test "SONNY-6560 (1) --format dot and mermaid render every result shape or say what they left out" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    {
        const r = try env.query(&.{"CREATE (:Sonny6560 {name: 'a\"b'})-[:KNOWS]->(:Sonny6560 {name: 'c'})"}, null);
        defer r.deinit();
        errdefer r.dump(&.{"CREATE ..."});
        try testing.expectEqual(@as(?u8, 0), r.code);
    }

    // A path renders its nodes and its relationship.
    {
        const r = try env.query(&.{ "MATCH p = (:Sonny6560)-[:KNOWS]->(:Sonny6560) RETURN p", "--format", "dot" }, null);
        defer r.deinit();
        errdefer r.dump(&.{ "query", "MATCH p = ... RETURN p", "--format", "dot" });
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(contains(r.out, "digraph"));
        try testing.expect(contains(r.out, "->"));
        try testing.expect(contains(r.out, "KNOWS"));
        // The name holding a double quote is escaped inside the DOT string.
        try testing.expect(contains(r.out, "a\\\"b"));
        try testing.expect(!contains(r.out, "a\"b\""));
    }
    {
        const r = try env.query(&.{ "MATCH p = (:Sonny6560)-[:KNOWS]->(:Sonny6560) RETURN p", "--format", "mermaid" }, null);
        defer r.deinit();
        errdefer r.dump(&.{ "query", "MATCH p = ... RETURN p", "--format", "mermaid" });
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(contains(r.out, "flowchart"));
        try testing.expect(contains(r.out, "-->"));
        try testing.expect(contains(r.out, "KNOWS"));
    }
    for ([_][]const u8{ "dot", "mermaid" }) |fmt| {
        // A failed statement says why on stderr and exits 1.
        {
            const r = try env.query(&.{ "MATCH (n) RETURN nosuchfunction6560(n)", "--format", fmt }, null);
            defer r.deinit();
            errdefer r.dump(&.{ "query", "MATCH (n) RETURN nosuchfunction6560(n)", "--format", fmt });
            try testing.expectEqual(@as(?u8, 1), r.code);
            try testing.expect(contains(r.err, "Error"));
        }
        // EXPLAIN prints its plan.
        {
            const r = try env.query(&.{ "EXPLAIN MATCH (n:Sonny6560) RETURN n", "--format", fmt }, null);
            defer r.deinit();
            errdefer r.dump(&.{ "query", "EXPLAIN MATCH (n:Sonny6560) RETURN n", "--format", fmt });
            try testing.expectEqual(@as(?u8, 0), r.code);
            try testing.expect(contains(r.out, "\"ops\""));
        }
        // Values that are not graph elements are named as left out.
        {
            const r = try env.query(&.{ "RETURN 1 AS x", "--format", fmt }, null);
            defer r.deinit();
            errdefer r.dump(&.{ "query", "RETURN 1 AS x", "--format", fmt });
            try testing.expectEqual(@as(?u8, 0), r.code);
            try testing.expect(contains(r.err, "not shown"));
        }
    }
}

fn countNodes(env: *Env, label: []const u8) !i64 {
    const q = try std.fmt.allocPrint(testing.allocator, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    defer testing.allocator.free(q);
    const r = try env.query(&.{q}, null);
    defer r.deinit();
    errdefer r.dump(&.{ "query", q });
    try testing.expectEqual(@as(?u8, 0), r.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trim(u8, r.out, " \r\n"), .{});
    defer parsed.deinit();
    return parsed.value.object.get("rows").?.array.items[0].object.get("c").?.integer;
}

test "SONNY-6560 (3) --begin, --commit and --rollback are refused, not ignored; --batch carries an explicit transaction" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    {
        const r = try env.run(&.{ "query", "--help" }, null);
        defer r.deinit();
        const help = if (r.out.len > 0) r.out else r.err;
        for ([_][]const u8{ "--begin", "--commit", "--rollback" }) |opt| {
            if (contains(help, opt)) {
                r.dump(&.{ "query", "--help" });
                return error.HelpDocumentsUnreadOption;
            }
        }
    }
    for ([_][]const []const u8{
        &.{ "CREATE (:Sonny6560Tx {k: 1})", "--begin", "--rollback" },
        &.{ "CREATE (:Sonny6560Tx {k: 1})", "--begin", "--commit" },
        &.{ "CREATE (:Sonny6560Tx {k: 1})", "--rollback" },
    }) |args| {
        const r = try env.query(args, null);
        defer r.deinit();
        errdefer r.dump(args);
        try testing.expectEqual(@as(?u8, 2), r.code);
    }
    try testing.expectEqual(@as(i64, 0), try countNodes(&env, "Sonny6560Tx"));

    // The supported spelling: one connection, explicit BEGIN ... ROLLBACK.
    {
        const r = try env.query(&.{"--batch"}, "BEGIN\nCREATE (:Sonny6560Tx {k: 1})\nROLLBACK\n");
        defer r.deinit();
        errdefer r.dump(&.{ "query", "--batch" });
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    try testing.expectEqual(@as(i64, 0), try countNodes(&env, "Sonny6560Tx"));
    {
        const r = try env.query(&.{"--batch"}, "BEGIN\nCREATE (:Sonny6560Tx {k: 2})\nCOMMIT\n");
        defer r.deinit();
        errdefer r.dump(&.{ "query", "--batch" });
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    try testing.expectEqual(@as(i64, 1), try countNodes(&env, "Sonny6560Tx"));
}

test "SONNY-6560 (3) options a help text documents and nothing reads are refused and no longer documented" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try Env.start();
    defer env.stop();

    try expectRefused(&env, &.{ "--config", "geode.toml", "query", "RETURN 1" }, "--config");
    try expectRefused(&env, &.{ "--json", "query", "RETURN 1" }, "--json");
    try expectRefused(&env, &.{ "--verbose", "query", "RETURN 1" }, "--verbose");
    try expectRefused(&env, &.{ "-v", "query", "RETURN 1" }, "-v");
    try expectRefused(&env, &.{ "role", "create", "sonny6560p", "--permissions", "read" }, "--permissions");
    try expectRefused(&env, &.{ "auth", "logout", "--token", "t" }, "--token");

    const helps = [_]struct { argv: []const []const u8, unread: []const []const u8 }{
        .{ .argv = &.{"--help"}, .unread = &.{ "--config", "--json", "--verbose" } },
        .{ .argv = &.{ "role", "--help" }, .unread = &.{"--permissions"} },
        .{ .argv = &.{ "auth", "logout", "--help" }, .unread = &.{"--token"} },
    };
    for (helps) |h| {
        const r = try env.run(h.argv, null);
        defer r.deinit();
        for (h.unread) |opt| {
            if (contains(r.out, opt) or contains(r.err, opt)) {
                r.dump(h.argv);
                std.debug.print("SONNY-6560 (3): help still documents {s}\n", .{opt});
                return error.HelpDocumentsUnreadOption;
            }
        }
    }
}
