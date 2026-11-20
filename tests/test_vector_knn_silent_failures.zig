// geode#873 / geode#877 (ENG-3905 reopen) / geode#875(i) residual —
// the vector surface's silent-wrong-answer and crash defects.
//
// Every defect below was live-verified READ-ONLY against this branch's parent
// (v0.8.8 / 587e6801) before a line of the fix was written. They share one
// shape: a vector query that returns a WRONG answer (or kills the process)
// with SQLSTATE 00000 — the caller cannot tell "no data" from "broken".
//
// ---------------------------------------------------------------------------
// F1 (#873-A) — vector_dot() truncates its result to an integer.
//
//     src/eval_extended.zig:2114   return .{ .Int = @intFromFloat(sum) };
//
//   Its two siblings in the same file return a scale-6 Decimal:
//     vectorL2      -> .Decimal{ .coeff = @intFromFloat(dist * 1e6), .scale = 6 }
//     vectorCosine  -> .Decimal{ .coeff = @intFromFloat(sim  * 1e6), .scale = 6 }
//   and the CONTRACT already advertises FLOAT:
//     src/gql/language_metadata.zig:1000-1002 and
//     src/execution/statement_handlers.zig:444  ("(vector, vector) -> FLOAT").
//   So every unit-vector dot product — the dominant RAG/reranking use — floors
//   to 0, and 0.96 is indistinguishable from "orthogonal".
//
// F2 (#873-B, P0 denial of service) — the unchecked @intFromFloat in the same
//   family panics the WHOLE SERVER on a large-magnitude operand:
//
//     RETURN vector_dot(vectorf32([1e20,1e20]), vectorf32([1e20,1e20]))
//
//   The accumulated magnitude exceeds the destination integer and
//   `@intFromFloat` of an out-of-range/NaN float is illegal behaviour. Verified
//   live, it has TWO faces:
//     * PANIC (process abort) — vector_dot (eval_extended.zig:2114), vector_l2
//       (:2128), and every eval.zig:2390 surface (distance / euclidean /
//       manhattan / similarity-with-dot_product). A single unauthenticated
//       query takes the server down.
//     * SILENT GARBAGE — vectorCosine (:2148) accumulates in f32, so the ratio
//       becomes NaN and the conversion yields i128 MIN: a "cosine similarity"
//       of -1.7e32 returned with SQLSTATE 00000.
//   The fix is a CHECKED conversion returning error.DecimalOverflow, plus f64
//   accumulation in the cosine lane so a well-defined ratio stays a ratio.
//
// F3 (#877 (b)) — an unrelated vector index shadows the brute-force scan.
//   `evalVectorKnn` COMMITS to the index the moment one is found
//   (src/eval.zig:2459) and falls back only on error.IndexNotFound (:2462);
//   an HNSW index with no matching entries returns an EMPTY slice, not an
//   error (src/index/advanced_types_index.zig:527-529). Worse,
//   `findAdvancedVectorIndexForProperty` matches on PROPERTY NAME ONLY and
//   ignores the label entirely (src/index/index_manager.zig:1416-1425), so
//   creating a vector index on a COMPLETELY UNRELATED label that happens to
//   reuse the property name silently empties a working knn result.
//
// F4 (#877 (a) / ENG-3905 residual) — a LIST-typed embedding property is
//   invisible to knn. `propertyVectorCandidate` accepts only VectorF32 /
//   VectorI32 and returns null for everything else (src/eval.zig:2205); the
//   index side skips identically (index_manager.zig:1779 / :1793). A node
//   written as `{embedding: [1.0, 0.0]}` — the natural shape for a JSON /
//   client-side embedding — is never a knn candidate and never errors.
//
// F5 (#877 (c)) — knn() on a MISSPELLED property returns []. `evalVectorKnn`
//   (src/eval.zig:2421-2486) never checks that the property exists, so a typo
//   is reported as "no neighbours". This pins the new distinct diagnostic
//   `error.UnknownProperty` (same class as the `error.UnknownFunction`
//   precedent from docs/@BUGS_731.md bug 8b), while keeping "property known,
//   zero scoreable rows" an EMPTY LIST.
//
// F6 (NEW, cross-graph data leak) — `scanVectorKnn` (src/eval.zig:2273-2321)
//   iterates the GLOBAL store with no graph_name / tenant_id filter, even
//   though `Node` carries both (src/graph_store.zig:855, :858). Verified live:
//   a session on one graph received node ids belonging to another graph.
//
// F7 (#875 (i) residual) — src/eval.zig has ZERO read_budget poll sites, so a
//   brute-force knn scan cannot be cancelled mid-scan. Pinned here with the
//   same mechanism tests/test_gap0044_read_budget_cancel.zig uses.
//
// NOTE ON TEST ORDER: the F2 cases PANIC before the fix. Zig's test runner
// isolates a crashed test, but they are still declared LAST so the F1/F3-F7
// evidence is never at the mercy of that.
//
// TWO NEW ERROR IDENTITIES this file pins (neither exists yet):
//   * error.DecimalOverflow already exists in value_types.EvalError but has NO
//     entry in src/server/proto_util.zig's mapError, so it currently falls
//     through to the generic 58000 internal-error class. It must map to 22003
//     (numeric_value_out_of_range), next to error.IntegerOverflow.
//   * error.UnknownProperty must be ADDED to value_types.EvalError, listed in
//     eval.isPropagatableEvalError (so a nested call does not collapse it to
//     NULL), and mapped to 42002 (invalid reference; 42703 before SONNY-6543) in proto_util.mapError.
// The over-the-wire twin of this file asserts both GQLSTATEs:
// ../geode-test-harness/geodetestlab-cli/specs/vector_knn_contract.yml
//
// CANARY: REQ=REQ-GEODE-873-VECTOR-DOT-FLOAT; FEATURE="VectorSimilarityFunctions"; ASPECT=DotProductIsFloat; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-873-VECTOR-DECIMAL-OVERFLOW; FEATURE="VectorSimilarityFunctions"; ASPECT=CheckedFloatToDecimal; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-877-KNN-INDEX-SHADOW; FEATURE="VectorKnn"; ASPECT=UnrelatedIndexMustNotShadowScan; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-877-KNN-LIST-PROPERTY; FEATURE="VectorKnn"; ASPECT=NumericListCoercion; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-877-KNN-UNKNOWN-PROPERTY; FEATURE="VectorKnn"; ASPECT=UnknownPropertyDiagnostic; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-877-KNN-GRAPH-ISOLATION; FEATURE="VectorKnn"; ASPECT=ScanRespectsSessionGraph; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
// CANARY: REQ=REQ-GEODE-875-KNN-SCAN-CANCELLABLE; FEATURE="VectorKnn"; ASPECT=ReadBudgetPoll; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const read_budget = geode.read_budget;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Harness — one real catalog + store driven through the real parser and
// executor (mirrors tests/test_eng3904_3905_vector_literals.zig). No mocks:
// every defect here lives in the evaluator/index seam, so both halves are real.
// ---------------------------------------------------------------------------

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
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        // The advanced-index registry is PROCESS-GLOBAL and is not torn down by
        // the catalog/store cleanups. Tests in this file create real vector
        // indexes, so it must be reset here and in deinit or a later test's
        // first vector write faults iterating a freed registry entry
        // (checkVectorDimensionForWrite -> index_manager.zig:1355). Same
        // discipline as tests/test_advanced_index_restart.zig:76/102.
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
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
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn run(self: *Harness, query: []const u8) !void {
        var r = try self.exec(query);
        r.deinit(self.arena.allocator());
    }

    /// First column of the first row.
    pub fn scalar(self: *Harness, query: []const u8) !Value {
        const res = try self.exec(query);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoRows;
        return res.rows[0][0];
    }

    /// The engine-assigned id of the single node matched by `query`, which must
    /// project `id(n)` as its only column.
    pub fn nodeId(self: *Harness, query: []const u8) !i64 {
        const v = try self.scalar(query);
        return switch (v) {
            .Int => |i| i,
            .BigInt => |i| i,
            else => {
                std.debug.print("\nFAIL: expected an Int node id, got Value.{s}\n", .{@tagName(v)});
                return error.ExpectedNodeId;
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Assertion helpers. Each prints the ACTUAL shape on failure so a red run is
// self-describing evidence rather than a bare "expected X".
// ---------------------------------------------------------------------------

/// A numeric result as f64. An `Int` is REJECTED loudly: the whole point of F1
/// is that a fractional score must not arrive as an integer.
fn floatScore(v: Value) !f64 {
    return switch (v) {
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @floatFromInt(d.scale)),
        .Double => |d| d,
        .Real => |r| @floatCast(r),
        .Int, .SmallInt, .BigInt => {
            std.debug.print(
                "\nFAIL: fractional score arrived as an INTEGER (Value.{s}) — truncated, not a FLOAT\n",
                .{@tagName(v)},
            );
            return error.ScoreTruncatedToInteger;
        },
        else => {
            std.debug.print("\nFAIL: expected a numeric score, got Value.{s}\n", .{@tagName(v)});
            return error.ExpectedNumericScore;
        },
    };
}

fn expectApproxScore(expected: f64, v: Value) !void {
    const actual = try floatScore(v);
    if (!std.math.approxEqAbs(f64, expected, actual, 1e-6)) {
        std.debug.print("\nFAIL: score {d} != expected {d} (tol 1e-6)\n", .{ actual, expected });
        return error.WrongScore;
    }
}

/// The knn id list as a slice of Values. A non-list result fails loudly.
fn knnIds(v: Value) ![]Value {
    return switch (v) {
        .List => |items| items,
        else => {
            std.debug.print("\nFAIL: knn() returned Value.{s}, not a LIST\n", .{@tagName(v)});
            return error.ExpectedKnnList;
        },
    };
}

fn idsContain(ids: []Value, want: i64) bool {
    for (ids) |v| {
        const got: i64 = switch (v) {
            .Int => |i| i,
            .BigInt => |i| i,
            else => continue,
        };
        if (got == want) return true;
    }
    return false;
}

fn printIds(label: []const u8, ids: []Value) void {
    std.debug.print("\n  {s} -> {d} id(s): [", .{ label, ids.len });
    for (ids, 0..) |v, i| {
        if (i != 0) std.debug.print(", ", .{});
        switch (v) {
            .Int => |x| std.debug.print("{d}", .{x}),
            .BigInt => |x| std.debug.print("{d}", .{x}),
            else => std.debug.print("<{s}>", .{@tagName(v)}),
        }
    }
    std.debug.print("]\n", .{});
}

fn expectIdsContain(label: []const u8, ids: []Value, want: i64) !void {
    if (!idsContain(ids, want)) {
        std.debug.print("\nFAIL: {s}: knn result is missing node id {d}", .{ label, want });
        printIds(label, ids);
        return error.KnnMissingExpectedNode;
    }
}

fn expectIdsExclude(label: []const u8, ids: []Value, unwanted: i64) !void {
    if (idsContain(ids, unwanted)) {
        std.debug.print("\nFAIL: {s}: knn result LEAKED node id {d}", .{ label, unwanted });
        printIds(label, ids);
        return error.KnnLeakedForeignNode;
    }
}

// ===========================================================================
// F1 (#873-A) — vector_dot() must be a FLOAT, matching its advertised contract
// and its two siblings in the same file.
// ===========================================================================

test "geode#873-A: vector_dot of two unit vectors is a fractional FLOAT, not a truncated Int" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // 0.6*0.8 + 0.8*0.6 = 0.96. RED: Value.Int = 0 — a perfectly good
    // similarity reported as "orthogonal".
    const v = try h.scalar("RETURN vector_dot(vectorf32([0.6, 0.8]), vectorf32([0.8, 0.6])) AS d");
    try expectApproxScore(0.96, v);
}

test "geode#873-A: an integral vector_dot is still FLOAT-typed with the right value" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // 1*4 + 2*5 + 3*6 = 32. RED: Value.Int = 32 — numerically right, but the
    // wrong TYPE, which is what silently floors every fractional sibling call.
    const v = try h.scalar("RETURN vector_dot(vectorf32([1.0,2.0,3.0]), vectorf32([4.0,5.0,6.0])) AS d");
    try expectApproxScore(32.0, v);

    // Sign must survive the conversion.
    const n = try h.scalar("RETURN vector_dot(vectorf32([1.0, 0.0]), vectorf32([-0.5, 0.0])) AS d");
    try expectApproxScore(-0.5, n);
}

test "geode#873-A control: the vector_dot SIBLINGS already answer as scale-6 FLOATs" {
    // Green today. Pins the exact output shape vector_dot must join, so a red
    // sibling above can only mean the dot-product defect.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try expectApproxScore(1.0, try h.scalar("RETURN vector_l2(vectorf32([0.0,0.0]), vectorf32([1.0,0.0])) AS d"));
    try expectApproxScore(1.0, try h.scalar("RETURN vector_cosine(vectorf32([1.0,0.0]), vectorf32([1.0,0.0])) AS d"));
    try expectApproxScore(0.0, try h.scalar("RETURN vector_cosine(vectorf32([1.0,0.0]), vectorf32([0.0,1.0])) AS d"));
    try expectApproxScore(1.0, try h.scalar("RETURN similarity(vectorf32([1.0,0.0]), vectorf32([1.0,0.0])) AS s"));
}

// ===========================================================================
// F3 (#877 (b)) — a vector index on an UNRELATED label must not empty knn.
// ===========================================================================

test "geode#877-b: a vector index on an unrelated label must not empty a working knn" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnshadow");
    try h.run("USE GRAPH knnshadow");
    try h.run("CREATE (:ShadowDoc {sid: 1, embedding: vectorf32([1.0, 0.0])})");
    try h.run("CREATE (:ShadowDoc {sid: 2, embedding: vectorf32([0.0, 1.0])})");

    const doc1 = try h.nodeId("MATCH (n:ShadowDoc {sid: 1}) RETURN id(n)");
    const doc2 = try h.nodeId("MATCH (n:ShadowDoc {sid: 2}) RETURN id(n)");

    // CONTROL (green today): the brute-force scan finds both documents.
    {
        const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
        try expectIdsContain("control (no index)", ids, doc1);
        try expectIdsContain("control (no index)", ids, doc2);
    }

    // A DIFFERENT label that merely REUSES the property name gets an index.
    // Nothing about :ShadowDoc changed.
    try h.run("CREATE (:UnrelatedThing {embedding: vectorf32([100.0, 100.0])})");
    try h.run("CREATE INDEX unrelated_vec_idx ON UnrelatedThing (embedding) USING vector");

    // KEY ASSERTION. RED: findAdvancedVectorIndexForProperty matches on the
    // property NAME alone, evalVectorKnn commits to that index, and the query
    // answers with the unrelated node (or nothing) — the two real documents
    // vanish with SQLSTATE 00000.
    {
        const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
        try expectIdsContain("after unrelated CREATE INDEX", ids, doc1);
        try expectIdsContain("after unrelated CREATE INDEX", ids, doc2);
    }

    // (ii) The same defect with an index that ends up EMPTY: drop the only row
    // the unrelated index covers. An index with no entries returns an empty
    // slice, NOT error.IndexNotFound, so the :2462 fallback never fires.
    try h.run("MATCH (n:UnrelatedThing) DELETE n");
    {
        const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
        try expectIdsContain("after unrelated index emptied", ids, doc1);
        try expectIdsContain("after unrelated index emptied", ids, doc2);
    }
}

// ===========================================================================
// F4 (#877 (a) / ENG-3905 residual) — LIST-typed embedding properties.
// ===========================================================================

test "geode#877-a: a numeric LIST embedding property is a knn candidate (scan path)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnlist");
    try h.run("USE GRAPH knnlist");
    try h.run("CREATE (:ListDoc {lid: 1, embedding: [1.0, 0.0]})");
    try h.run("CREATE (:ListDoc {lid: 2, embedding: [0.0, 1.0]})");

    const near = try h.nodeId("MATCH (n:ListDoc {lid: 1}) RETURN id(n)");
    const far = try h.nodeId("MATCH (n:ListDoc {lid: 2}) RETURN id(n)");

    // Control: the property really is stored as a list (not silently dropped).
    const stored = try h.scalar("MATCH (n:ListDoc {lid: 1}) RETURN n.embedding AS e");
    switch (stored) {
        .List => |items| try testing.expectEqual(@as(usize, 2), items.len),
        .ExtValue => |ext| switch (ext) {
            .List => |items| try testing.expectEqual(@as(usize, 2), items.len),
            .Array => {},
            else => {
                std.debug.print("\nFAIL: list property stored as ExtValue.{s}\n", .{@tagName(ext)});
                return error.ListPropertyNotStoredAsList;
            },
        },
        else => {
            std.debug.print("\nFAIL: list property stored as Value.{s}\n", .{@tagName(stored)});
            return error.ListPropertyNotStoredAsList;
        },
    }

    // KEY ASSERTION. RED: propertyVectorCandidate returns null for a List, so
    // BOTH documents are invisible and knn answers [].
    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
    try expectIdsContain("list-typed embedding", ids, near);
    try expectIdsContain("list-typed embedding", ids, far);

    // Metric ordering must be REAL, not incidental: the nearest neighbour of
    // [1,0] is the [1,0] document.
    if (ids.len == 0) return error.KnnReturnedNothing;
    const first: i64 = switch (ids[0]) {
        .Int => |i| i,
        .BigInt => |i| i,
        else => return error.ExpectedNodeId,
    };
    if (first != near) {
        std.debug.print("\nFAIL: nearest neighbour is id {d}, expected {d}", .{ first, near });
        printIds("list-typed embedding", ids);
        return error.WrongNearestNeighbour;
    }
}

test "geode#877-a: an integer LIST embedding is coerced; a non-numeric list is skipped, not an error" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnlistmix");
    try h.run("USE GRAPH knnlistmix");
    try h.run("CREATE (:MixDoc {mid: 1, embedding: [1, 0]})");
    try h.run("CREATE (:MixDoc {mid: 2, embedding: ['a', 'b']})");
    try h.run("CREATE (:MixDoc {mid: 3, embedding: [0.0, 1.0]})");

    const int_list = try h.nodeId("MATCH (n:MixDoc {mid: 1}) RETURN id(n)");
    const junk = try h.nodeId("MATCH (n:MixDoc {mid: 2}) RETURN id(n)");
    const float_list = try h.nodeId("MATCH (n:MixDoc {mid: 3}) RETURN id(n)");

    // An all-integer list is a legitimate vector (same coercion VectorI32 gets).
    // A list that is not numeric is simply not a candidate — skipped silently,
    // exactly as a String property is, and it must NOT poison the query.
    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
    try expectIdsContain("mixed lists", ids, int_list);
    try expectIdsContain("mixed lists", ids, float_list);
    try expectIdsExclude("mixed lists", ids, junk);
}

test "geode#877-a: a vector INDEX over a LIST-typed property serves knn too" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnlistidx");
    try h.run("USE GRAPH knnlistidx");
    try h.run("CREATE (:IdxListDoc {xid: 1, embedding: [1.0, 0.0]})");
    try h.run("CREATE (:IdxListDoc {xid: 2, embedding: [0.0, 1.0]})");

    const near = try h.nodeId("MATCH (n:IdxListDoc {xid: 1}) RETURN id(n)");
    const far = try h.nodeId("MATCH (n:IdxListDoc {xid: 2}) RETURN id(n)");

    // RED: vectorDimOfPropertyValue / vectorFromPropertyValue (index_manager
    // :1793 / :1779) skip List properties, so the index is built over nothing
    // and then SHADOWS the scan (F3) — the compounded silent empty result.
    try h.run("CREATE INDEX list_vec_idx ON IdxListDoc (embedding) USING vector");

    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
    try expectIdsContain("indexed list-typed embedding", ids, near);
    try expectIdsContain("indexed list-typed embedding", ids, far);
}

// ===========================================================================
// F5 (#877 (c)) — a misspelled property must be a DIAGNOSTIC, not [].
// ===========================================================================

test "geode#877-c: knn() on a property no row supplies raises UnknownProperty" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnunknown");
    try h.run("USE GRAPH knnunknown");
    try h.run("CREATE (:UnkDoc {uid: 1, embedding: vectorf32([1.0, 0.0])})");
    try h.run("CREATE (:UnkDoc {uid: 2, embedding: vectorf32([0.0, 1.0])})");

    // Control (green today): the correctly-spelled property answers.
    {
        const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
        try testing.expect(ids.len == 2);
    }

    // KEY ASSERTION. RED: silently returns an empty list, so a typo is
    // indistinguishable from "your data has no neighbours". The new error
    // identity mirrors the error.UnknownFunction precedent (docs/@BUGS_731.md
    // bug 8b) and needs its own EvalError arm + GQLSTATE mapping.
    try testing.expectError(
        error.UnknownProperty,
        h.exec("RETURN knn('embeddings', vectorf32([1.0,0.0]), 5, 'l2') AS ids"),
    );
    try testing.expectError(
        error.UnknownProperty,
        h.exec("RETURN vector_knn('no_such_prop_at_all', vectorf32([1.0,0.0]), 5, 'l2') AS ids"),
    );
}

test "geode#877-c guard: a KNOWN property with no scoreable vector still returns an empty list" {
    // The counter-contract to the test above: "property exists, zero
    // neighbours" must stay a clean empty result. The UnknownProperty
    // diagnostic must not be implemented as "empty result -> error".
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knnzero");
    try h.run("USE GRAPH knnzero");
    // The property IS supplied by a row — it just never yields a vector.
    try h.run("CREATE (:ZeroDoc {zid: 1, embedding: 'not-a-vector'})");
    try h.run("CREATE (:ZeroDoc {zid: 2, embedding: 'also-not-a-vector'})");

    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
    try testing.expectEqual(@as(usize, 0), ids.len);
}

// ===========================================================================
// F6 (NEW) — the brute-force scan must respect the session's graph.
// ===========================================================================

test "geode#877-F6: a knn scan must not return nodes from another graph" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knn_secret");
    try h.run("USE GRAPH knn_secret");
    // Deliberately the NEAREST vector to the probe below, so a leak cannot be
    // hidden by a k-cutoff.
    try h.run("CREATE (:SecretDoc {kid: 1, embedding: vectorf32([1.0, 0.0])})");
    const secret_id = try h.nodeId("MATCH (n:SecretDoc {kid: 1}) RETURN id(n)");

    try h.run("CREATE GRAPH knn_public");
    try h.run("USE GRAPH knn_public");
    try h.run("CREATE (:PublicDoc {kid: 2, embedding: vectorf32([0.0, 1.0])})");
    const public_id = try h.nodeId("MATCH (n:PublicDoc {kid: 2}) RETURN id(n)");

    // KEY ASSERTION. RED: scanVectorKnn walks the GLOBAL store with no
    // graph_name filter, so the session on knn_public receives knn_secret's
    // node id — and it sorts FIRST.
    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 10, 'l2') AS ids"));
    try expectIdsExclude("session on knn_public", ids, secret_id);
    try expectIdsContain("session on knn_public", ids, public_id);
}

// ===========================================================================
// F7 (#875 (i) residual) — the brute-force scan must be cancellable.
// ===========================================================================

test "geode#875-i: a brute-force knn scan polls the read cancel flag" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knncancel");
    try h.run("USE GRAPH knncancel");
    {
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            var buf: [160]u8 = undefined;
            try h.run(try std.fmt.bufPrint(
                &buf,
                "CREATE (:CancelDoc {{cid: {d}, embedding: vectorf32([{d}.0, 1.0])}})",
                .{ i, i },
            ));
        }
    }

    // The read scope is installed by the executor only for MATCH-carrying
    // shapes (src/execution/query_execution.zig:1656), and every such shape
    // ALREADY polls at its own row boundary — which would trip before
    // scanVectorKnn is ever entered and prove nothing. So this installs the
    // scope directly, exactly the way the transport handler does, around a
    // MATCH-free `RETURN knn(...)`: the ONLY poll site that can trip is one
    // inside the knn scan itself. Deterministic — the flag is already set, no
    // thread race, no wall-clock dependency.
    var cancel_flag = std.atomic.Value(bool).init(true); // client already gone
    read_budget.setStreamCancelSource(&cancel_flag);
    defer read_budget.setStreamCancelSource(null);

    var scope = read_budget.Scope.init();
    read_budget.beginScope(&scope);
    defer read_budget.endScope(&scope);

    // RED: src/eval.zig has no read_budget poll at all; the scan runs to
    // completion and returns a list. GREEN: aborts at a scan batch boundary.
    try testing.expectError(
        error.ReadQueryCancelled,
        h.exec("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"),
    );
}

test "geode#875-i guard: with no cancel set, the same scan completes normally" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH knncancelok");
    try h.run("USE GRAPH knncancelok");
    try h.run("CREATE (:OkDoc {oid: 1, embedding: vectorf32([1.0, 0.0])})");

    var scope = read_budget.Scope.init();
    read_budget.beginScope(&scope);
    defer read_budget.endScope(&scope);

    const ids = try knnIds(try h.scalar("RETURN knn('embedding', vectorf32([1.0,0.0]), 5, 'l2') AS ids"));
    try testing.expectEqual(@as(usize, 1), ids.len);
}

// ===========================================================================
// F2 (#873-B, P0) — DECLARED LAST ON PURPOSE.
//
// Before the fix each of these PANICS ("integer part of floating point value
// out of bounds" / NaN), which aborts the whole test binary — in production it
// aborts the SERVER. Keeping them last means the F1/F3-F7 evidence above is
// still produced by the same run.
// ===========================================================================

test "geode#873-B control: in-range magnitudes still answer (no over-eager rejection)" {
    // GREEN today and must stay green: the checked conversion may reject only
    // what genuinely does not fit an i128 scale-6 coefficient, never an
    // ordinary embedding magnitude. (vector_dot is exercised for the same
    // property by the F1 tests above; it is left out here so this control is
    // unambiguously a NO-REGRESSION guard rather than an F1 duplicate.)
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try expectApproxScore(2000.0, try h.scalar("RETURN vector_l2(vectorf32([1000.0]), vectorf32([-1000.0])) AS d"));
    try expectApproxScore(2000.0, try h.scalar("RETURN distance(vectorf32([1000.0]), vectorf32([-1000.0]), 'l2') AS d"));
    try expectApproxScore(2000.0, try h.scalar("RETURN euclidean(vectorf32([1000.0]), vectorf32([-1000.0])) AS d"));
    try expectApproxScore(2000.0, try h.scalar("RETURN manhattan(vectorf32([1000.0]), vectorf32([-1000.0])) AS d"));
    try expectApproxScore(1000000.0, try h.scalar("RETURN similarity(vectorf32([1000.0]), vectorf32([1000.0]), 'dot_product') AS s"));
}

test "geode#873-B: vector_dot with out-of-range magnitudes errors instead of panicking" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // f32 1e20 * 1e20 overflows to +inf inside the f32 accumulation loop;
    // @intFromFloat(+inf) is illegal behaviour -> process panic.
    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN vector_dot(vectorf32([1e20, 1e20]), vectorf32([1e20, 1e20])) AS d"),
    );
}

test "geode#873-B: vector_l2 with out-of-range magnitudes errors instead of panicking" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN vector_l2(vectorf32([1e35]), vectorf32([-1e35])) AS d"),
    );
}

test "geode#873-B: vector_cosine of large-magnitude vectors is a real ratio, not i128 garbage" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The OTHER face of the same unchecked conversion, verified live on
    // v0.8.8: `vectorCosine` accumulates in f32 (`dot_product += av * bv` with
    // two f32 operands, eval_extended.zig:2140-2144), so 1e20*1e20 saturates to
    // +inf, the ratio becomes inf/inf = NaN, and `@intFromFloat(NaN * 1e6)`
    // yields i128 MIN. The engine answers
    //
    //     RETURN vector_cosine(vectorf32([1e20,1e20]), vectorf32([1e20,1e20]))
    //     -> -170141183460469220000000000000000
    //
    // as a COSINE SIMILARITY — a quantity that is mathematically confined to
    // [-1, 1] — with SQLSTATE 00000. Two identical vectors have cosine
    // similarity 1.0 at every magnitude; the fix is the f64 accumulation its
    // eval.zig twin already uses (metricDistance, eval.zig:2164-2177), so an
    // error here would be just as wrong as the garbage.
    try expectApproxScore(1.0, try h.scalar("RETURN vector_cosine(vectorf32([1e20, 1e20]), vectorf32([1e20, 1e20])) AS d"));
    try expectApproxScore(0.0, try h.scalar("RETURN vector_cosine(vectorf32([1e20, 0.0]), vectorf32([0.0, 1e20])) AS d"));

    // GREEN today: the eval.zig sibling (f64 core) already gets this right,
    // which is what makes the divergence above a defect and not a limit.
    try expectApproxScore(1.0, try h.scalar("RETURN similarity(vectorf32([1e20, 1e20]), vectorf32([1e20, 1e20])) AS s"));
}

test "geode#873-B control: a NON-FINITE vector component is already refused at construction" {
    // The reason the cosine lane above has no inf-input case: 1e39 exceeds
    // f32 max (~3.4e38), and `vectorf32` refuses it outright (22003) rather
    // than storing +inf. Pinned so a future "make it lenient" change cannot
    // quietly reopen a NaN path into the Decimal conversion. SONNY-6596:
    // `1e39` is a DOUBLE literal now (ISO/IEC 39075 21.2); the parser refused
    // it before as an out-of-range decimal, so the check is vectorf32's own.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.NumericOutOfRange, h.exec("RETURN vectorf32([1e39]) AS v"));
}

test "geode#873-B: distance()/euclidean()/manhattan() with out-of-range magnitudes error instead of panicking" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // eval.zig:2390 — the shared Decimal conversion of every vector scalar fn.
    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN distance(vectorf32([1e35]), vectorf32([-1e35]), 'l2') AS d"),
    );
    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN euclidean(vectorf32([1e35]), vectorf32([-1e35])) AS d"),
    );
    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN manhattan(vectorf32([1e35]), vectorf32([-1e35])) AS d"),
    );
}

test "geode#873-B: similarity() with the dot_product metric errors instead of panicking" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The cosine arm is bounded to [-1,1] and cannot overflow; the dot_product
    // arm is unbounded and reaches the same unchecked conversion.
    try testing.expectError(
        error.DecimalOverflow,
        h.exec("RETURN similarity(vectorf32([1e35]), vectorf32([1e35]), 'dot_product') AS s"),
    );
}
