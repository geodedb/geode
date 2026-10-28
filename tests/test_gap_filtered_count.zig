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
const graph_storage_adapter = geode.graph_storage_adapter;

const N_NODES: usize = 500;
const N_COL: usize = 300; // ordinal 0..299  -> source='col'
const N_X: usize = 200; //  ordinal 300..499 -> source='x'

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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

    /// Run a statement and discard its result (for CREATE seeding).
    fn exec(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    /// Run a `RETURN count(...)` query and return the single integer result.
    fn countOf(self: *Harness, query: []const u8) !i64 {
        var r = try self.runQuery(query);
        defer r.deinit(self.arena.allocator());
        return r.rows[0][0].Int;
    }

    /// Differential assertion: the streaming filtered-count fast path for
    /// `fast_query` must (1) materialize ZERO rows (delta == 0, proving the fast
    /// path fired) and (2) return EXACTLY the same count as `oracle_query`, the
    /// general materialize/eval path (an AND-compound predicate that DECLINES the
    /// fast path and runs the row-by-row executor — the oracle). `oracle_query`
    /// is constructed so the extra AND clause is true for every seeded node, so
    /// the two counts must be identical.
    fn expectFastMatchesOracle(
        self: *Harness,
        fast_query: []const u8,
        oracle_query: []const u8,
    ) !void {
        planned_read_runtime.resetPathRowsMaterialized();
        const fast = try self.countOf(fast_query);
        const fast_delta = planned_read_runtime.getPathRowsMaterialized();

        planned_read_runtime.resetPathRowsMaterialized();
        const oracle = try self.countOf(oracle_query);
        const oracle_delta = planned_read_runtime.getPathRowsMaterialized();

        // The fast path streamed (no per-row materialize)...
        try testing.expectEqual(@as(u64, 0), fast_delta);
        // ...the oracle ran the general (materializing) path...
        try testing.expect(oracle_delta > 0);
        // ...and both produced the SAME count.
        try testing.expectEqual(oracle, fast);
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

// ---------------------------------------------------------------------------
// Differential parity tests (fast filtered-count == general/eval oracle).
//
// These cover the reviewer-found divergences between the per-slot fast-path
// comparison and the materialize/eval.zig WHERE semantics. Each was RED before
// the comparison delegated to `eval.evalBinary` (string ordering counted 0, NFC
// eq under-counted, str<->int eq missed) and is GREEN after, matching the
// general path exactly.
// ---------------------------------------------------------------------------

// BUG #1 (CRITICAL): string ordering predicates returned 0 instead of the true
// count. eval does NFC-normalized lexicographic ordering; the fast path must
// agree.
test "DIFFERENTIAL: string ordering n.name > 'm' / <= 'x' == general oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const names = [_][]const u8{ "alpha", "mango", "nova", "zeta", "mike", "yak" };
    for (names) |nm| {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:S {{name: '{s}', tag: 1}})", .{nm});
        try h.exec(q);
    }

    // > 'm' : mango, mike, nova, yak, zeta → 5 (alpha excluded).
    try h.expectFastMatchesOracle(
        "MATCH (n:S) WHERE n.name > 'm' RETURN count(n) AS c",
        "MATCH (n:S) WHERE n.name > 'm' AND n.tag = 1 RETURN count(n) AS c",
    );
    // <= 'x' : alpha, mango, mike, nova → 4 (yak, zeta excluded).
    try h.expectFastMatchesOracle(
        "MATCH (n:S) WHERE n.name <= 'x' RETURN count(n) AS c",
        "MATCH (n:S) WHERE n.name <= 'x' AND n.tag = 1 RETURN count(n) AS c",
    );
}

// BUG #2 (NFC eq): a property stored in a canonically-equal but byte-different
// Unicode form must compare equal to the literal (eval NFC-normalizes; the fast
// path previously used raw-byte std.mem.eql and under-counted).
test "DIFFERENTIAL: NFC eq (decomposed property == composed literal) == oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // "café" with é stored DECOMPOSED as 'e' + U+0301 (combining acute):
    //   bytes: c a f e 0xCC 0x81
    try h.exec("CREATE (:V {name: 'cafe\xCC\x81', tag: 1})");
    try h.exec("CREATE (:V {name: 'other', tag: 1})");

    // Literal "café" with é COMPOSED as U+00E9 (0xC3 0xA9). Byte-different from
    // the stored form, but NFC-equal → must match exactly one node.
    try h.expectFastMatchesOracle(
        "MATCH (n:V) WHERE n.name = 'caf\xC3\xA9' RETURN count(n) AS c",
        "MATCH (n:V) WHERE n.name = 'caf\xC3\xA9' AND n.tag = 1 RETURN count(n) AS c",
    );
}

// BUG #3 (str<->int eq coercion): eval stringifies and compares across Str/Int
// for = / !=; the fast path previously returned false for the cross-type pair.
test "DIFFERENTIAL: str<->int eq/ne coercion == general oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.exec("CREATE (:W {code: '5', tag: 1})"); // string "5"
    try h.exec("CREATE (:W {code: 5, tag: 1})"); //   int 5
    try h.exec("CREATE (:W {code: '7', tag: 1})"); // string "7"

    // = 5  → both the string "5" and the int 5 stringify-coerce equal → 2.
    try h.expectFastMatchesOracle(
        "MATCH (n:W) WHERE n.code = 5 RETURN count(n) AS c",
        "MATCH (n:W) WHERE n.code = 5 AND n.tag = 1 RETURN count(n) AS c",
    );
    // = '5' → string "5" eq, int 5 stringify-coerce equal → 2.
    try h.expectFastMatchesOracle(
        "MATCH (n:W) WHERE n.code = '5' RETURN count(n) AS c",
        "MATCH (n:W) WHERE n.code = '5' AND n.tag = 1 RETURN count(n) AS c",
    );
    // != 5 → only the string "7" survives → 1.
    try h.expectFastMatchesOracle(
        "MATCH (n:W) WHERE n.code != 5 RETURN count(n) AS c",
        "MATCH (n:W) WHERE n.code != 5 AND n.tag = 1 RETURN count(n) AS c",
    );
}

// Numeric eq / ordering / ne parity (regression guard — already worked, must
// stay equal to the oracle after the eval delegation).
test "DIFFERENTIAL: numeric eq / ordering / ne == general oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:N {{ordinal: {d}, tag: 1}})", .{i});
        try h.exec(q);
    }

    try h.expectFastMatchesOracle(
        "MATCH (n:N) WHERE n.ordinal = 5 RETURN count(n) AS c",
        "MATCH (n:N) WHERE n.ordinal = 5 AND n.tag = 1 RETURN count(n) AS c",
    );
    try h.expectFastMatchesOracle(
        "MATCH (n:N) WHERE n.ordinal >= 8 RETURN count(n) AS c",
        "MATCH (n:N) WHERE n.ordinal >= 8 AND n.tag = 1 RETURN count(n) AS c",
    );
    try h.expectFastMatchesOracle(
        "MATCH (n:N) WHERE n.ordinal != 3 RETURN count(n) AS c",
        "MATCH (n:N) WHERE n.ordinal != 3 AND n.tag = 1 RETURN count(n) AS c",
    );
}

// ---------------------------------------------------------------------------
// eval.evalBinary string-compare ASCII fast-path (perf/coldopen-loop1-prop_head).
//
// The `l == .Str and r == .Str` branch of eval.evalBinary previously spun up a
// fresh DebugAllocator and heap-allocated two NFC-normalized copies PER CALL
// (catastrophic in per-row WHERE/filter/join scans). The fix adds an ASCII fast
// path: when BOTH operands are pure ASCII, NFC is the identity, so it compares
// the raw bytes directly with zero allocation. Non-ASCII operands still route
// through nfcNormalize (using the caller-provided allocator, not a per-call one)
// for Unicode correctness.
//
// `eval.nfc_fallback_count` is a test-only counter incremented ONLY on the
// non-ASCII NFC fallback, letting us assert the fast path engages without
// changing results.
// ---------------------------------------------------------------------------
test "eval ASCII fast path engages (no NFC alloc) yet stays byte-identical; non-ASCII still NFC" {
    const eval = geode.eval;
    const Value = eval.Value;
    const alloc = testing.allocator;

    // ---- ASCII correctness: results identical to NFC-then-compare ----
    eval.nfc_fallback_count = 0;
    const col_a = Value{ .Str = "col" };
    const col_b = Value{ .Str = "col" };
    const aa = Value{ .Str = "a" };
    const bb = Value{ .Str = "b" };

    try testing.expect((try eval.evalBinary(alloc, .Eq, col_a, col_b)).Bool); // 'col' == 'col'
    try testing.expect(!(try eval.evalBinary(alloc, .Ne, col_a, col_b)).Bool);
    try testing.expect((try eval.evalBinary(alloc, .Lt, aa, bb)).Bool); // a < b
    try testing.expect((try eval.evalBinary(alloc, .Gt, bb, aa)).Bool); // b > a
    try testing.expect((try eval.evalBinary(alloc, .Le, col_a, col_b)).Bool);
    try testing.expect((try eval.evalBinary(alloc, .Ge, col_a, col_b)).Bool);
    try testing.expect(!(try eval.evalBinary(alloc, .Eq, aa, bb)).Bool);

    // All-ASCII: the NFC fallback must NOT have run at all.
    try testing.expectEqual(@as(usize, 0), eval.nfc_fallback_count);

    // ---- Non-ASCII NFC equivalence: composed É == decomposed E+U+0301 ----
    eval.nfc_fallback_count = 0;
    const composed = Value{ .Str = "\xC3\x89" }; // U+00C9 composed
    const decomposed = Value{ .Str = "E\xCC\x81" }; // 'E' + U+0301
    try testing.expect((try eval.evalBinary(alloc, .Eq, composed, decomposed)).Bool);
    try testing.expect(!(try eval.evalBinary(alloc, .Ne, composed, decomposed)).Bool);
    try testing.expect(eval.nfc_fallback_count > 0); // fallback engaged

    // ---- Mixed (ASCII vs non-ASCII): must take NFC path, must not shortcut ----
    eval.nfc_fallback_count = 0;
    const ascii_e = Value{ .Str = "E" };
    try testing.expect(!(try eval.evalBinary(alloc, .Eq, ascii_e, composed)).Bool);
    try testing.expect(eval.nfc_fallback_count > 0);
}

// ---------------------------------------------------------------------------
// GAP-ENT-0019: selective indexed-equality filtered count uses an exact-index
// SEEK (O(matching)) instead of the O(label) scan — WITHOUT changing the count.
//
// Seed N nodes each with a UNIQUE indexed string key `source_id='colK'` and a
// common indexed string key `source='col'`. Assertions:
//   * `count WHERE source_id='col5'` == 1 AND the exact-index lookup counter
//     advanced (the seek fired). RED pre-fix: full scan, counter delta == 0.
//   * `count WHERE source='col'` == N (all match) — seek returns N candidates,
//     count still exact.
//   * a NON-equality predicate (`ordinal < K`) and a NUMERIC-looking string are
//     NOT seeked (counter delta == 0) yet return the exact count via the scan.
// The counts must equal the full-scan oracle in every case.
// ---------------------------------------------------------------------------

const SEEK_N: usize = 400;

fn seedUnique(h: *Harness) !void {
    var i: usize = 0;
    while (i < SEEK_N) : (i += 1) {
        const aa = h.arena.allocator();
        // source_id is unique per node; source is common; ordinal is numeric.
        const q = try std.fmt.allocPrint(
            aa,
            "CREATE (:U {{source_id: 'col{d}', source: 'col', ordinal: {d}}})",
            .{ i, i },
        );
        try h.exec(q);
    }
}

test "GAP-ENT-0019: selective source_id='col5' count == 1 via exact-index seek" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedUnique(&h);

    // SELECTIVE: exactly one node has source_id='col5'.
    graph_storage_adapter.resetLookupCounters();
    const before = graph_storage_adapter.getExactNodePropertyLookupCount();
    const c = try h.countOf("MATCH (n:U) WHERE n.source_id = 'col5' RETURN count(n) AS c");
    const delta = graph_storage_adapter.getExactNodePropertyLookupCount() - before;

    try testing.expectEqual(@as(i64, 1), c);
    // The seek fired: the exact node-property index was probed (RED pre-fix: the
    // full-scan path never calls getCandidateNodesByLabelAndProperty → delta 0).
    try testing.expect(delta >= 1);
}

test "GAP-ENT-0019: common source='col' count == N (all match, still exact)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedUnique(&h);

    const c = try h.countOf("MATCH (n:U) WHERE n.source = 'col' RETURN count(n) AS c");
    try testing.expectEqual(@as(i64, @intCast(SEEK_N)), c);

    // A miss (no such value) must count exactly 0 through the seek.
    const zero = try h.countOf("MATCH (n:U) WHERE n.source_id = 'nope' RETURN count(n) AS c");
    try testing.expectEqual(@as(i64, 0), zero);
}

test "GAP-ENT-0019: non-equality predicate is NOT seeked but still exact via scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedUnique(&h);

    // Ordering predicate: not an equality → no seek → full scan. ordinal<10 → 10.
    graph_storage_adapter.resetLookupCounters();
    const before = graph_storage_adapter.getExactNodePropertyLookupCount();
    const c = try h.countOf("MATCH (n:U) WHERE n.ordinal < 10 RETURN count(n) AS c");
    const delta = graph_storage_adapter.getExactNodePropertyLookupCount() - before;

    try testing.expectEqual(@as(i64, 10), c);
    try testing.expectEqual(@as(u64, 0), delta); // scan path, no exact-index seek
}

test "GAP-ENT-0019: seek parity with full-scan oracle (selective + all-match)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedUnique(&h);

    // The AND-compound oracle DECLINES the seek/fast path and runs the general
    // materialize/eval scan; the extra clause (ordinal >= 0) is true for all, so
    // the seek and the oracle must return the SAME count.
    try h.expectFastMatchesOracle(
        "MATCH (n:U) WHERE n.source_id = 'col5' RETURN count(n) AS c",
        "MATCH (n:U) WHERE n.source_id = 'col5' AND n.ordinal >= 0 RETURN count(n) AS c",
    );
    try h.expectFastMatchesOracle(
        "MATCH (n:U) WHERE n.source = 'col' RETURN count(n) AS c",
        "MATCH (n:U) WHERE n.source = 'col' AND n.ordinal >= 0 RETURN count(n) AS c",
    );
}
