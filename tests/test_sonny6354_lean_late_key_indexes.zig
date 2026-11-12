// SONNY-6354 regression: residuals of SONNY-6268 and SONNY-3056.
//
// 1. A node whose reserved id has bit 63 set. MERGE's property index flags an
//    entry with that bit, so such an id is never an entry (`putOrUpdate`
//    refuses it). SONNY-6268 made the property SET, the no-save SET and the
//    label add propagate that refusal, so the write itself failed. And a
//    removal for such an id compared equal to the entry "shared, lowest
//    holder <the id without bit 63>" and dropped another node's entry.
//    SONNY-6362: such an id is now refused when a node is created with it.
// 2. Lean index mode (GEODE_INDEX_MERGE_KEYS_ONLY=1): the exact node-property
//    index holds a key only once it is registered (the first MERGE on it).
//    Nodes written before carried it unindexed and nothing added them, yet
//    every seek trusts `shouldIndexProperty` as "the index is complete for
//    this key": a WHERE / inline-map seek and the bulk edge endpoint
//    resolvers (whose zero posting is an authoritative miss) did not find
//    them, and the index saved at shutdown carried the hole across a reopen.
// 3. A composite MERGE key registered at runtime was backfilled from the
//    resident nodes only, so an evicted holder had no composite entry and
//    the composite probe's authoritative miss lost it.
//
// Real executor, store, adapter and node cache; no mocks.
//
// CANARY: REQ=REQ-SONNY-6354-LEAN-LATE-KEY-INDEXES; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6354_lean_late_key_indexes.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const G = graph_store.DEFAULT_GRAPH_NAME;
const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;

/// Nodes per label: far more than the node cache holds.
const N: usize = 300;
/// The node cache's total cap (per shard: cap / 16).
const CACHE_CAP = "32";

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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        // Read when the store is made.
        if (setenv("GEODE_NODE_CACHE_ENTRIES", CACHE_CAP, 1) != 0) return error.SetEnvFailed;
        graph_store.setLeanIndexingForTest(true);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        // The server installs the node cache's hydrate hook at start
        // (`initGlobalStore`); without it the cap stays inert.
        graph_store.getGlobalStore(allocator).installNodeCacheHydrate();
        if (graph_store.getGlobalAdapter() == null) return error.NoAdapter;
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
        graph_store.setLeanIndexingForTest(false);
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn restart(self: *Harness) !void {
        return self.restartLean(true);
    }

    /// A new process, with lean index mode on or off.
    fn restartLean(self: *Harness, lean: bool) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        // A new process: no key registered until the sidecar is read.
        graph_store.setLeanIndexingForTest(lean);
        graph_store.getGlobalStore(self.allocator).installNodeCacheHydrate();
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn runf(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        return self.run(try std.fmt.allocPrint(self.arena.allocator(), fmt, args));
    }

    /// The single cell `query` returns, rendered ('text', 12, null).
    fn cell(self: *Harness, query: []const u8) ![]const u8 {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1 or res.rows[0].len < 1) {
            std.debug.print("{s}: {d} rows\n", .{ query, res.rows.len });
            return error.UnexpectedRows;
        }
        const aa = self.arena.allocator();
        return switch (res.rows[0][0]) {
            .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
            .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
            .Null => "null",
            else => |v| try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
        };
    }

    fn expectCell(self: *Harness, query: []const u8, want: []const u8) !void {
        const got = try self.cell(query);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ query, want, got });
            return error.WrongAnswer;
        }
    }

    fn expectCount(self: *Harness, label: []const u8, want: usize) !void {
        const aa = self.arena.allocator();
        try self.expectCell(try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label}), try std.fmt.allocPrint(aa, "{d}", .{want}));
    }
};

fn tOf(id: u64) []const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const v = store.getNodeProperty(id, "t") orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

const flag: u64 = @as(u64, 1) << 63;

// SONNY-6362: a node is no longer created with such an id
// (`graph_store.refuseFlaggedNodeId`): it was never a MERGE entry, so a MERGE
// of a value it alone held created a duplicate, and the loader refuses a
// persisted id with bit 63 (`parsePersistedPublicId`), so it vanished at
// restart. The SETs, the label add and the removals still pass a flagged id
// by (SONNY-6354) as defence; no path creates one to reach them.
test "SONNY-6354: a node whose reserved id has bit 63 set is refused at creation (it took SETs and labels, and was no MERGE entry)" {
    var gs = try graph_store.GraphStore.init(testing.allocator);
    defer gs.deinit();
    try gs.createGraph("g");
    var id: u64 = 0;

    try testing.expectError(error.NodeIdFlagged, gs.createNodeWithReservedIdAndGraph(flag | 3, &[_][]const u8{"F"}, "g"));
    try testing.expectError(error.NodeIdFlagged, gs.createNodeWithId(flag | 3, &[_][]const u8{"F"}, "g"));
    try testing.expect(gs.nodes.get(flag | 3) == null);
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.not_found, gs.lookupOnlyMergeHolder("g", "F", "x", .{ .Int = 1 }, &id));
}

test "SONNY-6354: a bit-63 id with a holder's low bits is refused, and the holders' entry stays" {
    var gs = try graph_store.GraphStore.init(testing.allocator);
    defer gs.deinit();
    try gs.createGraph("g");
    var id: u64 = 0;

    // Two holders of x = 7: the entry reads "shared, lowest holder 5".
    try gs.createNodeWithReservedIdAndGraph(5, &[_][]const u8{"B"}, "g");
    try gs.setNodeProperty(5, "x", .{ .Int = 7 });
    try gs.createNodeWithReservedIdAndGraph(6, &[_][]const u8{"B"}, "g");
    try gs.setNodeProperty(6, "x", .{ .Int = 7 });
    // A third holder whose id is 5 with bit 63 set is not created, so its
    // removal and delete touch nothing.
    try testing.expectError(error.NodeIdFlagged, gs.createNodeWithReservedIdAndGraph(flag | 5, &[_][]const u8{"B"}, "g"));

    gs.removeNodeProperty(flag | 5, "x");
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, gs.lookupMergeCandidate("g", "B", "x", .{ .Int = 7 }, &id));
    try testing.expectEqual(@as(u64, 5), id);

    gs.deleteNode(flag | 5);
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, gs.lookupMergeCandidate("g", "B", "x", .{ .Int = 7 }, &id));
    try testing.expectEqual(@as(u64, 5), id);
}

test "SONNY-6354: lean mode, a key registered after its nodes were written: seeks and endpoint resolution find them, also after a reopen" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    // Written by CREATE: `j` is not registered, so not in the exact index.
    for (0..N) |i| try h.runf("CREATE (:S {{j: {d}, t: 's{d}'}})", .{ i, i });
    // The first MERGE on `j` registers it (through another label).
    try h.run("MERGE (n:Other {j: -1})");

    try h.expectCell("MATCH (n:S) WHERE n.j = 5 RETURN count(n) AS c", "1");
    try h.expectCell("MATCH (n:S {j: 7}) RETURN n.t AS t", "'s7'");
    {
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        const filters = [_]PropKV{
            .{ .key = "j", .value = .{ .Int = 9 } },
            .{ .key = "t", .value = .{ .String = "s9" } },
        };
        _ = try adapter.lookupNodeIdByLabelAndAllProps(G, "S", &filters, error.EndpointMissing);
        const pid = try adapter.lookupPublicNodeIdByLabelAndAllProps(G, "S", &filters, error.EndpointMissing);
        try testing.expectEqualStrings("s9", tOf(pid));
    }
    // A node written after the registration is found too.
    try h.run("CREATE (:S {j: 100000, t: 'late'})");
    try h.expectCell("MATCH (n:S) WHERE n.j = 100000 RETURN n.t AS t", "'late'");

    // A reopen: `j` comes from the sidecar, and the exact index is reloaded
    // from what the shutdown saved.
    try h.restart();
    try h.expectCell("MATCH (n:S) WHERE n.j = 11 RETURN count(n) AS c", "1");
    try h.expectCell("MATCH (n:S {j: 13}) RETURN n.t AS t", "'s13'");
    try h.expectCell("MATCH (n:S) WHERE n.j = 100000 RETURN n.t AS t", "'late'");
}

test "SONNY-6354: a composite MERGE key registered at runtime resolves a holder that is not resident" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);

    for (0..N) |i| try h.runf("CREATE (:C {{src: 'gbif', sid: {d}, t: 'c{d}'}})", .{ i, i });
    try testing.expect(store.nodes.count() < N / 2);
    graph_store.registerCompositeMergeKey(&.{ "src", "sid" });

    const prev = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev);
    for ([_]i64{ 0, 1, 2, 150 }) |sid| {
        const filters = [_]PropKV{
            .{ .key = "src", .value = .{ .String = "gbif" } },
            .{ .key = "sid", .value = .{ .Int = sid } },
        };
        const pid = try adapter.lookupPublicNodeIdByLabelAndAllProps(G, "C", &filters, error.EndpointMissing);
        const want = try std.fmt.allocPrint(h.arena.allocator(), "c{d}", .{sid});
        try testing.expectEqualStrings(want, tOf(pid));
    }
    // A value no node holds is still an authoritative miss.
    const none = [_]PropKV{
        .{ .key = "src", .value = .{ .String = "gbif" } },
        .{ .key = "sid", .value = .{ .Int = 999_999 } },
    };
    try testing.expectError(error.EndpointMissing, adapter.lookupPublicNodeIdByLabelAndAllProps(G, "C", &none, error.EndpointMissing));
}

test "SONNY-6354: an exact index saved in lean mode is not trusted after a restart with lean mode off" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // `z` is never a MERGE key: in lean mode the exact index leaves it out.
    for (0..N) |i| try h.runf("CREATE (:Z {{z: {d}, t: 'z{d}'}})", .{ i, i });
    try h.expectCell("MATCH (n:Z {z: 4}) RETURN n.t AS t", "'z4'");

    // Lean mode off: every key is indexed and every seek trusts the index.
    try h.restartLean(false);
    try h.expectCell("MATCH (n:Z {z: 5}) RETURN n.t AS t", "'z5'");
    try h.expectCell("MATCH (n:Z) WHERE n.z = 6 RETURN count(n) AS c", "1");
}
