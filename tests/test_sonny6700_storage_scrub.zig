// SONNY-6700: an operator can overwrite the dead space of every graph:
// `CALL geode.storage.scrub()` (Admin only, audited).
//
// SONNY-6692 scrubbed one graph's freed pages and tombstoned property slab
// blobs, and only at the end of an FLE migration. Two kinds of dead space
// stayed in the data directory with no way for an operator to clear them:
//   (1) var-store slab runs that were freed (labels, small values written to
//       the var store) kept their bytes in the shared slab block;
//   (2) allocated property and var-store pages no live record owns (a leak,
//       a crash leftover) were never touched.
// And there was no operator procedure at all: a value superseded by an
// update or a DELETE stayed until its space was reused.
//
// After `CALL geode.storage.scrub()` the whole data directory is read back:
// no superseded value, freed slab run or orphaned page of any graph is in
// any file, and the live data reads back. In process, and against a real
// `geode serve`: a readwrite user is refused (42501, audited) and changes
// nothing; the admin's run scrubs every graph and is audited.
//
// Real executor, real persisted store, real server. No mocks.
//
// CANARY: REQ=REQ-SONNY-6700-STORAGE-SCRUB; FEATURE="StorageAdministration"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6700_storage_scrub.zig; OWNER=storage; UPDATED=2026-11-17

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const proto_util = geode.proto_util;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn expectSqlstate(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

/// Does any file under `dir_path` contain `needle`?
fn dirContains(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const data = dir.readFileAlloc(io(), entry.path, allocator, .limited(1 << 30)) catch continue;
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) {
            std.debug.print("SONNY-6700: '{s}' is in {s}\n", .{ needle, entry.path });
            return true;
        }
    }
    return false;
}

fn countOnDisk(dir_path: []const u8, markers: []const []const u8) !usize {
    var n: usize = 0;
    for (markers) |m| {
        if (try dirContains(testing.allocator, dir_path, m)) n += 1;
    }
    return n;
}

const Env = struct {
    f: fx.Fixture,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        self.session = execution.SessionState.init(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Env) void {
        self.arena.deinit();
        self.session.deinit();
        self.f.deinit();
    }

    fn exec(self: *Env, query: []const u8) !execution.ExecutionResult {
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog, .session_state = &self.session };
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        var last: execution.ExecutionResult = undefined;
        for (parsed.program.statements) |stmt| last = try execution.executeStatementWithContext(self.arena.allocator(), stmt, ctx);
        return last;
    }

    fn run(self: *Env, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn refused(self: *Env, query: []const u8) anyerror {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return err;
    }

    fn str(self: *Env, query: []const u8) ![]const u8 {
        const res = try self.exec(query);
        if (res.rows.len != 1) return error.UnexpectedRows;
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => error.UnexpectedValue,
        };
    }
};

/// Shard 0 of `graph`'s engine (opened by a stats read first).
fn shard0(graph: []const u8) !*gs.GraphEngine {
    const adapter = geode.graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.getStorageStats(graph);
    const mg = adapter.engines.get(graph) orelse return error.GraphNotFound;
    return mg.engine.shards[0];
}

/// An allocated page no record owns, as a leak or a crash leaves one,
/// holding `marker`.
fn leakPage(engine: *gs.GraphEngine, file: gs.FileId, fsm: anytype, marker: []const u8) !void {
    const p = try fsm.allocPage();
    const frame = try engine.buffer_pool.pinNew(file, p);
    const idx = engine.buffer_pool.frameIndex(frame);
    @memcpy(frame.dataSlice()[gs.page.PAGE_HEADER_SIZE + 64 ..][0..marker.len], marker);
    engine.buffer_pool.unpin(idx, true);
    engine.markPersistenceDirty();
}

/// A small var-store value, packed into the shared slab block, then freed.
fn freedVarSlabRun(engine: *gs.GraphEngine, marker: []const u8) !void {
    const ref = try engine.var_store.write(marker);
    if (!gs.var_store.isSlabHead(ref)) return error.NotASlabRun;
    try engine.var_store.free(ref);
    engine.markPersistenceDirty();
}

const live_value = "LIVE-6700-KEEP-ME";
const superseded_delete = "DEAD-6700-DELETED-NODE";
const var_slab_default = "DEAD-6700-VARSLAB-DEFAULT";
const var_slab_other = "DEAD-6700-VARSLAB-OTHER";
const orphan_props_default = "DEAD-6700-ORPHAN-PROPS-DEFAULT";
const orphan_var_other = "DEAD-6700-ORPHAN-VAR-OTHER";
const dead_markers = [_][]const u8{ superseded_delete, var_slab_default, var_slab_other, orphan_props_default, orphan_var_other };

test "SONNY-6700: CALL geode.storage.scrub() clears every graph's freed var-store slab runs, orphaned pages and superseded values from the data directory; the live data reads back" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();

    try e.run("CREATE (:K6700 {k: 1, v: '" ++ live_value ++ "'})");
    try e.run("CREATE (:K6700 {k: 2, v: '" ++ superseded_delete ++ "'})");
    try e.run("MATCH (n:K6700 {k: 2}) DELETE n");
    try e.run("CREATE GRAPH g6700");
    try e.run("USE GRAPH g6700; CREATE (:K6700 {k: 3, v: '" ++ live_value ++ "'})");

    const d = try shard0("default");
    try freedVarSlabRun(d, var_slab_default);
    try leakPage(d, .props, &d.free_space_props, orphan_props_default);
    const o = try shard0("g6700");
    try freedVarSlabRun(o, var_slab_other);
    try leakPage(o, .var_store, &o.free_space_var, orphan_var_other);
    try geode.graph_store.getGlobalAdapter().?.checkpointAll();
    // On disk before the scrub (the precondition the test relies on).
    const before = try countOnDisk(e.f.h.data_dir, &dead_markers);
    try testing.expectEqual(dead_markers.len, before);

    // Inside a transaction it is refused.
    _ = try e.exec("START TRANSACTION");
    const in_txn = e.refused("CALL geode.storage.scrub()");
    _ = try e.exec("ROLLBACK");
    geode.txn_undo_log.setThreadTxnId(0); // as the transport does after a request
    try expectSqlstate(in_txn, "25000");

    const res = e.exec("CALL geode.storage.scrub()") catch |err| {
        std.debug.print("SONNY-6700: CALL geode.storage.scrub() failed: {s} (before the fix there was no such procedure)\n", .{@errorName(err)});
        return err;
    };
    // One row per graph; each graph's orphans were freed.
    var saw_default = false;
    var saw_other = false;
    for (res.rows) |row| {
        const g = switch (row[0]) {
            .Str => |s| s,
            else => return error.UnexpectedValue,
        };
        if (std.mem.eql(u8, g, "default")) saw_default = true;
        if (std.mem.eql(u8, g, "g6700")) saw_other = true;
    }
    try testing.expect(saw_default and saw_other);

    const after = try countOnDisk(e.f.h.data_dir, &dead_markers);
    if (after != 0) {
        std.debug.print("SONNY-6700: {d} of {d} dead values are still in the data directory after CALL geode.storage.scrub()\n", .{ after, dead_markers.len });
        return error.DeadBytesRemain;
    }
    try testing.expectEqualStrings(live_value, try e.str("MATCH (n:K6700 {k: 1}) RETURN n.v"));
    try testing.expectEqualStrings(live_value, try e.str("USE GRAPH g6700; MATCH (n:K6700 {k: 3}) RETURN n.v"));
}

// ---------------------------------------------------------------------------
// A real server: Admin only, audited, every graph
// ---------------------------------------------------------------------------

const rw_user = "rw6700";
const rw_password = "Read Write 6700 Passphrase";

fn quicStatus(client: *util.QuicProtoClient, query: []const u8) !?[]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| return try testing.allocator.dupe(u8, c);
    return null;
}

fn quicOk(client: *util.QuicProtoClient, query: []const u8) !void {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s} {?s}\n", .{ query, c, r.error_message });
        return error.UnexpectedStatus;
    }
}

/// The first column of every row as strings (the caller frees with the arena).
fn quicStrs(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const []const u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s} {?s}\n", .{ query, c, r.error_message });
        return error.UnexpectedStatus;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (r.rows) |row| try out.append(aa, switch (row[0]) {
        .string => |s| try aa.dupe(u8, s),
        else => "",
    });
    return out.items;
}

fn connect(addr: []const u8, user: []const u8, password: []const u8) !util.QuicProtoClient {
    var c = try util.QuicProtoClient.connect(testing.allocator, addr);
    errdefer c.deinit();
    var h = try c.hello(testing.allocator, user, password);
    defer h.deinit(testing.allocator);
    if (!h.success) return error.HelloRefused;
    return c;
}

/// The audit record lines naming `action` with `result`.
fn countAudit(log: []const u8, action: []const u8, result: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    var nb: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"action\":\"{s}\"", .{action}) catch return 0;
    var rb: [64]u8 = undefined;
    const rneedle = std.fmt.bufPrint(&rb, "\"result\":\"{s}\"", .{result}) catch return 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null and std.mem.indexOf(u8, line, rneedle) != null) n += 1;
    }
    return n;
}

const server_markers = [_][]const u8{ "DEAD-6700-SRV-DEFAULT-DELETED", "DEAD-6700-SRV-OTHER-UPDATED" };

test "SONNY-6700: against a running server, geode.storage.scrub is refused for a readwrite user (42501) and scrubs every graph for the admin; both are audited" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/geode-6700-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io(), root) catch {};
    const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{root});
    defer a.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    const log_path = try std.fmt.allocPrint(a, "{s}/audit6700.jsonl", .{root});
    defer a.free(log_path);
    const log_env = try std.fmt.allocPrint(a, "GEODE_AUDIT_LOG_PATH={s}", .{log_path});
    defer a.free(log_env);

    const port = try util.getRandomPort();
    const addr = try util.formatAddr(a, port);
    defer a.free(addr);
    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{ "GEODE_AUDIT_ENABLED=1", log_env });
    var running = true;
    defer if (running) handle.deinit();
    try util.waitForServerReady(a, addr, 30000);

    {
        var admin = try connect(addr, util.defaultUsername(), util.defaultPassword());
        defer admin.deinit();
        try quicOk(&admin, "CREATE USER " ++ rw_user ++ " SET PASSWORD '" ++ rw_password ++ "'");
        try quicOk(&admin, "ALTER USER " ++ rw_user ++ " SET ROLE readwrite");
        try quicOk(&admin, "CREATE (:S6700 {k: 1, v: '" ++ live_value ++ "'})");
        try quicOk(&admin, "CREATE (:S6700 {k: 2, v: '" ++ server_markers[0] ++ "'})");
        try quicOk(&admin, "MATCH (n:S6700 {k: 2}) DELETE n");
        try quicOk(&admin, "CREATE GRAPH g6700s");
        try quicOk(&admin, "USE GRAPH g6700s; CREATE (:S6700 {k: 3, v: '" ++ server_markers[1] ++ "'})");
        try quicOk(&admin, "USE GRAPH g6700s; MATCH (n:S6700 {k: 3}) SET n.v = '" ++ live_value ++ "', n.grown = 'grown past its slot'");
        try testing.expectEqual(server_markers.len, try countOnDisk(data_dir, &server_markers));

        // A readwrite user: refused, nothing scrubbed.
        {
            var rw = try connect(addr, rw_user, rw_password);
            defer rw.deinit();
            const status = try quicStatus(&rw, "CALL geode.storage.scrub()");
            defer if (status) |s| a.free(s);
            try testing.expect(status != null);
            try testing.expectEqualStrings("42501", status.?);
        }
        try testing.expectEqual(server_markers.len, try countOnDisk(data_dir, &server_markers));

        // The admin: every graph, with the server running.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const graphs = quicStrs(arena.allocator(), &admin, "CALL geode.storage.scrub()") catch |err| {
            std.debug.print("SONNY-6700: CALL geode.storage.scrub() failed: {s} (before the fix there was no such procedure)\n", .{@errorName(err)});
            return err;
        };
        var saw_default = false;
        var saw_other = false;
        for (graphs) |g| {
            if (std.mem.eql(u8, g, "default")) saw_default = true;
            if (std.mem.eql(u8, g, "g6700s")) saw_other = true;
        }
        try testing.expect(saw_default and saw_other);
        const after = try countOnDisk(data_dir, &server_markers);
        if (after != 0) {
            std.debug.print("SONNY-6700: {d} superseded values are in the running server's data directory after CALL geode.storage.scrub()\n", .{after});
            return error.DeadBytesRemain;
        }
        const v1 = try quicStrs(arena.allocator(), &admin, "MATCH (n:S6700 {k: 1}) RETURN n.v");
        try testing.expectEqualStrings(live_value, v1[0]);
        const v3 = try quicStrs(arena.allocator(), &admin, "USE GRAPH g6700s; MATCH (n:S6700 {k: 3}) RETURN n.v");
        try testing.expectEqualStrings(live_value, v3[0]);
    }
    running = false;
    if (handle.stopGracefully(60_000) != .exited) return error.ServerDidNotStopCleanly;

    const log = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, a, .limited(64 << 20));
    defer a.free(log);
    const ok = countAudit(log, "geode.storage.scrub", "success");
    const denied = countAudit(log, "geode.storage.scrub", "failure");
    if (ok < 1 or denied < 1) {
        std.debug.print("SONNY-6700: audit records for geode.storage.scrub: {d} success, {d} failure (want at least 1 each)\n", .{ ok, denied });
        return error.NotAudited;
    }
}
