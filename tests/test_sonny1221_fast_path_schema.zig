// SONNY-1221 (GEO-UP-008) reproduction / regression: the engine-direct
// node-scan fast path reported every projected column as type NULL.
//
// `src/server/node_scan_stream.zig` serves a single-node-pattern MATCH whose
// RETURN list is bare property references straight from the storage adapter,
// on both transports (the `.rows` arm of `server/quic_connection_handler.zig`
// and of `transport/grpc_server.zig`). Each transport sends the schema frame
// BEFORE it builds any page, and `NodeScanStream.buildSchema` hard-coded "NULL"
// for every projected column. The executor path types each column from its
// first rows (`proto_util.buildSchemaDefinition` -> `inferColumnType`: the
// first non-null value among the first 10 rows), so for the same query the
// executor answered STRING / INTEGER and the fast path NULL / NULL.
//
// Every query below is also run through the executor
// (`executeStatementWithContext` + `proto_util.buildSchemaDefinition`), and the
// fast path must report exactly the executor's types: STRING / INTEGER for set
// properties (a null in some rows does not hide the type), and NULL for a
// column that no row sets.
//
// Transports:
//   * QUIC over a real `geode serve --data-dir` (an authenticated session with
//     no RLS policy, so the fast path serves the read).
//   * gRPC in process, through the real Execute and Pull handlers. Over a real
//     `geode serve` an authenticated gRPC session never reaches the fast path
//     (the global RLS filter engine is always installed there), so in process
//     is the only way to exercise that handler's fast-path schema frame. The
//     test asserts the session really holds a node-scan stream.
//
// The fix builds the frame's sample rows before the frame
// (`NodeScanStream.prefetchSchemaSample`) and serves them as the first rows.
// The stream tests at the end pin that: every row exactly once, in the same
// order and page boundaries as without the prefetch, at any page size; no leak
// when a stream is dropped or rewound with prefetched rows pending; and a
// bare-node column's node moving with its row.
//
// CANARY: REQ=REQ-SONNY-1221-FAST-PATH-SCHEMA; FEATURE="EngineDirectProjectionSchema"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1221_fast_path_schema.zig; OWNER=engine; UPDATED=2026-09-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const logging = @import("logging");
const grpc = @import("grpc_impl").impl;
const util = @import("proto_test_util.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const proto_util = geode.proto_util;
const user_mgmt = geode.user_management;

const seed_queries = [_][]const u8{
    "CREATE (:L {s: 'a', i: 1})",
    "CREATE (:L {s: 'b', i: 2})",
    // `i` unset here: a null in some rows must not hide the column's type.
    "CREATE (:L {s: 'c'})",
};

const Case = struct {
    query: []const u8,
    /// What the executor path reports for this query over `seed_queries`
    /// (checked against the executor itself in the gRPC test).
    types: []const []const u8,
};

const cases = [_]Case{
    .{ .query = "MATCH (n:L) RETURN n.s, n.i", .types = &.{ "STRING", "INTEGER" } },
    // No row sets `missing`: an all-null column still reports NULL.
    .{ .query = "MATCH (n:L) RETURN n.s, n.missing", .types = &.{ "STRING", "NULL" } },
};

/// Pin the engine logger to `.fatal`: the in-process handlers log every request
/// at info, which the build runner would echo back as piped stderr.
fn silenceEngineLogs() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn expectTypes(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len != actual.len) {
        std.debug.print("column count: expected {d}, found {d}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }
    for (expected, actual, 0..) |e, a, i| {
        if (!std.mem.eql(u8, e, a)) {
            std.debug.print("column {d}: expected type {s}, found {s}\n", .{ i, e, a });
            return error.TestExpectedEqual;
        }
    }
}

/// In-process PERSISTED deployment (`--data-dir`): the storage adapter exists,
/// so the engine-direct fast path is live (SONNY-1218 declines without it).
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        // Fail loud rather than prove nothing: without the adapter every read
        // below would be the executor's.
        if (graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn seed(self: *Harness) !void {
        for (seed_queries) |q| {
            var r = try self.run(q);
            r.deinit(self.arena.allocator());
        }
    }

    /// The executor path's schema types for `query` (arena-owned).
    fn executorTypes(self: *Harness, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        var result = try self.run(query);
        defer result.deinit(aa);
        const def = try proto_util.buildSchemaDefinition(aa, &result);
        const types = try aa.alloc([]const u8, def.columns.items.len);
        for (def.columns.items, 0..) |col, i| types[i] = col.type;
        return types;
    }
};

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

fn failWithError(what: []const u8, e: schema.Error) error{ServerError} {
    std.debug.print("{s} failed: {s}\n", .{ what, e.message });
    return error.ServerError;
}

// ---------------------------------------------------------------------------
// gRPC: the real Execute + Pull handlers, in process.
// ---------------------------------------------------------------------------
test "SONNY-1221: gRPC fast-path schema frame reports the executor's column types" {
    silenceEngineLogs();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    // An unauthenticated session: auth off, no global RLS filter engine in
    // process, so the `.rows` arm takes the node-scan fast path.
    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);

    // Everything the handlers allocate lives in this arena. It outlives the
    // session store, whose teardown frees the session's stream into it.
    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();

    var store = grpc.SessionStore.init(ga, .{});
    defer store.deinit();
    grpc.setSessionStore(&store);
    defer grpc.setSessionStore(null);
    const session_id = try store.createSession("", "", null, null, null, false, 0);
    const entry = store.getEntry(session_id) orelse return error.SessionMissing;

    for (cases) |case| {
        const executor_types = try h.executorTypes(case.query);
        try expectTypes(case.types, executor_types);

        const req = try encodeProto(ga, schema.ExecuteRequest{
            .session_id = session_id,
            .query = case.query,
            .params = .empty,
        });
        const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
        const def = switch (resp.payload orelse return error.MissingPayload) {
            .schema => |d| d,
            .@"error" => |e| return failWithError("Execute", e),
            else => return error.UnexpectedPayload,
        };

        // The fast path served it: the session holds a node-scan stream, not an
        // executor result.
        try testing.expect(entry.state.active_node_scan_stream != null);
        try testing.expect(entry.state.active_result_values == null);

        var types = try ga.alloc([]const u8, def.columns.items.len);
        for (def.columns.items, 0..) |col, i| types[i] = col.type;
        try expectTypes(executor_types, types);

        // The rows still arrive, each exactly once, across several pages.
        var seen_s = std.ArrayList([]const u8).empty;
        var seen_second_non_null: usize = 0;
        var pulls: usize = 0;
        while (true) : (pulls += 1) {
            if (pulls > 16) return error.PullNeverFinished;
            const pull_req = try encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 2 });
            const pull = try decodeProto(schema.PullResponse, ga, try grpc.handlePull(pull_req, ga));
            const page_resp = pull.response orelse return error.MissingPayload;
            const page = switch (page_resp.payload orelse return error.MissingPayload) {
                .page => |p| p,
                .@"error" => |e| return failWithError("Pull", e),
                else => return error.UnexpectedPayload,
            };
            try testing.expect(page.rows.items.len <= 2);
            for (page.rows.items) |row| {
                try testing.expectEqual(@as(usize, 2), row.values.items.len);
                const s = row.values.items[0].kind orelse return error.NullS;
                try seen_s.append(ga, switch (s) {
                    .string_val => |v| v.value,
                    else => return error.UnexpectedValueKind,
                });
                if (row.values.items[1].kind) |k| {
                    if (k != .null_val) seen_second_non_null += 1;
                }
            }
            if (page.final) break;
        }
        std.mem.sort([]const u8, seen_s.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        try testing.expectEqual(@as(usize, 3), seen_s.items.len);
        try testing.expectEqualStrings("a", seen_s.items[0]);
        try testing.expectEqualStrings("b", seen_s.items[1]);
        try testing.expectEqualStrings("c", seen_s.items[2]);
        // `i` is set on two of the three nodes; `missing` on none.
        const want_non_null: usize = if (std.mem.eql(u8, case.types[1], "NULL")) 0 else 2;
        try testing.expectEqual(want_non_null, seen_second_non_null);
    }
}

// ---------------------------------------------------------------------------
// QUIC: a real server, a real client.
// ---------------------------------------------------------------------------
test "SONNY-1221: QUIC fast-path schema frame reports the executor's column types" {
    // These reads take the node-scan fast path, not the executor. The QUIC
    // `.rows` arm streams a query through `node_scan_stream` when the storage
    // adapter exists (`--data-dir` below), the session has no tenant scope, the
    // program has no effectful preamble, and no RLS policy is installed
    // (`authenticatedReadNeedsRlsSnapshot`: an authenticated session alone
    // does not force the snapshot path). All four hold for this fresh server
    // and these queries, and the gRPC test above asserts that the same query
    // shapes are served by a node-scan stream. Nothing on the wire tells the
    // two paths apart once their types agree. The evidence is the RED run:
    // before the fix this test failed with "expected type STRING, found
    // NULL", and only the fast path ever typed these columns NULL.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const addr = try util.formatAddr(allocator, try util.getRandomPort());
    defer allocator.free(addr);

    // `--data-dir` makes it a persisted deployment, so the fast path is live.
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, null);
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 120_000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    const hello_ok = hello.success;
    hello.deinit(allocator);
    try testing.expect(hello_ok);

    for (seed_queries) |q| {
        var r = try client.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 60);
        defer r.deinit(allocator);
        if (r.error_code) |code| {
            std.debug.print("seed {s} failed: {s} {s}\n", .{ q, code, r.error_message orelse "" });
            return error.SeedFailed;
        }
    }

    for (cases) |case| {
        var res = try client.executeAndCollectWithTimeout(allocator, case.query, util.emptyParams(), 100, 60);
        defer res.deinit(allocator);
        if (res.error_code) |code| {
            std.debug.print("{s} failed: {s} {s}\n", .{ case.query, code, res.error_message orelse "" });
            return error.QueryFailed;
        }
        try expectTypes(case.types, res.column_types);
        try testing.expectEqual(@as(usize, 3), res.rows.len);
    }
}

// ---------------------------------------------------------------------------
// The stream: rows prefetched for the schema frame are served exactly once.
// ---------------------------------------------------------------------------

/// More rows than one type sample (10), spread over several small pages.
const many: usize = 25;
const many_query = "MATCH (n:M) RETURN n.s, n.i";

fn seedMany(h: *Harness) !void {
    const aa = h.arena.allocator();
    for (0..many) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:M {{s: 's{d:0>2}', i: {d}}})", .{ i, i }));
        r.deinit(aa);
    }
}

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

/// A fast-path stream for `src`. `query_arena` must outlive it: the stream
/// borrows column names from the parsed query.
fn openStream(
    h: *Harness,
    allocator: std.mem.Allocator,
    query_arena: *std.heap.ArenaAllocator,
    src: []const u8,
) !node_scan_stream.NodeScanStream {
    const q = try parseQuery(query_arena, src);
    return (try node_scan_stream.prepare(allocator, q, h.ctx, &.{}, &.{}, &.{})) orelse error.FastPathDeclined;
}

fn schemaTypes(arena: std.mem.Allocator, def: schema.SchemaDefinition) ![]const []const u8 {
    const types = try arena.alloc([]const u8, def.columns.items.len);
    for (def.columns.items, 0..) |col, i| types[i] = col.type;
    return types;
}

/// Page `stream` to its end with `page_size` and return column 0 (`n.s`) in
/// serve order, owned by `allocator`. Every page but the last must be full.
fn drainColumn0(stream: *node_scan_stream.NodeScanStream, allocator: std.mem.Allocator, page_size: usize) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    const full = if (page_size == 0) node_scan_stream.default_page_rows else page_size;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, page_size);
        defer page.result.deinit(allocator);
        if (!page.final) try testing.expectEqual(full, page.result.rows.len);
        for (page.result.rows) |row| try out.append(allocator, try allocator.dupe(u8, row[0].Str));
        if (page.final) break;
    }
    try testing.expect(!stream.hasRemaining());
    return out.toOwnedSlice(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

fn expectDistinct(items: []const []const u8) !void {
    for (items, 0..) |s, i| {
        for (items[i + 1 ..]) |t| try testing.expect(!std.mem.eql(u8, s, t));
    }
}

test "SONNY-1221: rows prefetched for the schema frame are served once, in order, at any page size" {
    silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();
    try seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    // Baseline: no prefetch, one page.
    var plain = try openStream(&h, allocator, &qa, many_query);
    defer plain.deinit();
    const baseline = try drainColumn0(&plain, allocator, 0);
    defer freeStrings(allocator, baseline);
    try testing.expectEqual(many, baseline.len);
    try expectDistinct(baseline);

    const executor_types = try h.executorTypes(many_query);
    // 1..3: the sample spans several pages; 10: exactly one page; 11: the
    // sample plus one scanned row; 0: the default page size, everything at once.
    for ([_]usize{ 1, 2, 3, 7, 10, 11, 0 }) |page_size| {
        var stream = try openStream(&h, allocator, &qa, many_query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
        try testing.expect(stream.hasRemaining());
        try expectTypes(executor_types, try schemaTypes(qa.allocator(), try stream.buildSchema(qa.allocator())));

        const got = try drainColumn0(&stream, allocator, page_size);
        defer freeStrings(allocator, got);
        try testing.expectEqual(baseline.len, got.len);
        for (baseline, got) |want, have| try testing.expectEqualStrings(want, have);
    }
}

test "SONNY-1221: a stream dropped or rewound with prefetched rows pending leaks nothing and repeats nothing" {
    silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();
    try seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    // Dropped before any page was built.
    {
        var stream = try openStream(&h, allocator, &qa, many_query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
    }
    // Dropped after one page took part of the prefetched rows.
    {
        var stream = try openStream(&h, allocator, &qa, many_query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
        var page = try stream.buildNextPage(allocator, 3);
        page.result.deinit(allocator);
    }
    // Rewound after one page: the same rows as a stream that was never
    // rewound, in the same order, each once. Without a WHERE the OFFSET is
    // where the cursor STARTS (slot collection is bounded by OFFSET+LIMIT), so
    // a rewind must go back there, not to slot 0.
    for ([_][]const u8{ many_query, "MATCH (n:M) RETURN n.s, n.i SKIP 5 LIMIT 3" }) |query| {
        var plain = try openStream(&h, allocator, &qa, query);
        defer plain.deinit();
        const want = try drainColumn0(&plain, allocator, 0);
        defer freeStrings(allocator, want);

        var stream = try openStream(&h, allocator, &qa, query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
        var page = try stream.buildNextPage(allocator, 1);
        page.result.deinit(allocator);
        stream.rewind();
        const got = try drainColumn0(&stream, allocator, 2);
        defer freeStrings(allocator, got);
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "SONNY-1221: a prefetched row's bare node moves with the row" {
    silenceEngineLogs();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // Catches a node destroyed twice (by the prefetched rows and by the page
    // that served its row) or destroyed while its row is still being served.
    // Deliberately never deinit'd: a page frees a projected node only
    // shallowly (`OwnedGraphEntities.deinit` destroys the struct, not its
    // labels, properties or graph name), a separate pre-existing issue whose
    // leak report would otherwise fail this test.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var stream = try openStream(&h, allocator, &qa, "MATCH (n:M) RETURN n, n.s");
    defer stream.deinit();
    try stream.prefetchSchemaSample(allocator);
    try expectTypes(&.{ "NODE", "STRING" }, try schemaTypes(qa.allocator(), try stream.buildSchema(qa.allocator())));

    var seen: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, 3);
        defer page.result.deinit(allocator);
        for (page.result.rows) |row| {
            // The node is alive and is this row's node.
            const s = row[0].Node.properties.get("s") orelse return error.NodePropertyMissing;
            try testing.expectEqualStrings(row[1].Str, s.String);
            seen += 1;
        }
        if (page.final) break;
    }
    try testing.expectEqual(many, seen);
}
