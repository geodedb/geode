//! SONNY-6562: the metadata a real `geode serve` sends with a result must
//! describe the result it sends, over QUIC and over gRPC.
//!
//! 1. Declared column types (the SCHEMA frame's `type`).
//!    ISO/IEC 39075:2024 21.2 SR: an <exact numeric literal> such as `1.25`
//!    has an exact numeric declared type. Geode's fixed-point value
//!    (`Value.Decimal`, sent as `decimal_val`) is its exact numeric, so it is
//!    declared DECIMAL; it was declared FLOAT.
//!    14.2 SR and 22.18 / 22.19 ("General / Static combination of value
//!    types"): a column's type is the combination of the types of all its
//!    values (every UNION operand, every row): exact + exact numeric is exact
//!    numeric, an approximate numeric makes it approximate, values of
//!    different primary base types combine to the open dynamic union type
//!    (`ANY`, 18.9 <open dynamic union type>); NULL adds nothing. Geode typed
//!    a column from the first non-null value among its first 10 rows.
//! 2. `ordered` / `order_keys` on the data pages. They must say the result is
//!    ordered exactly when the server guarantees its order: when the statement
//!    that produces the result ends in an ORDER BY (14.10 <order by and page
//!    statement>; 14.2 for a UNION's trailing ORDER BY). `FOR a IN [2,1,3]
//!    RETURN a ORDER BY a DESC` sent 3,2,1 with `ordered:false`.
//! 3. PROFILE: Geode's executor never spills, so no PROFILE may report a
//!    spill. With GEODE_SPILL_THRESHOLD_BYTES set, a version-1 PROFILE said
//!    `spill_reason:"threshold"` (and a spill counter of 1 for a sort,
//!    DISTINCT, UNION or GROUP BY) because its synthetic peak passed the
//!    threshold. docs/BINARY_PROTOCOL.md: the reason is present only when a
//!    spill counter is above 0.
//!
//! One server listens on both transports; every query runs on each, and the
//! protobuf value kinds it sends are checked against the declared types.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const geode = @import("geode");
const schema = @import("schema");
const util = @import("proto_test_util.zig");
const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;

const Transport = enum { quic, grpc };
/// SONNY-6782: plaintext gRPC is served in Debug only, so a release build
/// runs the QUIC half.
const transports: []const Transport = if (util.grpc_plaintext_served) &.{ .quic, .grpc } else &.{.quic};

/// The protobuf kind of a value as sent.
const Kind = enum { null, int, double, decimal, string, bool, bytes, list, map, node, edge, path, ext };

fn kindOf(v: schema.Value) Kind {
    const k = v.kind orelse return .null;
    return switch (k) {
        .null_val => .null,
        .int_val => .int,
        .double_val => .double,
        .bool_val => .bool,
        .string_val => .string,
        .decimal_val => .decimal,
        .bytes_val => .bytes,
        .list_val => .list,
        .map_val => .map,
        .node_val => .node,
        .edge_val => .edge,
        .path_val => .path,
        .ext_val => .ext,
    };
}

/// What a server sent for one query: the SCHEMA frame's types, each row's
/// value kinds (and the first column's integer or string, for the order
/// checks), and the data pages' ordering metadata.
const Raw = struct {
    a: std.mem.Allocator,
    types: std.ArrayList([]u8) = .empty,
    rows: std.ArrayList([]Kind) = .empty,
    first_ints: std.ArrayList(?i64) = .empty,
    first_strings: std.ArrayList(?[]u8) = .empty,
    ordered: bool = false,
    order_keys: std.ArrayList([]u8) = .empty,
    error_code: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn init(a: std.mem.Allocator) Raw {
        return .{ .a = a };
    }

    fn deinit(self: *Raw) void {
        for (self.types.items) |t| self.a.free(t);
        self.types.deinit(self.a);
        for (self.rows.items) |r| self.a.free(r);
        self.rows.deinit(self.a);
        self.first_ints.deinit(self.a);
        for (self.first_strings.items) |fs| if (fs) |x| self.a.free(x);
        self.first_strings.deinit(self.a);
        for (self.order_keys.items) |k| self.a.free(k);
        self.order_keys.deinit(self.a);
        if (self.error_code) |c| self.a.free(c);
        if (self.error_message) |m| self.a.free(m);
    }

    fn consumer(self: *Raw) query_runner.QueryEventConsumer {
        return .{ .context = self, .handleEventFn = handle };
    }

    fn handle(c: *query_runner.QueryEventConsumer, _: std.mem.Allocator, event: query_runner.QueryEvent, _: u64) anyerror!query_runner.QueryEventSummary {
        const self: *Raw = @ptrCast(@alignCast(c.context));
        switch (event) {
            .hello_failure => |m| {
                self.error_code = try self.a.dupe(u8, "28000");
                self.error_message = try self.a.dupe(u8, m);
                return .{ .stop = true };
            },
            .execute => |resp| {
                const payload = resp.payload orelse return .{};
                switch (payload) {
                    .schema => |def| {
                        for (def.columns.items) |col| try self.types.append(self.a, try self.a.dupe(u8, col.type));
                        return .{ .schema_received = true };
                    },
                    .page => |page| {
                        for (page.rows.items) |row| {
                            const kinds = try self.a.alloc(Kind, row.values.items.len);
                            for (row.values.items, kinds) |v, *k| k.* = kindOf(v);
                            try self.rows.append(self.a, kinds);
                            var first_int: ?i64 = null;
                            var first_string: ?[]u8 = null;
                            if (row.values.items.len > 0) if (row.values.items[0].kind) |k| switch (k) {
                                .int_val => |i| first_int = i.value,
                                .string_val => |sv| first_string = try self.a.dupe(u8, sv.value),
                                else => {},
                            };
                            try self.first_ints.append(self.a, first_int);
                            try self.first_strings.append(self.a, first_string);
                        }
                        self.ordered = page.ordered;
                        for (self.order_keys.items) |k| self.a.free(k);
                        self.order_keys.clearRetainingCapacity();
                        for (page.order_keys.items) |k| try self.order_keys.append(self.a, try self.a.dupe(u8, k));
                        return .{ .saw_page = true, .page_final = page.final };
                    },
                    .@"error" => |e| {
                        self.error_code = try self.a.dupe(u8, e.code);
                        self.error_message = try self.a.dupe(u8, e.message);
                        return .{ .stop = true };
                    },
                    else => return .{},
                }
            },
        }
    }
};

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    quic: util.QuicProtoClient,

    fn start(a: std.mem.Allocator, env: []const []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(a, quic_port);
        errdefer a.free(quic_addr);
        const grpc_addr = try util.formatAddr(a, grpc_port);
        errdefer a.free(grpc_addr);

        var full_env = std.ArrayList([]const u8).empty;
        defer full_env.deinit(a);
        try full_env.appendSlice(a, util.TestEnv.grpcPlaintext());
        try full_env.appendSlice(a, env);

        var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, full_env.items);
        errdefer handle.deinit();
        try util.waitForServerReady(a, quic_addr, 10000);

        var quic = try util.QuicProtoClient.connect(a, quic_addr);
        errdefer quic.deinit();
        var hq = try quic.hello(a, util.defaultUsername(), util.defaultPassword());
        hq.deinit(a);

        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr, .quic = quic };
    }

    fn stop(self: *Server, a: std.mem.Allocator) void {
        self.quic.deinit();
        self.handle.deinit();
        a.free(self.quic_addr);
        a.free(self.grpc_addr);
    }

    /// A gRPC session of its own for each query: the test client's HTTP/2
    /// connection answers one streamed query.
    fn grpcClient(self: *Server, a: std.mem.Allocator) !util.GrpcProtoClient {
        var grpc = try util.GrpcProtoClient.connect(a, self.grpc_addr);
        errdefer grpc.deinit();
        var hg = try grpc.hello(a, util.defaultUsername(), util.defaultPassword());
        hg.deinit(a);
        return grpc;
    }

    fn run(self: *Server, a: std.mem.Allocator, q: []const u8) !void {
        var r = try self.quic.executeAndCollect(a, q, util.emptyParams(), 100);
        defer r.deinit(a);
        if (r.error_code) |code| {
            std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
            return error.QueryFailed;
        }
    }

    fn raw(self: *Server, a: std.mem.Allocator, transport: Transport, q: []const u8, page_size: u32) !Raw {
        var result = Raw.init(a);
        errdefer result.deinit();
        var consumer = result.consumer();
        switch (transport) {
            .quic => {
                const Adapter = struct {
                    client: *util.QuicProtoClient,
                    fn send(proto: *query_runner.ProtocolClient, _: std.mem.Allocator, msg: schema.QuicClientMessage) anyerror!void {
                        const ad: *@This() = @ptrCast(@alignCast(proto.context));
                        try ad.client.writeMessage(msg);
                    }
                    fn read(proto: *query_runner.ProtocolClient, alloc: std.mem.Allocator, timeout_secs: u32) anyerror!schema.QuicServerMessage {
                        const ad: *@This() = @ptrCast(@alignCast(proto.context));
                        while (true) {
                            const packet = try ad.client.readPacketWait(alloc, .{ .while_server_alive_ms = @max(timeout_secs, 1) * 1000 });
                            const msg = packet.quic orelse return error.InvalidMessage;
                            switch (msg) {
                                .execute, .pull, .hello => return msg,
                                else => {},
                            }
                        }
                    }
                };
                var adapter = Adapter{ .client = &self.quic };
                var proto = query_runner.ProtocolClient{ .context = &adapter, .sendClientMessageFn = Adapter.send, .readServerMessageFn = Adapter.read };
                try query_runner.consumeQuery(a, &proto, .{
                    .session_id = self.quic.session_id,
                    .query_text = q,
                    .format = "json",
                    .timeout_secs = 10,
                    .page_size = page_size,
                    .params = util.emptyParams(),
                }, &consumer);
            },
            .grpc => {
                var grpc = try self.grpcClient(a);
                defer grpc.deinit();
                var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = grpc.stream };
                var transport_impl = adapter.asTransport();
                try query_runner.consumeQueryWithTransport(a, &transport_impl, .{
                    .session_id = grpc.session_id,
                    .query_text = q,
                    .format = "json",
                    .timeout_secs = 10,
                    .page_size = page_size,
                    .params = util.emptyParams(),
                }, &consumer);
            },
        }
        if (result.error_code) |code| {
            std.debug.print("{s} [{s}]: {s} {s}\n", .{ q, @tagName(transport), code, result.error_message orelse "" });
            return error.QueryFailed;
        }
        return result;
    }
};

/// The declared types that describe a value of this kind: its own type,
/// every type it combines into (22.19), and ANY.
fn declaredTypeCovers(declared: []const u8, k: Kind) bool {
    if (std.mem.eql(u8, declared, "ANY")) return true;
    const eq = struct {
        fn f(a: []const u8, names: []const []const u8) bool {
            for (names) |n| if (std.mem.eql(u8, a, n)) return true;
            return false;
        }
    }.f;
    return switch (k) {
        .null => true,
        .int => eq(declared, &.{ "INTEGER", "BIGINT", "SMALLINT", "DECIMAL", "DOUBLE", "REAL" }),
        .decimal => eq(declared, &.{ "DECIMAL", "DOUBLE", "REAL" }),
        .double => eq(declared, &.{ "DOUBLE", "REAL" }),
        .bool => eq(declared, &.{"BOOLEAN"}),
        .string => eq(declared, &.{ "STRING", "VARCHAR", "CHAR", "TEXT" }),
        .bytes => eq(declared, &.{"BYTEA"}),
        .list => eq(declared, &.{"LIST"}),
        .map => eq(declared, &.{"MAP"}),
        .node => eq(declared, &.{"NODE"}),
        .edge => eq(declared, &.{"RELATIONSHIP"}),
        .path => eq(declared, &.{"PATH"}),
        .ext => !eq(declared, &.{ "INTEGER", "BIGINT", "SMALLINT", "DECIMAL", "DOUBLE", "REAL", "STRING", "BOOLEAN", "NULL", "LIST", "MAP", "NODE", "RELATIONSHIP", "PATH" }),
    };
}

/// Every value sent is described by its column's declared type.
fn coverFailures(q: []const u8, transport: Transport, r: *const Raw) usize {
    var bad: usize = 0;
    for (r.rows.items) |row| for (row, 0..) |k, i| {
        const declared = if (i < r.types.items.len) r.types.items[i] else "";
        if (!declaredTypeCovers(declared, k)) {
            std.debug.print("{s} [{s}]: column {d} declared {s} holds {s}\n", .{ q, @tagName(transport), i, declared, @tagName(k) });
            bad += 1;
        }
    };
    return bad;
}

fn typeFailures(q: []const u8, transport: Transport, want: []const []const u8, got: []const []u8) usize {
    var ok = want.len == got.len;
    if (ok) for (want, got) |w, g| {
        if (!std.mem.eql(u8, w, g)) ok = false;
    };
    if (ok) return 0;
    std.debug.print("{s} [{s}] declared:", .{ q, @tagName(transport) });
    for (got) |g| std.debug.print(" {s}", .{g});
    std.debug.print("  want:", .{});
    for (want) |w| std.debug.print(" {s}", .{w});
    std.debug.print("\n", .{});
    return 1;
}

const TypeCase = struct {
    q: []const u8,
    types: []const []const u8,
};

const type_cases = [_]TypeCase{
    // 21.2: an exact numeric literal is exact numeric.
    .{ .q = "RETURN 1.25 AS a", .types = &.{"DECIMAL"} },
    .{ .q = "RETURN 1.25 AS a, 2 AS b, 'x' AS c, true AS d", .types = &.{ "DECIMAL", "INTEGER", "STRING", "BOOLEAN" } },
    // 14.2 / 22.19 SR 4 d ii 2: exact + exact numeric is exact.
    .{ .q = "RETURN 2 AS a UNION RETURN 1.25 AS a", .types = &.{"DECIMAL"} },
    .{ .q = "RETURN 1.25 AS a UNION RETURN 2 AS a", .types = &.{"DECIMAL"} },
    // 22.19 SR 4 d ii 1: an approximate numeric makes the column approximate.
    .{ .q = "RETURN 2 AS a UNION ALL RETURN CAST(1 AS DOUBLE) AS a", .types = &.{"DOUBLE"} },
    .{ .q = "RETURN 1.25 AS a UNION ALL RETURN CAST(1 AS DOUBLE) AS a", .types = &.{"DOUBLE"} },
    // 22.18 SR 9 c ii: different primary base types, the open dynamic union.
    .{ .q = "RETURN 'x' AS a UNION ALL RETURN 1 AS a", .types = &.{"ANY"} },
    .{ .q = "RETURN [1] AS a UNION ALL RETURN 1 AS a", .types = &.{"ANY"} },
    // 22.19 SR 3 / 4 a: NULL adds nothing; only NULL is the null type.
    .{ .q = "RETURN NULL AS a UNION ALL RETURN 1 AS a", .types = &.{"INTEGER"} },
    .{ .q = "RETURN NULL AS a", .types = &.{"NULL"} },
    // Every row, not the first 10.
    .{ .q = "FOR x IN [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12.5] RETURN x", .types = &.{"DECIMAL"} },
    .{ .q = "FOR x IN [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 'twelve'] RETURN x", .types = &.{"ANY"} },
    // ORDER BY over mixed rows: the order does not change the type.
    .{ .q = "FOR x IN [3, 1.5, 2] RETURN x ORDER BY x", .types = &.{"DECIMAL"} },
    .{ .q = "FOR x IN [3, 1.5, 2] RETURN x ORDER BY x DESC", .types = &.{"DECIMAL"} },
    // CASE branches of different types.
    .{ .q = "FOR x IN [1, 2] RETURN CASE WHEN x = 1 THEN 1 ELSE 2.5 END AS c", .types = &.{"DECIMAL"} },
    .{ .q = "FOR x IN [1, 2] RETURN CASE WHEN x = 1 THEN 1 ELSE 'two' END AS c", .types = &.{"ANY"} },
    // collect() of mixed values is a list (element types are not declared).
    .{ .q = "FOR x IN [1, 'a', 2.5] RETURN collect(x) AS c", .types = &.{"LIST"} },
    // OPTIONAL MATCH: its NULL rows add nothing; the later decimal counts.
    .{ .q = "MATCH (a:S6562Opt) OPTIONAL MATCH (a)-[:R]->(b) RETURN a.k AS k, b.v AS v ORDER BY k", .types = &.{ "INTEGER", "DECIMAL" } },
    .{ .q = "MATCH (a:S6562Opt) OPTIONAL MATCH (a)-[:NONE]->(b) RETURN b.v AS v", .types = &.{"NULL"} },
};

test "SONNY-6562: every declared column type is the combined type of the column's values (QUIC and gRPC)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var s = try Server.start(a, &.{});
    defer s.stop(a);
    // k = 1 has no edge (NULL), k = 2 an integer, k = 3 a decimal: the first
    // non-null value is an integer, the column holds a decimal.
    try s.run(a, "CREATE (:S6562Opt {k: 1})");
    try s.run(a, "CREATE (:S6562Opt {k: 2})-[:R]->(:S6562T {v: 7})");
    try s.run(a, "CREATE (:S6562Opt {k: 3})-[:R]->(:S6562T {v: 2.5})");

    var failures: usize = 0;
    for (type_cases) |c| {
        for (transports) |t| {
            var r = try s.raw(a, t, c.q, 100);
            defer r.deinit();
            failures += typeFailures(c.q, t, c.types, r.types.items);
            failures += coverFailures(c.q, t, &r);
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6562: a streamed node scan longer than its schema sample does not declare a type its later rows contradict" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var s = try Server.start(a, &.{});
    defer s.stop(a);
    // Eleven integers, then a decimal and a string: the QUIC node-scan stream
    // sends its schema frame before it has read these.
    var i: usize = 0;
    while (i < 11) : (i += 1) {
        var buf: [64]u8 = undefined;
        try s.run(a, try std.fmt.bufPrint(&buf, "CREATE (:S6562Scan {{v: {d}}})", .{i}));
    }
    try s.run(a, "CREATE (:S6562Scan {v: 2.5})");
    try s.run(a, "CREATE (:S6562Scan {v: 'late'})");

    var failures: usize = 0;
    const query = "MATCH (n:S6562Scan) RETURN n.v";
    for (transports) |t| {
        var r = try s.raw(a, t, query, 5);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 13), r.rows.items.len);
        failures += coverFailures(query, t, &r);
    }

    // A result the server has read whole declares the exact combined type.
    try s.run(a, "CREATE (:S6562Small {v: 1})");
    try s.run(a, "CREATE (:S6562Small {v: 2.5})");
    const small = "MATCH (n:S6562Small) RETURN n.v";
    for (transports) |t| {
        var r = try s.raw(a, t, small, 5);
        defer r.deinit();
        failures += typeFailures(small, t, &.{"DECIMAL"}, r.types.items);
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

const OrderCase = struct {
    q: []const u8,
    /// The keys the result is ordered by, or null when the server does not
    /// guarantee an order.
    keys: ?[]const []const u8,
    /// Ordered cases: whether the first column descends (the rows are
    /// checked against the claim).
    desc: bool = false,
};

const order_cases = [_]OrderCase{
    // 14.8 FOR, then 14.10: the RETURN's ORDER BY orders the result.
    .{ .q = "FOR a IN [2, 1, 3] RETURN a ORDER BY a DESC", .keys = &.{"a"}, .desc = true },
    .{ .q = "FOR a IN [2, 1, 3] RETURN a ORDER BY a", .keys = &.{"a"} },
    .{ .q = "FOR a IN [2, 1, 3] RETURN a", .keys = null },
    // A FOR whose body reads, its last RETURN ordered.
    .{ .q = "FOR x IN [1] MATCH (n:S6562Ord) RETURN n.k AS k ORDER BY k DESC", .keys = &.{"k"}, .desc = true },
    // The control: a single MATCH ... RETURN ... ORDER BY.
    .{ .q = "MATCH (n:S6562Ord) RETURN n.k AS k ORDER BY k", .keys = &.{"k"} },
    // A chain: the final part's ORDER BY orders the result.
    .{ .q = "MATCH (n:S6562Ord) WITH n MATCH (m:S6562Ord) WHERE m.k = n.k RETURN m.k AS k ORDER BY k DESC", .keys = &.{"k"}, .desc = true },
    .{ .q = "WITH 1 AS one MATCH (n:S6562Ord) RETURN n.k AS k ORDER BY k DESC", .keys = &.{"k"}, .desc = true },
    // A WITH's ORDER BY does not order the final result.
    .{ .q = "MATCH (n:S6562Ord) WITH n.k AS k ORDER BY k RETURN k", .keys = null },
    .{ .q = "WITH 3 AS x ORDER BY x WITH x RETURN x", .keys = null },
    // 14.2: a UNION's trailing ORDER BY orders the combined rows.
    .{ .q = "RETURN 2 AS a UNION RETURN 1 AS a UNION RETURN 3 AS a ORDER BY a", .keys = &.{"a"} },
    .{ .q = "RETURN 2 AS a UNION RETURN 1 AS a", .keys = null },
    // CALL ... RETURN ... ORDER BY.
    .{ .q = "CALL { MATCH (x:S6562Ord) RETURN x.k AS k } RETURN k ORDER BY k DESC", .keys = &.{"k"}, .desc = true },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label", .keys = &.{"label"} },
    .{ .q = "CALL db.labels() YIELD label RETURN label", .keys = null },
};

/// The first column, read as integers or strings, is in the claimed order.
fn firstColumnOrdered(r: *const Raw, desc: bool) bool {
    const n = r.rows.items.len;
    if (n < 2) return true;
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const order: std.math.Order = if (r.first_ints.items[i] != null and r.first_ints.items[i + 1] != null)
            std.math.order(r.first_ints.items[i].?, r.first_ints.items[i + 1].?)
        else if (r.first_strings.items[i] != null and r.first_strings.items[i + 1] != null)
            std.mem.order(u8, r.first_strings.items[i].?, r.first_strings.items[i + 1].?)
        else
            return false;
        if (desc and order == .lt) return false;
        if (!desc and order == .gt) return false;
    }
    return true;
}

fn orderFailures(c: OrderCase, t: Transport, r: *const Raw) usize {
    var failures: usize = 0;
    const want_ordered = c.keys != null;
    if (r.ordered != want_ordered) {
        std.debug.print("{s} [{s}]: ordered={} want {}\n", .{ c.q, @tagName(t), r.ordered, want_ordered });
        failures += 1;
    }
    if (c.keys) |keys| {
        var keys_ok = keys.len == r.order_keys.items.len;
        if (keys_ok) for (keys, r.order_keys.items) |w, g| {
            if (!std.mem.eql(u8, w, g)) keys_ok = false;
        };
        if (!keys_ok) {
            std.debug.print("{s} [{s}]: order_keys:", .{ c.q, @tagName(t) });
            for (r.order_keys.items) |k| std.debug.print(" {s}", .{k});
            std.debug.print("\n", .{});
            failures += 1;
        }
        if (r.rows.items.len < 2 or !firstColumnOrdered(r, c.desc)) {
            std.debug.print("{s} [{s}]: rows not in the claimed order ({d} rows)\n", .{ c.q, @tagName(t), r.rows.items.len });
            failures += 1;
        }
    } else if (r.order_keys.items.len != 0) {
        std.debug.print("{s} [{s}]: order_keys without an order\n", .{ c.q, @tagName(t) });
        failures += 1;
    }
    return failures;
}

test "SONNY-6562: ordered and order_keys are set exactly when the result's statement ends in an ORDER BY (QUIC and gRPC)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var s = try Server.start(a, &.{});
    defer s.stop(a);
    try s.run(a, "CREATE (:S6562Ord {k: 2})");
    try s.run(a, "CREATE (:S6562Ord {k: 1})");
    try s.run(a, "CREATE (:S6562Ord {k: 3})");
    try s.run(a, "CREATE (:S6562OrdB {k: 1})");

    var failures: usize = 0;
    for (order_cases) |c| {
        for (transports) |t| {
            var r = try s.raw(a, t, c.q, 100);
            defer r.deinit();
            failures += orderFailures(c, t, &r);
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

fn spillFailures(q: []const u8, t: Transport, json: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const spills = parsed.value.object.get("spills") orelse return error.MissingSpills;
    var counted: i64 = 0;
    for ([_][]const u8{ "sort_spills", "distinct_spills", "union_spills" }) |k| {
        if (spills.object.get(k)) |v| counted += v.integer;
    }
    if (parsed.value.object.get("hashagg_spills")) |v| counted += v.integer;
    const reasons = spills.object.get("spill_reason") != null or parsed.value.object.get("hashagg_spill_reason") != null;
    if (counted == 0 and !reasons) return 0;
    std.debug.print("{s} [{s}]: {s}\n", .{ q, @tagName(t), json });
    return 1;
}

const profile_queries = [_][]const u8{
    // A data change takes the version-1 payload (SONNY-6548's shape).
    "PROFILE CREATE (:S6562Spill {k: 1})",
    // And each operator a spill counter was made up for.
    "PROFILE RETURN DISTINCT 1 AS x, 1 AS y ORDER BY x LIMIT 5",
    "PROFILE RETURN 1 AS x UNION RETURN 2 AS x",
    "PROFILE RETURN 1 AS x GROUP BY x",
    "PROFILE MATCH (n:S6562Spill) RETURN n.k AS k ORDER BY k",
};

test "SONNY-6562: PROFILE reports no spill (the executor never spills) under a spill threshold (QUIC and gRPC)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var s = try Server.start(a, &.{"GEODE_SPILL_THRESHOLD_BYTES=1"});
    defer s.stop(a);

    var failures: usize = 0;
    for (profile_queries) |q| {
        const json = try s.quic.executeProfileJson(a, q);
        defer a.free(json);
        failures += try spillFailures(q, .quic, json);

        if (!util.grpc_plaintext_served) continue; // SONNY-6782: Debug-only plaintext gRPC
        var grpc = try s.grpcClient(a);
        defer grpc.deinit();
        var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = grpc.stream };
        var transport = adapter.asTransport();
        var result = try query_runner.collectQueryWithTransport(a, &transport, .{
            .session_id = grpc.session_id,
            .query_text = q,
            .format = "json",
            .timeout_secs = 10,
            .page_size = 100,
            .params = util.emptyParams(),
        });
        defer result.deinit();
        if (result.has_error) {
            std.debug.print("{s} [grpc]: {s} {s}\n", .{ q, result.error_status, result.error_message });
            return error.QueryFailed;
        }
        const payload = result.result_payload orelse return error.MissingProfile;
        failures += try spillFailures(q, .grpc, payload);
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6562: buildSchemaDefinition declares each column the 22.18 / 22.19 combination of all its values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Value = geode.value_types.Value;
    const dec = Value{ .Decimal = .{ .coeff = 125, .scale = 2 } };
    const Case = struct { values: []const Value, want: []const u8 };
    const empty_list: []Value = &.{};
    const cases = [_]Case{
        .{ .values = &.{ .{ .Int = 1 }, dec }, .want = "DECIMAL" },
        .{ .values = &.{ dec, .{ .Int = 1 } }, .want = "DECIMAL" },
        .{ .values = &.{ .{ .SmallInt = 1 }, .{ .BigInt = 2 } }, .want = "BIGINT" },
        .{ .values = &.{ .{ .SmallInt = 1 }, .{ .Int = 2 } }, .want = "INTEGER" },
        .{ .values = &.{ .{ .Int = 1 }, .{ .Double = 2 } }, .want = "DOUBLE" },
        .{ .values = &.{ dec, .{ .Real = 2 } }, .want = "DOUBLE" },
        .{ .values = &.{ .{ .Real = 1 }, .{ .Real = 2 } }, .want = "REAL" },
        .{ .values = &.{ .{ .Real = 1 }, .{ .Double = 2 } }, .want = "DOUBLE" },
        .{ .values = &.{ .Null, .{ .Int = 1 }, .Null }, .want = "INTEGER" },
        .{ .values = &.{ .Null, .Null }, .want = "NULL" },
        .{ .values = &.{}, .want = "NULL" },
        .{ .values = &.{ .{ .Str = "a" }, .{ .Text = "b" } }, .want = "STRING" },
        .{ .values = &.{ .{ .Bool = true }, .{ .Bool = false } }, .want = "BOOLEAN" },
        .{ .values = &.{ .{ .Str = "a" }, .{ .Int = 1 } }, .want = "ANY" },
        .{ .values = &.{ .{ .Bool = true }, .{ .Int = 1 } }, .want = "ANY" },
        .{ .values = &.{ .{ .List = empty_list }, .{ .Int = 1 } }, .want = "ANY" },
        .{ .values = &.{ .{ .List = empty_list }, .{ .List = empty_list } }, .want = "LIST" },
        // ANY absorbs everything after it.
        .{ .values = &.{ .{ .Str = "a" }, .{ .Int = 1 }, dec }, .want = "ANY" },
    };
    for (cases) |c| {
        const rows = try a.alloc([]Value, c.values.len);
        for (c.values, rows) |v, *row| {
            row.* = try a.alloc(Value, 1);
            row.*[0] = v;
        }
        var columns = [_][]const u8{"c"};
        const result = geode.execution.ExecutionResult{ .columns = &columns, .rows = rows, .flags = .empty };
        const def = try geode.proto_util.buildSchemaDefinition(a, &result);
        try testing.expectEqualStrings(c.want, def.columns.items[0].type);
    }
}
