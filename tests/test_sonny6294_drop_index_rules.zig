// SONNY-6294 regression: DROP INDEX is deterministic, locks the graph it
// changes, and its "not found" errors are 42704.
//
//   (1) CREATE INDEX accepted one index name on two labels of a graph, and
//       DROP INDEX <name> then dropped whichever row hash iteration met
//       first. DROP INDEX names an index by name alone, and the fulltext and
//       vector runtimes are keyed by name, so a name identifies ONE index of
//       a graph: a second CREATE INDEX with the name in the same graph (any
//       label) is refused (42P07 DuplicateIndex; a no-op under IF NOT
//       EXISTS), and CREATE CONSTRAINT likewise (42710
//       ConstraintAlreadyExists). A catalog written before this rule may
//       hold one name on several labels: DROP INDEX drops all of them in the
//       scope it resolves (the graph's own rows, else the engine-wide
//       rows), as DROP CONSTRAINT does (SONNY-6270), and says so.
//   (2) The handlers locked the DEFAULT graph for every DROP INDEX (it might
//       be a fulltext index, whose engine lives there), so a DROP INDEX in
//       graph g ran beside g's writers and blocked default's. It now locks
//       the session's graph, as CREATE INDEX (non-fulltext) and constraint
//       DDL do. A fulltext index lives in the default graph: dropping one
//       from another graph's session is refused (0A000; `USE GRAPH default;
//       DROP INDEX <name>` drops it, under default's lock).
//   (3) IndexNotFound and ConstraintNotFound reached clients as 58000
//       (system error). They are 42704 (undefined_object).
//
// Real executor, catalog, gRPC handler and graph locks; no mocks.
//
// CANARY: REQ=REQ-SONNY-6294-DROP-INDEX-RULES; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6294_drop_index_rules.zig; OWNER=catalog; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const catalog_mod = geode.catalog;
const query_traits = geode.query_traits;
const proto_util = geode.proto_util;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const default_graph = graph_store.DEFAULT_GRAPH_NAME;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// The executor harness of tests/test_sonny6270_drop_constraint.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator, persisted: bool) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer if (tmp) |*t| t.cleanup();
        errdefer if (data_dir) |d| allocator.free(d);
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
        }

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        if (self.data_dir) |d| self.allocator.free(d);
        self.arena.deinit();
        if (self.tmp) |*t| t.cleanup();
    }

    fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn cat(self: *Harness) *catalog_mod.Catalog {
        return self.ctx.catalog;
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn runf(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        try self.run(try std.fmt.allocPrint(self.arena.allocator(), fmt, args));
    }

    fn execf(self: *Harness, comptime fmt: []const u8, args: anytype) !execution.ExecutionResult {
        return self.exec(try std.fmt.allocPrint(self.arena.allocator(), fmt, args));
    }

    fn expectRefusalf(self: *Harness, expected: anyerror, comptime fmt: []const u8, args: anytype) !void {
        const query = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, @errorName(expected) });
            return error.ExpectedRefusal;
        } else |err| {
            if (err != expected) {
                std.debug.print("{s}: refused with {s}, expected {s}\n", .{ query, @errorName(err), @errorName(expected) });
                return error.WrongRefusal;
            }
        }
    }

    /// Index rows named `name`, in any graph; `label` (if given) is set to
    /// the label of the last one met.
    fn indexRows(self: *Harness, name: []const u8, label: ?*[]const u8) usize {
        const c = self.cat();
        c.rwlock.lockSharedUncancelable(io());
        defer c.rwlock.unlockShared(io());
        var n: usize = 0;
        var it = c.indexes.valueIterator();
        while (it.next()) |row| {
            if (!std.mem.eql(u8, row.name, name)) continue;
            n += 1;
            if (label) |l| l.* = row.table_name;
        }
        return n;
    }

    fn constraintRows(self: *Harness, name: []const u8, label: ?*[]const u8) usize {
        const c = self.cat();
        c.rwlock.lockSharedUncancelable(io());
        defer c.rwlock.unlockShared(io());
        var n: usize = 0;
        var it = c.constraints.valueIterator();
        while (it.next()) |row| {
            if (!std.mem.eql(u8, row.name, name)) continue;
            n += 1;
            if (label) |l| l.* = row.label;
        }
        return n;
    }

    /// An index row as a catalog written before SONNY-6294 may hold it: the
    /// name on a further label of the graph (CREATE INDEX now refuses that).
    fn plantIndexRow(self: *Harness, graph: []const u8, label: []const u8, name: []const u8) !void {
        const c = self.cat();
        const a = c.allocator;
        const cols = try a.alloc([]const u8, 1);
        cols[0] = try a.dupe(u8, "k");
        const info = catalog_mod.IndexInfo{
            .name = try a.dupe(u8, name),
            .index_type = try a.dupe(u8, "btree"),
            .table_name = try a.dupe(u8, label),
            .columns = cols,
            .graph = try a.dupe(u8, graph),
        };
        const key = try std.fmt.allocPrint(a, "{s}\x1f{s}:{s}", .{ graph, label, name });
        c.rwlock.lockUncancelable(io());
        defer c.rwlock.unlock(io());
        try c.indexes.put(key, info);
    }
};

/// Labels in an order that depends on `run`: rotated and, on odd runs,
/// reversed, so CREATE order and hash order both vary.
fn labelsFor(run: usize, out: *[3][]const u8) void {
    const base = [_][]const u8{ "Alpha6294", "Beta6294", "Gamma6294" };
    for (0..3) |i| out[i] = base[(i + run) % 3];
    if (run % 2 == 1) std.mem.reverse([]const u8, out);
}

test "SONNY-6294 (1): an index or constraint name is one object per graph: a second CREATE on another label is refused, in every run" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.run("CREATE GRAPH g6294");

    for (0..20) |run| {
        var labels: [3][]const u8 = undefined;
        labelsFor(run, &labels);

        try h.runf("CREATE INDEX idx_dup_{d} FOR (n:{s}) ON (n.k)", .{ run, labels[0] });
        try h.expectRefusalf(error.DuplicateIndex, "CREATE INDEX idx_dup_{d} FOR (n:{s}) ON (n.k)", .{ run, labels[1] });
        try h.expectRefusalf(error.DuplicateIndex, "CREATE INDEX idx_dup_{d} FOR (n:{s}) ON (n.j)", .{ run, labels[2] });
        // IF NOT EXISTS: the name exists, nothing is created.
        try h.runf("CREATE INDEX IF NOT EXISTS idx_dup_{d} FOR (n:{s}) ON (n.k)", .{ run, labels[1] });
        var label: []const u8 = "";
        try testing.expectEqual(@as(usize, 1), h.indexRows(try std.fmt.allocPrint(h.arena.allocator(), "idx_dup_{d}", .{run}), &label));
        try testing.expectEqualStrings(labels[0], label);

        // Another graph is another namespace (SONNY-1319).
        try h.run("USE GRAPH g6294");
        try h.runf("CREATE INDEX idx_dup_{d} FOR (n:{s}) ON (n.k)", .{ run, labels[1] });
        try h.run("USE GRAPH default");

        // DROP INDEX drops the one index of that name in the graph.
        try h.runf("DROP INDEX idx_dup_{d}", .{run});
        try testing.expectEqual(@as(usize, 1), h.indexRows(try std.fmt.allocPrint(h.arena.allocator(), "idx_dup_{d}", .{run}), null));

        // Constraints: the same rule, checked before a UNIQUE constraint
        // validates the data.
        try h.runf("CREATE CONSTRAINT c_dup_{d} FOR (n:{s}) REQUIRE n.k IS NOT NULL", .{ run, labels[0] });
        try h.expectRefusalf(error.ConstraintAlreadyExists, "CREATE CONSTRAINT c_dup_{d} FOR (n:{s}) REQUIRE n.k IS UNIQUE", .{ run, labels[1] });
        try h.expectRefusalf(error.ConstraintAlreadyExists, "CREATE CONSTRAINT c_dup_{d} FOR (n:{s}) REQUIRE n.k IS NOT NULL", .{ run, labels[2] });
        try h.runf("CREATE CONSTRAINT IF NOT EXISTS c_dup_{d} FOR (n:{s}) REQUIRE n.k IS UNIQUE", .{ run, labels[1] });
        try testing.expectEqual(@as(usize, 1), h.constraintRows(try std.fmt.allocPrint(h.arena.allocator(), "c_dup_{d}", .{run}), &label));
        try testing.expectEqualStrings(labels[0], label);
        try h.runf("DROP CONSTRAINT c_dup_{d}", .{run});
        try testing.expectEqual(@as(usize, 0), h.constraintRows(try std.fmt.allocPrint(h.arena.allocator(), "c_dup_{d}", .{run}), null));
    }
}

test "SONNY-6294 (1): a name a legacy catalog holds on several labels is dropped on all of them, in every run, and DROP says so" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.run("CREATE GRAPH g6294l");

    for (0..20) |run| {
        var labels: [3][]const u8 = undefined;
        labelsFor(run, &labels);
        const aa = h.arena.allocator();
        const name = try std.fmt.allocPrint(aa, "legacy_{d}", .{run});
        const keep = try std.fmt.allocPrint(aa, "keep_{d}", .{run});

        // The graph's own rows on three labels (planted in a run-dependent
        // order), an engine-wide row of the name, another graph's row of the
        // name, and an unrelated index.
        for (labels) |l| try h.plantIndexRow(default_graph, l, name);
        try h.plantIndexRow(catalog_mod.ENGINE_WIDE_GRAPH, "Wide6294", name);
        try h.plantIndexRow("g6294l", labels[0], name);
        try h.runf("CREATE INDEX {s} FOR (n:{s}) ON (n.k)", .{ keep, labels[0] });
        try testing.expectEqual(@as(usize, 5), h.indexRows(name, null));

        // First DROP: the graph's own three rows, all of them.
        const res = try h.execf("DROP INDEX {s}", .{name});
        try testing.expectEqual(@as(usize, 2), h.indexRows(name, null));
        var noted = false;
        for (res.flags.items) |flag| {
            if (std.mem.indexOf(u8, flag, "DROP INDEX removed") != null) noted = true;
        }
        if (!noted) {
            std.debug.print("run {d}: DROP INDEX of a name on several labels gave no note\n", .{run});
            return error.MissingNote;
        }
        // Second DROP: the engine-wide row (the default graph's catalog has
        // it too). Another graph's row stays.
        try h.runf("DROP INDEX {s}", .{name});
        try testing.expectEqual(@as(usize, 1), h.indexRows(name, null));
        try h.expectRefusalf(error.IndexNotFound, "DROP INDEX {s}", .{name});
        try testing.expectEqual(@as(usize, 1), h.indexRows(keep, null));

        try h.run("USE GRAPH g6294l");
        try h.runf("DROP INDEX {s}", .{name});
        try h.run("USE GRAPH default");
        try testing.expectEqual(@as(usize, 0), h.indexRows(name, null));
        try h.runf("DROP INDEX {s}", .{keep});
    }
}

test "SONNY-6294 (1): legacy duplicate rows are dropped together, durably" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.plantIndexRow(default_graph, "Alpha6294", "legacy_durable");
    try h.plantIndexRow(default_graph, "Beta6294", "legacy_durable");
    // Saved with the next catalog change.
    try h.run("CREATE INDEX durable_keep FOR (n:Alpha6294) ON (n.k)");
    try h.restart();
    try testing.expectEqual(@as(usize, 2), h.indexRows("legacy_durable", null));

    try h.run("DROP INDEX legacy_durable");
    try testing.expectEqual(@as(usize, 0), h.indexRows("legacy_durable", null));
    try h.restart();
    try testing.expectEqual(@as(usize, 0), h.indexRows("legacy_durable", null));
    try testing.expectEqual(@as(usize, 1), h.indexRows("durable_keep", null));
}

test "SONNY-6294 (2): DROP INDEX counts as a statement on the session's graph" {
    const Case = struct { query: []const u8, session: []const u8, lock: []const u8 };
    const cases = [_]Case{
        .{ .query = "DROP INDEX gi", .session = "g2", .lock = "g2" },
        .{ .query = "DROP INDEX IF EXISTS gi", .session = "g2", .lock = "g2" },
        .{ .query = "DROP INDEX gi", .session = default_graph, .lock = default_graph },
        .{ .query = "USE GRAPH g2; DROP INDEX gi", .session = default_graph, .lock = "g2" },
        .{ .query = "USE GRAPH default; DROP INDEX gi", .session = "g2", .lock = default_graph },
        // As constraint DDL and non-fulltext CREATE INDEX are.
        .{ .query = "DROP CONSTRAINT gc", .session = "g2", .lock = "g2" },
        .{ .query = "CREATE INDEX gi FOR (n:Item) ON (n.k)", .session = "g2", .lock = "g2" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        var parsed = try geode.parseGql(c.query, testing.allocator);
        defer parsed.deinit();
        const analysis = query_traits.analyzeProgram(&parsed.program);
        const plan = query_traits.statementPlan(&parsed.program, &analysis, c.session, default_graph, .grpc);
        if (!std.mem.eql(u8, plan.lock_graph, c.lock) or plan.spans_graphs) {
            std.debug.print("{s} (session {s}): expected lock {s}, got lock {s} spans={}\n", .{ c.query, c.session, c.lock, plan.lock_graph, plan.spans_graphs });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Holds `graph`'s read lock for `hold_ms`, then lets go.
const Holder = struct {
    graph: []const u8,
    hold_ms: u64 = 400,
    held: std.atomic.Value(bool) = .init(false),
    letting_go: std.atomic.Value(bool) = .init(false),

    fn go(self: *Holder) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        sleepMs(self.hold_ms);
        self.letting_go.store(true, .release);
        graph_store.releaseGraphLock(lock);
    }

    fn start(self: *Holder) !std.Thread {
        const t = try std.Thread.spawn(.{}, go, .{self});
        while (!self.held.load(.acquire)) sleepMs(1);
        return t;
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

fn execute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

fn expectWireCode(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            if (!std.mem.eql(u8, e.code, code)) {
                std.debug.print("{s}: {s} {s}; expected {s}\n", .{ query, e.code, e.message, code });
                return error.WrongSqlstate;
            }
        },
        else => {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
            return error.ExpectedRefusal;
        },
    }
}

/// `query` while another thread holds `graph`'s read lock for 400 ms: true
/// when it returned only after the lock was let go (it needed `graph`'s
/// write lock).
fn waitsFor(ga: std.mem.Allocator, session_id: []const u8, graph: []const u8, query: []const u8) !bool {
    var holder: Holder = .{ .graph = graph };
    const t = try holder.start();
    defer t.join();
    try expectRuns(ga, session_id, query);
    return holder.letting_go.load(.acquire);
}

test "SONNY-6294 (2)+(3): over gRPC, DROP INDEX in a named graph holds that graph's write lock, not default's; fulltext stays in default; not-found is 42704" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g2");
    try h.seed(&.{"CREATE (:Doc {body: 'the quick brown fox'})"});

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    const allow_all_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(allow_all_was);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const s = try sessions.createSession("indexer", "", null, null, null, false, 0);
    try expectRuns(ga, s, "USE GRAPH g2");

    // g2's own index: DROP INDEX waits for g2's readers ...
    try expectRuns(ga, s, "CREATE INDEX g2_idx FOR (n:Item) ON (n.k)");
    if (!try waitsFor(ga, s, "g2", "DROP INDEX g2_idx")) {
        std.debug.print("DROP INDEX in g2 did not wait for g2's lock\n", .{});
        return error.DropIndexDidNotLockSessionGraph;
    }
    // ... and not for default's.
    try expectRuns(ga, s, "CREATE INDEX g2_idx FOR (n:Item) ON (n.k)");
    if (try waitsFor(ga, s, default_graph, "DROP INDEX g2_idx")) {
        std.debug.print("DROP INDEX in g2 waited for the default graph's lock\n", .{});
        return error.DropIndexLockedDefaultGraph;
    }

    // A fulltext index lives in the default graph: from g2 its DROP is
    // refused (it would change default under g2's lock) and it stays.
    try expectRuns(ga, s, "CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    const adapter = graph_store.getGlobalAdapter().?;
    try testing.expect(adapter.getFulltextIndexNamed(default_graph, "doc_idx") != null);
    try expectWireCode(ga, s, "DROP INDEX doc_idx", "0A000");
    try testing.expect(adapter.getFulltextIndexNamed(default_graph, "doc_idx") != null);
    // From the default graph it drops, under default's lock.
    if (!try waitsFor(ga, s, default_graph, "USE GRAPH default; DROP INDEX doc_idx")) {
        std.debug.print("DROP INDEX of a fulltext index did not wait for default's lock\n", .{});
        return error.FulltextDropDidNotLockDefault;
    }
    try testing.expect(adapter.getFulltextIndexNamed(default_graph, "doc_idx") == null);

    // (3) On the wire: 42704 for a missing index or constraint, 42P07 /
    // 42710 for a taken name.
    try expectRuns(ga, s, "USE GRAPH g2");
    try expectWireCode(ga, s, "DROP INDEX never_6294", "42704");
    try expectWireCode(ga, s, "DROP CONSTRAINT never_6294", "42704");
    try expectRuns(ga, s, "CREATE INDEX taken_6294 FOR (n:Item) ON (n.k)");
    try expectWireCode(ga, s, "CREATE INDEX taken_6294 FOR (n:Other) ON (n.k)", "42P07");
    try expectRuns(ga, s, "CREATE CONSTRAINT taken_c_6294 FOR (n:Item) REQUIRE n.k IS NOT NULL");
    try expectWireCode(ga, s, "CREATE CONSTRAINT taken_c_6294 FOR (n:Other) REQUIRE n.k IS NOT NULL", "42710");
}

test "SONNY-6294 (3): the catalog's errors map to their SQLSTATEs" {
    const Case = struct { err: anyerror, code: []const u8 };
    const cases = [_]Case{
        .{ .err = error.IndexNotFound, .code = "42704" },
        .{ .err = error.ConstraintNotFound, .code = "42704" },
        .{ .err = error.DuplicateIndex, .code = "42P07" },
        .{ .err = error.IndexAlreadyExists, .code = "42P07" },
        .{ .err = error.IndexNameInUseByOtherGraph, .code = "42P07" },
        .{ .err = error.ConstraintAlreadyExists, .code = "42710" },
        .{ .err = error.FulltextIndexInDefaultGraph, .code = "0A000" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const info = proto_util.mapError(c.err);
        if (!std.mem.eql(u8, info.code, c.code)) {
            std.debug.print("{s}: {s} ({s}); expected {s}\n", .{ @errorName(c.err), info.code, info.message, c.code });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
