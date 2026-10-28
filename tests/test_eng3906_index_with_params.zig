// RED reproduction tests — ENG-3906 (engine half): `CREATE INDEX ... WITH (...)`
// index parameters are only half-validated, and the half that IS validated is
// reachable by exactly one of the two spellings the parser accepts.
//
// THE BUG (triage complete; verified against v0.8.5 / 5c37d58a on a live server):
//
//   (A1) COLON SPELLING BYPASSES METRIC VALIDATION.
//        src/gql/parser.zig:5151 captures `metric` ONLY when the next token is
//        `.eq`. The `key: value` map spelling never reaches the capture, so
//        `ci.metric` stays null and the validator at src/execution.zig:1585-1597
//        has nothing to reject. Live probe:
//
//          CREATE INDEX ... USING vector WITH (metric = 'banana')  -> 42704  (correct)
//          CREATE INDEX ... USING vector WITH (metric: 'banana')   -> 00000  (THE BUG)
//          CREATE INDEX ... USING HNSW   WITH (metric: 'banana')   -> 00000  (THE BUG)
//
//   (A2) UNKNOWN / UNSUPPORTED WITH KEYS ARE SILENTLY DISCARDED.
//        The parser's WITH loop (src/gql/parser.zig:5140-5175) advances past
//        every token it does not recognise, so a typo'd or unimplemented
//        parameter is accepted and thrown away. The user believes they tuned
//        the index; nothing happened. Live probe, all 00000:
//
//          WITH (banana: 42)
//          WITH (banana = 42)
//          WITH (m: 16, ef_construction: 200, ef_search: 100)
//          WITH (metric = 'cosine', ef_construction = 200, M = 16)
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//
//   1. `metric` is validated IDENTICALLY in both spellings — `metric = 'x'` and
//      `metric: 'x'` must agree, for every USING alias that selects the vector
//      index type (`vector`, `HNSW`, `vector_f32`).
//   2. Every supported metric spelling (l2 / euclidean / cosine / dot /
//      dot_product / inner_product, case-insensitive) is still ACCEPTED in both
//      spellings. This is the guard against "fix it by rejecting everything".
//   3. STRICT REJECTION of unknown keys: on a vector-typed index, any WITH key
//      other than `metric` is REJECTED with a clear error instead of being
//      discarded. Both spellings. The error must be an undefined-object-class
//      (42704-family) diagnostic; these tests only assert THAT it is rejected,
//      leaving the exact error name to the fixer — the SQLSTATE itself is
//      pinned by the harness spec
//      (geode-test-harness/geodetestlab-cli/specs/vector_index_param_validation.yml).
//
//   SCOPE: strict rejection is scoped to the vector index types, matching where
//   the existing metric validation lives (src/execution.zig:1585). Non-vector
//   index types (`USING btree WITH (fillfactor: 70)`) also silently discard
//   their WITH parameters today; that is deliberately NOT asserted here so this
//   file stays inside the ENG-3906 blast radius.
//
// RED MECHANISM: every `expectRejected` case below returns 00000 today, so each
// one fails now and passes once the parser captures both spellings and the
// executor rejects unknown keys. Do not relax these tests; implement the fix.
//
// CANARY: REQ=REQ-ENG-3906-INDEX-WITH-PARAM-VALIDATION; FEATURE="VectorIndex"; ASPECT=WithParameterValidation; STATUS=TESTED; TEST=tests/test_eng3906_index_with_params.zig; OWNER=index; UPDATED=2026-08-24

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

/// Same shape as tests/test_gap0918_vector_validation.zig — a single real
/// catalog + store, driven through the real parser and executor. No mocks: the
/// bug lives in the parse -> execute seam, so both halves must be real.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
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
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
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

    /// Record (do NOT abort on) a statement that was accepted when it should
    /// have been rejected. Every case is exercised so one RED run enumerates the
    /// full defect surface instead of stopping at the first assertion.
    ///
    /// `expected_error` is the error the fixer is expected to raise when it is
    /// already named by the contract (the metric cases reuse the `=` spelling's
    /// existing `error.InvalidIndexMetric`). Pass null for the unknown-key
    /// cases, where the contract pins only THAT the statement is rejected.
    pub fn checkRejected(
        self: *Harness,
        failures: *std.ArrayListUnmanaged([]const u8),
        gpa: std.mem.Allocator,
        query: []const u8,
        expected_error: ?anyerror,
    ) !void {
        if (self.exec(query)) |_| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "ACCEPTED (expected rejection): {s}",
                .{query},
            ));
        } else |err| {
            if (expected_error) |want| {
                if (err != want) {
                    try failures.append(gpa, try std.fmt.allocPrint(
                        gpa,
                        "REJECTED with {s} (expected {s}): {s}",
                        .{ @errorName(err), @errorName(want), query },
                    ));
                }
            }
        }
    }

    /// Record (do NOT abort on) a statement that must be ACCEPTED — the guard
    /// half of the contract.
    pub fn checkAccepted(
        self: *Harness,
        failures: *std.ArrayListUnmanaged([]const u8),
        gpa: std.mem.Allocator,
        query: []const u8,
    ) !void {
        if (self.exec(query)) |_| {} else |err| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "REJECTED with {s} (expected acceptance): {s}",
                .{ @errorName(err), query },
            ));
        }
    }
};

test "ENG-3906: CREATE INDEX WITH-parameter validation (both spellings, unknown keys)" {
    // ONE harness for all phases, for the same reason
    // tests/test_gap0918_vector_validation.zig uses one: the hnsw library keeps
    // a worker pool and a process-global index-manager registry alive across
    // index lifetimes, so tearing the store down between tests segfaults inside
    // registerVectorDimValidation (src/index/index_manager.zig:1275) — an
    // artefact of per-test re-init that a real server never performs, not a
    // finding about the code under test. For the same reason every assertion is
    // ACCUMULATED and reported together at the end: one run, whole defect
    // surface.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    _ = try h.exec("CREATE GRAPH eng3906");
    _ = try h.exec("USE GRAPH eng3906");

    // ---- (A1) metric validation must be identical in `=` and `:` ----

    // Baseline / control: the `=` spelling already rejects a bogus metric.
    // Green today; must stay green.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_eq_bad ON E3906EqBad (emb) USING vector WITH (metric = 'banana')", error.InvalidIndexMetric);

    // KEY ASSERTIONS (RED): the `:` spelling must reject the same bogus metric,
    // for every USING alias that selects the vector index type. Today all three
    // return success and the index is created with no metric at all.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_colon_bad ON E3906ColonBad (emb) USING vector WITH (metric: 'banana')", error.InvalidIndexMetric);
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_hnsw_colon_bad ON E3906HnswBad (emb) USING HNSW WITH (metric: 'banana')", error.InvalidIndexMetric);
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_f32_colon_bad ON E3906F32Bad (emb) USING vector_f32 WITH (metric: 'banana')", error.InvalidIndexMetric);

    // ---- (A1 guard) every supported metric still accepted, both spellings ----
    //
    // The supported set per src/execution.zig:1586. This is the guard against a
    // fix that simply rejects everything the `:` spelling produces.
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_1 ON E3906Ok1 (emb) USING vector WITH (metric = 'l2')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_2 ON E3906Ok2 (emb) USING vector WITH (metric = 'euclidean')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_3 ON E3906Ok3 (emb) USING vector WITH (metric = 'cosine')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_4 ON E3906Ok4 (emb) USING vector WITH (metric = 'dot')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_5 ON E3906Ok5 (emb) USING vector WITH (metric = 'dot_product')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_eq_6 ON E3906Ok6 (emb) USING vector WITH (metric = 'inner_product')");

    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_1 ON E3906Co1 (emb) USING vector WITH (metric: 'l2')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_2 ON E3906Co2 (emb) USING vector WITH (metric: 'euclidean')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_3 ON E3906Co3 (emb) USING vector WITH (metric: 'cosine')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_4 ON E3906Co4 (emb) USING vector WITH (metric: 'dot')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_5 ON E3906Co5 (emb) USING vector WITH (metric: 'dot_product')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_co_6 ON E3906Co6 (emb) USING vector WITH (metric: 'inner_product')");

    // Metric names are matched case-insensitively (eqlIgnoreCase) — both spellings.
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_case_1 ON E3906Case1 (emb) USING HNSW WITH (metric = 'COSINE')");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_case_2 ON E3906Case2 (emb) USING HNSW WITH (metric: 'Cosine')");

    // A vector index with no WITH clause at all remains valid.
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3906_ok_none ON E3906None (emb) USING vector");

    // ---- (A2) unknown WITH keys must be rejected, not discarded ----
    //
    // KEY ASSERTIONS (RED) — every one of these returns success today.
    // A typo'd parameter must not be silently swallowed.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_1 ON E3906Unk1 (emb) USING vector WITH (banana: 42)", null);
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_2 ON E3906Unk2 (emb) USING vector WITH (banana = 42)", null);

    // The HNSW tuning knobs users copy out of Neo4j/pgvector documentation are
    // NOT implemented by this engine. Accepting them is a correctness lie about
    // the index that was actually built.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_3 ON E3906Unk3 (emb) USING vector WITH (m: 16, ef_construction: 200, ef_search: 100)", null);
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_4 ON E3906Unk4 (emb) USING HNSW WITH (ef_construction = 200, M = 16)", null);

    // A valid metric does NOT license the unknown keys travelling with it.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_5 ON E3906Unk5 (emb) USING vector WITH (metric = 'cosine', ef_construction = 200, M = 16)", null);
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3906_unk_6 ON E3906Unk6 (emb) USING vector WITH (metric: 'cosine', ef_search: 100)", null);

    if (failures.items.len != 0) {
        std.debug.print("\n[ENG-3906] {d} WITH-parameter contract violation(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.IndexWithParameterContractViolated;
    }
}
