// SONNY-6567 (3): a fulltext search hit whose node cannot be READ fails the
// search; a hit whose node no longer exists is skipped.
//
// `fts_dispatch.filterAuthorizedHits` resolves each hit's node (resident, or
// rebuilt from the engine when the bounded node cache evicted it) and keeps
// it if the caller may see it. The rebuild's error was turned into "no such
// node" (`getOrHydrate catch null orelse continue`), so a hit that could not
// be read (out of memory, an engine read error) was silently left out: a
// short result reported as a success. A node that is gone (deleted, the
// index stale) may be skipped; a node that could not be read must fail the
// search; a node the caller may not see is filtered, not an error.
//
// The store, parser and executor are real (the `test-fts-authorization`
// harness). The node cache's allocator (the one an evicted node is rebuilt
// with) is wrapped in one that can be made to fail: the indexed node is
// evicted from the node cache, then the search runs with those allocations
// failing from the k-th one on, for every k up to the
// first run that needs none. Each run must return the hit or fail; it must
// never succeed without it. A node deleted since indexing is skipped; a node
// of another tenant is filtered.
//
// CANARY: REQ=REQ-SONNY-6567-FTS-UNREADABLE-HIT; FEATURE="FullText"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_fts_unreadable_hit.zig; OWNER=fts; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

const MAX_SWEEP: usize = 4000;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// The `test-fts-authorization` harness, with the store on `store_allocator`.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator, store_allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(store_allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
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

    /// A CALL in a transaction body: it resolves its hits against the store
    /// itself, not a read snapshot that rebuilds every node first (see
    /// `test-fts-authorization`'s `runQueryUnsnapshotted`).
    fn search(self: *Harness, call_query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        const wrapped = try std.fmt.allocPrint(aa, "START TRANSACTION {{ {s} }}", .{call_query});
        var parsed = try geode.parseGql(wrapped, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn ok(self: *Harness, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn singleId(self: *Harness, query: []const u8) !u64 {
        var r = try self.run(query);
        defer r.deinit(self.arena.allocator());
        if (r.rows.len != 1) return error.UnexpectedRows;
        return @intCast(r.rows[0][0].Int);
    }
};

test "SONNY-6567 (3): a search hit whose node cannot be read fails the search, never drops silently" {
    var h = try Harness.init(testing.allocator, testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const store = graph_store.getGlobalStore(testing.allocator);
    store.installNodeCacheHydrate();
    // The store's memory is `smp_allocator` (`graph_store.global_allocator`);
    // the cache rebuilds an evicted node with `store.nodes.allocator`. Wrap
    // that one (frees still reach smp_allocator) for the sweep.
    var failing = std.testing.FailingAllocator.init(store.nodes.allocator, .{});
    const cache_allocator = store.nodes.allocator;
    store.nodes.allocator = failing.allocator();
    defer store.nodes.allocator = cache_allocator;

    try h.ok("CREATE (:Fts6567 {body: 'unreadable hit widget'})");
    const node_id = try h.singleId("MATCH (n:Fts6567) RETURN id(n)");
    try h.ok("CREATE INDEX fts6567_idx FOR (d:Fts6567) ON (d.body) USING fulltext");

    var silent: usize = 0;
    var failed: usize = 0;
    var runs: usize = 0;
    var k: usize = 0;
    while (k < MAX_SWEEP) : (k += 1) {
        store.nodes.remove(node_id); // evicted, not deleted
        failing.has_induced_failure = false;
        failing.fail_index = failing.alloc_index + k;
        const outcome = h.search("CALL geode.fts.search('fts6567_idx', 'widget')");
        failing.fail_index = std.math.maxInt(usize);
        const induced = failing.has_induced_failure;
        runs += 1;
        if (outcome) |res_const| {
            var res = res_const;
            defer res.deinit(aa);
            if (res.rows.len != 1) {
                silent += 1;
                std.debug.print("SONNY-6567 (3) store allocation {d} failing: the search succeeded with {d} rows (the hit dropped)\n", .{ k, res.rows.len });
            }
        } else |_| failed += 1;
        // A run no failure reached: every allocation the search makes was failed once.
        if (!induced) break;
    }
    std.debug.print("SONNY-6567 (3) {d} runs: {d} failed, {d} answered without the hit\n", .{ runs, failed, silent });
    try testing.expectEqual(@as(usize, 0), silent);

    // With nothing failing, the evicted node's hit is found.
    store.nodes.remove(node_id);
    {
        var res = try h.search("CALL geode.fts.search('fts6567_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }

    // A node deleted since indexing (the posting stale) is skipped, not an error.
    store.deleteNode(node_id);
    {
        var res = try h.search("CALL geode.fts.search('fts6567_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
}

test "SONNY-6567 (3): a hit the caller may not see is filtered, not an error" {
    var h = try Harness.init(testing.allocator, testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    const store = graph_store.getGlobalStore(testing.allocator);
    store.installNodeCacheHydrate();

    h.ctx.tenant_id = "tenant_a";
    var mine: u64 = undefined;
    {
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        try h.ok("CREATE (:Fts6567T {body: 'tenant widget'})");
        mine = try h.singleId("MATCH (n:Fts6567T) RETURN id(n)");
    }
    h.ctx.tenant_id = "tenant_b";
    {
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        try h.ok("CREATE (:Fts6567T {body: 'tenant widget'})");
    }
    h.ctx.tenant_id = null;
    try h.ok("CREATE INDEX fts6567_t_idx FOR (d:Fts6567T) ON (d.body) USING fulltext");

    var all = try h.run("MATCH (n:Fts6567T) RETURN id(n)");
    defer all.deinit(aa);
    try testing.expectEqual(@as(usize, 2), all.rows.len);
    for (all.rows) |row| store.nodes.remove(@intCast(row[0].Int));

    h.ctx.tenant_id = "tenant_a";
    defer h.ctx.tenant_id = null;
    var res = try h.search("CALL geode.fts.search('fts6567_t_idx', 'widget')");
    defer res.deinit(aa);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, @intCast(mine)), res.rows[0][0].Int);
}
