// SONNY-6547 (1): a graph that refuses its statements answers every one of
// them the same way over QUIC and over gRPC.
//
// A graph is refused in two ways: its first-touch hydration met damaged
// storage (quarantined, SONNY-6523: `DataCorruption`), or the storage engine
// refused to open it because its shard label dictionaries disagree
// (SONNY-6524: `LabelDictionaryDiverged`). Both transports gate a program on
// such a graph before it runs (`graph_store.programQuarantineError`), but a
// read the gate lets through to its first hydration fails later, inside the
// path that serves it. The node-scan stream (`node_scan_stream.prepare`)
// returned that error out of the request handler: the QUIC connection loop
// answers such an error with the generic "58000 Internal Server Error", and
// gRPC failed the RPC itself, where every other path answers 58000 with the
// error's operator message (`proto_util.mapError`). A server always installs
// a row-security engine and every session is authenticated, so its reads go
// through a read snapshot that hydrates first, and the node-scan stream is
// reached only where no row-security engine is installed: the request
// handlers called in process (embedded use, the gRPC fixture).
//
// Both states are built for real. One `geode serve` seeds the default graph
// (nodes, relationships with a property, an exact property index, a fulltext
// index) and a second graph `qg` the same way, checkpoints and is SIGKILLed.
// One copy has every written page of every shard's node store zeroed and the
// derived-index snapshots removed (as test-sonny6523-quarantine-fail-closed
// does), and is used through the default graph and through `qg`; in another, `qg`'s shard label dictionaries are split the way geode's
// old ORDER BY path split them (as test-sonny6524-label-dict-split does, with
// the engine calls that did it). Each shape then runs against a fresh copy of
// each store on a fresh server, once over QUIC and once over gRPC (QUIC and
// plaintext gRPC listeners of the same binary), as the first statement after
// the restart and again, and through the gRPC request handler in process
// (`grpc_server.handleExecute`, then `handlePull`) on the same copy opened as
// the process store with no row-security engine. Every answer must be a
// refusal, and all three must carry the same GQLSTATUS and the same message
// class (the message up to its first ':').
//
// CANARY: REQ=REQ-SONNY-6547-TRANSPORT-PARITY; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6547_transport_parity.zig; OWNER=transport; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const index_manager = geode.index_manager;
const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;
const ManagedGraph = geode.graph_storage_adapter.ManagedGraph;

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const NODES: usize = 240;
const EDGES: usize = 40;
const QG_NODES: usize = 96;
const QG = "qg";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Transport = enum { quic, grpc };

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, bulk: bool, log_path: []const u8) !Server {
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
        const env: []const []const u8 = if (bulk) &.{ plain[0], plain[1], "GEODE_BULK_INGEST=1" } else plain;
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, quic_addr, 30000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr };
    }

    /// SIGKILL: no shutdown checkpoint.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.quic_addr);
        allocator.free(self.grpc_addr);
    }
};

/// One answer, as the client saw it.
const Answer = struct {
    ok: bool = false,
    rows: usize = 0,
    /// The GQLSTATUS of a refusal; "RPC" when the request itself failed.
    code: [16]u8 = undefined,
    code_len: usize = 0,
    /// The message up to its first ':' (the error's class).
    class: [64]u8 = undefined,
    class_len: usize = 0,

    fn codeText(a: *const Answer) []const u8 {
        return a.code[0..a.code_len];
    }
    fn classText(a: *const Answer) []const u8 {
        return a.class[0..a.class_len];
    }
    fn same(a: *const Answer, b: *const Answer) bool {
        return a.ok == b.ok and std.mem.eql(u8, a.codeText(), b.codeText()) and std.mem.eql(u8, a.classText(), b.classText());
    }
    fn set(a: *Answer, code: []const u8, message: []const u8) void {
        a.code_len = @min(code.len, a.code.len);
        @memcpy(a.code[0..a.code_len], code[0..a.code_len]);
        const end = std.mem.indexOfScalar(u8, message, ':') orelse message.len;
        a.class_len = @min(end, a.class.len);
        @memcpy(a.class[0..a.class_len], message[0..a.class_len]);
    }
};

fn fromResult(r: *const util.ExecResult) Answer {
    var a: Answer = .{ .ok = r.error_code == null, .rows = r.rows.len };
    if (r.error_code) |c| a.set(c, r.error_message orelse "");
    return a;
}

/// The gRPC test client sends every Execute on HTTP/2 stream 3
/// (`grpc_query_transport.execute_stream_id`), so it runs one Execute per
/// connection; the session (and its graph) outlives the connection.
const GrpcSession = struct {
    allocator: std.mem.Allocator,
    addr: []const u8,
    session_id: []u8,

    fn execute(self: *GrpcSession, q: []const u8) !util.ExecResult {
        var c = try util.GrpcProtoClient.connect(self.allocator, self.addr);
        defer c.deinit();
        c.session_id = try self.allocator.dupe(u8, self.session_id);
        return c.executeAndCollect(self.allocator, q, util.emptyParams(), 1000);
    }
};

const Client = union(Transport) {
    quic: util.QuicProtoClient,
    grpc: GrpcSession,

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

    fn ask(self: *Client, allocator: std.mem.Allocator, q: []const u8) Answer {
        var r = switch (self.*) {
            .quic => |*c| c.executeAndCollect(allocator, q, util.emptyParams(), 1000),
            .grpc => |*s| s.execute(q),
        } catch |err| {
            var a: Answer = .{};
            a.set("RPC", @errorName(err));
            return a;
        };
        defer r.deinit(allocator);
        return fromResult(&r);
    }
};

fn queryOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s} {s}\n", .{ q, c, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

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

fn walBytes(allocator: std.mem.Allocator, shards: []const []u8) !u64 {
    var total: u64 = 0;
    for (shards) |s| {
        const p = try std.fmt.allocPrint(allocator, "{s}/wal/graph.wal", .{s});
        defer allocator.free(p);
        const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch continue;
        total += st.size;
    }
    return total;
}

/// Every shard's WAL is empty: a checkpoint ran after the last write.
fn waitCheckpointed(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    var shards = try shardDirs(allocator, data_dir);
    defer {
        for (shards.items) |p| allocator.free(p);
        shards.deinit(allocator);
    }
    var waited_ms: u64 = 0;
    while (waited_ms < 90_000) : (waited_ms += 100) {
        if (try walBytes(allocator, shards.items) == 0) return;
        io().sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.CheckpointNotObserved;
}

/// Zero every written page of each shard's nodes.store and empty labels.idx,
/// so the restart's hydration rebuilds from the damaged node store. Returns
/// the pages zeroed.
fn zeroNodePages(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    var shards = try shardDirs(allocator, data_dir);
    defer {
        for (shards.items) |p| allocator.free(p);
        shards.deinit(allocator);
    }
    var zeroed: usize = 0;
    for (shards.items) |shard| {
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
    // The geode-level hydration snapshots live beside the graph root.
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "hydration_") or !std.mem.endsWith(u8, entry.basename, ".snap")) continue;
        try entry.dir.deleteFile(io(), entry.basename);
    }
    return zeroed;
}

/// Public ids for the nodes written in process, clear of any a server minted.
var next_public_id: u64 = 7_100_000_000_000;

fn bulkNodes(ad: *StorageAdapter, g: []const u8, label: []const u8, n: usize) !void {
    for (0..n) |_| {
        next_public_id += 1;
        _ = try ad.bulkInsertNodeWithReservedId(g, next_public_id, &.{label}, &.{});
    }
}

/// Split `qg`'s shard label dictionaries as geode's old ORDER BY path did
/// (test-sonny6524-label-dict-split's `order_by_split`): X named on shard 0
/// only, then Y named on every shard (shard 0 gives it the next id after X,
/// the other shards the id X has on shard 0), and Y nodes on every shard.
fn splitLabelDictionaries(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const ad = try StorageAdapter.init(allocator, data_dir, .{ .data_dir = data_dir });
    defer ad.deinit();
    const mg: *ManagedGraph = try ad.getOrCreateGraph(QG);
    _ = try mg.engine.shards[0].label_dict.getOrAssign("X6547");
    _ = try mg.engine.shards[0].getOrAssignLabel("Y6547");
    for (mg.engine.shards[1..]) |e| _ = try e.getOrAssignLabel("Y6547");
    try bulkNodes(ad, QG, "Y6547", 48);
    try bulkNodes(ad, QG, "X6547", 48);
}

fn run(argv: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(testing.allocator, threaded.io(), .{ .argv = argv });
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

const Shape = struct {
    q: []const u8,
    write: bool = false,
    /// GEODE_BULK_INGEST=1 (the bulk write fast paths).
    bulk: bool = false,
    /// Runs on the default graph whatever the session's graph is
    /// (`procedure_access.isDefaultGraphProcedure`).
    default_graph: bool = false,
};

/// The shapes of test-sonny6523-quarantine-fail-closed.
const shapes = [_]Shape{
    .{ .q = "MATCH (n:P) RETURN count(n) AS c" },
    .{ .q = "MATCH (n) RETURN count(n) AS c" },
    .{ .q = "MATCH (n) RETURN count(*) AS c" },
    .{ .q = "MATCH ()-[r:R]->() RETURN count(r) AS c" },
    .{ .q = "MATCH ()-[r]->() RETURN count(r) AS c" },
    .{ .q = "MATCH (n:P) WHERE n.i >= 0 RETURN count(n) AS c" },
    .{ .q = "MATCH (n:P) WHERE n.name = 'p-00007' RETURN count(n) AS c" },
    .{ .q = "MATCH (n:P) WHERE n.name = 'p-00007' RETURN n.i AS i" },
    .{ .q = "MATCH (n:P {name: 'p-00008'}) RETURN n.i AS i" },
    .{ .q = "MATCH (n:P) RETURN n.name AS name ORDER BY n.name LIMIT 3" },
    .{ .q = "MATCH (n:P) RETURN n.i AS i ORDER BY n.i DESC LIMIT 1" },
    .{ .q = "MATCH (n:P) RETURN n.name AS name" },
    .{ .q = "MATCH (n) RETURN n.name AS name" },
    .{ .q = "MATCH (n:P) RETURN n.name AS name LIMIT 5" },
    .{ .q = "MATCH (a:P)-[r:R]->(b) RETURN r.w AS w" },
    .{ .q = "MATCH (n:P) RETURN max(n.i) AS m" },
    .{ .q = "CALL db.labels()" },
    .{ .q = "CALL db.relationshipTypes()" },
    .{ .q = "CALL db.propertyKeys()" },
    .{ .q = "CALL geode.fts.search('p_body', 'alpha')", .default_graph = true },
    .{ .q = "CREATE (:P {name: 'new-1', i: 1000})", .write = true },
    .{ .q = "CREATE (:P {name: 'new-2', i: 1001})", .write = true, .bulk = true },
    .{ .q = "MERGE (:P {name: 'p-00003'})", .write = true },
    .{ .q = "MERGE (:P {name: 'new-3'})", .write = true, .bulk = true },
    .{ .q = "/*+BATCH*/ MERGE (:P {name: 'new-4'}); MERGE (:P {name: 'new-5'})", .write = true, .bulk = true },
    .{ .q = "MATCH (a:P {name: 'p-00001'}), (b:P {name: 'p-00002'}) CREATE (a)-[:R {w: 99}]->(b)", .write = true },
    .{ .q = "MATCH (a:P {name: 'p-00001'}), (b:P {name: 'p-00002'}) CREATE (a)-[:R {w: 98}]->(b)", .write = true, .bulk = true },
    .{ .q = "MATCH (n:P) WHERE n.name = 'p-00004' SET n.i = 7", .write = true },
    .{ .q = "CREATE (n:P {name: 'new-6'}) RETURN n.name AS name", .write = true },
};

const Store = enum {
    /// Every node page zeroed: the default graph is quarantined
    /// (DataCorruption).
    damaged,
    /// The same store, through `qg`: a second graph, hydrated on its first
    /// touch only (the default graph is hydrated as the server starts), so
    /// the statement that first reads it meets the damage on whatever path
    /// serves it.
    damaged_second_graph,
    /// `qg`'s shard label dictionaries split: refused at open.
    label_dict_diverged,

    fn graph(s: Store) ?[]const u8 {
        return switch (s) {
            .damaged => null,
            .damaged_second_graph, .label_dict_diverged => QG,
        };
    }
};

/// The two answers (first touch, then again) of one shape on one transport,
/// on a fresh copy of `pristine`.
fn answersOf(allocator: std.mem.Allocator, pristine: []const u8, work: []const u8, log_path: []const u8, store: Store, s: Shape, t: Transport) ![2]Answer {
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
    var server = try Server.start(allocator, work, s.bulk, log_path);
    defer server.kill(allocator);
    var client = try Client.connect(allocator, &server, t);
    defer client.deinit();
    if (store.graph()) |g| {
        var qb: [64]u8 = undefined;
        const use = client.ask(allocator, try std.fmt.bufPrint(&qb, "USE GRAPH {s}", .{g}));
        if (!use.ok) {
            std.debug.print("{s} USE GRAPH {s}: {s} {s}\n", .{ @tagName(t), g, use.codeText(), use.classText() });
            return error.UseGraphFailed;
        }
    }
    var out: [2]Answer = undefined;
    for (&out) |*a| a.* = client.ask(allocator, s.q);
    return out;
}

/// One answer of the gRPC handler called in process: an error response, or
/// the schema then the first page (whose error, if any, is the answer). A
/// handler that fails with an error of its own is answered "HANDLER".
fn inProcessAnswer(ga: std.mem.Allocator, sid: []const u8, q: []const u8) Answer {
    var a: Answer = .{};
    const resp = fx.execute(ga, sid, q) catch |err| {
        a.set("HANDLER", @errorName(err));
        return a;
    };
    switch (resp.payload orelse {
        a.set("HANDLER", "MissingPayload");
        return a;
    }) {
        .@"error" => |e| {
            a.set(e.code, e.message);
            return a;
        },
        .schema => {},
        else => {
            a.ok = true;
            return a;
        },
    }
    const req = fx.encodeProto(ga, schema.PullRequest{ .session_id = sid, .page_size = 64 }) catch |err| {
        a.set("HANDLER", @errorName(err));
        return a;
    };
    const pulled = grpc.handlePull(req, ga) catch |err| {
        a.set("HANDLER", @errorName(err));
        return a;
    };
    const pull = fx.decodeProto(schema.PullResponse, ga, pulled) catch |err| {
        a.set("HANDLER", @errorName(err));
        return a;
    };
    const presp = pull.response orelse {
        a.set("HANDLER", "MissingPayload");
        return a;
    };
    switch (presp.payload orelse {
        a.set("HANDLER", "MissingPayload");
        return a;
    }) {
        .@"error" => |e| a.set(e.code, e.message),
        else => a.ok = true,
    }
    return a;
}

/// The two answers of one shape through the gRPC request handler in process,
/// on a fresh copy of `pristine` opened as the process store: the embedded
/// configuration (no row-security engine installed, authentication off), in
/// which a read is served by the node-scan stream and the engine-direct paths
/// instead of a read snapshot.
fn inProcessAnswersOf(allocator: std.mem.Allocator, pristine: []const u8, work: []const u8, store_kind: Store, s: Shape) ![2]Answer {
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
    // A process store opened without a data directory (by an earlier in-process
    // engine call) would be returned as it is: `initGlobalStore` then finds no
    // adapter.
    graph_store.deinitGlobalStoreForTestCrash();
    const store = try graph_store.initGlobalStore(allocator, work);
    defer graph_store.setDataDirOverride(allocator, null);
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
    const sid = try sessions.createSession("s6547", "", null, null, null, false, 0);
    if (store_kind.graph()) |g| {
        var qb: [64]u8 = undefined;
        const use = inProcessAnswer(arena.allocator(), sid, try std.fmt.bufPrint(&qb, "USE GRAPH {s}", .{g}));
        if (!use.ok) {
            std.debug.print("in process USE GRAPH {s}: {s} {s}\n", .{ g, use.codeText(), use.classText() });
            return error.UseGraphFailed;
        }
    }
    var out: [2]Answer = undefined;
    for (&out) |*a| a.* = inProcessAnswer(arena.allocator(), sid, s.q);
    return out;
}

test "SONNY-6547 (1): a quarantined or label-dictionary-diverged graph answers every shape alike over QUIC and gRPC" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const base = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6547-tp-{d}", .{port});
    defer allocator.free(base);
    const seed = try std.fmt.allocPrint(allocator, "{s}/seed", .{base});
    defer allocator.free(seed);
    const damaged = try std.fmt.allocPrint(allocator, "{s}/damaged", .{base});
    defer allocator.free(damaged);
    const diverged = try std.fmt.allocPrint(allocator, "{s}/diverged", .{base});
    defer allocator.free(diverged);
    const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
    defer allocator.free(work);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{base});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), seed);
    defer std.Io.Dir.cwd().deleteTree(io(), base) catch {};
    var keep_log = false;
    defer if (!keep_log) std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};

    // Seed the default graph and `qg`, checkpoint, SIGKILL.
    {
        var server = try Server.start(allocator, seed, false, log_path);
        defer server.kill(allocator);
        var client = try util.QuicProtoClient.connect(allocator, server.quic_addr);
        defer client.deinit();
        client.watchServerLiveness(server.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        h.deinit(allocator);
        for (0..NODES) |i| {
            var qb: [160]u8 = undefined;
            const body = if (i % 2 == 0) "alpha beta" else "gamma delta";
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:P {{name: 'p-{d:0>5}', i: {d}, body: '{s}'}})", .{ i, i, body }));
        }
        for (0..EDGES) |i| {
            var qb: [200]u8 = undefined;
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "MATCH (a:P {{name: 'p-{d:0>5}'}}), (b:P {{name: 'p-{d:0>5}'}}) CREATE (a)-[:R {{w: {d}}}]->(b)", .{ i, i + 1, i }));
        }
        try queryOk(&client, allocator, "CREATE INDEX p_name FOR (n:P) ON (n.name)");
        try queryOk(&client, allocator, "CREATE INDEX p_body FOR (n:P) ON (n.body) USING fulltext");
        try queryOk(&client, allocator, "CREATE GRAPH " ++ QG);
        try queryOk(&client, allocator, "USE GRAPH " ++ QG);
        for (0..QG_NODES) |i| {
            var qb: [160]u8 = undefined;
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:P {{name: 'p-{d:0>5}', i: {d}}})", .{ i, i }));
        }
        for (0..EDGES / 2) |i| {
            var qb: [200]u8 = undefined;
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "MATCH (a:P {{name: 'p-{d:0>5}'}}), (b:P {{name: 'p-{d:0>5}'}}) CREATE (a)-[:R {{w: {d}}}]->(b)", .{ i, i + 1, i }));
        }
        try queryOk(&client, allocator, "CREATE INDEX qg_name FOR (n:P) ON (n.name)");
        try waitCheckpointed(allocator, seed);
    }
    try run(&.{ "cp", "-a", seed, damaged });
    try run(&.{ "cp", "-a", seed, diverged });
    const zeroed = try zeroNodePages(allocator, damaged);
    try testing.expect(zeroed > 0);
    try splitLabelDictionaries(allocator, diverged);
    std.debug.print("SONNY-6547 (1): zeroed {d} node page(s); split qg's label dictionaries\n", .{zeroed});

    var divergences: usize = 0;
    var open: usize = 0;
    for ([_]Store{ .damaged, .damaged_second_graph, .label_dict_diverged }) |store| {
        const pristine = switch (store) {
            .damaged, .damaged_second_graph => damaged,
            .label_dict_diverged => diverged,
        };
        for (shapes) |s| {
            if (s.default_graph and store.graph() != null) continue;
            const q = try answersOf(allocator, pristine, work, log_path, store, s, .quic);
            const g = try answersOf(allocator, pristine, work, log_path, store, s, .grpc);
            const p = try inProcessAnswersOf(allocator, pristine, work, store, s);
            for ([_][]const u8{ "first touch", "again" }, q, g, p) |when, qa, ga, pa| {
                const alike = qa.same(&ga) and qa.same(&pa);
                std.debug.print("{s} | {s} | {s} | QUIC {s} {s} | gRPC {s} {s} | gRPC in process {s} {s}{s}\n", .{
                    @tagName(store),                    s.q,                                when,
                    if (qa.ok) "OK" else qa.codeText(), qa.classText(),                     if (ga.ok) "OK" else ga.codeText(),
                    ga.classText(),                     if (pa.ok) "OK" else pa.codeText(), pa.classText(),
                    if (alike) "" else "  <-- DIFFERS",
                });
                if (!alike) divergences += 1;
                if (qa.ok or ga.ok or pa.ok) open += 1;
            }
        }
    }
    if (divergences > 0 or open > 0) {
        keep_log = true;
        std.debug.print("SONNY-6547 (1): {d} answer(s) differ between QUIC and gRPC; {d} answered a refused graph (server log kept: {s})\n", .{ divergences, open, log_path });
    }
    try testing.expectEqual(@as(usize, 0), open);
    try testing.expectEqual(@as(usize, 0), divergences);
}
