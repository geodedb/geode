// CREATE-family evaluated-property `Value` leak: every property expression a
// CREATE/MERGE evaluates is `eval.evalExpr`-ed into a `Value` that may OWN heap
// memory, the store then DEEP-COPIES that value, and the intermediate is never
// freed. For a `vectorf32(...)` literal the orphan is the whole vector payload.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   * `types/vector.zig:55` — `VectorF32.fromString` ends in
//     `allocator.dupe(f32, elements.items)`, so every evaluated
//     `vectorf32('[...]')` / `vectorf32([...])` owns a heap allocation.
//   * `execution/write_precheck.zig:216` —
//     `checkPatternPropsWritableScoped` does
//     `const value = eval.evalExpr(allocator, prop.value.*, env) catch continue;`
//     and NEVER frees it. This is a pure pre-pass: the value cannot escape, so
//     every inline property of every CREATE/INSERT/MERGE pattern leaks here
//     before the statement even starts writing.
//   * `execution/crud_operations.zig:1423` — the homogeneous batch CREATE fast
//     path (`executeBatchCreateHomogeneous`, entered from :1517 for a
//     multi-chain CREATE with one shared label/property shape) evaluates into
//     `batch_entries` and frees nothing.
//   * `execution/crud_operations.zig:2628` (head node) and :2666-2680 (hop
//     endpoints + relationship) — GAP-0930's pre-evaluation buffers. Line
//     :2647 frees the `[]Value` SLICE only (`allocator.free(evaluated_values)`),
//     never the values inside it.
//   * `storage/property_value_codec.zig:362` — the store deep-copies on write,
//     which is what makes the intermediates pure garbage rather than aliases.
//
//   The leak is invisible to the existing vector suites because they run the
//   executor on an ARENA (tests/test_eng3912_dim_pinning.zig:107-113 and the
//   sibling vector tests all pass `self.arena.allocator()`), and it is
//   invisible in production only in the sense that the per-request arena
//   (GAP-0755) delays it to end-of-request — a bulk ingest of N vector rows
//   still holds N orphaned vector payloads for the life of the request.
//
// THIS SUITE runs the REAL parse -> executeStatementWithContext path under
// `std.testing.allocator`, whose leak detector is the assertion. Every test
// drives a real statement; nothing is stubbed.
//
//   1. serial single-chain CREATE with a vector property   (crud_operations.zig:2628)
//   2. multi-chain homogeneous batch CREATE                (crud_operations.zig:1423)
//   3. relationship CREATE with vector props on both ends  (crud_operations.zig:2666-2680)
//   4. MERGE with a vector property                        (write_precheck pre-pass)
//   5. CONTROL: the same shapes with an INT property must be leak-free TODAY,
//      proving the harness itself is clean and that a failure above is the
//      vector payload and not the test rig.
//   6. GUARDRAIL: a store-ALIASING value — `MATCH (n:Doc) CREATE (:Copy
//      {emb: n.emb})` — is BORROWED from the store, not owned by the
//      evaluation. The fix must not free it (that is a double-free /
//      use-after-free of live store memory), so this test pins the boundary
//      the fix has to respect. Its BEHAVIOURAL assertions (copy written,
//      source still intact, source reusable for a second copy) pass today and
//      must stay passing.
//
// MEASURED leak attribution on this branch (allocation site -> count, per
// test, from the run recorded in the commit message):
//     serial CREATE ............ 2 x types/vector.zig:55
//     batch CREATE ............. 6 x types/vector.zig:55
//     relationship CREATE ...... 4 x types/vector.zig:55
//     MERGE .................... 5 x types/vector.zig:55
//     guardrail ................ 2 x types/vector.zig:55
//                              + 2 x execution/match_operations.zig:11030
//                              + 2 x execution/match_operations.zig:11031
//     control .................. CLEAN
//
//   The two match_operations sites are the sibling leak in the MATCH->CREATE
//   path: `env_names = try allocator.alloc(...)` / `env_values = try
//   allocator.alloc(...)` build the per-match binding env and nothing frees
//   either array. Same family (write-path evaluation bookkeeping), named here
//   so the fix closes it too rather than leaving this step red.
//
// CANARY: REQ=REQ-EXEC-CREATE-VALUE-OWNERSHIP-001; FEATURE="CreatePropertyEvaluation"; ASPECT=EvaluatedValueLeak; STATUS=TESTED; TEST=tests/test_create_vector_value_leak.zig; OWNER=execution; UPDATED=2026-09-01
// CANARY: REQ=REQ-EXEC-CREATE-VALUE-OWNERSHIP-002; FEATURE="CreatePropertyEvaluation"; ASPECT=StoreAliasNotDoubleFreed; STATUS=TESTED; TEST=tests/test_create_vector_value_leak.zig; OWNER=execution; UPDATED=2026-09-01

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Same real store / catalog / parser / executor wiring as the vector suites,
/// with ONE deliberate difference: every statement executes against
/// `std.testing.allocator` instead of an arena, so an intermediate the
/// executor forgets to free is reported as a leak instead of being swept up by
/// the arena at teardown.
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
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
        self.tmp.cleanup();
    }

    /// Parse + execute one statement on the strict allocator and release
    /// everything the RESULT owns. Anything still outstanding afterwards is a
    /// leak inside the executor.
    pub fn run(self: *Harness, query: []const u8) !void {
        self.ctx.session_state = &self.session;
        var parsed = try geode.parseGqlOptions(query, self.allocator, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var result = try execution.executeStatementWithContext(
            self.allocator,
            parsed.program.statements[0],
            self.ctx,
        );
        result.deinit(self.allocator);
    }

    /// Verification goes through the STORE, never through a `MATCH` read.
    ///
    /// Deliberate: the planned-read path has its OWN pre-existing leak
    /// (`planned_read_runtime.materializeNode` at :2940/:2942 duplicates every
    /// property key/value into the result allocator and the row teardown does
    /// not release them). Asserting with `MATCH ... RETURN n.emb` would drag
    /// that unrelated leak into every test here — including the control — and
    /// destroy this suite's ability to attribute a leak to the CREATE path.
    /// Reading the committed nodes straight out of the store keeps the only
    /// allocations under test the ones the write path makes.
    pub fn labelCount(self: *Harness, graph_name: []const u8, label: []const u8) usize {
        const store = graph_store.getGlobalStore(self.allocator);
        const ids = store.getNodesByLabel(graph_name, label) orelse return 0;
        return ids.len;
    }

    /// True when every node carrying `label` has a non-null `property`.
    pub fn allHaveProperty(
        self: *Harness,
        graph_name: []const u8,
        label: []const u8,
        property: []const u8,
    ) bool {
        const store = graph_store.getGlobalStore(self.allocator);
        const ids = store.getNodesByLabel(graph_name, label) orelse return false;
        if (ids.len == 0) return false;
        for (ids) |id| {
            const node = store.getNodePtrHydrated(id) orelse return false;
            _ = node.properties.get(property) orelse return false;
        }
        return true;
    }
};

// ===========================================================================
// 0. CONTROL — the harness itself is clean.
//    An INT property owns no heap memory, so the very same statement shapes
//    must already be leak-free. If this test fails, everything below is
//    reporting the rig, not the bug.
// ===========================================================================
test "control: CREATE with scalar properties is leak-free under the strict allocator" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_ctl");
    try h.run("USE GRAPH cvl_ctl");
    try h.run("CREATE (:CtlDoc {i: 1})");
    try h.run("CREATE (:CtlDoc {i: 2}), (:CtlDoc {i: 3}), (:CtlDoc {i: 4})");
    try h.run("CREATE (:CtlA {i: 10})-[:CTL_REL {w: 1}]->(:CtlB {i: 11})");
    try h.run("MERGE (:CtlDoc {i: 99})");

    try testing.expectEqual(@as(usize, 5), h.labelCount("cvl_ctl", "CtlDoc"));
    try testing.expectEqual(@as(usize, 1), h.labelCount("cvl_ctl", "CtlA"));
    try testing.expectEqual(@as(usize, 1), h.labelCount("cvl_ctl", "CtlB"));
}

// ===========================================================================
// 1. THE REGRESSION TEST — a single-chain CREATE with an evaluated vector
//    property. RED today: the pre-pass at write_precheck.zig:216 evaluates the
//    vector and drops it on the floor, and crud_operations.zig:2628's
//    pre-evaluated buffer frees only the slice.
// ===========================================================================
test "CREATE with an evaluated vectorf32 property frees the intermediate value" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_serial");
    try h.run("USE GRAPH cvl_serial");
    try h.run("CREATE (:CvlDoc {id: 1, emb: vectorf32('[0.1, 0.2, 0.3, 0.4]')})");

    try testing.expectEqual(@as(usize, 1), h.labelCount("cvl_serial", "CvlDoc"));
    try testing.expect(h.allHaveProperty("cvl_serial", "CvlDoc", "emb"));
}

// ===========================================================================
// 2. The homogeneous multi-chain batch CREATE fast path
//    (crud_operations.zig:1423, reached via the :1517 dispatch). Three chains
//    with the same label + property shape, so the batch path is what runs.
// ===========================================================================
test "batch CREATE (homogeneous multi-chain) frees every evaluated vector value" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_batch");
    try h.run("USE GRAPH cvl_batch");
    try h.run(
        "CREATE (:CvlBatch {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')}), " ++
            "(:CvlBatch {id: 2, emb: vectorf32('[0.0, 1.0, 0.0, 0.0]')}), " ++
            "(:CvlBatch {id: 3, emb: vectorf32('[0.0, 0.0, 1.0, 0.0]')})",
    );

    try testing.expectEqual(@as(usize, 3), h.labelCount("cvl_batch", "CvlBatch"));
    try testing.expect(h.allHaveProperty("cvl_batch", "CvlBatch", "emb"));
}

// ===========================================================================
// 3. The relationship CREATE path — both endpoints AND the relationship carry
//    evaluated values (crud_operations.zig:2666-2680), all three buffers freed
//    as slices only.
// ===========================================================================
test "relationship CREATE frees the evaluated vector values on both endpoints" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_rel");
    try h.run("USE GRAPH cvl_rel");
    try h.run(
        "CREATE (:CvlLeft {id: 1, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})" ++
            "-[:CVL_REL]->" ++
            "(:CvlRight {id: 2, emb: vectorf32('[4.0, 3.0, 2.0, 1.0]')})",
    );

    try testing.expect(h.allHaveProperty("cvl_rel", "CvlLeft", "emb"));
    try testing.expect(h.allHaveProperty("cvl_rel", "CvlRight", "emb"));
}

// ===========================================================================
// 4. MERGE — the same write_precheck pre-pass runs for MERGE patterns, so the
//    evaluated vector leaks there too (on BOTH the create and the match
//    outcome).
// ===========================================================================
test "MERGE with an evaluated vector property frees the intermediate value" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_merge");
    try h.run("USE GRAPH cvl_merge");
    // First MERGE creates.
    try h.run("MERGE (:CvlMerge {id: 7, emb: vectorf32('[5.0, 6.0, 7.0, 8.0]')})");
    // Second MERGE matches — the pre-pass evaluates the vector again either way.
    try h.run("MERGE (:CvlMerge {id: 7, emb: vectorf32('[5.0, 6.0, 7.0, 8.0]')})");

    try testing.expectEqual(@as(usize, 1), h.labelCount("cvl_merge", "CvlMerge"));
    try testing.expect(h.allHaveProperty("cvl_merge", "CvlMerge", "emb"));
}

// ===========================================================================
// 5. GUARDRAIL — GREEN TODAY AND MUST STAY GREEN.
//    `n.emb` in a CREATE property position is a value BORROWED from the store,
//    not one the evaluation allocated. A fix that blindly `deinit`s every
//    evaluated property value would free live store memory here (double free /
//    use-after-free), so this pins the boundary: the aliasing shape must keep
//    working, keep producing a correct copy, and keep the source readable
//    afterwards.
// ===========================================================================
test "guardrail: CREATE from a store-aliased vector property is not double-freed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH cvl_alias");
    try h.run("USE GRAPH cvl_alias");
    try h.run("CREATE (:CvlSrc {id: 1, emb: vectorf32('[9.0, 8.0, 7.0, 6.0]')})");

    // The property value handed to the CREATE comes straight out of the store.
    try h.run("MATCH (n:CvlSrc) CREATE (:CvlCopy {emb: n.emb})");

    // The copy exists...
    try testing.expect(h.allHaveProperty("cvl_alias", "CvlCopy", "emb"));
    // ...and the SOURCE is still intact and readable (it would not be if the
    // create path had taken ownership of the borrowed value).
    try testing.expect(h.allHaveProperty("cvl_alias", "CvlSrc", "emb"));

    // A second copy from the same source proves the store value survived the
    // first CREATE rather than being consumed by it.
    try h.run("MATCH (n:CvlSrc) CREATE (:CvlCopy2 {emb: n.emb})");
    try testing.expect(h.allHaveProperty("cvl_alias", "CvlCopy2", "emb"));
}
