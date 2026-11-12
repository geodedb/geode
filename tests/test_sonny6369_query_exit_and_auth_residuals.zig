// SONNY-6369 regression: residuals found during SONNY-6367/6313/2773/3034.
//
// 1. `geode query` exited 0 when the query failed (cmdQuery: only a transport
//    failure exited non-zero). A query the server answers with an error
//    exits 1 now, as --batch and --file already did.
// 2. Giving a superuser a role other than admin had no effect, offline or
//    over the wire, and reported success: a superuser always resolves to
//    Admin (role_resolver). It is refused now (0A000), and nothing changes.
// 3. geode.rls add / remove procedures answered missing arguments and "engine
//    not initialized" with 00000 "error:" rows; they are GQLSTATUS errors.
// 4. geode.auth.user_set_attribute / user_remove_attribute results did not own
//    their rows (a caller freeing them leaked), and removing an attribute that
//    is not set answered 00000; it is an error (42704).
// 5. docs/GQL_AUTH_DDL.md said a CREATE USER whose save failed answered a
//    status row; ENTERPRISE_GAPS.md and KNOWN_TEST_ISSUES.md gave the
//    gql_conformance suite as 20/20.
// 6. EXPLAIN POLICY did not report the checks the executor makes itself: the
//    procedure gate, the DDL schema gates, the USE GRAPH bind check.
// 7. A user imported with a BLAKE2b hash kept it for ever (it was never
//    re-hashed with Argon2id at login), and the BLAKE2b check took
//    microseconds where an Argon2id check takes tens of milliseconds, so the
//    login time told which accounts held a legacy hash.
//
// CANARY: REQ=REQ-SONNY-6369-QUERY-EXIT-AUTH-RESIDUALS; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");
const wd = @import("sonny2753_gps_world.zig");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const execution = geode.execution;
const rls_dispatch = geode.execution.rls_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = user_mgmt.Role;
const linux = std.os.linux;

const binary_path = "./zig-out/bin/geode";
const hmac_hex = "6c" ** 32;
const admin_user = util.DefaultAuth.username;
const admin_pw = util.DefaultAuth.password;
const legacy_pw = "Amber Window Gentle Thunder Two";
const wrong_pw = "Copper Meadow Whisper Falcon Eight";

// ---------------------------------------------------------------------------
// Subprocess helpers (as tests/test_sonny6367_offline_user_cli.zig)
// ---------------------------------------------------------------------------

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn nowNanos() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` and wait for it (120 s at most).
fn runGeode(aa: std.mem.Allocator, args: []const []const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    const t0 = nowMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) > 0) try output.appendSlice(aa, buf[0..n]);
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        if (nowMillis() - t0 > 120_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                try output.appendSlice(aa, buf[0..n]);
            }
            f.close(io);
        }
    }
    return .{ .code = code, .output = output.items };
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6369-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

/// A data directory with a key file and a sealed store (the bootstrap admin,
/// a superuser).
fn bootstrappedStore(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try freshDir(aa, tag);
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    const key_file = try std.Io.Dir.cwd().createFile(io, key_path, .{ .permissions = .fromMode(0o600) });
    try key_file.writeStreamingAll(io, hmac_hex);
    key_file.close(io);

    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    _ = try mgr.bootstrapDefaultAdmin(&kr.key);
    try mgr.verifyChain(&kr.key);
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

/// What the store holds for `user`, read offline: its role as the server
/// resolves it at login, its password hash, its auth version and its
/// reset flag; the chain verifies.
const Stored = struct { role: Role, hash: []const u8, auth_version: u64, reset_required: bool, superuser: bool };

fn storedUser(aa: std.mem.Allocator, dir: []const u8, user: []const u8) !Stored {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    const r = mgr.storage.getUserByUsername(user) orelse return error.UserNotStored;
    const kr = try AuthGraphManager.resolveExistingHmacKey(pa, dir);
    try mgr.verifyChain(&kr.key);
    return .{
        .role = geode.security.role_resolver.resolveRoleFromGraph(mgr.storage.store, r),
        .hash = try aa.dupe(u8, r.getPasswordHash()),
        .auth_version = r.auth_version,
        .reset_required = r.password_reset_required,
        .superuser = r.is_superuser,
    };
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,

    fn start(allocator: std.mem.Allocator, dir: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .proc = proc, .addr = addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
    }

    /// SIGTERM and wait (30 s at most) for the graceful shutdown, which
    /// flushes the store; then `stop`. A write made outside a statement
    /// (the login's hash upgrade) is durable once flushed.
    fn stopGracefully(self: *Server, allocator: std.mem.Allocator) void {
        if (self.proc.child.id) |pid| {
            std.posix.kill(pid, .TERM) catch {};
            const t0 = nowMillis();
            while (util.processAlive(pid) and nowMillis() - t0 < 30_000) {
                var req = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
                _ = linux.nanosleep(&req, null);
            }
        }
        self.stop(allocator);
    }
};

// ---------------------------------------------------------------------------
// 1. geode query exits non-zero when the query fails
// ---------------------------------------------------------------------------

fn query(aa: std.mem.Allocator, addr: []const u8, q: []const u8) !Run {
    return runGeode(aa, &.{ binary_path, "query", "--server", addr, "--insecure", "--no-saved-session", "-U", admin_user, "-P", admin_pw, q });
}

test "SONNY-6369: geode query exits 1 when the server answers the query with an error, 0 when it succeeds" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "query");
    defer removeDir(dir);
    var s = try Server.start(testing.allocator, dir);
    defer s.stop(testing.allocator);

    const ok = try query(aa, s.addr, "RETURN 1 AS x");
    if (ok.code != 0) std.debug.print("RETURN 1 exited {d}:\n{s}\n", .{ ok.code, ok.output });
    try testing.expectEqual(@as(u8, 0), ok.code);

    for ([_][]const u8{ "RETURN 1/0 AS x", "THIS IS NOT GQL", "CALL geode.nosuch.procedure6369()" }) |q| {
        const r = try query(aa, s.addr, q);
        if (r.code == 0) std.debug.print("`{s}` failed and exited 0:\n{s}\n", .{ q, r.output });
        try testing.expectEqual(@as(u8, 1), r.code);
    }
}

// ---------------------------------------------------------------------------
// 2. A superuser keeps the admin role; another role is refused
// ---------------------------------------------------------------------------

fn expectWireCode(allocator: std.mem.Allocator, client: *util.QuicProtoClient, q: []const u8, want: ?[]const u8) !void {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 10);
    defer r.deinit(allocator);
    if (want) |code| {
        const got = r.error_code orelse {
            std.debug.print("`{s}` answered 00000, want {s}\n", .{ q, code });
            return error.FailureReportedAsSuccess;
        };
        if (!std.mem.eql(u8, got, code)) std.debug.print("`{s}`: {s} {?s}, want {s}\n", .{ q, got, r.error_message, code });
        try testing.expectEqualStrings(code, got);
    } else if (r.error_code) |c| {
        std.debug.print("`{s}`: {s} {?s}, want success\n", .{ q, c, r.error_message });
        return error.QueryRefused;
    }
}

test "SONNY-6369: giving a superuser a role other than admin is refused over the wire and offline, and changes nothing" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const allocator = testing.allocator;
    const dir = try freshDir(aa, "superuser");
    defer removeDir(dir);

    {
        var s = try Server.start(allocator, dir);
        defer s.stop(allocator);
        var client = try util.QuicProtoClient.connect(allocator, s.addr);
        defer client.deinit();
        var h = try client.hello(allocator, admin_user, admin_pw);
        defer h.deinit(allocator);
        try testing.expect(h.success);

        try expectWireCode(allocator, &client, "ALTER USER " ++ admin_user ++ " SET ROLE readonly", "0A000");
        try expectWireCode(allocator, &client, "CALL geode.auth.user_assign_role('" ++ admin_user ++ "', 'readwrite')", "0A000");
        // admin is the role it has: no change, no error.
        try expectWireCode(allocator, &client, "ALTER USER " ++ admin_user ++ " SET ROLE admin", null);
        // Still an administrator.
        try expectWireCode(allocator, &client, "CREATE USER bob6369 SET PASSWORD 'Correct Horse Battery Staple Seven'", null);
    }

    for ([_][]const []const u8{
        &.{ binary_path, "user", "assign-role", admin_user, "readonly", "--force", "--data-dir", dir },
        &.{ binary_path, "user", "update", admin_user, "--role", "user", "--force", "--data-dir", dir },
    }) |args| {
        const r = try runGeode(aa, args);
        if (r.code == 0) std.debug.print("{s} {s} of the superuser exited 0:\n{s}\n", .{ args[1], args[2], r.output });
        try testing.expect(r.code != 0);
    }
    const st = try storedUser(aa, dir, admin_user);
    try testing.expect(st.superuser);
    try testing.expectEqual(Role.Admin, st.role);
    // Offline admin is still accepted.
    const ok = try runGeode(aa, &.{ binary_path, "user", "assign-role", admin_user, "admin", "--force", "--data-dir", dir });
    if (ok.code != 0) std.debug.print("assign-role admin to the superuser exited {d}:\n{s}\n", .{ ok.code, ok.output });
    try testing.expectEqual(@as(u8, 0), ok.code);
}

// ---------------------------------------------------------------------------
// 3-4. geode.rls and attribute procedure failures; result ownership
// ---------------------------------------------------------------------------

const StrictWorld = struct {
    h: harness.Harness,
    auth_was: bool,
    engine_was: ?*anyopaque,

    fn init(self: *StrictWorld) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "alice6369", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
        rls_dispatch.resetCallbacks();
        self.engine_was = rls_types.getGlobalExprRLSEngine();
        rls_types.setGlobalExprRLSEngine(null);
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6369";
    }

    fn deinit(self: *StrictWorld) void {
        rls_types.setGlobalExprRLSEngine(self.engine_was);
        rls_dispatch.resetCallbacks();
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    /// Run `q` with std.testing.allocator and free its result (a leak fails
    /// the test).
    fn run(self: *StrictWorld, q: []const u8) !void {
        var parsed = try geode.parseGqlOptions(q, testing.allocator, .{});
        defer parsed.deinit();
        var result = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.h.ctx);
        result.deinit(testing.allocator);
    }

    /// `q` fails with an error proto_util maps to `code`.
    fn expectCode(self: *StrictWorld, q: []const u8, code: []const u8) !void {
        if (self.run(q)) |_| {
            std.debug.print("`{s}` answered 00000, want {s}\n", .{ q, code });
            return error.FailureReportedAsSuccess;
        } else |err| {
            const got = geode.proto_util.mapError(err).code;
            if (!std.mem.eql(u8, got, code)) std.debug.print("`{s}`: {s} ({s}), want {s}\n", .{ q, got, @errorName(err), code });
            try testing.expectEqualStrings(code, got);
        }
    }
};

test "SONNY-6369: geode.rls add / remove procedures answer missing arguments and a missing engine with GQLSTATUS errors" {
    var w: StrictWorld = undefined;
    try w.init();
    defer w.deinit();

    // Missing arguments: 22023.
    try w.expectCode("CALL geode.rls.add_deny_policy('', 'Secret', 'bob')", "22023");
    try w.expectCode("CALL geode.rls.remove_deny_policy('g1', '', 'bob')", "22023");
    try w.expectCode("CALL geode.rls.add_attribute_policy('g1', 'Doc', '', 'dept')", "22023");
    try w.expectCode("CALL geode.rls.remove_attribute_policy('g1', 'Doc', 'dept', '')", "22023");
    // No filter engine / expression engine in this process: 55000.
    try w.expectCode("CALL geode.rls.add_deny_policy('g1', 'Secret', 'bob')", "55000");
    try w.expectCode("CALL geode.rls.remove_deny_policy('g1', 'Secret', 'bob')", "55000");
    try w.expectCode("CALL geode.rls.add_attribute_policy('g1', 'Doc', 'dept', 'dept')", "55000");
    try w.expectCode("CALL geode.rls.remove_attribute_policy('g1', 'Doc', 'dept', 'dept')", "55000");
}

test "SONNY-6369: user_set_attribute / user_remove_attribute results own their rows; removing an attribute that is not set is 42704" {
    var w: StrictWorld = undefined;
    try w.init();
    defer w.deinit();

    try w.run("CALL geode.auth.user_set_attribute('alice6369', 'dept', 'eng')");
    try w.run("CALL geode.auth.user_remove_attribute('alice6369', 'dept')");
    // Not set (any more): an error, not a status row.
    try w.expectCode("CALL geode.auth.user_remove_attribute('alice6369', 'dept')", "42704");
    try w.expectCode("CALL geode.auth.user_remove_attribute('alice6369', 'never6369')", "42704");
    // Missing arguments, a user that does not exist.
    try w.expectCode("CALL geode.auth.user_remove_attribute('', 'dept')", "22023");
    try w.expectCode("CALL geode.auth.user_remove_attribute('alice6369', '')", "22023");
    try w.expectCode("CALL geode.auth.user_remove_attribute('nobody6369', 'dept')", "42704");
}

// ---------------------------------------------------------------------------
// 5. Stale docs
// ---------------------------------------------------------------------------

fn readFileAlloc(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    const sio = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().openFile(sio, path, .{});
    defer f.close(sio);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(sio, &buf, off);
        if (n == 0) break;
        try out.appendSlice(aa, buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    return out.items;
}

test "SONNY-6369: the docs give CREATE USER's save failure as 58030 and the gql_conformance suite's real count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const auth_ddl = try readFileAlloc(aa, "docs/GQL_AUTH_DDL.md");
    var lines = std.mem.splitScalar(u8, auth_ddl, '\n');
    var create_row: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| `CREATE USER` |")) create_row = line;
    }
    const row = create_row orelse return error.CreateUserRowMissing;
    if (std.mem.indexOf(u8, row, "58030") == null or std.mem.indexOf(u8, row, "error: UserNotPersisted") != null) {
        std.debug.print("docs/GQL_AUTH_DDL.md CREATE USER row: {s}\n", .{row});
        return error.StaleDoc;
    }

    const suite = try readFileAlloc(aa, "tests/gql_conformance.zig");
    var count: usize = 0;
    var sl = std.mem.splitScalar(u8, suite, '\n');
    while (sl.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"")) count += 1;
    }
    const want = try std.fmt.allocPrint(aa, "{d}/{d}", .{ count, count });
    for ([_][]const u8{ "docs/ENTERPRISE_GAPS.md", "docs/KNOWN_TEST_ISSUES.md" }) |path| {
        const text = try readFileAlloc(aa, path);
        var it = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (it.next()) |line| : (n += 1) {
            if (std.mem.indexOf(u8, line, "gql_conformance") == null) continue;
            if (std.mem.indexOf(u8, line, "20/20") != null) {
                std.debug.print("{s}:{d} gives gql_conformance as 20/20; the suite has {s}\n", .{ path, n + 1, want });
                return error.StaleDoc;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 6. EXPLAIN POLICY reports the executor's own checks
// ---------------------------------------------------------------------------

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

const Row = struct { action: []const u8, resource: []const u8, decision: []const u8, reason: []const u8 };

/// EXPLAIN POLICY FOR `inner` through the gRPC Execute handler, as rows.
fn explain(ga: std.mem.Allocator, session_id: []const u8, inner: []const u8) ![]const Row {
    const q = try std.fmt.allocPrint(ga, "EXPLAIN POLICY FOR {s}", .{inner});
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = q, .params = .empty });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: refused {s} {s}\n", .{ q, e.code, e.message });
            return error.Refused;
        },
        else => {},
    }
    var out = std.ArrayList(Row).empty;
    var pulls: usize = 0;
    while (pulls < 32) : (pulls += 1) {
        const preq = try encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
        const pull = try decodeProto(schema.PullResponse, ga, try grpc.handlePull(preq, ga));
        const presp = pull.response orelse return error.MissingPayload;
        const page = switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            else => return error.UnexpectedPayload,
        };
        for (page.rows.items) |row| {
            if (row.values.items.len != 5) return error.WrongColumnCount;
            var s: [4][]const u8 = undefined;
            for (row.values.items[1..5], 0..) |v, i| {
                s[i] = if (v.kind) |k| switch (k) {
                    .string_val => |sv| sv.value,
                    else => return error.NotAString,
                } else return error.NotAString;
            }
            try out.append(ga, .{ .action = s[0], .resource = s[1], .decision = s[2], .reason = s[3] });
        }
        if (page.final) return out.toOwnedSlice(ga);
    }
    return error.PullNeverFinished;
}

fn expectReported(ga: std.mem.Allocator, session_id: []const u8, inner: []const u8, action: []const u8, resource: []const u8, allowed: bool) !void {
    const rows = try explain(ga, session_id, inner);
    for (rows) |r| {
        if (!std.mem.eql(u8, r.action, action) or !std.mem.eql(u8, r.resource, resource)) continue;
        const is_allow = std.mem.eql(u8, r.decision, "allow");
        if (is_allow != allowed) {
            std.debug.print("EXPLAIN POLICY FOR {s}: {s} on {s} reported {s} ({s}); the gate {s}\n", .{ inner, action, resource, r.decision, r.reason, if (allowed) "allows it" else "refuses it" });
            return error.ReportDisagreesWithGate;
        }
        return;
    }
    std.debug.print("EXPLAIN POLICY FOR {s}: no row for {s} on {s}; rows:\n", .{ inner, action, resource });
    for (rows) |r| std.debug.print("  {s} {s} {s} {s}\n", .{ r.action, r.resource, r.decision, r.reason });
    return error.DecisionNotReported;
}

const read_a = [_]wd.policy_catalog.Action{.read};
const schema_a = [_]wd.policy_catalog.Action{.schema};

test "SONNY-6369: EXPLAIN POLICY reports the USE GRAPH bind check" {
    var w: wd.World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    const nora = try w.session("nora6369", .None, null);
    try wd.expectDenied(ga, nora, "USE GRAPH g1");
    try expectReported(ga, nora, "USE GRAPH g1", "bind_graph", "graph:g1", false);

    const rita = try w.session("rita6369", .Admin, null);
    try wd.expectRuns(ga, rita, "USE GRAPH g1");
    try expectReported(ga, rita, "USE GRAPH g1", "bind_graph", "graph:g1", true);
}

test "SONNY-6369: EXPLAIN POLICY reports the procedure gate, with a deny on the graph the procedure runs on" {
    var w: wd.World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("no_reads_g1_6369", "g1", &read_a, .deny);

    const on_g1 = try w.session("rita6369", .ReadWrite, "g1");
    try wd.expectDenied(ga, on_g1, "CALL db.labels()");
    try expectReported(ga, on_g1, "CALL db.labels()", "read", "procedure:db.labels", false);

    const on_g2 = try w.session("rita6369", .ReadWrite, "g2");
    try wd.expectRuns(ga, on_g2, "CALL db.labels()");
    try expectReported(ga, on_g2, "CALL db.labels()", "read", "procedure:db.labels", true);
}

test "SONNY-6369: EXPLAIN POLICY reports the DDL schema gates (the graph DDL names, and every graph for catalog DDL)" {
    var w: wd.World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    // Schema on g1 only: the handler's gate allows index DDL there, the
    // executor's catalog gate (schema on every graph) does not.
    try w.policy("schema_g1_6369", "g1", &schema_a, .allow);

    const on_g1 = try w.session("rita6369", .ReadWrite, "g1");
    try wd.expectDenied(ga, on_g1, "CREATE INDEX idx6369 FOR (n:C) ON (n.v)");
    try expectReported(ga, on_g1, "CREATE INDEX idx6369 FOR (n:C) ON (n.v)", "schema", "graph:g1", true);
    try expectReported(ga, on_g1, "CREATE INDEX idx6369 FOR (n:C) ON (n.v)", "schema", "graph:*", false);

    // CREATE GRAPH asks schema and bind on the graph it names.
    try wd.expectDenied(ga, on_g1, "CREATE GRAPH g9_6369");
    try expectReported(ga, on_g1, "CREATE GRAPH g9_6369", "schema", "graph:g9_6369", false);

    const admin = try w.session("root6369", .Admin, null);
    try expectReported(ga, admin, "CREATE INDEX idx6369 FOR (n:C) ON (n.v)", "schema", "graph:*", true);
    try expectReported(ga, admin, "CREATE GRAPH g9_6369", "bind_graph", "graph:g9_6369", true);
}

// ---------------------------------------------------------------------------
// 7. BLAKE2b -> Argon2id at login; the legacy check takes Argon2id's time
// ---------------------------------------------------------------------------

/// The legacy BLAKE2b format: lowercase hex of
/// BLAKE2b-256(password ++ "geode-salt-secure-v2").
fn legacyBlake2bHex(password: []const u8) [64]u8 {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(password);
    h.update("geode-salt-secure-v2");
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "SONNY-6369: a BLAKE2b-imported user's hash is replaced with Argon2id at its first successful login, without ending its sessions" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const allocator = testing.allocator;
    const dir = try bootstrappedStore(aa, "rehash");
    defer removeDir(dir);

    const hex = legacyBlake2bHex(legacy_pw);
    const imp = try runGeode(aa, &.{ binary_path, "user", "import", "legacy6369", "--hash", &hex, "--algorithm", "blake2b", "--role", "readwrite", "--force", "--data-dir", dir });
    if (imp.code != 0) std.debug.print("user import exited {d}:\n{s}\n", .{ imp.code, imp.output });
    try testing.expectEqual(@as(u8, 0), imp.code);
    const before = try storedUser(aa, dir, "legacy6369");
    try testing.expectEqualStrings(&hex, before.hash);

    {
        var s = try Server.start(allocator, dir);
        defer s.stopGracefully(allocator);
        // A wrong password migrates nothing.
        {
            var c = try util.QuicProtoClient.connect(allocator, s.addr);
            defer c.deinit();
            var h = try c.hello(allocator, "legacy6369", wrong_pw);
            defer h.deinit(allocator);
            try testing.expect(!h.success);
        }
        var c = try util.QuicProtoClient.connect(allocator, s.addr);
        defer c.deinit();
        var h = try c.hello(allocator, "legacy6369", legacy_pw);
        defer h.deinit(allocator);
        try testing.expect(h.success);
        // The session the login opened is still current.
        var r = try c.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 10);
        defer r.deinit(allocator);
        if (r.error_code) |code| {
            std.debug.print("the migrating login's session was refused: {s} {?s}\n", .{ code, r.error_message });
            return error.SessionEnded;
        }
    }

    const after = try storedUser(aa, dir, "legacy6369");
    if (!std.mem.startsWith(u8, after.hash, "$argon2id$")) {
        std.debug.print("after a successful login the stored hash is still {s}\n", .{after.hash});
        return error.LegacyHashKept;
    }
    try testing.expectEqual(before.auth_version, after.auth_version);
    try testing.expectEqual(before.reset_required, after.reset_required);
    try testing.expectEqual(Role.ReadWrite, after.role);
    try testing.expect(try user_mgmt.verifyPassword(legacy_pw, after.hash));

    // The migrated user logs in with the same password; a wrong one fails.
    var s = try Server.start(allocator, dir);
    defer s.stop(allocator);
    {
        var c = try util.QuicProtoClient.connect(allocator, s.addr);
        defer c.deinit();
        var h = try c.hello(allocator, "legacy6369", wrong_pw);
        defer h.deinit(allocator);
        try testing.expect(!h.success);
    }
    var c = try util.QuicProtoClient.connect(allocator, s.addr);
    defer c.deinit();
    var h = try c.hello(allocator, "legacy6369", legacy_pw);
    defer h.deinit(allocator);
    try testing.expect(h.success);
}

test "SONNY-6369: checking a password against a legacy BLAKE2b hash takes as long as an Argon2id check" {
    const argon = try user_mgmt.hashPassword(testing.allocator, legacy_pw);
    defer testing.allocator.free(argon);
    const hex = legacyBlake2bHex(legacy_pw);

    var argon_min: u64 = std.math.maxInt(u64);
    var legacy_min: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var t0 = nowNanos();
        try testing.expect(!try user_mgmt.verifyPassword(wrong_pw, argon));
        argon_min = @min(argon_min, nowNanos() - t0);
        t0 = nowNanos();
        try testing.expect(!try user_mgmt.verifyPassword(wrong_pw, &hex));
        legacy_min = @min(legacy_min, nowNanos() - t0);
    }
    // The right password still verifies.
    try testing.expect(try user_mgmt.verifyPassword(legacy_pw, &hex));
    if (legacy_min * 3 < argon_min) {
        std.debug.print("legacy check {d} us, Argon2id check {d} us: the time tells a legacy hash apart\n", .{ legacy_min / 1000, argon_min / 1000 });
        return error.LegacyCheckTimingOracle;
    }
}
