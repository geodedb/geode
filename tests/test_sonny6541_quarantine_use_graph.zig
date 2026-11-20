// SONNY-6541 (7): a session whose current graph is quarantined can still
// switch to another graph.
//
// SONNY-6523's transport gate (`graph_store.programQuarantineError`, QUIC and
// gRPC) and SONNY-6528's executor gate refuse a program on a quarantined
// graph's data before it runs. They checked the session's current graph for
// every program, a bare `USE GRAPH other` included, so a session that had
// moved onto a damaged graph could not move off it: the client had to
// reconnect. A program made only of session-switching statements (USE
// GRAPH, SESSION SET GRAPH, SESSION RESET GRAPH) reads and writes no graph
// data; it now runs. A program that switches and then reads
// (`USE GRAPH damaged; MATCH ...`) is still refused for its target graph.
//
// A real `geode serve` seeds a second graph, checkpoints and is SIGKILLed;
// every written page of its node store is zeroed and the derived-index
// snapshots are removed (the default graph holds no node). The same
// sequence then runs through the QUIC transport of a real server, the gRPC
// handler in process, and the executor in process, each on a fresh copy:
// move onto the damaged graph, have a read refused, move off it (USE GRAPH,
// SESSION SET GRAPH, SESSION RESET GRAPH), read the default graph, and have
// `USE GRAPH damaged; MATCH ...` refused.
//
// CANARY: REQ=REQ-SONNY-6541-QUARANTINE-SESSION-SWITCH; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6541_quarantine_use_graph.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const grpc = @import("grpc_impl").impl;

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const index_manager = geode.index_manager;

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const G = "g6541u";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn run(argv: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(std.testing.allocator, threaded.io(), .{ .argv = argv });
    std.testing.allocator.free(r.stdout);
    std.testing.allocator.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8, log_path: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --data-dir '{s}' --persist-interval 300 2>>'{s}'", .{ geode_test_bin.geode_exe, addr, data_dir, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL: no shutdown checkpoint over the damaged store.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

const Answer = struct {
    ok: bool,
    rows: usize = 0,
    first: ?util.TestValue = null,
    code: [16]u8 = undefined,
    code_len: usize = 0,
    message: [200]u8 = undefined,
    message_len: usize = 0,
};

fn askWire(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !Answer {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    var a: Answer = .{ .ok = r.error_code == null, .rows = r.rows.len };
    if (r.error_code) |c| {
        a.code_len = @min(c.len, a.code.len);
        @memcpy(a.code[0..a.code_len], c[0..a.code_len]);
        const m = r.error_message orelse "";
        a.message_len = @min(m.len, a.message.len);
        @memcpy(a.message[0..a.message_len], m[0..a.message_len]);
    } else if (r.rows.len > 0 and r.rows[0].len > 0) {
        a.first = switch (r.rows[0][0]) {
            .int => |v| .{ .int = v },
            else => null,
        };
    }
    return a;
}

fn queryOkWire(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    const a = try askWire(client, allocator, q);
    if (!a.ok) {
        std.debug.print("{s}: {s} {s}\n", .{ q, a.code[0..a.code_len], a.message[0..a.message_len] });
        return error.QueryFailed;
    }
}

/// The shard directories of the default graph (the security graph's root
/// holds its audit log).
fn shardDirs(allocator: std.mem.Allocator, data_dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    var root = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer root.close(io());
    var it = root.iterate();
    while (try it.next(io())) |e| {
        if (e.kind != .directory) continue;
        const audit = try std.fmt.allocPrint(allocator, "{s}/{s}/audit.jsonl", .{ data_dir, e.name });
        defer allocator.free(audit);
        if (std.Io.Dir.cwd().statFile(io(), audit, .{})) |_| continue else |_| {}
        const graphs = try std.fmt.allocPrint(allocator, "{s}/{s}/graphs", .{ data_dir, e.name });
        defer allocator.free(graphs);
        var gd = std.Io.Dir.cwd().openDir(io(), graphs, .{ .iterate = true }) catch continue;
        defer gd.close(io());
        var git = gd.iterate();
        while (try git.next(io())) |s| {
            if (s.kind != .directory) continue;
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ graphs, s.name }));
        }
    }
    return out;
}

fn fileSize(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !u64 {
    const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(p);
    const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch return 0;
    return st.size;
}

fn walBytes(allocator: std.mem.Allocator, shards: []const []u8) !u64 {
    var total: u64 = 0;
    for (shards) |s| {
        const wal = try std.fmt.allocPrint(allocator, "{s}/wal", .{s});
        defer allocator.free(wal);
        total += try fileSize(allocator, wal, "graph.wal");
    }
    return total;
}

/// Every shard's WAL is empty: a checkpoint ran after the last write.
fn waitCheckpointed(allocator: std.mem.Allocator, shards: []const []u8) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 90_000) : (waited_ms += 100) {
        if (try walBytes(allocator, shards) == 0) return;
        io().sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.CheckpointNotObserved;
}

/// Zero every written page of each shard's nodes.store; remove the loop2
/// hydration snapshots and empty labels.idx, so the restart's hydration
/// rebuilds from the damaged node store. Returns the pages zeroed.
fn damage(allocator: std.mem.Allocator, shards: []const []u8) !usize {
    var zeroed: usize = 0;
    for (shards) |shard| {
        var dir = try std.Io.Dir.cwd().openDir(io(), shard, .{ .iterate = true });
        defer dir.close(io());
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.basename, "labels.idx")) {
                var f = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
                defer f.close(io());
                try f.setLength(io(), 0);
                continue;
            }
            if (!std.mem.eql(u8, entry.basename, "nodes.store")) continue;
            var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
            defer file.close(io());
            const len = try file.length(io());
            var page: u64 = 0;
            while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
                var header: [PAGE_HEADER_SIZE]u8 = undefined;
                _ = try file.readPositionalAll(io(), &header, page * PAGE_SIZE);
                if (std.mem.allEqual(u8, &header, 0)) continue;
                const zeros = [_]u8{0} ** PAGE_SIZE;
                try file.writePositionalAll(io(), &zeros, page * PAGE_SIZE);
                zeroed += 1;
            }
        }
    }
    return zeroed;
}

/// The geode-level hydration snapshots live beside the graph root.
fn removeHydrationSnapshots(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var removed: usize = 0;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "hydration_") or !std.mem.endsWith(u8, entry.basename, ".snap")) continue;
        try entry.dir.deleteFile(io(), entry.basename);
        removed += 1;
    }
    return removed;
}

/// One step of the sequence: a program and whether it must run.
const Step = struct { q: []const u8, runs: bool };

const steps = [_]Step{
    .{ .q = "USE GRAPH " ++ G, .runs = true },
    .{ .q = "MATCH (n:Q) RETURN count(n) AS c", .runs = false },
    .{ .q = "USE GRAPH default", .runs = true },
    .{ .q = "MATCH (n) RETURN count(n) AS c", .runs = true },
    .{ .q = "USE GRAPH " ++ G ++ "; MATCH (n:Q) RETURN count(n) AS c", .runs = false },
    .{ .q = "MATCH (n) RETURN count(n) AS c", .runs = true },
    .{ .q = "USE GRAPH " ++ G, .runs = true },
    .{ .q = "SESSION SET GRAPH default", .runs = true },
    .{ .q = "MATCH (n) RETURN count(n) AS c", .runs = true },
    .{ .q = "USE GRAPH " ++ G, .runs = true },
    .{ .q = "SESSION RESET GRAPH", .runs = true },
    .{ .q = "MATCH (n) RETURN count(n) AS c", .runs = true },
    .{ .q = "USE GRAPH " ++ G, .runs = true },
    .{ .q = "USE GRAPH default; MATCH (n) RETURN count(n) AS c", .runs = true },
};

/// Counts a step that ran when it must be refused, or the reverse.
fn judge(path: []const u8, s: Step, ran: bool, detail: []const u8) usize {
    if (ran == s.runs) return 0;
    std.debug.print("{s}: '{s}' {s} ({s})\n", .{ path, s.q, if (ran) "RAN; it reads the damaged graph" else "was REFUSED", detail });
    return 1;
}

fn copyOf(pristine: []const u8, work: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
}

fn askExecutor(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) ?anyerror {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return err;
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return err;
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return err;
    result.deinit(allocator);
    return null;
}

test "SONNY-6541 (7): a session on a quarantined graph switches off it over QUIC, gRPC and in process" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const base = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6541-ug-{d}", .{port});
    defer allocator.free(base);
    const pristine = try std.fmt.allocPrint(allocator, "{s}/damaged", .{base});
    defer allocator.free(pristine);
    const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
    defer allocator.free(work);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{base});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), pristine);
    defer std.Io.Dir.cwd().deleteTree(io(), base) catch {};
    var keep_log = false;
    defer if (!keep_log) std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};

    {
        var server = try Server.start(allocator, pristine, &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try queryOkWire(&client, allocator, "CREATE GRAPH " ++ G);
        for (0..60) |i| {
            var qb: [120]u8 = undefined;
            try queryOkWire(&client, allocator, try std.fmt.bufPrint(&qb, "USE GRAPH " ++ G ++ "; CREATE (:Q {{i: {d}}})", .{i}));
        }
        var shards = try shardDirs(allocator, pristine);
        defer {
            for (shards.items) |p| allocator.free(p);
            shards.deinit(allocator);
        }
        try waitCheckpointed(allocator, shards.items);
    }
    {
        var shards = try shardDirs(allocator, pristine);
        defer {
            for (shards.items) |p| allocator.free(p);
            shards.deinit(allocator);
        }
        const zeroed = try damage(allocator, shards.items);
        _ = try removeHydrationSnapshots(allocator, pristine);
        std.debug.print("SONNY-6541 (7): zeroed {d} node page(s)\n", .{zeroed});
        try testing.expect(zeroed > 0);
    }

    var failures: usize = 0;
    // QUIC, a real server.
    {
        try copyOf(pristine, work);
        var server = try Server.start(allocator, work, &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for (steps) |s| {
            const a = try askWire(&client, allocator, s.q);
            failures += judge("QUIC", s, a.ok, if (a.ok) "" else a.message[0..@min(a.message_len, 100)]);
        }
    }
    // gRPC, the real handler in process.
    {
        try copyOf(pristine, work);
        const store = try graph_store.initGlobalStore(allocator, work);
        defer graph_store.deinitGlobalStoreForTestCrash();
        try store.loadFromFile();
        _ = geode.txn_undo_log.getGlobalUndoLog(allocator);
        _ = try index_manager.ensureGlobalIndexManager(allocator);
        defer index_manager.cleanupGlobalIndexManager();
        defer execution.cleanupCatalogInstance();
        const auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        defer user_mgmt.setAuthEnabled(auth_was);
        const allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(true);
        defer gps.setInsecureAllowAll(allow_was);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var sessions = grpc.SessionStore.init(arena.allocator(), .{});
        defer sessions.deinit();
        grpc.setSessionStore(&sessions);
        defer grpc.setSessionStore(null);
        defer geode.txn_undo_log.setThreadTxnId(0);
        const sid = try sessions.createSession("s6541", "", null, null, null, false, 0);
        for (steps) |s| {
            // A request the handler fails with an error of its own (not a
            // response) is refused too: the node-scan read of a quarantined
            // graph does that (`node_scan_stream.prepare`).
            const code = fx.outcome(arena.allocator(), sid, s.q) catch |err| {
                failures += judge("gRPC", s, false, @errorName(err));
                continue;
            };
            failures += judge("gRPC", s, code == null, code orelse "");
        }
    }
    // The executor, in process (no transport).
    {
        try copyOf(pristine, work);
        const store = try graph_store.initGlobalStore(allocator, work);
        defer graph_store.deinitGlobalStoreForTestCrash();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        for (steps) |s| {
            const err = askExecutor(allocator, &session, s.q);
            failures += judge("executor", s, err == null, if (err) |e| @errorName(e) else "");
        }
    }

    if (failures > 0) {
        keep_log = true;
        std.debug.print("SONNY-6541 (7): {d} step(s) answered wrongly (server log kept: {s})\n", .{ failures, log_path });
        return error.QuarantineSessionSwitch;
    }
}
