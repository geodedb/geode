// CANARY: REQ=REQ-GQL-FTS-STORAGE-PERF-001; FEATURE="FtsStorageBackend"; ASPECT=SearchLatencyGate; STATUS=TESTED; TEST=tests/test_fts_latency.zig; OWNER=storage; UPDATED=2026-05-31
//
// CI-aware latency gate for the fts-storage-backed full-text-search path.
//
// Geode's FTS is backed by the `fts_storage` library through
// `src/storage/fts_storage_adapter.zig`; the GQL surface is
// `CALL geode.fts.search(index, query[, max])`, with documents auto-indexed on
// CREATE once a `CREATE FULLTEXT INDEX ... FOR (n:Label) ON (n.prop)` exists
// (see tests/test_fts_e2e.zig and ../geode-test-harness/geode-cli/specs/fts/
// fts_basic.yml for the canonical end-to-end sequence this mirrors).
//
// This test exercises the real store + real parser + real executor (no mocks),
// mirroring tests/test_gap0811_aggregation_fastpath.zig: seed a known :Doc
// corpus + a fulltext index, run the CALL, and assert BOTH correctness (the
// expected rows come back) and — outside CI — a strict latency upper bound.
//
// The latency budget is generous (single-core, and the search walks the WAL/
// memtable + segment posting lists for the term). The CI skip is applied for
// the same reason as the other perf-gate tests: the local pre-push runs many
// shards >> cores, which makes a wall-clock budget meaningless there. The
// correctness assertions always run.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat helper (copied from test_gap0811_aggregation_fastpath.zig).
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Harness mirrors tests/test_gap0811_aggregation_fastpath.zig and
/// tests/test_fts_e2e.zig: route query allocations through an arena, install a
/// data-dir override, lazy-init the global store via getGlobalStore.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "FTS latency: CALL geode.fts.search returns matching docs within budget" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();

    // 1) Seed a small :Doc corpus BEFORE the index (backfill path — the same
    //    sequence tests/test_fts_e2e.zig validates). "quick" appears in two
    //    docs, "zebra" in none.
    {
        var r = try h.runQuery("CREATE (:Doc {id: 1, body: 'the quick brown fox jumps over the lazy dog'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE (:Doc {id: 2, body: 'a quick red fox and a slow brown bear'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE (:Doc {id: 3, body: 'lorem ipsum dolor sit amet consectetur'})");
        r.deinit(aa);
    }

    // 2) Create the fulltext index (backfills the three existing nodes). Uses
    //    the proven GQL DDL form: CREATE INDEX <name> FOR (d:Doc) ON (d.body)
    //    USING fulltext (see tests/test_fts_e2e.zig).
    {
        var r = try h.runQuery("CREATE INDEX doc_fts FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // Warm up (caches / first-allocation amortization). Untimed.
    {
        var warm = try h.runQuery("CALL geode.fts.search('doc_fts', 'quick')");
        warm.deinit(aa);
    }

    // Timed: a single CALL geode.fts.search.
    const t0 = compat_nanoTimestamp();
    var res = try h.runQuery("CALL geode.fts.search('doc_fts', 'quick')");
    defer res.deinit(aa);
    const elapsed_ns = compat_nanoTimestamp() - t0;

    // Correctness ALWAYS runs: "quick" is in docs 1 and 2, so at least two
    // rows must come back.
    try testing.expect(res.rows.len >= 2);

    // A term present in no document returns zero rows (sanity on the search
    // path, not just "always returns everything").
    {
        var none = try h.runQuery("CALL geode.fts.search('doc_fts', 'zebra')");
        defer none.deinit(aa);
        try testing.expectEqual(@as(usize, 0), none.rows.len);
    }

    // Latency smoke. Budget is deliberately generous for a single-core box
    // (search drains the term's posting list across memtable + segments).
    // Skipped under CI/oversubscription for the same reason as the other
    // perf-gate tests; the correctness assertions above always run.
    if (std.c.getenv("CI") == null) {
        try testing.expect(elapsed_ns < 50_000_000); // 50 ms
    }
}
