// SONNY-3056 regression: lean index mode (GEODE_INDEX_MERGE_KEYS_ONLY=1),
// a MERGE key registered after its nodes were written, and a holder that is
// not resident.
//
// In lean mode only registered MERGE keys are put in MERGE's property index.
// A key is registered by the first MERGE on it; nodes written before that
// (by CREATE, or by a MERGE on another key) carry the key unindexed. The
// registration backfilled the index from the RESIDENT nodes only
// (`GraphStore.backfillMergeIndexForKey` iterated the bounded node cache),
// so a holder that had been evicted had no entry, the lookup trusted the
// miss, and MERGE created a duplicate instead of matching it.
//
// Pinned here, on a persisted store with a small node cache: the executor's
// MERGE and the server's bulk MERGE helpers match a holder written before
// the key was registered and evicted since, create nothing, and keep doing
// so after a reopen.
//
// Real executor, store, adapter and node cache; no mocks.
//
// CANARY: REQ=REQ-SONNY-3056-LEAN-MERGE-BACKFILL; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3056_lean_merge_evicted_holder.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const G = graph_store.DEFAULT_GRAPH_NAME;

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
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        // A new process: no key registered until the sidecar is read.
        graph_store.setLeanIndexingForTest(true);
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
    const v = (store.getNodePropertyOrError(id, "t") catch @panic("SONNY-6621: unexpected read failure")) orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

test "SONNY-3056: lean mode, a key registered after its nodes were written: MERGE matches an evicted holder" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const store = graph_store.getGlobalStore(testing.allocator);

    // ---- the executor's MERGE ----
    // Written by CREATE: in lean mode `k` is not registered, so not indexed.
    for (0..N) |i| try h.runf("CREATE (:T {{k: {d}, t: 'n{d}'}})", .{ i, i });
    // Precondition: the cache holds far fewer than N nodes, so the first
    // ones written are not resident.
    try testing.expect(store.nodes.count() < N / 2);
    // The first MERGE on `k` registers it; the holder of 0 was evicted.
    try h.expectCell("MERGE (n:T {k: 0}) RETURN n.t AS t", "'n0'");
    try h.expectCell("MERGE (n:T {k: 1}) RETURN n.t AS t", "'n1'");
    try h.expectCell("MERGE (n:T {k: 150}) RETURN n.t AS t", "'n150'");
    try h.expectCount("T", N);
    // A new value is created once, then matched.
    try h.expectCell("MERGE (n:T {k: 100000}) RETURN n.t AS t", "null");
    try h.expectCell("MERGE (n:T {k: 100000}) RETURN count(n) AS c", "1");
    try h.expectCount("T", N + 1);

    // ---- the server's bulk MERGE (adapter.bulkMergeNode*) on a new key ----
    for (0..N) |i| try h.runf("CREATE (:U {{u: {d}, t: 'u{d}'}})", .{ i, i });
    try testing.expect(store.nodes.count() < N / 2);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    {
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        const r0 = try adapter.bulkMergeNode(G, "U", "u", .{ .Int = 0 }, &.{}, null, false);
        try testing.expect(!r0.wrote);
        try testing.expectEqualStrings("u0", tOf(r0.id));
        const r1 = try adapter.bulkMergeNodeWithReservedId(G, store.reserveNodeId(), "U", "u", .{ .Int = 2 }, &.{}, false);
        try testing.expect(!r1.wrote);
        try testing.expectEqualStrings("u2", tOf(r1.id));
    }
    try h.expectCount("U", N);

    // ---- a MERGE on a key registered while another key's nodes exist ----
    for (0..N) |i| try h.runf("CREATE (:W {{w: 'v{d}'}})", .{i});
    try h.run("MERGE (n:Other {w: 'x'})"); // registers `w` through another label
    try h.expectCell("MERGE (n:W {w: 'v0'}) RETURN count(n) AS c", "1");
    try h.expectCount("W", N);

    // ---- a reopen: the key is in the sidecar, the cache starts cold ----
    try h.restart();
    try h.expectCell("MERGE (n:T {k: 3}) RETURN n.t AS t", "'n3'");
    try h.expectCount("T", N + 1);
}
