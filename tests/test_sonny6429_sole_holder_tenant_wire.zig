// SONNY-6429 item 1: the tenant-scoped sole-holder endpoint lookup
// (`GraphStore.lookupOnlyMergeHolderForTenant`,
// `StorageAdapter.lookupSoleNodeByMergeKeyForTenant`), written while merging
// the security lane into the SONNY-738 sweep branch, had no test of its own.
// It resolves the endpoints of the MATCH ... CREATE edge fast path
// (quic_connection_handler.zig `executeBulkMatchCreateEdge`, and the group
// commit coordinator's `bulk_match_create_edge` op in group_commit.zig).
//
// Two halves:
//   * in process, against the real store and adapter (persisted, bounded and
//     unbounded node cache, lean indexing, and after a reopen): the lookup's
//     answer for a session of tenant A when (a) two of A's nodes hold the key,
//     (b) one of A's and one of B's hold it, (c) only B's node holds it, and
//     (d) for an unscoped session, against the general executor's MATCH as
//     that session (the oracle): a sole holder is that node, none is a miss,
//     more is `MergeKeyNotUnique` (the caller declines to the executor), and
//     B's node is never the answer for A;
//   * over the wire, a spawned server with group commit on and off, and with
//     lean indexing (GEODE_INDEX_MERGE_KEYS_ONLY=1): each of
//     those fixtures, with a MATCH ... CREATE edge and a MATCH ... MERGE edge
//     statement run by A, B or an unscoped session, sent once in autocommit
//     (where the server's fast paths may serve it) and once inside an explicit
//     transaction (where only the executor does), on separate copies of the
//     fixture. The responses (status code and message) and every edge each
//     session can see afterwards must be identical: no fast path binds or
//     reveals another tenant's node, through the edges it writes or the error
//     it answers.
//
// SONNY-6436 items 2-3 extend it: the composite-key endpoint resolver of the
// MATCH ... MERGE edge fast path (`lookupPublicNodeIdByLabelAndAllProps`)
// took the lowest of the nodes holding a registered composite key, where the
// executor's MATCH binds each (in process, and over the wire with a
// duplicated `{k, s}` endpoint); and MERGE's index answered a key lean
// indexing left out of it as held by no node (`lookupMergeCandidate`,
// `lookupNodeByMergeKey[ForTenant]`), so `bulkInsertEdge` skipped an edge
// the executor makes. Both decline now.
//
// SONNY-6447 item 5 extends it: endpoints whose key is a number held as an
// integer by one node and as an equal float by another (`{k: 1}`,
// `{k: 1.0}`). The executor's MATCH binds both (1 = 1.0) and a node MERGE
// of either form finds the existing node; MERGE's index keeps them as one
// key, while the exact property index the merge-edge resolver
// (`lookupPublicNodeIdByLabelAndAllProps`) counts postings in keys each
// form separately.
//
// CANARY: REQ=REQ-SONNY-6447-NUMERIC-KEY-PARITY; FEATURE="WriteFastPathParity"; ASPECT=IntFloatEqualEndpointKeys; STATUS=TESTED; TEST=tests/test_sonny6429_sole_holder_tenant_wire.zig; OWNER=storage; UPDATED=2026-11-12
// CANARY: REQ=REQ-SONNY-6429-SOLE-HOLDER-TENANT; FEATURE="WriteFastPathParity"; ASPECT=SoleHolderTenantRegression; STATUS=TESTED; TEST=tests/test_sonny6429_sole_holder_tenant_wire.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gsa = geode.graph_storage_adapter;
const Value = geode.value_types.Value;
const G = graph_store.DEFAULT_GRAPH_NAME;

const TA = "t6429a";
const TB = "t6429b";
const UNSCOPED = graph_store.DEFAULT_TENANT_ID;

// ---------------------------------------------------------------------------
// In process: the lookup against the executor's MATCH.
// ---------------------------------------------------------------------------

const Mode = enum { persisted, unbounded_cache, lean };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    catalog: @FieldType(execution.ExecutionContext, "catalog"),

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        if (mode == .unbounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
        }
        errdefer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        graph_store.setLeanIndexingForTest(mode == .lean);
        errdefer graph_store.setLeanIndexingForTest(false);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .catalog = catalog };
    }

    fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        graph_store.setLeanIndexingForTest(false);
    }

    fn reopen(self: *Session) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.resetLazyHydrateCounters();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        self.catalog = try execution.ensureCatalogInstance(allocator);
    }

    fn run(self: *Session, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var ctx: execution.ExecutionContext = .{ .catalog = self.catalog, .tenant_id = tenant };
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn exec(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        var r = try self.run(tenant, query);
        r.deinit(self.arena.allocator());
    }
};

const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.SoleHolderLookupDiverged;
    }
};

/// The executor's `t` values of the nodes `label {k: 1}` matches for the
/// session of `tenant` (null: unscoped), sorted and joined by ','.
fn holdersSeen(s: *Session, tenant: ?[]const u8, label: []const u8) ![]const u8 {
    const aa = s.arena.allocator();
    const q = try std.fmt.allocPrint(aa, "MATCH (n:{s} {{k: 1}}) RETURN n.t", .{label});
    var result = try s.run(tenant, q);
    defer result.deinit(aa);
    const ts = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, ts) |row, *out| out.* = switch (row[0]) {
        .Str => |t| try aa.dupe(u8, t),
        else => "?",
    };
    std.mem.sort([]const u8, ts, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.mem.join(aa, ",", ts);
}

/// The lookup's answer for `request_tenant`, as the `t` of the node it names,
/// "miss" or "not-unique".
fn lookupAnswer(s: *Session, label: []const u8, request_tenant: []const u8) ![]const u8 {
    const a = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const id = a.lookupSoleNodeByMergeKeyForTenant(G, label, "k", .{ .Int = 1 }, request_tenant, error.SourceNodeNotFound) catch |err| switch (err) {
        error.SourceNodeNotFound => return "miss",
        error.MergeKeyNotUnique => return "not-unique",
        else => return err,
    };
    const store = graph_store.getGlobalStore(testing.allocator);
    const node = (try store.nodes.getOrHydratePtr(id)) orelse return "vanished";
    const t = node.properties.get("t") orelse return "no-t";
    return switch (t) {
        .String => |v| try std.fmt.allocPrint(s.arena.allocator(), "{s}/{s}", .{ node.tenant_id, v }),
        else => "t?",
    };
}

/// The lookup's answer for `request_tenant` must follow from what the
/// executor's MATCH sees for the same session: one node is that node, none
/// is a miss, more are `not-unique`.
fn expectLookup(s: *Session, f: *Failures, case: []const u8, label: []const u8, request_tenant: []const u8, want: []const u8) !void {
    const session_tenant: ?[]const u8 = if (std.mem.eql(u8, request_tenant, UNSCOPED)) null else request_tenant;
    const seen = try holdersSeen(s, session_tenant, label);
    const n_seen: usize = if (seen.len == 0) 0 else std.mem.count(u8, seen, ",") + 1;
    const got = try lookupAnswer(s, label, request_tenant);
    // Under lean indexing the exact node-property index cannot list a
    // tenant's holders of a key registered at runtime, so a tenant-scoped
    // lookup may decline (the executor then answers): never a wrong node,
    // never a miss where the session's tenant holds the key.
    if (s.mode == .lean and session_tenant != null and n_seen > 0 and std.mem.eql(u8, got, "not-unique")) return;
    if (!std.mem.eql(u8, got, want)) try f.add("[{s}] case {s} as {s}: lookup answered {s}, expected {s} (the executor's MATCH sees [{s}])", .{ @tagName(s.mode), case, request_tenant, got, want, seen });
    const consistent = switch (n_seen) {
        0 => std.mem.eql(u8, got, "miss"),
        1 => std.mem.endsWith(u8, got, seen) and got.len > seen.len and got[got.len - seen.len - 1] == '/',
        else => std.mem.eql(u8, got, "not-unique"),
    };
    if (!consistent) try f.add("[{s}] case {s} as {s}: lookup answered {s}, but the executor's MATCH sees [{s}]", .{ @tagName(s.mode), case, request_tenant, got, seen });
}

fn checkLookups(s: *Session, f: *Failures) !void {
    // (a) two of A's nodes hold the key.
    try expectLookup(s, f, "a", "A6429", TA, "not-unique");
    try expectLookup(s, f, "a", "A6429", TB, "miss");
    // (b) one of A's and one of B's.
    try expectLookup(s, f, "b", "B6429", TA, TA ++ "/a");
    try expectLookup(s, f, "b", "B6429", TB, TB ++ "/b");
    // (c) only B's.
    try expectLookup(s, f, "c", "C6429", TA, "miss");
    try expectLookup(s, f, "c", "C6429", TB, TB ++ "/b");
    // (d) an unscoped session sees every tenant's holders.
    try expectLookup(s, f, "d/a", "A6429", UNSCOPED, "not-unique");
    try expectLookup(s, f, "d/b", "B6429", UNSCOPED, "not-unique");
    try expectLookup(s, f, "d/c", "C6429", UNSCOPED, TB ++ "/b");
    // A key no node holds.
    try expectLookup(s, f, "none", "N6429", TA, "miss");
    try expectLookup(s, f, "none", "N6429", UNSCOPED, "miss");
    // (e) one of A's two nodes deleted: A's remaining node is its only holder.
    try expectLookup(s, f, "e", "E6429", TA, TA ++ "/a2");
    try expectLookup(s, f, "e", "E6429", UNSCOPED, "not-unique");
}

fn checkLeanUnregisteredDeclines(s: *Session, f: *Failures) !void {
    for ([_][]const u8{ "A6429", "B6429", "C6429", "N6429", "E6429" }) |label| {
        for ([_][]const u8{ TA, TB, UNSCOPED }) |tenant| {
            const got = try lookupAnswer(s, label, tenant);
            if (!std.mem.eql(u8, got, "not-unique")) try f.add("[lean, k unregistered] {s} as {s}: lookup answered {s}, expected to decline (not-unique)", .{ label, tenant, got });
        }
    }
}

test "SONNY-6429: the tenant-scoped sole-holder lookup answers what the executor's MATCH sees" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for ([_]Mode{ .persisted, .unbounded_cache, .lean }) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.exec(TA, "CREATE (:A6429 {k: 1, t: 'a1'})");
        try s.exec(TA, "CREATE (:A6429 {k: 1, t: 'a2'})");
        // B's node takes the lower id, so it is the one MERGE's index names.
        try s.exec(TB, "CREATE (:B6429 {k: 1, t: 'b'})");
        try s.exec(TA, "CREATE (:B6429 {k: 1, t: 'a'})");
        try s.exec(TB, "CREATE (:C6429 {k: 1, t: 'b'})");
        try s.exec(TA, "CREATE (:N6429 {k: 2, t: 'a'})");
        try s.exec(TA, "CREATE (:E6429 {k: 1, t: 'a1'})");
        try s.exec(TA, "CREATE (:E6429 {k: 1, t: 'a2'})");
        try s.exec(TB, "CREATE (:E6429 {k: 1, t: 'b'})");
        try s.exec(TA, "MATCH (n:E6429 {t: 'a1'}) DELETE n");
        if (mode == .lean) {
            // No MERGE registered `k`, so lean indexing kept it out of
            // MERGE's index: the index cannot answer, and every lookup
            // declines to the executor (it answered "no holder", and the
            // fast path skipped an edge the executor makes).
            try checkLeanUnregisteredDeclines(&s, &f);
            // Registered (as a MERGE on it does), it is backfilled and
            // answers.
            graph_store.registerMergeIndexKey("k");
        }
        try checkLookups(&s, &f);
        try s.reopen();
        try checkLookups(&s, &f);
    }
    try f.check("sole-holder lookup");
}

// ---------------------------------------------------------------------------
// SONNY-6436 items 2-3, in process: endpoint resolution never takes one of
// several holders, nor answers "absent" from an index that cannot know.
// ---------------------------------------------------------------------------

/// `lookupPublicNodeIdByLabelAndAllProps` for `{k: 1, s: 'x'}` under `label`:
/// the `t` of the node it names, "miss" or "not-unique".
fn compositeAnswer(s: *Session, label: []const u8) ![]const u8 {
    const a = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const filters = [_]gsa.StorageAdapter.PropKV{
        .{ .key = "k", .value = .{ .Int = 1 } },
        .{ .key = "s", .value = .{ .String = "x" } },
    };
    const id = a.lookupPublicNodeIdByLabelAndAllProps(G, label, &filters, error.SourceNodeNotFound) catch |err| switch (err) {
        error.SourceNodeNotFound => return "miss",
        error.MergeKeyNotUnique => return "not-unique",
        else => return err,
    };
    const store = graph_store.getGlobalStore(testing.allocator);
    const node = (try store.nodes.getOrHydratePtr(id)) orelse return "vanished";
    return switch (node.properties.get("t") orelse return "no-t") {
        .String => |v| try s.arena.allocator().dupe(u8, v),
        else => "t?",
    };
}

fn expectComposite(s: *Session, f: *Failures, when: []const u8, label: []const u8, want: []const u8) !void {
    const got = try compositeAnswer(s, label);
    if (!std.mem.eql(u8, got, want)) try f.add("[composite {{k, s}}, {s}] {s}: resolver answered {s}, expected {s}", .{ when, label, got, want });
}

test "SONNY-6436: a registered composite key two nodes hold resolves to neither (the executor's MATCH binds both)" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.persisted);
    defer s.deinit();
    graph_store.registerCompositeMergeKey(&.{ "k", "s" });
    defer graph_store.clearCompositeMergeKeysForTest();
    try s.exec(null, "CREATE (:C6436 {k: 1, s: 'x', t: 'c1'})");
    try s.exec(null, "CREATE (:C6436 {k: 1, s: 'x', t: 'c2'})");
    try s.exec(null, "CREATE (:D6436 {k: 1, s: 'x', t: 'd'})");
    try s.exec(null, "CREATE (:N6436 {k: 1, s: 'y', t: 'n'})");
    for ([_][]const u8{ "fresh", "reopened" }) |when| {
        try expectComposite(&s, &f, when, "C6436", "not-unique");
        try expectComposite(&s, &f, when, "D6436", "d");
        try expectComposite(&s, &f, when, "N6436", "miss");
        if (std.mem.eql(u8, when, "fresh")) try s.reopen();
    }
    // Back to one holder: it answers again.
    try s.exec(null, "MATCH (n:C6436 {t: 'c1'}) DELETE n");
    try expectComposite(&s, &f, "one deleted", "C6436", "c2");
    try f.check("composite endpoint resolution");
}

test "SONNY-6436: a key lean indexing left out of MERGE's index is never answered as held by no node" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.lean);
    defer s.deinit();
    // No MERGE registered `u6436`, so lean indexing keeps it out of MERGE's
    // index although both nodes hold it.
    try s.exec(null, "CREATE (:L6436 {u6436: 1, t: 'l'})");
    try s.exec(null, "CREATE (:M6436 {u6436: 1, t: 'm'})");
    const store = graph_store.getGlobalStore(testing.allocator);
    const a = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const one: graph_store.PropertyValue = .{ .Int = 1 };

    var id: u64 = 0;
    const r = store.lookupMergeCandidate(G, "L6436", "u6436", one, &id);
    if (r != .not_indexable) try f.add("lookupMergeCandidate answered .{s}, expected .not_indexable (the index cannot know)", .{@tagName(r)});
    const rt = store.lookupMergeCandidateForTenant(G, "L6436", "u6436", one, TA, &id);
    if (rt != .not_indexable) try f.add("lookupMergeCandidateForTenant answered .{s}, expected .not_indexable", .{@tagName(rt)});

    for ([_]?[]const u8{ null, UNSCOPED, TA }) |tenant| {
        const name = tenant orelse "(lookupNodeByMergeKey)";
        const res = if (tenant) |t|
            a.lookupNodeByMergeKeyForTenant(G, "L6436", "u6436", one, t, error.SourceNodeNotFound)
        else
            a.lookupNodeByMergeKey(G, "L6436", "u6436", one, error.SourceNodeNotFound);
        if (res) |got| {
            _ = got;
        } else |err| if (err != error.MergeKeyNotUnique) try f.add("{s}: answered {s}, expected MergeKeyNotUnique (decline)", .{ name, @errorName(err) });
    }

    // The bulk edge path: it skipped the edge as "source not found", where
    // the executor's MATCH ... CREATE makes it. It declines now, and writes
    // nothing.
    if (a.bulkInsertEdge(G, "L6436", one, "u6436", "M6436", one, "u6436", "R6436", &.{}, null)) |_| {
        try f.add("bulkInsertEdge wrote an edge; expected it to decline", .{});
    } else |err| if (err != error.MergeKeyNotUnique) try f.add("bulkInsertEdge answered {s}, expected MergeKeyNotUnique (decline)", .{@errorName(err)});
    var res = try s.run(null, "MATCH (:L6436)-[r:R6436]->(:M6436) RETURN count(r)");
    defer res.deinit(s.arena.allocator());
    const n: i64 = switch (res.rows[0][0]) {
        .Int => |v| v,
        else => -1,
    };
    if (n != 0) try f.add("{d} R6436 edge(s) after the declined bulkInsertEdge, expected 0", .{n});
    try f.check("lean-unregistered key");
}

// ---------------------------------------------------------------------------
// Over the wire: autocommit (fast paths may serve) against an explicit
// transaction (the executor only), for each session and fixture.
// ---------------------------------------------------------------------------

const Server = struct {
    handle: util.ServerHandle,
    data_dir: []const u8,
    addr: []const u8,

    fn start(data_dir_buf: []u8, extra_env: []const []const u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const io = std.Io.Threaded.global_single_threaded.io();
        const data_dir = try std.fmt.bufPrint(data_dir_buf, "/tmp/geode-sonny6429-{d}", .{port});
        std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, extra_env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .data_dir = data_dir, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
    }

    /// A session as the fixture's admin user, in `tenant` (null: unscoped).
    fn connect(self: *Server, tenant: ?[]const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id.?);
        var hello = try client.helloWith(testing.allocator, util.defaultUsername(), util.defaultPassword(), null, tenant);
        defer hello.deinit(testing.allocator);
        if (!hello.success) {
            std.debug.print("HELLO refused: {s}\n", .{hello.error_message});
            return error.HelloRefused;
        }
        return client;
    }
};

/// The response to `query`: `ok:` and its rows sorted (cells '|', rows ';'),
/// or `error:<code>:<message>`.
fn respond(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    var res = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer res.deinit(testing.allocator);
    if (res.error_code) |code| {
        if (!std.mem.eql(u8, code, "00000")) return std.fmt.allocPrint(aa, "error:{s}:{s}", .{ code, res.error_message orelse "" });
    }
    const rows = try aa.alloc([]const u8, res.rows.len);
    for (res.rows, rows) |row, *out| {
        var line: std.ArrayList(u8) = .empty;
        for (row, 0..) |cell, j| {
            if (j > 0) try line.append(aa, '|');
            switch (cell) {
                .int => |v| try line.print(aa, "{d}", .{v}),
                .string => |v| try line.appendSlice(aa, v),
                .null => try line.appendSlice(aa, "null"),
                else => try line.appendSlice(aa, "?"),
            }
        }
        out.* = try line.toOwnedSlice(aa);
    }
    std.mem.sort([]const u8, rows, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.fmt.allocPrint(aa, "ok:{s}", .{try std.mem.join(aa, ";", rows)});
}

fn mustRun(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) !void {
    const got = try respond(aa, client, query);
    if (!std.mem.startsWith(u8, got, "ok:")) {
        std.debug.print("{s}: {s}\n", .{ query, got });
        return error.SetupFailed;
    }
}

const Who = enum { a, b, admin };

/// A fixture: who creates which `P` / `Q` endpoints (`t` names the node).
const Fixture = struct {
    name: []const u8,
    runner: Who,
    nodes: []const struct { who: Who, label: enum { P, Q }, t: []const u8, key: ?[]const u8 = null },
    /// SONNY-6436: the endpoints carry, and the statements match on, the
    /// registered composite merge key `{k, s}` (the merge-edge fast path
    /// resolves it in one composite-index probe).
    composite: bool = false,
    /// SONNY-6447: the key the statements match on, when not the nodes'
    /// (a node's `key` overrides the fixture's for it). A numeric fixture
    /// also runs a node MERGE of `merge_key` and reports the `P` nodes.
    match_key: ?[]const u8 = null,
    merge_key: ?[]const u8 = null,
};

const fixtures = [_]Fixture{
    // (a) two of A's nodes hold the source key.
    .{ .name = "a", .runner = .a, .nodes = &.{
        .{ .who = .a, .label = .P, .t = "a1" }, .{ .who = .a, .label = .P, .t = "a2" },
        .{ .who = .a, .label = .Q, .t = "qa" }, .{ .who = .b, .label = .Q, .t = "qb" },
    } },
    // (b) one of A's and one of B's (B's first, the lower id).
    .{ .name = "b", .runner = .a, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" },  .{ .who = .a, .label = .P, .t = "a" },
        .{ .who = .b, .label = .Q, .t = "qb" }, .{ .who = .a, .label = .Q, .t = "qa" },
    } },
    // (b') the same, run by B.
    .{ .name = "b-as-b", .runner = .b, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" },  .{ .who = .a, .label = .P, .t = "a" },
        .{ .who = .b, .label = .Q, .t = "qb" }, .{ .who = .a, .label = .Q, .t = "qa" },
    } },
    // (c) only B's node holds the source key.
    .{ .name = "c", .runner = .a, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" },
        .{ .who = .a, .label = .Q, .t = "qa" },
        .{ .who = .b, .label = .Q, .t = "qb" },
    } },
    // (c') only B's node holds the target key.
    .{ .name = "c-target", .runner = .a, .nodes = &.{
        .{ .who = .a, .label = .P, .t = "a" }, .{ .who = .b, .label = .Q, .t = "qb" },
    } },
    // (d) an unscoped session over (b) and (c).
    .{ .name = "d-b", .runner = .admin, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" },  .{ .who = .a, .label = .P, .t = "a" },
        .{ .who = .b, .label = .Q, .t = "qb" }, .{ .who = .a, .label = .Q, .t = "qa" },
    } },
    .{ .name = "d-c", .runner = .admin, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" }, .{ .who = .a, .label = .Q, .t = "qa" },
    } },
    // (d) an unscoped session, each key held by one node, of B.
    .{ .name = "d-sole", .runner = .admin, .nodes = &.{
        .{ .who = .b, .label = .P, .t = "b" }, .{ .who = .b, .label = .Q, .t = "qb" },
    } },
    // SONNY-6436 item 2 (last: registering `{k, s}` registers `k` with lean
    // indexing, and the fixtures above run with it unregistered): two nodes
    // hold the source's composite key, then one.
    .{ .name = "composite-two-holders", .runner = .admin, .composite = true, .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "p1" }, .{ .who = .admin, .label = .P, .t = "p2" },
        .{ .who = .admin, .label = .Q, .t = "q" },
    } },
    .{ .name = "composite-sole", .runner = .admin, .composite = true, .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "p" }, .{ .who = .admin, .label = .Q, .t = "q" },
    } },
    // SONNY-6447 item 5: the source key held as 1 by one node and 1.0 by
    // another, matched as 1 and as 1.0 (the executor binds both).
    .{ .name = "num-int-and-float-match-int", .runner = .admin, .match_key = "k: 1", .merge_key = "k: 1.0", .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "pi", .key = "k: 1" }, .{ .who = .admin, .label = .P, .t = "pf", .key = "k: 1.0" },
        .{ .who = .admin, .label = .Q, .t = "q", .key = "k: 1" },
    } },
    .{ .name = "num-int-and-float-match-float", .runner = .admin, .match_key = "k: 1.0", .merge_key = "k: 1", .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "pi", .key = "k: 1" }, .{ .who = .admin, .label = .P, .t = "pf", .key = "k: 1.0" },
        .{ .who = .admin, .label = .Q, .t = "q", .key = "k: 1" },
    } },
    // Only the other form is held (the executor still binds it).
    .{ .name = "num-float-held-match-int", .runner = .admin, .match_key = "k: 1", .merge_key = "k: 1", .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "pf", .key = "k: 1.0" }, .{ .who = .admin, .label = .Q, .t = "q", .key = "k: 1.0" },
    } },
    .{ .name = "num-int-held-match-float", .runner = .admin, .match_key = "k: 1.0", .merge_key = "k: 1.0", .nodes = &.{
        .{ .who = .admin, .label = .P, .t = "pi", .key = "k: 1" }, .{ .who = .admin, .label = .Q, .t = "q", .key = "k: 1" },
    } },
};

const Sessions = struct {
    a: util.QuicProtoClient,
    b: util.QuicProtoClient,
    admin: util.QuicProtoClient,

    fn get(self: *Sessions, who: Who) *util.QuicProtoClient {
        return switch (who) {
            .a => &self.a,
            .b => &self.b,
            .admin => &self.admin,
        };
    }
};

const Route = enum { autocommit, transaction };

/// Build `fx` under labels `P<tag>` / `Q<tag>`, run the edge statements as
/// its runner over `route`, and describe what each session then sees.
fn runFixture(aa: std.mem.Allocator, sessions: *Sessions, fx: Fixture, tag: []const u8, route: Route) ![]const u8 {
    const key = if (fx.composite) "k: 1, s: 'x'" else "k: 1";
    // SONNY-6436: a multi-property MERGE served by the node MERGE fast path
    // registers the composite merge key `{k, s}` (idempotent).
    if (fx.composite) try mustRun(aa, &sessions.admin, "MERGE (:Reg6436 {k: 1, s: 'x'})");
    for (fx.nodes) |n| {
        const q = try std.fmt.allocPrint(aa, "CREATE (:{s}{s} {{{s}, t: '{s}'}})", .{ @tagName(n.label), tag, n.key orelse key, n.t });
        try mustRun(aa, sessions.get(n.who), q);
    }
    const runner = sessions.get(fx.runner);
    const mk = fx.match_key orelse key;
    var stmts: std.ArrayList([]const u8) = .empty;
    try stmts.appendSlice(aa, &.{
        try std.fmt.allocPrint(aa, "MATCH (a:P{s} {{{s}}}), (b:Q{s} {{{s}}}) CREATE (a)-[:E]->(b)", .{ tag, mk, tag, mk }),
        try std.fmt.allocPrint(aa, "MATCH (a:P{s} {{{s}}}), (b:Q{s} {{{s}}}) MERGE (a)-[:M]->(b)", .{ tag, mk, tag, mk }),
        try std.fmt.allocPrint(aa, "MATCH (a:P{s} {{{s}}}), (b:Q{s} {{{s}}}) MERGE (a)-[:M]->(b)", .{ tag, mk, tag, mk }),
    });
    // SONNY-6447: a node MERGE of the other numeric form, and the P nodes.
    if (fx.merge_key) |m| {
        try stmts.append(aa, try std.fmt.allocPrint(aa, "MERGE (:P{s} {{{s}}})", .{ tag, m }));
        try stmts.append(aa, try std.fmt.allocPrint(aa, "MATCH (p:P{s}) RETURN coalesce(p.t, 'merged')", .{tag}));
    }
    var out: std.ArrayList(u8) = .empty;
    for (stmts.items, 0..) |stmt, i| {
        if (route == .transaction) {
            var began = try runner.begin(testing.allocator);
            began.deinit(testing.allocator);
        }
        const got = respond(aa, runner, stmt) catch |err| {
            std.debug.print("{s} ({s}, as {s}): {s}\n", .{ stmt, @tagName(route), @tagName(fx.runner), @errorName(err) });
            return err;
        };
        if (route == .transaction) {
            if (!try runner.commit(testing.allocator)) try out.appendSlice(aa, "[commit refused]");
        }
        try out.print(aa, "  stmt{d} -> {s}\n", .{ i, got });
    }
    const view = try std.fmt.allocPrint(aa, "MATCH (p:P{s})-[r]->(q:Q{s}) RETURN p.t, type(r), q.t", .{ tag, tag });
    const all_edges = try std.fmt.allocPrint(aa, "MATCH (p:P{s})-[r]-() RETURN p.t, type(r)", .{tag});
    for ([_]Who{ .a, .b, .admin }) |who| {
        try out.print(aa, "  {s} sees {s}\n", .{ @tagName(who), try respond(aa, sessions.get(who), view) });
        try out.print(aa, "  {s} edges {s}\n", .{ @tagName(who), try respond(aa, sessions.get(who), all_edges) });
    }
    return out.toOwnedSlice(aa);
}

fn exerciseWire(env: []const []const u8, mode_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var dir_buf: [64]u8 = undefined;
    var server = try Server.start(&dir_buf, env);
    defer server.stop();

    var sessions: Sessions = .{
        .a = try server.connect(TA),
        .b = undefined,
        .admin = undefined,
    };
    defer sessions.a.deinit();
    sessions.b = try server.connect(TB);
    defer sessions.b.deinit();
    sessions.admin = try server.connect(null);
    defer sessions.admin.deinit();

    var failures: std.ArrayList([]const u8) = .empty;
    for (fixtures, 0..) |fx, i| {
        const fast = try runFixture(aa, &sessions, fx, try std.fmt.allocPrint(aa, "F{d}", .{i}), .autocommit);
        const exec = try runFixture(aa, &sessions, fx, try std.fmt.allocPrint(aa, "X{d}", .{i}), .transaction);
        if (!std.mem.eql(u8, fast, exec)) {
            try failures.append(aa, try std.fmt.allocPrint(aa, "fixture {s} (run by {s}):\n autocommit:\n{s} executor (explicit transaction):\n{s}", .{ fx.name, @tagName(fx.runner), fast, exec }));
        }
    }
    if (failures.items.len == 0) return;
    std.debug.print("\nSONNY-6429 wire ({s}): {d} fixture(s) diverged from the executor:\n", .{ mode_name, failures.items.len });
    for (failures.items) |msg| std.debug.print("{s}\n", .{msg});
    return error.FastPathDivergedFromExecutor;
}

test "SONNY-6429: over QUIC the edge statements answer and write what the executor does, per tenant (group commit on)" {
    try exerciseWire(util.TestEnv.standard(), "group commit on");
}

test "SONNY-6429: over QUIC the edge statements answer and write what the executor does, per tenant (group commit off, GEODE_BULK_INGEST=1)" {
    try exerciseWire(&.{ "GEODE_GROUP_COMMIT=0", "GEODE_BULK_INGEST=1" }, "group commit off");
}

test "SONNY-6429: over QUIC the edge statements answer and write what the executor does, per tenant (group commit off, default fast paths)" {
    try exerciseWire(&.{"GEODE_GROUP_COMMIT=0"}, "group commit off, default fast paths");
}

test "SONNY-6429: over QUIC the edge statements answer and write what the executor does, per tenant (lean indexing)" {
    try exerciseWire(&.{"GEODE_INDEX_MERGE_KEYS_ONLY=1"}, "lean indexing");
}
