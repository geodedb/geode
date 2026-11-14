// SONNY-6541 (3): the first read of a damaged graph that nothing hydrated
// yet fails closed; it does not answer from the zeroed pages.
//
// SONNY-6523 / SONNY-6528 refuse every read of a quarantined graph: one
// whose first-touch hydration found its store damaged. The transports' gate
// (`graph_store.programQuarantineError`) hydrates a graph first only for a
// write; a read is checked only when it passes the hydration chokepoint
// (`ensureGraphHydrated`) itself. A read served engine-direct, from the
// pages, needs no resident product and never hydrates: as the first
// statement after a restart it answered from the zeroed pages (a filtered
// count, an ORDER BY, max()) before anything found the damage.
//
// The store is damaged as in test-sonny6528-quarantine-in-process (every
// written page of every shard's nodes.store zeroed, the derived-index
// snapshots removed), in process and, as in
// test-sonny6523-quarantine-fail-closed, under a real `geode serve` that
// seeded it, checkpointed and was SIGKILLed. Each read shape is then the
// FIRST statement on its own fresh copy of the damaged store, on the default
// graph and on a second graph: it must fail, with a corruption error, and
// must not answer (an empty or zero answer included).
//
// CANARY: REQ=REQ-SONNY-6541-FIRST-READ-FAIL-CLOSED; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6541_quarantine_first_read.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const NODES: usize = 200;
const EDGES: usize = 40;
const G = "g6541";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
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

const Outcome = union(enum) { rows: usize, failed: anyerror };

fn ask(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) Outcome {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return .{ .failed = err };
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return .{ .failed = err };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    return .{ .rows = result.rows.len };
}

fn queryOk(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !void {
    switch (ask(allocator, session, q)) {
        .rows => {},
        .failed => |err| {
            std.debug.print("'{s}' failed: {s}\n", .{ q, @errorName(err) });
            return err;
        },
    }
}

fn isQuarantineError(err: anyerror) bool {
    return err == error.DataCorruption or err == error.ChecksumMismatch or
        err == error.InvalidData or err == error.GraphQuarantined;
}

/// Zero every written page of every nodes.store under `data_dir`; remove the
/// loop2 hydration snapshots and empty labels.idx, so the reopen's hydration
/// rebuilds from the damaged node store and fails (DataCorruption).
fn damage(data_dir: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var zeroed: usize = 0;
    var snapshots: std.ArrayList([]u8) = .empty;
    defer {
        for (snapshots.items) |p| std.testing.allocator.free(p);
        snapshots.deinit(std.testing.allocator);
    }
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "labels.idx")) {
            var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
            defer file.close(io());
            try file.setLength(io(), 0);
            continue;
        }
        if (std.mem.startsWith(u8, entry.basename, "hydration_") and std.mem.endsWith(u8, entry.basename, ".snap")) {
            try snapshots.append(std.testing.allocator, try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_dir, entry.path }));
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, "nodes.store")) continue;
        var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
        defer file.close(io());
        const len = try file.length(io());
        var page: u64 = 0;
        while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
            var header: [32]u8 = undefined;
            _ = try file.readPositionalAll(io(), &header, page * PAGE_SIZE);
            if (std.mem.allEqual(u8, &header, 0)) continue;
            const zeros = [_]u8{0} ** PAGE_SIZE;
            try file.writePositionalAll(io(), &zeros, page * PAGE_SIZE);
            zeroed += 1;
        }
    }
    for (snapshots.items) |p| try std.Io.Dir.cwd().deleteFile(io(), p);
    return zeroed;
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
fn damageShards(allocator: std.mem.Allocator, shards: []const []u8) !usize {
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

/// Read shapes; each runs as the first statement on a fresh copy, on the
/// graph `USE GRAPH` names.
const read_shapes = [_][]const u8{
    "MATCH (n:P) RETURN count(n) AS c",
    "MATCH (n) RETURN count(n) AS c",
    "MATCH ()-[r:R]->() RETURN count(r) AS c",
    "MATCH (n:P) WHERE n.i >= 0 RETURN count(n) AS c",
    "MATCH (n:P) WHERE n.name = 'p-00007' RETURN count(n) AS c",
    "MATCH (n:P) WHERE n.name = 'p-00007' RETURN n.i AS i",
    "MATCH (n:P {name: 'p-00008'}) RETURN n.i AS i",
    "MATCH (n:P) RETURN n.name AS name ORDER BY n.name LIMIT 3",
    "MATCH (n:P) RETURN n.i AS i ORDER BY n.i DESC LIMIT 1",
    "MATCH (n:P) RETURN n.name AS name",
    "MATCH (n) RETURN n.name AS name",
    "MATCH (a:P)-[r:R]->(b) RETURN r.w AS w",
    "MATCH (n:P) RETURN max(n.i) AS m",
    "MATCH (n:P) RETURN min(n.i) AS m, sum(n.i) AS s",
    "CALL db.labels()",
    "SHOW TABLES",
};

const graph_names = [_][]const u8{ "default", G };

fn seedStatements(buf: *std.ArrayList([]u8), allocator: std.mem.Allocator, graph: []const u8) !void {
    for (0..NODES) |i| {
        try buf.append(allocator, try std.fmt.allocPrint(allocator, "USE GRAPH {s}; CREATE (:P {{name: 'p-{d:0>5}', i: {d}}})", .{ graph, i, i }));
    }
    for (0..EDGES) |i| {
        try buf.append(allocator, try std.fmt.allocPrint(allocator, "USE GRAPH {s}; MATCH (a:P {{name: 'p-{d:0>5}'}}), (b:P {{name: 'p-{d:0>5}'}}) CREATE (a)-[:R {{w: {d}}}]->(b)", .{ graph, i, i + 1, i }));
    }
    try buf.append(allocator, try std.fmt.allocPrint(allocator, "USE GRAPH {s}; CREATE INDEX p_name_{s} FOR (n:P) ON (n.name)", .{ graph, graph }));
}

fn allSeedStatements(allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var buf: std.ArrayList([]u8) = .empty;
    errdefer {
        for (buf.items) |s| allocator.free(s);
        buf.deinit(allocator);
    }
    try buf.append(allocator, try allocator.dupe(u8, "CREATE GRAPH " ++ G));
    for (graph_names) |g| try seedStatements(&buf, allocator, g);
    return buf;
}

fn freeStatements(allocator: std.mem.Allocator, buf: *std.ArrayList([]u8)) void {
    for (buf.items) |s| allocator.free(s);
    buf.deinit(allocator);
}

test "SONNY-6541 (3): the first read of a never-hydrated damaged graph fails closed in process" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(base);
    const pristine = try std.fmt.allocPrint(allocator, "{s}/damaged", .{base});
    defer allocator.free(pristine);
    const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
    defer allocator.free(work);
    defer graph_store.setDataDirOverride(allocator, null);
    try std.Io.Dir.cwd().createDirPath(io(), pristine);

    {
        _ = try graph_store.initGlobalStore(allocator, pristine);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        var stmts = try allSeedStatements(allocator);
        defer freeStatements(allocator, &stmts);
        for (stmts.items) |q| try queryOk(allocator, &session, q);
        for (graph_names) |g| for (read_shapes) |shape| {
            var qb: [256]u8 = undefined;
            const q = try std.fmt.bufPrint(&qb, "USE GRAPH {s}; {s}", .{ g, shape });
            switch (ask(allocator, &session, q)) {
                .rows => |n| if (n == 0) {
                    std.debug.print("healthy store: '{s}' returned no rows\n", .{q});
                    return error.HealthyShapeEmpty;
                },
                .failed => |err| {
                    std.debug.print("healthy store: '{s}' failed: {s}\n", .{ q, @errorName(err) });
                    return err;
                },
            }
        };
    }
    const zeroed = try damage(pristine);
    std.debug.print("SONNY-6541 (3) in process: zeroed {d} node page(s)\n", .{zeroed});
    try testing.expect(zeroed > 0);

    var failures: usize = 0;
    for (graph_names) |g| for (read_shapes) |shape| {
        try copyOf(pristine, work);
        const store = try graph_store.initGlobalStore(allocator, work);
        defer graph_store.deinitGlobalStoreForTestCrash();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        var qb: [256]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "USE GRAPH {s}; {s}", .{ g, shape });
        switch (ask(allocator, &session, q)) {
            .rows => |n| {
                failures += 1;
                std.debug.print("FAIL-OPEN (first statement): '{s}' answered {d} row(s)\n", .{ q, n });
            },
            .failed => |err| if (!isQuarantineError(err)) {
                failures += 1;
                std.debug.print("(first statement): '{s}' failed with {s}, not a corruption error\n", .{ q, @errorName(err) });
            },
        }
    };
    if (failures > 0) {
        std.debug.print("SONNY-6541 (3): {d} first read(s) of a damaged graph answered in process\n", .{failures});
        return error.FirstReadFailOpen;
    }
}

fn copyOf(pristine: []const u8, work: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
}

test "SONNY-6541 (3): the first read of a never-hydrated damaged graph fails closed over the wire" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const base = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6541-fr-{d}", .{port});
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
        var stmts = try allSeedStatements(allocator);
        defer freeStatements(allocator, &stmts);
        for (stmts.items) |q| try queryOkWire(&client, allocator, q);
        for (graph_names) |g| for (read_shapes) |shape| {
            var qb: [256]u8 = undefined;
            const q = try std.fmt.bufPrint(&qb, "USE GRAPH {s}; {s}", .{ g, shape });
            const a = try askWire(&client, allocator, q);
            if (!a.ok or a.rows == 0) {
                std.debug.print("healthy store: '{s}': ok={} rows={d} {s}\n", .{ q, a.ok, a.rows, a.message[0..a.message_len] });
                return error.HealthyShapeFailed;
            }
        };
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
        const zeroed = try damageShards(allocator, shards.items);
        const snaps = try removeHydrationSnapshots(allocator, pristine);
        std.debug.print("SONNY-6541 (3) over the wire: zeroed {d} node page(s) in {d} shard(s); removed {d} snapshot(s)\n", .{ zeroed, shards.items.len, snaps });
        try testing.expect(zeroed > 0);
    }

    var failures: usize = 0;
    for (graph_names) |g| for (read_shapes) |shape| {
        try copyOf(pristine, work);
        var server = try Server.start(allocator, work, &.{}, log_path);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        var qb: [256]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "USE GRAPH {s}; {s}", .{ g, shape });
        const a = try askWire(&client, allocator, q);
        if (a.ok) {
            failures += 1;
            std.debug.print("FAIL-OPEN (first statement): '{s}' answered OK, {d} row(s), first {any}\n", .{ q, a.rows, a.first });
        } else if (!std.mem.eql(u8, a.code[0..a.code_len], "58000")) {
            failures += 1;
            std.debug.print("(first statement): '{s}' refused {s} {s}, not 58000\n", .{ q, a.code[0..a.code_len], a.message[0..@min(a.message_len, 120)] });
        }
    };
    if (failures > 0) {
        keep_log = true;
        std.debug.print("SONNY-6541 (3): {d} first read(s) of a damaged graph answered over the wire (server log kept: {s})\n", .{ failures, log_path });
        return error.FirstReadFailOpen;
    }
}

fn nowNs() i96 {
    return std.Io.Clock.awake.now(io()).nanoseconds;
}

// The cost on a HEALTHY store, printed for the record (no assertion on
// time): the first read after a restart (it hydrates the graph when the
// gate hydrates), the same read warm, and the gate itself per call on a
// hydrated graph, without and with its hydration check.
test "SONNY-6541 (3): the healthy-path cost of the first-read check (printed)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(base);
    const healthy = try std.fmt.allocPrint(allocator, "{s}/healthy", .{base});
    defer allocator.free(healthy);
    defer graph_store.setDataDirOverride(allocator, null);
    try std.Io.Dir.cwd().createDirPath(io(), healthy);
    {
        _ = try graph_store.initGlobalStore(allocator, healthy);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        var stmts = try allSeedStatements(allocator);
        defer freeStatements(allocator, &stmts);
        for (stmts.items) |q| try queryOk(allocator, &session, q);
    }
    const store = try graph_store.initGlobalStore(allocator, healthy);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    try store.loadFromFile();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    const q = "USE GRAPH " ++ G ++ "; MATCH (n:P) WHERE n.i >= 0 RETURN count(n) AS c";
    const t0 = nowNs();
    try queryOk(allocator, &session, q);
    const first_ns = nowNs() - t0;
    const warm_runs: usize = 200;
    const t1 = nowNs();
    for (0..warm_runs) |_| try queryOk(allocator, &session, q);
    const warm_ns = @divTrunc(nowNs() - t1, warm_runs);
    const gate_runs: usize = 100_000;
    const names = [_][]const u8{G};
    const t2 = nowNs();
    for (0..gate_runs) |_| try testing.expect(graph_store.programQuarantineError(allocator, &names, false) == null);
    const gate_plain_ns = @divTrunc(nowNs() - t2, gate_runs);
    const t3 = nowNs();
    for (0..gate_runs) |_| try testing.expect(graph_store.programQuarantineError(allocator, &names, true) == null);
    const gate_hydrating_ns = @divTrunc(nowNs() - t3, gate_runs);
    std.debug.print("SONNY-6541 (3) healthy path: first read after restart {d} us; warm read {d} us; gate per call {d} ns without the hydration check, {d} ns with it\n", .{
        @divTrunc(first_ns, 1000), @divTrunc(warm_ns, 1000), gate_plain_ns, gate_hydrating_ns,
    });
}
