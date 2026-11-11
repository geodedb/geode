// SONNY-2977: a MATCH whose node pattern has a single-property inline map,
// followed by SET, changed only ONE of the nodes it matched. Found from
// go/oidc (SONNY-2821) on geode v0.8.2: three nodes sharing a tenant_id,
// `MATCH (p:ZZProbe {tenant_id: $t}) SET p.state = 'new'` changed one, with
// no error, with a literal too, with a WHERE, with a per-row RETURN (which
// returned one row); an aggregate RETURN, a two-property map and
// `WHERE p.tenant_id = $t` changed all three.
//
// The legacy executor's point read took MERGE's property index entry as the
// whole answer for a one-property map, and that entry names one node
// (SONNY-2806 round 7 made it `lookupOnlyMergeHolder`: the entry answers only
// for a key's only holder, and a key two nodes have held is read by the
// label scan).
//
// This is the ticket's probe matrix: for every statement, three nodes share
// the key, one statement runs, and all three change. On an in-memory store,
// a persisted store, a tenant-scoped session (another tenant holds nodes
// with the same key, which it must not write) and a session under an RLS
// policy (hidden nodes with the same key, which it must not write), and over
// QUIC against the real server (./zig-out/bin/geode). A key whose only
// holder the session may not see is written by none.
//
// CANARY: REQ=REQ-SONNY-2977-INLINE-MAP-SET; FEATURE="MatchSet"; ASPECT=EveryInlineMapHolder; STATUS=TESTED; TEST=tests/test_sonny2977_inline_map_set.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const Value = geode.value_types.Value;

const Mode = enum { in_memory, persisted, tenant_scoped, rls_policy };
const all_modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

const tenant_a = "tenant_a";
const param_names = [_][]const u8{ "t", "s" };
const param_values = [_]Value{ .{ .Str = "acme" }, .{ .Str = "old" } };
const tenant_b = "tenant_b";

/// One statement of the matrix: it changes the three `acme` nodes, and
/// returns `want` (null: not checked).
const Probe = struct { stmt: []const u8, want: ?[]const []const u8 = null };

const probes = [_]Probe{
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t}) SET p.state = 'new'" },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: 'acme'}) SET p.state = 'new'" },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t}) WHERE p.state = 'old' SET p.state = 'new'" },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t}) SET p.state = 'new' RETURN p.id", .want = &.{ "1", "2", "3" } },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t}) WHERE p.state = 'old' SET p.state = 'new' RETURN count(p)", .want = &.{"3"} },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t}) SET p.state = 'new' RETURN count(p)", .want = &.{"3"} },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t, state: $s}) SET p.state = 'new'" },
    .{ .stmt = "MATCH (p:ZZProbe {tenant_id: $t, state: 'old'}) SET p.state = 'new'" },
    .{ .stmt = "MATCH (p:ZZProbe) WHERE p.tenant_id = $t SET p.state = 'new'" },
};

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        const persisted = mode != .in_memory;
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.rls) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    /// Run `query` as the session, with `$t = 'acme'` and `$s = 'old'`.
    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var ctx = self.ctx;
        ctx.query_param_names = &param_names;
        ctx.query_param_values = &param_values;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, user: ?[]const u8, query: []const u8) !void {
        const saved_tenant = self.ctx.tenant_id;
        const saved_user = self.ctx.user;
        defer {
            self.ctx.tenant_id = saved_tenant;
            self.ctx.user = saved_user;
        }
        self.ctx.tenant_id = tenant;
        self.ctx.user = user;
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// Three `(:ZZProbe {tenant_id: 'acme', state: 'old', id: 1..3})` the
    /// session sees. A tenant-scoped session's are `tenant_a`'s, and
    /// `tenant_b` holds two more `acme` nodes and the only `solo` one. Under
    /// the RLS policy the session's user `bob` may not read `:Hidden`, and two
    /// hidden `acme` nodes and the only `solo` one sit beside the three.
    fn seed(self: *Session) !void {
        const aa = self.arena.allocator();
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        if (self.mode == .tenant_scoped) {
            try self.execAs(tenant_b, null, "CREATE (:ZZProbe {tenant_id: 'acme', state: 'old', id: 101})");
            try self.execAs(tenant_b, null, "CREATE (:ZZProbe {tenant_id: 'acme', state: 'old', id: 102})");
            try self.execAs(tenant_b, null, "CREATE (:ZZProbe {tenant_id: 'solo', state: 'old', id: 103})");
        }
        if (self.mode == .rls_policy) {
            try self.execAs(null, null, "CREATE (:ZZProbe:Hidden {tenant_id: 'acme', state: 'old', id: 101})");
            try self.execAs(null, null, "CREATE (:ZZProbe:Hidden {tenant_id: 'acme', state: 'old', id: 102})");
            try self.execAs(null, null, "CREATE (:ZZProbe:Hidden {tenant_id: 'solo', state: 'old', id: 103})");
        }
        for (1..4) |i| try self.execAs(own, null, try std.fmt.allocPrint(aa, "CREATE (:ZZProbe {{tenant_id: 'acme', state: 'old', id: {d}}})", .{i}));
        self.ctx.tenant_id = own;
        if (self.mode == .rls_policy) {
            const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
            engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
            self.rls = engine;
            try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", "bob");
            rls_types.setGlobalRLSFilterEngine(engine);
            self.ctx.user = "bob";
        }
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str, .Text => |s| try aa.dupe(u8, s),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// The rows of `result` as `a|b` strings, sorted.
fn rowsOf(aa: std.mem.Allocator, result: execution.ExecutionResult) ![]const []const u8 {
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

const Failures = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.InlineMapSetWrong;
    }
};

/// `query` returns exactly `want` (sorted), as the session or, with `as_owner`,
/// as its tenant with no user (so no policy hides a row).
fn expectRows(s: *Session, f: *Failures, what: []const u8, query: []const u8, want: []const []const u8, as_owner: bool) !void {
    const aa = s.arena.allocator();
    const saved_user = s.ctx.user;
    defer s.ctx.user = saved_user;
    if (as_owner) s.ctx.user = null;
    var result = s.run(query) catch |err| {
        try f.add("[{s}] {s} | {s}: error {s}", .{ @tagName(s.mode), what, query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const got = try rowsOf(aa, result);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) try f.add("[{s}] {s} | {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), what, query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
}

/// The rows the session may not see, unchanged.
fn expectOthersUntouched(s: *Session, f: *Failures, what: []const u8) !void {
    switch (s.mode) {
        .in_memory, .persisted => {},
        .tenant_scoped => {
            const saved = s.ctx.tenant_id;
            defer s.ctx.tenant_id = saved;
            s.ctx.tenant_id = tenant_b;
            try expectRows(s, f, what, "MATCH (p:ZZProbe) WHERE p.state = 'old' RETURN p.id", &.{ "101", "102", "103" }, true);
        },
        .rls_policy => try expectRows(s, f, what, "MATCH (p:Hidden) WHERE p.state = 'old' RETURN p.id", &.{ "101", "102", "103" }, true),
    }
}

fn runProbe(mode: Mode, probe: Probe, f: *Failures) !void {
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();
    var result = s.run(probe.stmt) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), probe.stmt, @errorName(err) });
        return;
    };
    const got = try rowsOf(aa, result);
    result.deinit(aa);
    if (probe.want) |want| {
        const same = got.len == want.len and for (got, want) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) try f.add("[{s}] {s}: returned {{{s}}}, expected {{{s}}}", .{ @tagName(mode), probe.stmt, try std.mem.join(aa, ",", got), try std.mem.join(aa, ",", want) });
    }
    // All three changed: read as the session, and as the owner (no policy).
    try expectRows(&s, f, probe.stmt, "MATCH (p:ZZProbe) WHERE p.state = 'new' RETURN p.id", &.{ "1", "2", "3" }, false);
    try expectRows(&s, f, probe.stmt, "MATCH (p:ZZProbe) WHERE p.state = 'new' RETURN count(p)", &.{"3"}, true);
    try expectOthersUntouched(&s, f, probe.stmt);
}

test "SONNY-2977: MATCH (x {k: v}) [WHERE ...] SET changes every node holding the key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for (all_modes) |mode| {
        for (probes) |probe| runProbe(mode, probe, &f) catch |err| {
            try f.add("[{s}] {s}: the probe aborted: {s}", .{ @tagName(mode), probe.stmt, @errorName(err) });
        };
    }
    try f.finish("SONNY-2977");
}

test "SONNY-2977: a key whose only holder the session may not see is written by none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    const writes = [_][]const u8{
        "MATCH (p:ZZProbe {tenant_id: 'solo'}) SET p.state = 'new'",
        "MATCH (p:ZZProbe {tenant_id: 'solo'}) SET p.state = 'new' RETURN p.id",
        "MATCH (p:ZZProbe {tenant_id: 'solo'}) SET p.state = 'new' RETURN count(p)",
    };
    for ([_]Mode{ .tenant_scoped, .rls_policy }) |mode| {
        for (writes) |stmt| {
            var s = try Session.init(mode);
            defer s.deinit();
            try s.seed();
            const aa = s.arena.allocator();
            if (s.run(stmt)) |r| {
                var result = r;
                const got = try rowsOf(aa, result);
                result.deinit(aa);
                const none = got.len == 0 or (got.len == 1 and std.mem.eql(u8, got[0], "0"));
                if (!none) try f.add("[{s}] {s}: returned {{{s}}} for a node the session may not see", .{ @tagName(mode), stmt, try std.mem.join(aa, ",", got) });
            } else |err| try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), stmt, @errorName(err) });
            try expectRows(&s, &f, stmt, "MATCH (p:ZZProbe) WHERE p.state = 'new' RETURN count(p)", &.{"0"}, true);
            try expectOthersUntouched(&s, &f, stmt);
        }
    }
    try f.finish("SONNY-2977 (not visible)");
}

// ---------------------------------------------------------------------------
// QUIC: the real server, one label per statement.

const Server = struct {
    handle: util.ServerHandle,
    data_dir: []const u8,
    addr: []const u8,

    fn start(data_dir_buf: []u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const io = std.Io.Threaded.global_single_threaded.io();
        const data_dir = try std.fmt.bufPrint(data_dir_buf, "/tmp/geode-sonny2977-{d}", .{port});
        std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{});
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .data_dir = data_dir, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
    }

    fn connect(self: *Server) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer client.deinit();
        // SONNY-2394: reply waits follow the server's liveness, not a fixed
        // 5 s deadline (a live server on a loaded CI shard can take longer);
        // a server that exits still fails at once, a hang at the 60 s cap.
        client.watchServerLiveness(self.handle.child.id.?);
        var hello = try client.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
        defer hello.deinit(testing.allocator);
        if (!hello.success) {
            std.debug.print("HELLO refused: {s}\n", .{hello.error_message});
            return error.HelloRefused;
        }
        return client;
    }
};

/// The rows of `query` (with `$t = 'acme'`, `$s = 'old'`) as sorted `a|b`
/// strings joined by ';', or `error:<code>`.
fn quicRows(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    // The query runner takes the parameters and frees them.
    const gpa = testing.allocator;
    var params = util.emptyParams();
    try params.append(gpa, try util.makeStringParam(gpa, "t", "acme"));
    try params.append(gpa, try util.makeStringParam(gpa, "s", "old"));
    var res = try client.executeAndCollect(testing.allocator, query, params, 100);
    defer res.deinit(testing.allocator);
    if (res.error_code) |code| return std.fmt.allocPrint(aa, "error:{s}", .{code});
    const rows = try aa.alloc([]const u8, res.rows.len);
    for (res.rows, rows) |row, *out| {
        var line: std.ArrayList(u8) = .empty;
        for (row, 0..) |cell, j| {
            if (j > 0) try line.append(aa, '|');
            switch (cell) {
                .int => |v| try line.print(aa, "{d}", .{v}),
                .string => |v| try line.appendSlice(aa, v),
                .null => try line.appendSlice(aa, "null"),
                else => try line.appendSlice(aa, "?"),
            }
        }
        out.* = try line.toOwnedSlice(aa);
    }
    std.mem.sort([]const u8, rows, {}, lessThan);
    return std.mem.join(aa, ";", rows);
}

test "SONNY-2977: over QUIC, MATCH (x {k: v}) [WHERE ...] SET changes every node holding the key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var f: Failures = .{ .arena = aa };
    var dir_buf: [128]u8 = undefined;
    var server = try Server.start(&dir_buf);
    defer server.stop();
    var client = try server.connect();
    defer client.deinit();

    for (probes, 0..) |probe, n| {
        // A label of its own per statement: `ZZProbe<n>`.
        const label = try std.fmt.allocPrint(aa, "ZZProbe{d}", .{n});
        const stmt = try std.mem.replaceOwned(u8, aa, probe.stmt, "ZZProbe", label);
        for (1..4) |i| {
            const create = try std.fmt.allocPrint(aa, "CREATE (:{s} {{tenant_id: 'acme', state: 'old', id: {d}}})", .{ label, i });
            const got = try quicRows(aa, &client, create);
            if (std.mem.startsWith(u8, got, "error:")) try f.add("[quic] {s}: {s}", .{ create, got });
        }
        const got = try quicRows(aa, &client, stmt);
        if (std.mem.startsWith(u8, got, "error:")) try f.add("[quic] {s}: {s}", .{ stmt, got });
        if (probe.want) |want| {
            const want_rows = try std.mem.join(aa, ";", want);
            if (!std.mem.eql(u8, got, want_rows)) try f.add("[quic] {s}: returned {s}, expected {s}", .{ stmt, got, want_rows });
        }
        const check = try std.fmt.allocPrint(aa, "MATCH (p:{s}) WHERE p.state = 'new' RETURN p.id", .{label});
        const changed = try quicRows(aa, &client, check);
        if (!std.mem.eql(u8, changed, "1;2;3")) try f.add("[quic] {s}: changed {{{s}}}, expected {{1;2;3}}", .{ stmt, changed });
    }
    try f.finish("SONNY-2977 (QUIC)");
}
