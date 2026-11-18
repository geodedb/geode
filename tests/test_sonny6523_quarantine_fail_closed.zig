// SONNY-6523 (1): a graph whose first-touch hydration failed (quarantined,
// REQ-GQL-028) refuses EVERY read and every write, on every path a real
// server serves it by.
//
// The quarantine was noted in a thread-local that only the executor's
// statement gate consumed. The transport's fast paths (the label-refcount
// count, the count/edge-count/filtered-count fast paths, the engine-direct
// node stream, the planned read, the write fast paths) answered from the
// resident products the failed hydration had left partial: `MATCH (n:L)
// RETURN count(n)` and `MATCH (n) RETURN count(n)` answered 0 for a graph
// holding hundreds of nodes (found while fixing SONNY-6492).
//
// The store is damaged the way test-sonny2409-zeroed-page-header damages it:
// a real `geode serve` seeds the default graph (nodes, relationships with a
// property, an exact property index, a fulltext index), checkpoints, and is
// SIGKILLed; every written page of every shard's nodes.store is zeroed and
// the derived-index snapshots are removed, so the restart's hydration scan
// meets the damage. Each shape then runs against its own fresh copy of that
// damaged store, as the first statement after the restart (the first touch
// hydrates) and again (the graph is quarantined by then). Every read must
// fail; none may answer, an empty or zero answer included. Every write must
// be refused before it reaches the engine: the shard WALs stay empty. DROP
// GRAPH of a quarantined graph still runs.
//
// CANARY: REQ=REQ-SONNY-6523-QUARANTINE-FAIL-CLOSED; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6523_quarantine_fail_closed.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const NODES: usize = 300;
const EDGES: usize = 40;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
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

fn ask(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !Answer {
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

fn queryOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    const a = try ask(client, allocator, q);
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
    /// Run the server with GEODE_BULK_INGEST=1 (the bulk write fast paths).
    bulk: bool = false,
};

const shapes = [_]Shape{
    // counts: label refcount, unlabeled, count(*), relationship counts, filtered
    .{ .q = "MATCH (n:P) RETURN count(n) AS c" },
    .{ .q = "MATCH (n) RETURN count(n) AS c" },
    .{ .q = "MATCH (n) RETURN count(*) AS c" },
    .{ .q = "MATCH ()-[r:R]->() RETURN count(r) AS c" },
    .{ .q = "MATCH ()-[r]->() RETURN count(r) AS c" },
    .{ .q = "MATCH (n:P) WHERE n.i >= 0 RETURN count(n) AS c" },
    .{ .q = "MATCH (n:P) WHERE n.name = 'p-00007' RETURN count(n) AS c" },
    // exact-index seek, ordered reads, scans
    .{ .q = "MATCH (n:P) WHERE n.name = 'p-00007' RETURN n.i AS i" },
    .{ .q = "MATCH (n:P {name: 'p-00008'}) RETURN n.i AS i" },
    .{ .q = "MATCH (n:P) RETURN n.name AS name ORDER BY n.name LIMIT 3" },
    .{ .q = "MATCH (n:P) RETURN n.i AS i ORDER BY n.i DESC LIMIT 1" },
    .{ .q = "MATCH (n:P) RETURN n.name AS name" },
    .{ .q = "MATCH (n) RETURN n.name AS name" },
    .{ .q = "MATCH (a:P)-[r:R]->(b) RETURN r.w AS w" },
    .{ .q = "MATCH (n:P) RETURN max(n.i) AS m" },
    // metadata
    .{ .q = "CALL db.labels()" },
    .{ .q = "CALL db.relationshipTypes()" },
    .{ .q = "CALL db.propertyKeys()" },
    // fulltext (default graph)
    .{ .q = "CALL geode.fts.search('p_body', 'alpha')" },
    // writes: the default fast paths, the bulk fast paths, the executor
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

test "SONNY-6523 (1): every read and write of a quarantined graph fails closed over the wire" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const base = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6523-q-{d}", .{port});
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

    // Seed a healthy store, run every read shape on it (each one answers),
    // checkpoint and SIGKILL.
    {
        var server = try Server.start(allocator, pristine, &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for (0..NODES) |i| {
            var qb: [160]u8 = undefined;
            const body = if (i % 2 == 0) "alpha beta" else "gamma delta";
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:P {{name: 'p-{d:0>5}', i: {d}, body: '{s}'}})", .{ i, i, body }));
        }
        for (0..EDGES) |i| {
            var qb: [200]u8 = undefined;
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "MATCH (a:P {{name: 'p-{d:0>5}'}}), (b:P {{name: 'p-{d:0>5}'}}) CREATE (a)-[:R {{w: {d}}}]->(b)", .{ i, i + 1, i }));
        }
        // A second graph, damaged with the default one: DROP GRAPH of it,
        // quarantined, must still run (that is how an operator removes it).
        try queryOk(&client, allocator, "CREATE GRAPH g6523");
        for (0..40) |i| {
            var qb: [120]u8 = undefined;
            try queryOk(&client, allocator, try std.fmt.bufPrint(&qb, "USE GRAPH g6523; CREATE (:Q {{i: {d}}})", .{i}));
        }
        try queryOk(&client, allocator, "USE GRAPH default");
        try queryOk(&client, allocator, "CREATE INDEX p_name FOR (n:P) ON (n.name)");
        try queryOk(&client, allocator, "CREATE INDEX p_body FOR (n:P) ON (n.body) USING fulltext");
        for (shapes) |s| {
            if (s.write) continue;
            const a = try ask(&client, allocator, s.q);
            if (!a.ok) {
                std.debug.print("healthy store: '{s}' failed: {s} {s}\n", .{ s.q, a.code[0..a.code_len], a.message[0..a.message_len] });
                return error.HealthyShapeFailed;
            }
            if (a.rows == 0) {
                std.debug.print("healthy store: '{s}' returned no rows\n", .{s.q});
                return error.HealthyShapeEmpty;
            }
        }
        var shards = try shardDirs(allocator, pristine);
        defer {
            for (shards.items) |p| allocator.free(p);
            shards.deinit(allocator);
        }
        try waitCheckpointed(allocator, shards.items);
    }

    // Damage the store.
    {
        var shards = try shardDirs(allocator, pristine);
        defer {
            for (shards.items) |p| allocator.free(p);
            shards.deinit(allocator);
        }
        try testing.expect(shards.items.len > 0);
        const zeroed = try damage(allocator, shards.items);
        const snaps = try removeHydrationSnapshots(allocator, pristine);
        std.debug.print("SONNY-6523 (1): zeroed {d} node page(s) in {d} shard(s); removed {d} hydration snapshot(s)\n", .{ zeroed, shards.items.len, snaps });
        try testing.expect(zeroed > 0);
    }

    var failures: usize = 0;
    for (shapes) |s| {
        std.Io.Dir.cwd().deleteTree(io(), work) catch {};
        try run(&.{ "cp", "-a", pristine, work });
        var shards = try shardDirs(allocator, work);
        defer {
            for (shards.items) |p| allocator.free(p);
            shards.deinit(allocator);
        }
        var server = try Server.start(allocator, work, if (s.bulk) &.{"GEODE_BULK_INGEST=1"} else &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        const wal_before = try walBytes(allocator, shards.items);
        for ([_][]const u8{ "first touch", "quarantined" }) |when| {
            const a = try ask(&client, allocator, s.q);
            if (a.ok) {
                failures += 1;
                std.debug.print("FAIL-OPEN ({s}{s}, {s}): '{s}' answered OK, {d} row(s), first {any}\n", .{ if (s.write) "write" else "read", if (s.bulk) ", bulk" else "", when, s.q, a.rows, a.first });
            } else {
                std.debug.print("closed ({s}): '{s}': {s} {s}\n", .{ when, s.q, a.code[0..a.code_len], a.message[0..@min(a.message_len, 90)] });
            }
        }
        if (s.write) {
            const wal_after = try walBytes(allocator, shards.items);
            if (wal_after != wal_before) {
                failures += 1;
                std.debug.print("WRITE REACHED THE ENGINE: '{s}': shard WALs {d} -> {d} bytes\n", .{ s.q, wal_before, wal_after });
            }
        }
    }
    // DROP GRAPH of a quarantined graph runs, and CREATE GRAPH of the name
    // then makes a fresh, empty graph.
    {
        std.Io.Dir.cwd().deleteTree(io(), work) catch {};
        try run(&.{ "cp", "-a", pristine, work });
        var server = try Server.start(allocator, work, &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        const a = try ask(&client, allocator, "USE GRAPH g6523; MATCH (n:Q) RETURN count(n) AS c");
        if (a.ok) {
            failures += 1;
            std.debug.print("FAIL-OPEN: the damaged graph g6523 answered a count: {any}\n", .{a.first});
        }
        const d = try ask(&client, allocator, "DROP GRAPH g6523");
        if (!d.ok) {
            failures += 1;
            std.debug.print("DROP GRAPH of the quarantined graph failed: {s} {s}\n", .{ d.code[0..d.code_len], d.message[0..d.message_len] });
        } else {
            try queryOk(&client, allocator, "CREATE GRAPH g6523");
            const c = try ask(&client, allocator, "USE GRAPH g6523; MATCH (n) RETURN count(n) AS c");
            if (!c.ok or c.first == null or c.first.?.int != 0) {
                failures += 1;
                std.debug.print("the graph created again under the dropped name is not empty: ok={} {any} {s}\n", .{ c.ok, c.first, c.message[0..c.message_len] });
            }
        }
    }

    if (failures > 0) {
        keep_log = true;
        std.debug.print("SONNY-6523 (1): {d} fail-open answer(s) for a quarantined graph (server log kept: {s})\n", .{ failures, log_path });
        return error.QuarantineFailOpen;
    }
}
