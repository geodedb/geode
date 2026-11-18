// SONNY-6591: every node write path keeps a fulltext index current, over the
// wire, on a real `geode serve`, before and after a restart.
//
// The report: after `CREATE INDEX ... USING fulltext` and a CREATE of a
// matching node, the index's fts.wal stayed empty and `CALL geode.fts.search`
// returned no row. Two defects:
//   1. The QUIC write fast path for a single-statement `CREATE (n:L {k: v})`
//      with no RETURN (`executeBulkSimpleCreate`, on by default) wrote the
//      node through the storage adapter and never ran the fulltext
//      maintenance hook every other write path runs.
//   2. The label -> fulltext index registry the maintenance hooks read
//      (`ManagedGraph.fts_label_index`) lives in memory and was filled only by
//      CREATE INDEX and `geode.fts.rebuild`. After a restart the index was
//      still searchable (its engine re-opens lazily on the first search), but
//      no write of any path, over any transport, reached it: CREATE, SET and
//      MERGE appended nothing, DELETE left the node's postings, and a REMOVE
//      or a SET replacing indexed text queued no rebuild.
//
// The matrix: one server per (transport, TDE) configuration; a fulltext index
// on (:Doc).body, and a second one on (:Undo).body for the paths whose
// maintenance is a whole-index rebuild (REMOVE, ROLLBACK), so that rebuild
// cannot index the nodes the other paths wrote. Round a writes, before the
// indexes exist, one node by the fast path and one by the executor (backfill),
// then every write path (executor and fast-path CREATE, two labels, fast-path
// and executor MERGE, MERGE ON CREATE SET, the `/*+BATCH*/` bulk MERGE,
// MATCH ... SET, an integer property then a string, DELETE, a transaction
// COMMIT and ROLLBACK, REMOVE), each with its own word, and looks each word up
// (`geode.fts.search` and its two-word `geode.fts.phrase`) right after its
// write. The server is SIGKILLed with no checkpoint since the writes. After
// the restart the first statement REMOVEs text written before it; every word
// is looked up again; round b runs every write path again with new words. The
// server is stopped with SIGTERM (its shutdown checkpoint). After that restart
// the first statement DELETEs a node written before it; every word is looked
// up; round c runs every path again; SIGKILL; a last restart looks every word
// up.
//
// CANARY: REQ=REQ-SONNY-6591-FTS-WRITE-PATHS; FEATURE="FullText"; ASPECT=WirePathMatrix; STATUS=TESTED; TEST=tests/test_sonny6591_fts_write_paths.zig; OWNER=fts; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const tde_key_hex = "6591" ** 16;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Transport = enum { quic, grpc };

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, tde: bool, log_path: []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(quic_addr);
        const grpc_addr = try util.formatAddr(allocator, grpc_port);
        errdefer allocator.free(grpc_addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --listen-grpc {s} --data-dir '{s}' --persist-interval 300 2>>'{s}'", .{ geode_test_bin.geode_exe, quic_addr, grpc_addr, data_dir, log_path });
        defer allocator.free(cmd);
        const plain = util.TestEnv.grpcPlaintext();
        const env: []const []const u8 = if (tde) &.{ plain[0], plain[1], "GEODE_TDE_KEY=" ++ tde_key_hex } else plain;
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, quic_addr, 30000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr };
    }

    /// SIGTERM, then wait for the server to exit (its shutdown checkpoint).
    fn stop(self: *Server) !void {
        const pid = self.handle.child.id orelse return error.NoServerPid;
        try std.posix.kill(pid, .TERM);
        var waited_ms: u64 = 0;
        while (util.processAlive(pid)) : (waited_ms += 100) {
            if (waited_ms >= 60_000) return error.ServerDidNotStop;
            io().sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }

    /// SIGKILL (a no-op after `stop`), and free the addresses.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.quic_addr);
        allocator.free(self.grpc_addr);
    }
};

/// The gRPC test client sends every Execute on HTTP/2 stream 3, so it runs
/// one Execute per connection; the session outlives the connection.
const Client = union(Transport) {
    quic: util.QuicProtoClient,
    grpc: struct { allocator: std.mem.Allocator, addr: []const u8, session_id: []u8 },

    fn connect(allocator: std.mem.Allocator, server: *Server, t: Transport) !Client {
        switch (t) {
            .quic => {
                var c = try util.QuicProtoClient.connect(allocator, server.quic_addr);
                errdefer c.deinit();
                c.watchServerLiveness(server.handle.child.id orelse return error.NoServerPid);
                var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
                defer h.deinit(allocator);
                if (!h.success) return error.HelloFailed;
                return .{ .quic = c };
            },
            .grpc => {
                var c = try util.GrpcProtoClient.connect(allocator, server.grpc_addr);
                defer c.deinit();
                var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
                defer h.deinit(allocator);
                if (!h.success) return error.HelloFailed;
                return .{ .grpc = .{ .allocator = allocator, .addr = server.grpc_addr, .session_id = try allocator.dupe(u8, c.session_id) } };
            },
        }
    }

    fn deinit(self: *Client) void {
        switch (self.*) {
            .quic => |*c| c.deinit(),
            .grpc => |*s| s.allocator.free(s.session_id),
        }
    }

    fn exec(self: *Client, allocator: std.mem.Allocator, q: []const u8) !util.ExecResult {
        switch (self.*) {
            .quic => |*c| return c.executeAndCollect(allocator, q, util.emptyParams(), 1000),
            .grpc => |*s| {
                var c = try util.GrpcProtoClient.connect(allocator, s.addr);
                defer c.deinit();
                c.session_id = try allocator.dupe(u8, s.session_id);
                return c.executeAndCollect(allocator, q, util.emptyParams(), 1000);
            },
        }
    }

    /// Rows the statement answers; error.QueryFailed when it is refused.
    fn rows(self: *Client, allocator: std.mem.Allocator, q: []const u8) !usize {
        var r = try self.exec(allocator, q);
        defer r.deinit(allocator);
        if (r.error_code) |c| {
            std.debug.print("{s}: {s} {s}\n", .{ q, c, r.error_message orelse "" });
            return error.QueryFailed;
        }
        return r.rows.len;
    }

    fn ok(self: *Client, allocator: std.mem.Allocator, q: []const u8) !void {
        _ = try self.rows(allocator, q);
    }
};

const Index = enum {
    doc_body,
    undo_body,
};

/// One write path. Every statement's "{w}" is the path's word for the round.
/// `setup` runs first and, with `pre`, the word must then be found once;
/// after `write` it must be found `want` times.
const Path = struct {
    name: []const u8,
    word: []const u8,
    index: Index = .doc_body,
    setup: []const []const u8 = &.{},
    pre: bool = false,
    write: []const []const u8,
    want: usize,
};

const write_paths = [_]Path{
    .{ .name = "executor CREATE", .word = "qexeccreate", .write = &.{"CREATE (n:Doc {body: '{w} zulu'}) RETURN n.body AS b"}, .want = 1 },
    .{ .name = "fast-path CREATE", .word = "qfastcreate", .write = &.{"CREATE (:Doc {body: '{w} zulu'})"}, .want = 1 },
    .{ .name = "fast-path CREATE, two properties", .word = "qfasttwoprops", .write = &.{"CREATE (:Doc {key: '{w}', body: '{w} zulu'})"}, .want = 1 },
    .{ .name = "CREATE, two labels", .word = "qmultilabel", .write = &.{"CREATE (:Doc:Extra {body: '{w} zulu'})"}, .want = 1 },
    .{ .name = "fast-path MERGE", .word = "qfastmerge", .write = &.{"MERGE (:Doc {body: '{w} zulu'})"}, .want = 1 },
    .{ .name = "fast-path MERGE ON CREATE SET", .word = "qmergeoncreate", .write = &.{"MERGE (n:Doc {key: '{w}'}) ON CREATE SET n.body = '{w} zulu'"}, .want = 1 },
    .{ .name = "executor MERGE", .word = "qexecmerge", .write = &.{"MERGE (n:Doc {body: '{w} zulu'}) RETURN n.body AS b"}, .want = 1 },
    .{ .name = "/*+BATCH*/ bulk MERGE", .word = "qbatchmerge", .write = &.{"/*+BATCH*/ MERGE (:Doc {body: '{w} zulu'}); MERGE (:Doc {body: '{w}x zulu'})"}, .want = 1 },
    .{ .name = "MATCH ... SET", .word = "qsetvalue", .setup = &.{"CREATE (:Doc {key: '{w}'})"}, .write = &.{"MATCH (n:Doc) WHERE n.key = '{w}' SET n.body = '{w} zulu'"}, .want = 1 },
    .{ .name = "integer property, then SET string", .word = "qnowstring", .setup = &.{"CREATE (:Doc {key: '{w}', body: 4242})"}, .write = &.{"MATCH (n:Doc) WHERE n.key = '{w}' SET n.body = '{w} zulu'"}, .want = 1 },
    .{ .name = "DELETE", .word = "qdeleted", .setup = &.{"CREATE (n:Doc {key: '{w}', body: '{w} zulu'}) RETURN n.key AS k"}, .pre = true, .write = &.{"MATCH (n:Doc) WHERE n.key = '{w}' DELETE n"}, .want = 0 },
    .{ .name = "transaction CREATE, COMMIT", .word = "qtxncommit", .write = &.{ "START TRANSACTION", "CREATE (:Doc {body: '{w} zulu'})", "COMMIT" }, .want = 1 },
    .{ .name = "transaction CREATE, ROLLBACK", .word = "qtxnrollback", .index = .undo_body, .write = &.{ "START TRANSACTION", "CREATE (:Undo {body: '{w} zulu'})", "ROLLBACK" }, .want = 0 },
    .{ .name = "REMOVE", .word = "qremoved", .index = .undo_body, .setup = &.{"CREATE (n:Undo {key: '{w}', body: '{w} zulu'}) RETURN n.key AS k"}, .pre = true, .write = &.{"MATCH (n:Undo) WHERE n.key = '{w}' REMOVE n.body"}, .want = 0 },
};

const Config = struct { transport: Transport, tde: bool };

/// A word and how many times it must be found, by search and by phrase.
const Expect = struct { name: []const u8, index: Index, word: []u8, want: usize };

const Run = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    expects: std.ArrayList(Expect) = .empty,
    failed: usize = 0,

    fn deinit(self: *Run) void {
        for (self.expects.items) |e| self.allocator.free(e.word);
        self.expects.deinit(self.allocator);
    }

    /// Looks `word` up and prints the cell; counts a failure.
    fn cell(self: *Run, client: *Client, timing: []const u8, name: []const u8, index: Index, word: []const u8, want: usize) !void {
        var qb: [256]u8 = undefined;
        const s = try client.rows(self.allocator, try std.fmt.bufPrint(&qb, "CALL geode.fts.search('{s}', '{s}')", .{ @tagName(index), word }));
        const p = try client.rows(self.allocator, try std.fmt.bufPrint(&qb, "CALL geode.fts.phrase('{s}', '{s} zulu')", .{ @tagName(index), word }));
        const pass = s == want and p == want;
        if (!pass) self.failed += 1;
        std.debug.print("SONNY-6591 | {s:<4} | TDE {s:<3} | {s:<26} | {s:<36} | {s:<18} | search {d} phrase {d} want {d} | {s}\n", .{
            @tagName(self.cfg.transport), if (self.cfg.tde) "on" else "off", timing, name, word, s, p, want, if (pass) "PASS" else "FAIL",
        });
    }

    fn expect(self: *Run, name: []const u8, index: Index, word: []const u8, want: usize) !void {
        const owned = try self.allocator.dupe(u8, word);
        errdefer self.allocator.free(owned);
        try self.expects.append(self.allocator, .{ .name = name, .index = index, .word = owned, .want = want });
    }

    /// Every word written so far.
    fn checkAll(self: *Run, client: *Client, timing: []const u8) !void {
        for (self.expects.items) |e| try self.cell(client, timing, e.name, e.index, e.word, e.want);
    }

    /// Runs `q` with every "{w}" replaced by `word`.
    fn run(self: *Run, client: *Client, q: []const u8, word: []const u8) !void {
        const stmt = try std.mem.replaceOwned(u8, self.allocator, q, "{w}", word);
        defer self.allocator.free(stmt);
        try client.ok(self.allocator, stmt);
    }

    /// Every write path once, with words suffixed by `round`, each looked up
    /// right after its write.
    fn round(self: *Run, client: *Client, r: u8) !void {
        var tb: [32]u8 = undefined;
        const timing = try std.fmt.bufPrint(&tb, "round {c}, right after", .{r});
        for (write_paths) |p| {
            var wb: [64]u8 = undefined;
            const word = try std.fmt.bufPrint(&wb, "{s}{c}", .{ p.word, r });
            for (p.setup) |q| try self.run(client, q, word);
            if (p.pre) try self.cell(client, "after its setup", p.name, p.index, word, 1);
            for (p.write) |q| try self.run(client, q, word);
            try self.cell(client, timing, p.name, p.index, word, p.want);
            try self.expect(p.name, p.index, word, p.want);
        }
    }
};

/// The shard directories of every user graph (the security graph's root
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

/// The bytes in every user graph shard's WAL.
fn walBytes(allocator: std.mem.Allocator, data_dir: []const u8) !u64 {
    var shards = try shardDirs(allocator, data_dir);
    defer {
        for (shards.items) |p| allocator.free(p);
        shards.deinit(allocator);
    }
    var total: u64 = 0;
    for (shards.items) |s| {
        const p = try std.fmt.allocPrint(allocator, "{s}/wal/graph.wal", .{s});
        defer allocator.free(p);
        const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch continue;
        total += st.size;
    }
    return total;
}

/// Runs the whole matrix for one configuration; the number of cells that fail.
fn runConfig(allocator: std.mem.Allocator, cfg: Config) !usize {
    const port = try util.getRandomPort();
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6591-{s}-{s}-{d}", .{ @tagName(cfg.transport), if (cfg.tde) "tde" else "plain", port });
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    var keep_log = false;
    defer if (!keep_log) std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};
    errdefer {
        keep_log = true;
        std.debug.print("SONNY-6591: server log kept: {s}\n", .{log_path});
    }

    var run: Run = .{ .allocator = allocator, .cfg = cfg };
    defer run.deinit();

    // Round a, then SIGKILL with no checkpoint since the writes.
    {
        var server = try Server.start(allocator, data_dir, cfg.tde, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, cfg.transport);
        defer client.deinit();
        // Backfill: written before the indexes exist.
        try client.ok(allocator, "CREATE (:Doc {body: 'qbackfillfast zulu'})");
        try client.ok(allocator, "CREATE (n:Doc {body: 'qbackfillexec zulu'}) RETURN n.body AS b");
        try client.ok(allocator, "CREATE INDEX doc_body FOR (n:Doc) ON (n.body) USING fulltext");
        try client.ok(allocator, "CREATE INDEX undo_body FOR (n:Undo) ON (n.body) USING fulltext");
        try run.expect("backfill (fast-path CREATE)", .doc_body, "qbackfillfast", 1);
        try run.expect("backfill (executor CREATE)", .doc_body, "qbackfillexec", 1);
        try run.checkAll(&client, "after CREATE INDEX");
        // Removed / deleted as the first statement after the restarts below.
        try client.ok(allocator, "CREATE (n:Undo {key: 'carry1', body: 'qcarryremove zulu'}) RETURN n.key AS k");
        try client.ok(allocator, "CREATE (n:Doc {key: 'carry2', body: 'qcarrydelete zulu'}) RETURN n.key AS k");
        try run.cell(&client, "round a, right after", "REMOVE after a restart (setup)", .undo_body, "qcarryremove", 1);
        try run.cell(&client, "round a, right after", "DELETE after a restart (setup)", .doc_body, "qcarrydelete", 1);
        try run.round(&client, 'a');
    }
    // SIGKILL restart: REMOVE text written before it first, then round b;
    // then SIGTERM (the shutdown checkpoint).
    {
        var server = try Server.start(allocator, data_dir, cfg.tde, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, cfg.transport);
        defer client.deinit();
        try client.ok(allocator, "MATCH (n:Undo) WHERE n.key = 'carry1' REMOVE n.body");
        try run.expect("REMOVE, first statement after a restart", .undo_body, "qcarryremove", 0);
        try run.expect("DELETE after a restart (setup)", .doc_body, "qcarrydelete", 1);
        try run.checkAll(&client, "SIGKILL, restart");
        try run.round(&client, 'b');
        try server.stop();
        std.debug.print("SONNY-6591 | {s:<4} | TDE {s:<3} | SIGTERM: {d} WAL byte(s) left in the user graph shards\n", .{ @tagName(cfg.transport), if (cfg.tde) "on" else "off", try walBytes(allocator, data_dir) });
    }
    // Checkpointed restart: DELETE a node written before it first, then round c;
    // then SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, cfg.tde, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, cfg.transport);
        defer client.deinit();
        try client.ok(allocator, "MATCH (n:Doc) WHERE n.key = 'carry2' DELETE n");
        for (run.expects.items) |*e| {
            if (std.mem.eql(u8, e.word, "qcarrydelete")) {
                e.name = "DELETE, first statement after a restart";
                e.want = 0;
            }
        }
        try run.checkAll(&client, "checkpoint, restart");
        try run.round(&client, 'c');
    }
    // SIGKILL restart: every word.
    {
        var server = try Server.start(allocator, data_dir, cfg.tde, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, cfg.transport);
        defer client.deinit();
        try run.checkAll(&client, "SIGKILL, restart (final)");
    }
    if (run.failed > 0) {
        keep_log = true;
        std.debug.print("SONNY-6591: {s}, TDE {s}: {d} cell(s) failed (server log kept: {s})\n", .{ @tagName(cfg.transport), if (cfg.tde) "on" else "off", run.failed, log_path });
    }
    return run.failed;
}

test "SONNY-6591: every node write path keeps a fulltext index current over QUIC and gRPC, with and without TDE, before and after restarts" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var failed: usize = 0;
    for ([_]Config{
        .{ .transport = .quic, .tde = false },
        .{ .transport = .quic, .tde = true },
        .{ .transport = .grpc, .tde = false },
        .{ .transport = .grpc, .tde = true },
    }) |cfg| failed += try runConfig(testing.allocator, cfg);
    try testing.expectEqual(@as(usize, 0), failed);
}
