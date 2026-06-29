// Filtered-count streaming fast path.
//
// `MATCH (n:T) WHERE n.<key> OP <lit> RETURN count(n)` MUST be served by a
// STREAMING count: enumerate the label's slots, test the predicate per slot
// reading ONLY the predicate's key, increment a counter — with NO full-node row
// materialization. The discriminator is `planned_read_runtime.getPathRowsMaterialized()`:
//
//   * pre-fix (RED): the query falls through every aggregate fast path to
//     `planned_read_runtime.executeIfSupported`, which calls
//     `materializeNodeOnlyRow` (a FULL node materialize + binding row) once per
//     MATCHING node and increments `g_path_rows_materialized` per row — then an
//     Aggregate counts the rows. Counter delta ~= number of matches.
//
//   * post-fix (GREEN): a dedicated streaming filtered-count fast path tallies
//     matches without materializing any node row. Counter delta == 0.
//
// Correctness gates preserved: an unfiltered `count(n)` still uses the O(1)
// label-refcount fast path (counter == 0, count exact); a GROUP BY / DISTINCT /
// non-simple (AND/OR) WHERE shape is NOT wrongly routed — it falls through to
// the correct existing path and returns the right answer.
//
// CANARY: REQ=REQ-PERF-FILTERED-COUNT; FEATURE="FilteredCountStreaming"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap_filtered_count.zig; OWNER=execution; UPDATED=2026-06-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const planned_read_runtime = geode.planned_read_runtime;

const N_NODES: usize = 500;
const N_COL: usize = 300; // ordinal 0..299  -> source='col'
const N_X: usize = 200; //  ordinal 300..499 -> source='x'

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .store = store,
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
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    // Seed N nodes: ordinal 0..N-1; source='col' for the first N_COL, else 'x'.
    fn seed(self: *Harness) !void {
        var i: usize = 0;
        while (i < N_NODES) : (i += 1) {
            const aa = self.arena.allocator();
            const src = if (i < N_COL) "col" else "x";
            const q = try std.fmt.allocPrint(
                aa,
                "CREATE (:T {{source: '{s}', ordinal: {d}}})",
                .{ src, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

test "filtered count(n) WHERE pred is streamed (no per-row materialize), count exact" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    planned_read_runtime.resetPathRowsMaterialized();
    var res = try h.runQuery("MATCH (n:T) WHERE n.source = 'col' RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());
    const delta = planned_read_runtime.getPathRowsMaterialized();

    // Correctness: exactly the 300 'col' nodes.
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, @intCast(N_COL)), res.rows[0][0].Int);

    // Streaming discriminator: pre-fix this is ~N_COL (one materialized row per
    // match); post-fix it MUST be 0 (no row materialization at all).
    try testing.expectEqual(@as(u64, 0), delta);
}

test "filtered count(*) numeric WHERE is streamed, count exact" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    planned_read_runtime.resetPathRowsMaterialized();
    var res = try h.runQuery("MATCH (n:T) WHERE n.ordinal < 150 RETURN count(*) AS c");
    defer res.deinit(h.arena.allocator());
    const delta = planned_read_runtime.getPathRowsMaterialized();

    try testing.expectEqual(@as(i64, 150), res.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), delta);
}

test "unfiltered count(n) still uses O(1) label refcount (no materialize)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    planned_read_runtime.resetPathRowsMaterialized();
    var res = try h.runQuery("MATCH (n:T) RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());
    const delta = planned_read_runtime.getPathRowsMaterialized();

    try testing.expectEqual(@as(i64, @intCast(N_NODES)), res.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), delta);
}

test "FALLBACK: GROUP BY filtered count is not wrongly routed, still correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    // GROUP BY over the single 'col' group → one row, count 300.
    var res = try h.runQuery("MATCH (n:T) WHERE n.source = 'col' RETURN n.source AS s, count(n) AS c GROUP BY n.source");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, @intCast(N_COL)), res.rows[0][1].Int);
}

test "FALLBACK: DISTINCT count over both sources, correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    // DISTINCT sources → 2 distinct values ('col','x').
    var res = try h.runQuery("MATCH (n:T) RETURN DISTINCT n.source");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 2), res.rows.len);
}

test "FALLBACK: compound (AND) WHERE count is not wrongly routed, still correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    // AND is not a simple `key OP lit`; the streaming fast path must DECLINE
    // and the existing planned path must return the correct count.
    // source='col' AND ordinal<150 → ordinals 0..149 → 150.
    var res = try h.runQuery("MATCH (n:T) WHERE n.source = 'col' AND n.ordinal < 150 RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, 150), res.rows[0][0].Int);
}
