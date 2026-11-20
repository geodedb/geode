// CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig:1; OWNER=index; UPDATED=2026-08-29
//
// ENG-3922 — the vector dimension guard has a hole, and the dimension CAP has
// a crash. Three defects, all reproduced here BEFORE the fix (TDD): every
// assertion below that is marked RED fails on the pre-fix tree.
//
//   (a) NO DIMENSION GUARD FOR AN UNINDEXED (label, property).
//       `IndexManager.vector_dim_registry` is keyed by INDEX NAME and is
//       populated only by `CREATE INDEX` DDL, so `checkVectorDimensionForWrite`
//       iterates ZERO entries for a property that has no vector index.
//       Verified pre-fix: a dim-4 write and then a dim-8 write to the same
//       unindexed `(:PFree).emb` are BOTH accepted, the mixed dimensions
//       persist across a restart, and the downstream readers degrade
//       silently — `vector_cosine` yields NULL and a knn scan drops the
//       non-conforming rows instead of reporting anything. An INDEXED pair is
//       correctly refused with `error.VectorDimensionMismatch` (SQLSTATE
//       22000); the guard's coverage, not its logic, is what is wrong.
//
//       The homogeneity of a vector property is a DATA-INTEGRITY invariant of
//       the property, not a side effect of an index existing. The planned fix
//       re-keys the registry to (graph, label, property) and seeds a pin
//       lazily from committed data on the first vector write, checked at the
//       existing single chokepoint (`property_mutation.setNodePropertyFromValue`
//       plus the `write_precheck` statement pre-pass).
//
//   (b) AN OVER-CAP VECTOR STRING LITERAL IS LAUNDERED INTO A BARE
//       `TypeMismatch` / SQLSTATE 58000. `vector.VectorF32.fromString` raises
//       a perfectly good `error.VectorTooLarge` for >65535 elements
//       (src/types/vector.zig:53, and :354 for VectorI32); that identity is
//       then discarded twice on the way out — `evaluator_functions.VectorF32`
//       collapses it to `EvaluatorError.InvalidFormat`, and `eval.zig`'s
//       constructor error mapper collapses THAT to `EvalError.TypeMismatch`.
//       `proto_util.mapError` has no arm for either, so the caller is told
//       58000 "internal system error" for a documented resource limit they
//       simply crossed. Same wrong-class bug ENG-3911 fixed for
//       `PropertyValueTooLarge`; same fix shape — propagate the real error and
//       map it to 54000 (program_limit_exceeded) with a message naming the cap.
//
//   (c) P0 CRASH / DoS: THE ARRAY-LITERAL FORM PANICS THE SERVER.
//       The string path checks the 65535 cap; the LIST path does not. Every
//       list-literal vector constructor does an unchecked `@intCast(list.len)`
//       into the u16 `dim` field, so a 65536-element list literal is an
//       integer-overflow PANIC that takes the whole process down:
//
//           src/eval_extended.zig:707  constructVector    (vector([...]))
//           src/eval_extended.zig:735  constructVectorF32 (vectorf32([...]))
//           src/eval_extended.zig:766  constructVectorI32 (vectori32([...]))
//           src/types/evaluator_functions.zig:303  Vector()
//           src/types/extended_functions.zig:237   VectorF64
//
//       It is reachable from a READ-ONLY statement with no write privilege and
//       no stored data — `RETURN size(vectorf32([ ...65536 elements... ]))` —
//       so any authenticated read-only client can halt the server. The correct
//       bounds-checking pattern already exists two thousand lines away in the
//       same file (src/eval_extended.zig:2071) and in src/eval.zig:2119, where
//       the list→vector coercion used by the similarity functions rejects
//       `items.len > std.math.maxInt(u16)`.
//
// SCOPE NOTE: these are store-level, in-process tests (parse + execute against
// a real graph store, no mocks, no server). The over-the-wire contract — the
// structured error AND the server staying alive after an over-cap literal — is
// pinned by the harness spec
// geode-test-harness/geodetestlab-cli/specs/vector_dim_guard.yml.
//
// TEST ORDER MATTERS. (c) is a PANIC on the pre-fix tree, and a panic aborts
// the whole test process, so the (a) and (b) tests are declared FIRST — a
// pre-fix run must still be able to report their failures before the crash
// test takes the runner down.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const proto_util = geode.proto_util;

/// The dimension cap: `VectorF32.dim` / `VectorI32.dim` are u16, so 65535 is
/// the largest representable dimension and 65536 is the first over-cap length.
const DIM_CAP: usize = 65535;

const GENERIC_SYSTEM_ERROR = "58000";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Same shape as tests/test_eng3912_dim_pinning.zig and
/// tests/test_gap0918_vector_validation.zig: a real global store over a temp
/// data dir, driven through the real parser and the real statement executor.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        // The hnsw worker pool is owned by the index manager; tear it down
        // before the store/allocator it was built with goes away.
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

    /// Tear the process-global engine state down and bring it back up against
    /// the SAME data dir — the closest a store-level test gets to a server
    /// restart. Mirrors `Harness.restart` in test_eng3912_dim_pinning.zig.
    pub fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }
};

/// `RETURN <ctor>([e, e, ... ])` — the ARRAY-LITERAL constructor form, built
/// programmatically because the over-cap case needs 65536 elements.
fn arrayFormQuery(allocator: std.mem.Allocator, wrap_in_size: bool, ctor: []const u8, n: usize, element: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "RETURN ");
    if (wrap_in_size) try buf.appendSlice(allocator, "size(");
    try buf.appendSlice(allocator, ctor);
    try buf.appendSlice(allocator, "([");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, element);
    }
    try buf.appendSlice(allocator, "])");
    if (wrap_in_size) try buf.appendSlice(allocator, ")");
    return buf.toOwnedSlice(allocator);
}

/// `RETURN <ctor>('[e,e,...]')` — the STRING constructor form.
fn stringFormQuery(allocator: std.mem.Allocator, ctor: []const u8, n: usize, element: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "RETURN ");
    try buf.appendSlice(allocator, ctor);
    try buf.appendSlice(allocator, "('[");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, element);
    }
    try buf.appendSlice(allocator, "]')");
    return buf.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

// ---------------------------------------------------------------------------
// (b) The over-cap STRING form: a real, nameable limit error — not a bare
//     `TypeMismatch`. Declared first so it reports before the (c) panic.
// ---------------------------------------------------------------------------
test "ENG-3922 (b): an over-cap vector string literal raises VectorTooLarge, not TypeMismatch" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = h.arena.allocator();

    _ = try h.exec("CREATE GRAPH eng3922_cap");
    _ = try h.exec("USE GRAPH eng3922_cap");

    // RED pre-fix: `vector.VectorF32.fromString` raises VectorTooLarge, but
    // evaluator_functions collapses it to InvalidFormat and eval.zig collapses
    // that to TypeMismatch, so the caller cannot tell "you exceeded the 65535
    // dimension cap" from "your literal is garbage".
    const over_f32 = try stringFormQuery(a, "vectorf32", DIM_CAP + 1, "1.0");
    try testing.expectError(error.VectorTooLarge, h.exec(over_f32));

    // Same laundering on the integer-vector path (src/types/vector.zig:354).
    const over_i32 = try stringFormQuery(a, "vectori32", DIM_CAP + 1, "1");
    try testing.expectError(error.VectorTooLarge, h.exec(over_i32));

    // GUARD: a genuinely malformed literal must KEEP its own identity — the
    // fix must not collapse everything into the new error the way the old code
    // collapsed everything into TypeMismatch. (GAP-0918(c) contract.)
    try testing.expectError(error.TypeMismatch, h.exec("RETURN vectorf32('[1.0, bad, 2.0]')"));
}

// ---------------------------------------------------------------------------
// The boundary. Declared before the (c) crash test so a pre-fix run still
// records it: 65535 is REPRESENTABLE and must keep working in both forms. The
// fix must reject 65536, not 65535 — an off-by-one here would be a functional
// regression for legitimately large embeddings.
// ---------------------------------------------------------------------------
test "ENG-3922: the 65535-dimension boundary still constructs in both literal forms" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = h.arena.allocator();

    _ = try h.exec("CREATE GRAPH eng3922_boundary");
    _ = try h.exec("USE GRAPH eng3922_boundary");

    // String form at the cap (passes pre-fix; the string path already checks).
    const at_cap_string = try stringFormQuery(a, "vectorf32", DIM_CAP, "1.0");
    const r1 = try h.exec(at_cap_string);
    try testing.expectEqual(@as(usize, 1), r1.rows.len);

    // Array form at the cap (passes pre-fix by luck: 65535 is exactly the
    // largest value the unchecked @intCast happens to accept).
    const at_cap_array = try arrayFormQuery(a, false, "vectorf32", DIM_CAP, "1.0");
    const r2 = try h.exec(at_cap_array);
    try testing.expectEqual(@as(usize, 1), r2.rows.len);

    // ...and `size()` agrees the dimension survived intact.
    const at_cap_sized = try arrayFormQuery(a, true, "vectorf32", DIM_CAP, "1.0");
    const r3 = try h.exec(at_cap_sized);
    try testing.expectEqual(@as(usize, 1), r3.rows.len);
    try testing.expectEqual(@as(i64, @intCast(DIM_CAP)), r3.rows[0][0].Int);

    // PINNED CURRENT BEHAVIOUR, not a new requirement: the two literal forms
    // disagree about the EMPTY vector. The string path rejects it
    // (`error.EmptyVector` -> InvalidFormat -> TypeMismatch); the array path
    // builds a dim-0 vector. ENG-3922 is about the UPPER bound, so this
    // asymmetry is recorded rather than changed — but it is recorded so the
    // upper-bound fix cannot alter it by accident, in either direction.
    try testing.expectError(error.TypeMismatch, h.exec("RETURN vectorf32('[]')"));
    const empty_array = try h.exec("RETURN vectorf32([])");
    try testing.expectEqual(@as(usize, 1), empty_array.rows.len);
}

// ---------------------------------------------------------------------------
// (b) The wire contract for the over-cap refusal: SQLSTATE class, code, and a
//     message that names the cap. Pure `proto_util.mapError` — no server, no
//     storage, no mocks (same mechanism as tests/test_eng3911_*).
// ---------------------------------------------------------------------------
test "ENG-3922 (b): VectorTooLarge is not the generic system-error class" {
    const info = proto_util.mapError(error.VectorTooLarge);

    // RED pre-fix: no arm exists, so the `else` fallback emits
    // {"status_class":"58000","error":"VectorTooLarge"} — telling the caller
    // the SERVER broke when they simply exceeded a documented limit.
    if (std.mem.eql(u8, info.code, GENERIC_SYSTEM_ERROR)) {
        std.debug.print(
            "\n[ENG-3922] over-cap vector mapped to the generic system-error class:\n" ++
                "           code = {s}, message = \"{s}\"\n" ++
                "           A refused-for-documented-limit request is not a server fault.\n",
            .{ info.code, info.message },
        );
        return error.OverCapVectorMappedToSystemError;
    }
}

test "ENG-3922 (b): VectorTooLarge maps to SQLSTATE 54000 (program_limit_exceeded)" {
    const info = proto_util.mapError(error.VectorTooLarge);

    // Precedent: error.PropertyValueTooLarge / error.PropertyKeyTooLong (ENG-3911).
    try testing.expectEqualStrings("54", info.code[0..2]);
    try testing.expectEqualStrings("54000", info.code);
}

test "ENG-3922 (b): the over-cap message names the vector dimension cap" {
    const info = proto_util.mapError(error.VectorTooLarge);

    // An operator must be able to size their embedding without reading source.
    if (!containsIgnoreCase(info.message, "65535")) {
        std.debug.print(
            "\n[ENG-3922] over-cap message does not state the 65535-dimension cap: \"{s}\"\n",
            .{info.message},
        );
        return error.OverCapMessageDoesNotNameCap;
    }
    if (!containsIgnoreCase(info.message, "dimension")) {
        std.debug.print(
            "\n[ENG-3922] over-cap message does not name the DIMENSION as what overflowed: \"{s}\"\n",
            .{info.message},
        );
        return error.OverCapMessageDoesNotNameDimension;
    }
}

test "ENG-3922 (b) GUARD: unrelated errors still fall through to 58000" {
    // The new arm must be narrow. (Passes pre-fix and post-fix.)
    // SONNY-6517: OutOfMemory has an arm of its own now (53200); an error
    // no arm names stands for "unrelated".
    const info = proto_util.mapError(error.Unexpected);
    try testing.expectEqualStrings(GENERIC_SYSTEM_ERROR, info.code);
}

// ---------------------------------------------------------------------------
// (a) The guard must cover an UNINDEXED (label, property) pair.
// ---------------------------------------------------------------------------
test "ENG-3922 (a): an unindexed vector property enforces dimension homogeneity" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3922_free");
    _ = try h.exec("USE GRAPH eng3922_free");

    // No CREATE INDEX anywhere in this test — that is the whole point.
    // The first vector write establishes the property's dimension.
    _ = try h.exec("CREATE (:P22Free {id: 1, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P22Free) RETURN n"));

    // RED pre-fix: BOTH writes are accepted and the property ends up holding a
    // dim-4 and a dim-8 vector under one name. Downstream that is silent data
    // loss — vector_cosine over the pair yields NULL and a knn scan drops the
    // non-conforming row rather than reporting anything.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Free {id: 2, emb: vectorf32('[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]')})"),
    );

    // The refusal is atomic: nothing was stored.
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P22Free) RETURN n"));

    // The established dimension keeps writing.
    _ = try h.exec("CREATE (:P22Free {id: 3, emb: vectorf32('[4.0, 3.0, 2.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:P22Free) RETURN n"));

    // The array-literal form goes through the same chokepoint.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Free {id: 4, emb: vectorf32([1.0, 2.0, 3.0])})"),
    );

    // A DIFFERENT LABEL that happens to reuse the property NAME is a different
    // property and is unconstrained. (Passes pre-fix — a guard against the fix
    // over-reaching into a property-name-only pin.)
    _ = try h.exec("CREATE (:Q22Free {id: 1, emb: vectorf32('[9.0, 9.0, 9.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:Q22Free) RETURN n"));

    // A non-vector property on the same label is untouched by any of this.
    _ = try h.exec("CREATE (:P22Free {id: 5, emb: vectorf32('[0.0, 0.0, 0.0, 0.0]'), note: 'plain'})");
    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:P22Free) RETURN n"));

    // ---- per-graph scope ----
    //
    // An UNINDEXED property has no process-global index object behind it, so
    // (unlike the deliberately process-wide INDEXED pin asserted in
    // test_eng3912_dim_pinning.zig) its pin is scoped to its graph. The same
    // label+property in another graph is a separate property with a separate
    // dimension. (Passes pre-fix; guards the fix's scope.)
    _ = try h.exec("CREATE GRAPH eng3922_free_other");
    _ = try h.exec("USE GRAPH eng3922_free_other");
    _ = try h.exec("CREATE (:P22Free {id: 100, emb: vectorf32('[1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P22Free) RETURN n"));

    // ...and that other graph now has its OWN dim-8 pin, independent of the
    // dim-4 one next door.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Free {id: 101, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})"),
    );

    // ---- restart parity ----
    //
    // The pin is process state derived from committed data, so after a restart
    // it must be re-seeded FROM THAT DATA (the `seedVectorDim` path), not from
    // whatever the first post-restart write happens to be. Without seeding, a
    // dim-8 write would establish itself as the new truth against two stored
    // dim-4 vectors.
    try h.restart();
    _ = try h.exec("USE GRAPH eng3922_free");

    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:P22Free) RETURN n"));
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Free {id: 6, emb: vectorf32('[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]')})"),
    );
    _ = try h.exec("CREATE (:P22Free {id: 7, emb: vectorf32('[5.0, 5.0, 5.0, 5.0]')})");
    try testing.expectEqual(@as(usize, 4), try h.countRows("MATCH (n:P22Free) RETURN n"));
}

// ---------------------------------------------------------------------------
// (c) P0: the over-cap ARRAY-LITERAL form must return an error, not panic.
//
// DECLARED LAST ON PURPOSE. On the pre-fix tree this does not fail — it
// PANICS ("integer does not fit in destination type" at
// src/eval_extended.zig:735) and takes the test runner down with it, which is
// exactly what it does to a live server. Anything declared after it would
// never report.
// ---------------------------------------------------------------------------
test "ENG-3922 (c) REGRESSION: an over-cap array-literal vector errors instead of crashing the process" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = h.arena.allocator();

    _ = try h.exec("CREATE GRAPH eng3922_crash");
    _ = try h.exec("USE GRAPH eng3922_crash");

    // The exact P0 reproducer from triage: a READ-ONLY statement, no write
    // privilege, no stored data, no index — and the server is gone.
    const sized = try arrayFormQuery(a, true, "vectorf32", DIM_CAP + 1, "1.0");
    try testing.expectError(error.VectorTooLarge, h.exec(sized));

    // The bare constructor, same path (src/eval_extended.zig:735).
    const bare_f32 = try arrayFormQuery(a, false, "vectorf32", DIM_CAP + 1, "1.0");
    try testing.expectError(error.VectorTooLarge, h.exec(bare_f32));

    // `vector([...])` -> constructVector (src/eval_extended.zig:707).
    const bare_vector = try arrayFormQuery(a, false, "vector", DIM_CAP + 1, "1.0");
    try testing.expectError(error.VectorTooLarge, h.exec(bare_vector));

    // `vectori32([...])` -> constructVectorI32 (src/eval_extended.zig:766).
    const bare_i32 = try arrayFormQuery(a, false, "vectori32", DIM_CAP + 1, "1");
    try testing.expectError(error.VectorTooLarge, h.exec(bare_i32));

    // LIVENESS: the whole point of (c). After four refusals the engine is
    // still serving — a refusal is not a crash.
    const alive = try h.exec("RETURN 1 AS x");
    try testing.expectEqual(@as(usize, 1), alive.rows.len);
    _ = try h.exec("CREATE (:P22Alive {id: 1, emb: vectorf32('[1.0, 2.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P22Alive) RETURN n"));
}

// CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimLifecycleRelease; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-30
test "ENG-3922 lifecycle: sole-holder overwrite re-pins, delete releases, live siblings still enforce" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3922_cycle");
    _ = try h.exec("USE GRAPH eng3922_cycle");

    // Establish a dim-4 pin with a single row.
    _ = try h.exec("CREATE (:P22Cycle {id: 1, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");

    // RED pre-fix: the sole holder could not be re-dimensioned by overwrite —
    // the pin was derived from committed data INCLUDING the row being
    // replaced, so a re-embedding SET was judged against its own predecessor
    // and permanently refused (only DROP GRAPH or a restart cleared it).
    _ = try h.exec("MATCH (n:P22Cycle) SET n.emb = vectorf32('[9.0, 8.0, 7.0]')");

    // The committed overwrite moved the pin: dim-3 keeps writing, dim-4 is
    // now the mismatched dimension.
    _ = try h.exec("CREATE (:P22Cycle {id: 2, emb: vectorf32('[6.0, 6.0, 6.0]')})");
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Cycle {id: 3, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})"),
    );

    // With a LIVE dim-3 sibling, overwriting one row to a new dimension is
    // still refused — the exclusion covers only the row being replaced, never
    // the rest of the committed data.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("MATCH (n:P22Cycle {id: 1}) SET n.emb = vectorf32('[1.0, 2.0, 3.0, 4.0]')"),
    );
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:P22Cycle) RETURN n"));

    // RED pre-fix (the documented ENG-3922 residual): deleting every
    // establishing row must release the pin — the policy's own escape hatch
    // ("to change a property's dimension you delete the rows that establish
    // it") has to actually work in-process.
    _ = try h.exec("MATCH (n:P22Cycle) DETACH DELETE n");
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:P22Cycle) RETURN n"));
    _ = try h.exec("CREATE (:P22Cycle {id: 10, emb: vectorf32('[1.0, 1.0, 1.0, 1.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P22Cycle) RETURN n"));

    // ...and the freshly established dim-5 pin has teeth.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P22Cycle {id: 11, emb: vectorf32('[1.0, 2.0]')})"),
    );
}
