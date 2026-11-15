// SONNY-6595: every node write path keeps a vector (HNSW) index current, and
// refuses a wrong-dimension vector, over the wire, on a real `geode serve`,
// before and after a restart.
//
// The report (found by reading code for SONNY-6591):
//   1. The QUIC node fast paths (`executeBulkSimpleCreate`, the default for a
//      single-statement `CREATE (n:L {k: v})` with no RETURN;
//      `executeBulkSimpleMerge`; the `/*+BATCH*/` `executeBatchSimpleMerge`)
//      write through the storage adapter and never ran the advanced-index
//      maintenance every executor write runs
//      (`property_mutation.maintainAdvancedIndexesForNodeWrite`). A vector
//      reaches them as a `$param` (a `vectorf32(...)` call is not
//      fast-pathed). knn() answers from any non-empty index it considers
//      authoritative, so a node written there was not found by knn() until the
//      index was rebuilt (a restart and the first knn after it).
//   2. `executeBulkSimpleCreate` ran no vector-dimension check
//      (`checkBulkVectorDims`, which the MERGE fast paths run), so a
//      wrong-dimension vector the executor refuses was stored.
//
// The matrix: one server per transport (QUIC, plaintext gRPC). Round a writes
// two nodes (one by the fast path, one by the executor) BEFORE a vector index
// on (:V).emb exists, creates the index (backfill), then runs every write path
// (executor CREATE, fast-path CREATE, fast-path MERGE ON CREATE SET,
// fast-path MERGE SET on a node without a vector, fast-path MERGE SET
// replacing a vector, executor MERGE, the `/*+BATCH*/` bulk MERGE, MATCH ...
// SET), each with its own vector, and asks knn(q, 1) right after the write
// whether the node is the nearest neighbour of its own vector (and, for the
// replaced vector, that it is no longer the nearest neighbour of the old one).
// No node carries `emb` under a second label: knn() then no longer trusts the
// index (`GraphStore.labelSolelyCarriesProperty`) and scans, which answers
// correctly whatever the index holds and would hide the defect.
// The server is SIGKILLed. After the restart the first statement is a
// fast-path CREATE, then every vector is asked again, round b runs every path,
// SIGTERM. After that restart every vector is asked again, round c runs every
// path, SIGKILL, and a last restart asks every vector again.
//
// Each round also writes a wrong-dimension vector to an indexed property
// (D.demb) and to an unindexed one whose dimension an earlier row established
// (U.e), by the executor and by the fast paths: every path must refuse it
// with the executor's error, and nothing may be stored. (A stored
// wrong-dimension vector on V.emb made every knn() on it fail with 22023
// after a restart; the probes stay off V.emb so the two defects show apart.)
//
// CANARY: REQ=REQ-SONNY-6595-VECTOR-WRITE-PATHS; FEATURE="VectorIndex"; ASPECT=WirePathMatrix; STATUS=TESTED; TEST=tests/test_sonny6595_vector_write_paths.zig; OWNER=index; UPDATED=2026-11-15

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Transport = enum { quic, grpc };

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, log_path: []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(quic_addr);
        const grpc_addr = try util.formatAddr(allocator, grpc_port);
        errdefer allocator.free(grpc_addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --listen-grpc {s} --data-dir '{s}' --persist-interval 300 2>>'{s}'", .{ geode_test_bin.geode_exe, quic_addr, grpc_addr, data_dir, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, util.TestEnv.grpcPlaintext());
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

/// A named vector parameter; `text` is VECTOR_F32 text ("[x, y, z]").
const VParam = struct { name: []const u8, text: []const u8 };

fn buildParams(allocator: std.mem.Allocator, vparams: []const VParam) !std.ArrayList(schema.Param) {
    var params = util.emptyParams();
    errdefer {
        for (params.items) |*p| p.deinit(allocator);
        params.deinit(allocator);
    }
    for (vparams) |vp| {
        const name = try allocator.dupe(u8, vp.name);
        errdefer allocator.free(name);
        const type_name = try allocator.dupe(u8, "VECTOR_F32");
        errdefer allocator.free(type_name);
        const text = try allocator.dupe(u8, vp.text);
        errdefer allocator.free(text);
        try params.append(allocator, .{
            .name = name,
            .value = .{ .kind = .{ .ext_val = .{ .type_name = type_name, .data = .{ .text = text } } } },
        });
    }
    return params;
}

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

    fn exec(self: *Client, allocator: std.mem.Allocator, q: []const u8, vparams: []const VParam) !util.ExecResult {
        // The query runner takes the parameters and frees them.
        const params = try buildParams(allocator, vparams);
        switch (self.*) {
            .quic => |*c| return c.executeAndCollect(allocator, q, params, 1000),
            .grpc => |*s| {
                var c = try util.GrpcProtoClient.connect(allocator, s.addr);
                defer c.deinit();
                c.session_id = try allocator.dupe(u8, s.session_id);
                return c.executeAndCollect(allocator, q, params, 1000);
            },
        }
    }

    /// Rows the statement answers; error.QueryFailed when it is refused.
    fn rows(self: *Client, allocator: std.mem.Allocator, q: []const u8, vparams: []const VParam) !usize {
        var r = try self.exec(allocator, q, vparams);
        defer r.deinit(allocator);
        if (r.error_code) |c| {
            std.debug.print("{s}: {s} {s}\n", .{ q, c, r.error_message orelse "" });
            return error.QueryFailed;
        }
        return r.rows.len;
    }

    fn ok(self: *Client, allocator: std.mem.Allocator, q: []const u8, vparams: []const VParam) !void {
        _ = try self.rows(allocator, q, vparams);
    }
};

/// One write path. In every statement "{w}" is the path's key for the round;
/// `$q` is its vector, `$b` the second batch node's, `$o` the vector `setup`
/// writes and `write` replaces.
const Path = struct {
    name: []const u8,
    setup: []const []const u8 = &.{},
    write: []const u8,
    /// A second node keyed "{w}x" carries `$b`.
    second: bool = false,
    /// `setup` wrote `$o`, which `write` replaces.
    replaces: bool = false,
};

const write_paths = [_]Path{
    .{ .name = "executor CREATE", .write = "CREATE (n:V {key: '{w}', emb: $q}) RETURN n.key AS k" },
    .{ .name = "fast-path CREATE", .write = "CREATE (:V {key: '{w}', emb: $q})" },
    .{ .name = "fast-path MERGE ON CREATE SET", .write = "MERGE (n:V {key: '{w}'}) ON CREATE SET n.emb = $q" },
    .{ .name = "fast-path MERGE SET, no vector before", .setup = &.{"CREATE (:V {key: '{w}'})"}, .write = "MERGE (n:V {key: '{w}'}) SET n.emb = $q" },
    .{ .name = "fast-path MERGE SET, replaces vector", .setup = &.{"CREATE (n:V {key: '{w}', emb: $o}) RETURN n.key AS k"}, .write = "MERGE (n:V {key: '{w}'}) SET n.emb = $q", .replaces = true },
    .{ .name = "executor MERGE", .write = "MERGE (n:V {key: '{w}'}) ON CREATE SET n.emb = $q RETURN n.key AS k" },
    .{ .name = "/*+BATCH*/ bulk MERGE", .write = "/*+BATCH*/ MERGE (n:V {key: '{w}'}) ON CREATE SET n.emb = $q; MERGE (m:V {key: '{w}x'}) ON CREATE SET m.emb = $b", .second = true },
    .{ .name = "MATCH ... SET", .setup = &.{"CREATE (:V {key: '{w}'})"}, .write = "MATCH (n:V) WHERE n.key = '{w}' SET n.emb = $q" },
};

/// The vector of path `i` in round `r` (`which`: 0 = $q, 1 = $b, 2 = $o).
/// Every vector is distinct and the old ones lie on the far side of the
/// origin, so the nearest neighbour of each written vector is its own node.
fn vecText(buf: []u8, i: usize, r: usize, which: u8) ![]const u8 {
    const x: i64 = @intCast(10 * (i + 1));
    const y: i64 = @intCast(100 * (r + 1));
    return switch (which) {
        0 => std.fmt.bufPrint(buf, "[{d}.0, {d}.0, 1.0]", .{ x, y }),
        1 => std.fmt.bufPrint(buf, "[{d}.0, {d}.0, 1.0]", .{ x + 5, y }),
        else => std.fmt.bufPrint(buf, "[-{d}.0, -{d}.0, 1.0]", .{ x, y }),
    };
}

/// A node and the vector knn(vector, 1) must (want 1) or must not (want 0)
/// answer it for.
const Expect = struct { name: []const u8, key: []u8, vec: []u8, want: usize };

const Run = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    expects: std.ArrayList(Expect) = .empty,
    failed: usize = 0,

    fn deinit(self: *Run) void {
        for (self.expects.items) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.vec);
        }
        self.expects.deinit(self.allocator);
    }

    fn mark(self: *Run, pass: bool) void {
        if (!pass) self.failed += 1;
    }

    /// Is `key`'s node the nearest neighbour of `vec`? Prints the cell.
    fn cell(self: *Run, client: *Client, timing: []const u8, name: []const u8, key: []const u8, vec: []const u8, want: usize) !void {
        var qb: [256]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "MATCH (v:V) WHERE id(v) IN knn('emb', $q, 1, 'l2') AND v.key = '{s}' RETURN v.key AS k", .{key});
        var res = try client.exec(self.allocator, q, &.{.{ .name = "q", .text = vec }});
        defer res.deinit(self.allocator);
        // A refused knn() is a failed cell (a stored wrong-dimension vector
        // made every knn() on the property fail after a restart).
        const got: ?usize = if (res.error_code == null) res.rows.len else null;
        const pass = got == want;
        self.mark(pass);
        const answer = if (got) |g| (if (g == 1) "it" else "not") else "ERR";
        const wanted = if (want == 1) "it" else "not";
        std.debug.print("SONNY-6595 | {s:<4} | {s:<26} | {s:<40} | {s:<10} | knn(1) {s:<4} want {s:<4} | {s} {s}\n", .{
            @tagName(self.transport), timing, name, key, answer, wanted, if (pass) "PASS" else "FAIL", res.error_code orelse "",
        });
    }

    fn expect(self: *Run, name: []const u8, key: []const u8, vec: []const u8, want: usize) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, vec);
        errdefer self.allocator.free(v);
        try self.expects.append(self.allocator, .{ .name = name, .key = k, .vec = v, .want = want });
    }

    fn checkAll(self: *Run, client: *Client, timing: []const u8) !void {
        for (self.expects.items) |e| try self.cell(client, timing, e.name, e.key, e.vec, e.want);
    }

    fn run(self: *Run, client: *Client, q: []const u8, key: []const u8, vparams: []const VParam) !void {
        const stmt = try std.mem.replaceOwned(u8, self.allocator, q, "{w}", key);
        defer self.allocator.free(stmt);
        var used: [3]VParam = undefined;
        var n: usize = 0;
        for (vparams) |vp| {
            var nb: [8]u8 = undefined;
            const ref = try std.fmt.bufPrint(&nb, "${s}", .{vp.name});
            if (std.mem.indexOf(u8, stmt, ref) != null) {
                used[n] = vp;
                n += 1;
            }
        }
        try client.ok(self.allocator, stmt, used[0..n]);
    }

    /// Every write path once, each looked up right after its write.
    fn round(self: *Run, client: *Client, r: usize) !void {
        var tb: [32]u8 = undefined;
        const timing = try std.fmt.bufPrint(&tb, "round {c}, right after", .{@as(u8, 'a') + @as(u8, @intCast(r))});
        for (write_paths, 0..) |p, i| {
            var kb: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "p{d}r{d}", .{ i, r });
            var k2b: [32]u8 = undefined;
            const key2 = try std.fmt.bufPrint(&k2b, "{s}x", .{key});
            var qb: [64]u8 = undefined;
            var bb: [64]u8 = undefined;
            var ob: [64]u8 = undefined;
            const vps = [_]VParam{
                .{ .name = "q", .text = try vecText(&qb, i, r, 0) },
                .{ .name = "b", .text = try vecText(&bb, i, r, 1) },
                .{ .name = "o", .text = try vecText(&ob, i, r, 2) },
            };
            for (p.setup) |s| try self.run(client, s, key, &vps);
            if (p.replaces) try self.cell(client, "after its setup", p.name, key, vps[2].text, 1);
            try self.run(client, p.write, key, &vps);
            try self.cell(client, timing, p.name, key, vps[0].text, 1);
            try self.expect(p.name, key, vps[0].text, 1);
            if (p.second) {
                try self.cell(client, timing, p.name, key2, vps[1].text, 1);
                try self.expect(p.name, key2, vps[1].text, 1);
            }
            if (p.replaces) {
                try self.cell(client, timing, "  (its old vector)", key, vps[2].text, 0);
                try self.expect("  (its old vector)", key, vps[2].text, 0);
            }
        }
    }

    /// A wrong-dimension vector: every path refuses it with the executor's
    /// error and stores nothing.
    fn dims(self: *Run, client: *Client, timing: []const u8, r: usize) !void {
        const two = [_]VParam{.{ .name = "q", .text = "[1.0, 2.0]" }};
        const Probe = struct { name: []const u8, q: []const u8, label: []const u8 };
        const probes = [_]Probe{
            .{ .name = "executor CREATE (indexed)", .q = "CREATE (n:D {key: '{w}', demb: $q}) RETURN n.key AS k", .label = "D" },
            .{ .name = "fast-path CREATE (indexed)", .q = "CREATE (:D {key: '{w}', demb: $q})", .label = "D" },
            .{ .name = "fast-path MERGE (indexed)", .q = "MERGE (n:D {key: '{w}'}) ON CREATE SET n.demb = $q", .label = "D" },
            .{ .name = "executor CREATE (unindexed)", .q = "CREATE (n:U {key: '{w}', e: $q}) RETURN n.key AS k", .label = "U" },
            .{ .name = "fast-path CREATE (unindexed)", .q = "CREATE (:U {key: '{w}', e: $q})", .label = "U" },
        };
        var executor_err: [2]?[]u8 = .{ null, null };
        defer for (executor_err) |e| if (e) |s| self.allocator.free(s);
        for (probes, 0..) |p, i| {
            var kb: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&kb, "dim{d}r{d}", .{ i, r });
            const stmt = try std.mem.replaceOwned(u8, self.allocator, p.q, "{w}", key);
            defer self.allocator.free(stmt);
            var res = try client.exec(self.allocator, stmt, &two);
            defer res.deinit(self.allocator);
            const err_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ res.error_code orelse "none", res.error_message orelse "" });
            defer self.allocator.free(err_text);
            const slot: usize = if (std.mem.eql(u8, p.label, "D")) 0 else 1;
            const is_executor = std.mem.startsWith(u8, p.name, "executor");
            if (is_executor) executor_err[slot] = try self.allocator.dupe(u8, err_text);
            var cb: [128]u8 = undefined;
            const count_q = try std.fmt.bufPrint(&cb, "MATCH (n:{s}) WHERE n.key = '{s}' RETURN n.key AS k", .{ p.label, key });
            const stored = try client.rows(self.allocator, count_q, &.{});
            const same = if (executor_err[slot]) |e| std.mem.eql(u8, e, err_text) else false;
            const pass = res.error_code != null and stored == 0 and same;
            self.mark(pass);
            std.debug.print("SONNY-6595 | {s:<4} | {s:<26} | wrong dimension: {s:<29} | {s} | stored {d} | {s}\n", .{
                @tagName(self.transport), timing, p.name, err_text, stored, if (pass) "PASS" else "FAIL",
            });
        }
    }
};

/// Runs the whole matrix for one transport; the number of cells that fail.
fn runTransport(allocator: std.mem.Allocator, transport: Transport) !usize {
    const port = try util.getRandomPort();
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6595-vec-{s}-{d}", .{ @tagName(transport), port });
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    var keep_log = false;
    defer if (!keep_log) std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};
    errdefer {
        keep_log = true;
        std.debug.print("SONNY-6595: server log kept: {s}\n", .{log_path});
    }

    var run: Run = .{ .allocator = allocator, .transport = transport };
    defer run.deinit();

    // Round a, then SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, transport);
        defer client.deinit();
        // Written before the index exists (backfill).
        try client.ok(allocator, "CREATE (:V {key: 'backfillfast', emb: $q})", &.{.{ .name = "q", .text = "[3.0, 7.0, 1.0]" }});
        try client.ok(allocator, "CREATE (n:V {key: 'backfillexec', emb: $q}) RETURN n.key AS k", &.{.{ .name = "q", .text = "[7.0, 3.0, 1.0]" }});
        // The wrong-dimension probes use their own properties, so a vector
        // a defective path stores does not disturb the knn() matrix on V.emb:
        // D.demb (indexed) and U.e (unindexed, its dimension pinned by data).
        try client.ok(allocator, "CREATE (n:D {key: 'dpin', demb: $q}) RETURN n.key AS k", &.{.{ .name = "q", .text = "[1.0, 2.0, 3.0]" }});
        try client.ok(allocator, "CREATE INDEX d_demb ON D (demb) USING vector WITH (metric = 'l2')", &.{});
        try client.ok(allocator, "CREATE (n:U {key: 'upin', e: $q}) RETURN n.key AS k", &.{.{ .name = "q", .text = "[1.0, 2.0, 3.0]" }});
        try client.ok(allocator, "CREATE INDEX v_emb ON V (emb) USING vector WITH (metric = 'l2')", &.{});
        try run.expect("backfill (fast-path CREATE)", "backfillfast", "[3.0, 7.0, 1.0]", 1);
        try run.expect("backfill (executor CREATE)", "backfillexec", "[7.0, 3.0, 1.0]", 1);
        try run.checkAll(&client, "after CREATE INDEX");
        try run.dims(&client, "round a", 0);
        try run.round(&client, 0);
    }
    // SIGKILL restart: the first statement is a fast-path CREATE, then every
    // vector; round b; SIGTERM.
    {
        var server = try Server.start(allocator, data_dir, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, transport);
        defer client.deinit();
        try run.dims(&client, "SIGKILL, restart, first", 1);
        try client.ok(allocator, "CREATE (:V {key: 'firstafterkill', emb: $q})", &.{.{ .name = "q", .text = "[5.0, 5.0, 9.0]" }});
        try run.expect("fast-path CREATE, first after a restart", "firstafterkill", "[5.0, 5.0, 9.0]", 1);
        try run.checkAll(&client, "SIGKILL, restart");
        try run.round(&client, 1);
        try server.stop();
    }
    // Checkpointed restart: every vector; round c; SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, transport);
        defer client.deinit();
        try run.checkAll(&client, "SIGTERM, restart");
        try run.dims(&client, "SIGTERM, restart", 2);
        try run.round(&client, 2);
    }
    // SIGKILL restart: every vector.
    {
        var server = try Server.start(allocator, data_dir, log_path);
        defer server.kill(allocator);
        var client = try Client.connect(allocator, &server, transport);
        defer client.deinit();
        try run.checkAll(&client, "SIGKILL, restart (final)");
    }
    if (run.failed > 0) {
        keep_log = true;
        std.debug.print("SONNY-6595: {s}: {d} cell(s) failed (server log kept: {s})\n", .{ @tagName(transport), run.failed, log_path });
    }
    return run.failed;
}

test "SONNY-6595: every node write path keeps a vector index current and refuses a wrong-dimension vector, over QUIC and gRPC, before and after restarts" {
    var failed: usize = 0;
    for ([_]Transport{ .quic, .grpc }) |t| failed += try runTransport(testing.allocator, t);
    try testing.expectEqual(@as(usize, 0), failed);
}
