// SONNY-6567 (2): a node or edge body that cannot be READ is an error, not
// "absent"; a `db.*` listing that cannot read every row it needs fails the
// statement instead of answering a short list.
//
// The hydrated getters (`GraphStore.getNodePtrHydrated`,
// `getEdgePtrHydrated`, `getEdgeHydrated`) rebuild a body the bounded cache
// evicted from the storage engine. They turned the rebuild's error (out of
// memory, an engine read error) into null (`catch return null`), the value
// that means "no such node", and `db.propertyKeys()` /
// `db.relationshipTypes()` then skipped the row (`orelse continue`): a key or
// a type silently missing from the answer. Under an RLS deny,
// `edgeVisible` took an unreadable endpoint for a hidden one.
//
// The store, parser, executor and RLS filter engine are real; the store has
// a data directory (so bodies are rebuilt from the engine), and the
// allocator its caches rebuild a body with is wrapped in one that can be
// made to fail. Every node and edge body is evicted,
// then each listing runs with those allocations failing from the k-th
// one on, for every k up to the first run that needs none, for a session
// with no policy and for one denied a label (inside a transaction body, so
// the listing reads the store itself). Each run must fail or answer the
// correct listing. The same listings as top-level CALLs, served from a read
// snapshot (`QueryReadSession`), must list the evicted edges too: the
// snapshot copied only the edges resident in a bounded edge cache.
//
// CANARY: REQ=REQ-SONNY-6567-HYDRATED-GETTER-ERRORS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_hydrated_getter_errors.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const rls_types = @import("rls_types");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;

const MAX_SWEEP: usize = 20_000;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const World = struct {
    failing: std.testing.FailingAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    rls: *rls_types.RLSFilterEngine,
    store: *graph_store.GraphStore,

    fn init(self: *World) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        // Bounded caches, so an evicted body is a state the store has (an
        // unbounded cache never evicts, and lists its resident keys).
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "4", 1) != 0) return error.SetEnvFailed;
        if (setenv("GEODE_EDGE_CACHE_ENTRIES", "4", 1) != 0) return error.SetEnvFailed;
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        self.store = graph_store.getGlobalStore(testing.allocator);
        self.store.installNodeCacheHydrate();
        self.store.installEdgeCacheHydrate();
        // The caches rebuild an evicted body with their own allocator
        // (`smp_allocator`); `failOn` wraps it (frees still reach it).
        self.failing = std.testing.FailingAllocator.init(self.store.nodes.allocator, .{});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;
        self.rls = try testing.allocator.create(rls_types.RLSFilterEngine);
        self.rls.* = rls_types.RLSFilterEngine.init(testing.allocator);

        for ([_][]const u8{
            "CREATE (:Pub {pub_key: 1})-[:OK {ok_key: 1}]->(:Pub {pub_key: 2})",
            "CREATE (:Sec {sec_key: 1})-[:LINK {link_key: 1}]->(:Pub {pub_key: 3})",
            "CREATE (:Pub {pub_key: 4})-[:BOTH {both_key: 1}]->(:Pub {pub_key: 5})",
        }) |q| {
            var r = try self.run(null, q);
            r.deinit(self.arena.allocator());
        }
        try self.rls.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Sec", "bob");
        rls_types.setGlobalRLSFilterEngine(self.rls);
    }

    /// Route both caches' rebuilds through the failing allocator (or back).
    fn failOn(self: *World, on: bool) void {
        const a = if (on) self.failing.allocator() else self.failing.internal_allocator;
        self.store.nodes.allocator = a;
        self.store.edges.allocator = a;
    }

    fn deinit(self: *World) void {
        rls_types.setGlobalRLSFilterEngine(null);
        self.rls.deinit();
        testing.allocator.destroy(self.rls);
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        self.arena.deinit();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        _ = unsetenv("GEODE_EDGE_CACHE_ENTRIES");
    }

    fn run(self: *World, user: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.user = user;
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], self.ctx);
    }

    /// Evict every node and edge body from the bounded caches (the engine
    /// keeps them).
    fn evictAll(self: *World) !void {
        const node_ids = try self.store.getAllNodesForTenant(testing.allocator, null);
        defer testing.allocator.free(node_ids);
        for (node_ids) |id| self.store.nodes.remove(id);
        const edge_ids = try self.store.allEdgeIds(testing.allocator);
        defer testing.allocator.free(edge_ids);
        for (edge_ids) |id| self.store.edges.remove(id);
    }

    /// The listing's one string column, joined (arena memory).
    fn listing(self: *World, user: ?[]const u8, query: []const u8) ![]const u8 {
        var res = try self.run(user, query);
        defer res.deinit(self.arena.allocator());
        var out: std.ArrayList(u8) = .empty;
        for (res.rows) |row| {
            try out.appendSlice(self.arena.allocator(), row[0].Str);
            try out.append(self.arena.allocator(), ',');
        }
        return out.items;
    }
};

const Case = struct { user: ?[]const u8, query: []const u8, want: []const u8 };

const cases = [_]Case{
    .{ .user = "alice", .query = "CALL db.propertyKeys()", .want = "both_key,link_key,ok_key,pub_key,sec_key," },
    .{ .user = "bob", .query = "CALL db.propertyKeys()", .want = "both_key,ok_key,pub_key," },
    .{ .user = "bob", .query = "CALL db.relationshipTypes()", .want = "BOTH,OK," },
};

/// `c` as a top-level CALL (served from a read snapshot), every body evicted.
fn snapshotWrong(w: *World, c: Case) !usize {
    try w.evictAll();
    const got = try w.listing(c.user, c.query);
    if (std.mem.eql(u8, got, c.want)) return 0;
    std.debug.print("SONNY-6567 (2) {s} as {s}, bodies evicted, from a read snapshot: '{s}', want '{s}'\n", .{ c.query, c.user.?, got, c.want });
    return 1;
}

/// `c` inside a transaction body (it reads the store itself, so an evicted
/// body is rebuilt by the hydrating getters), with the rebuilds' allocations
/// failing from the k-th on, for every k.
fn sweep(w: *World, c: Case) !usize {
    const q = try std.fmt.allocPrint(w.arena.allocator(), "START TRANSACTION {{ {s} }}", .{c.query});
    try w.evictAll();
    const healthy = try w.listing(c.user, q);
    var wrong: usize = 0;
    if (!std.mem.eql(u8, healthy, c.want)) {
        wrong += 1;
        std.debug.print("SONNY-6567 (2) {s} as {s} with nothing failing: '{s}', want '{s}'\n", .{ c.query, c.user.?, healthy, c.want });
    }
    var failed: usize = 0;
    var runs: usize = 0;
    var k: usize = 0;
    while (k < MAX_SWEEP) : (k += 1) {
        try w.evictAll();
        w.failing.has_induced_failure = false;
        w.failing.fail_index = w.failing.alloc_index + k;
        w.failOn(true);
        const got = w.listing(c.user, q);
        w.failOn(false);
        w.failing.fail_index = std.math.maxInt(usize);
        const induced = w.failing.has_induced_failure;
        runs += 1;
        if (got) |g| {
            if (!std.mem.eql(u8, g, c.want)) {
                wrong += 1;
                std.debug.print("SONNY-6567 (2) {s} as {s}, rebuild allocation {d} failing: answered '{s}'\n", .{ c.query, c.user.?, k, g });
            }
        } else |_| failed += 1;
        if (!induced) break;
    }
    std.debug.print("SONNY-6567 (2) {s} as {s}: {d} runs, {d} failed, {d} wrong answers\n", .{ c.query, c.user.?, runs, failed, wrong });
    return wrong;
}

test "SONNY-6567 (2): a db.* listing served from a read snapshot lists evicted edges" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var wrong: usize = 0;
    for (cases) |c| wrong += try snapshotWrong(&w, c);
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6567 (2): db.* listings fail, never answer short, when a body cannot be read" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var wrong: usize = 0;
    for (cases) |c| wrong += try sweep(&w, c);
    try testing.expectEqual(@as(usize, 0), wrong);
}
