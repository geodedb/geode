// ENG-3916 — `CREATE INDEX … OPTIONS { … }` parsed the braces and threw every
// key away.
//
// VERIFIED READ-ONLY AGAINST v0.8.5 / 13836738 BEFORE THE FIX:
//
//   src/gql/parser.zig:5296 consumed OPTIONS and then skipped to the matching
//   `}` without reading a single key. Both of these reported success and
//   configured nothing:
//
//     CREATE INDEX i ON L (p) USING fulltext OPTIONS {k1: 1.5, b: 0.3}  -> 00000
//     CREATE INDEX i ON L (p) USING fulltext OPTIONS {banana: 1}        -> 00000
//
//   Same class as ENG-3906 (WITH-parameter validation): the user believes they
//   tuned the index; nothing happened, and nothing said so.
//
// WHY REJECT RATHER THAN WIRE
//
//   The k1 / b knobs are NOT wireable. The fts-storage engine fixes BM25 k1 and
//   b as compile-time constants (`pub const BM25_K1: f32 = 1.2;` /
//   `pub const BM25_B: f32 = 0.75;` in its src/search.zig) and exposes no
//   per-index override; the analyzer is likewise fixed by
//   src/index/fts_tokenizer.zig. No index type in this engine implements ANY
//   OPTIONS key today, so every key is refused by name. If a future fts-storage
//   release exposes per-index BM25 parameters, wire them and move those keys
//   from "refused" to "accepted" in the same commit.
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   1. Any OPTIONS key is REJECTED — the documented-but-unimplemented tuning
//      keys (k1, b, analyzer) and typos alike, on fulltext and on every other
//      index type that accepts the OPTIONS clause.
//   2. An empty `OPTIONS {}` asks for nothing and stays accepted, as does a
//      CREATE INDEX with no OPTIONS clause at all — the guard against "fix it by
//      rejecting the whole clause".
//
// The SQLSTATE (42704, the same undefined_object family ENG-3906 uses) is
// pinned in src/server/proto_util.zig; these tests pin THAT it is rejected.
//
// CANARY: REQ=REQ-ENG-3916-INDEX-OPTIONS-VALIDATION; FEATURE="FulltextIndex"; ASPECT=OptionsKeyValidation; STATUS=TESTED; TEST=tests/test_eng3916_fts_index_options.zig; OWNER=index; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

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

    /// Record (do NOT abort on) a statement accepted when it should have been
    /// rejected, so one RED run enumerates the whole discarded-option surface.
    pub fn checkRejected(
        self: *Harness,
        failures: *std.ArrayListUnmanaged([]const u8),
        gpa: std.mem.Allocator,
        query: []const u8,
    ) !void {
        if (self.exec(query)) |_| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "ACCEPTED (options silently discarded): {s}",
                .{query},
            ));
        } else |err| {
            if (err != error.UnknownIndexOption) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "REJECTED with {s} (expected UnknownIndexOption, which names the key): {s}",
                    .{ @errorName(err), query },
                ));
            }
        }
    }

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

test "ENG-3916: CREATE INDEX OPTIONS keys are rejected, never silently discarded" {
    // ONE harness for all phases, for the same reason
    // tests/test_eng3906_index_with_params.zig uses one: the index-manager
    // registry is process-global and per-test re-init is an artefact of the
    // harness, not a finding about the code under test.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    _ = try h.exec("CREATE GRAPH eng3916");
    _ = try h.exec("USE GRAPH eng3916");

    // ---- KEY ASSERTIONS (RED): every one of these returned success ----
    //
    // The BM25 knobs users copy out of Lucene/Elasticsearch documentation. The
    // fts-storage engine fixes them at compile time; accepting them is a
    // correctness lie about the index that was actually built.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_k1 ON E3916A (body) USING fulltext OPTIONS {k1: 1.5}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_b ON E3916B (body) USING fulltext OPTIONS {b: 0.3}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_k1b ON E3916C (body) USING fulltext OPTIONS {k1: 1.5, b: 0.3}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_analyzer ON E3916D (body) USING fulltext OPTIONS {analyzer: 'english'}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_all ON E3916E (body) USING fulltext OPTIONS {k1: 1.5, b: 0.3, analyzer: 'english'}");

    // A plain typo must not be swallowed either.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_typo ON E3916F (body) USING fulltext OPTIONS {banana: 1}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_typo2 ON E3916G (body) USING fulltext OPTIONS {analyser: 'english'}");

    // Not fulltext-specific: OPTIONS is discarded for every index type the
    // clause is accepted on, so every index type refuses it.
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_plain ON E3916H (name) OPTIONS {k1: 1.5}");
    try h.checkRejected(&failures, gpa, "CREATE INDEX e3916_vec ON E3916I (emb) USING vector OPTIONS {m: 16}");

    // ---- GUARD: the shapes that ask for nothing must stay accepted ----
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3916_ok_empty ON E3916J (body) USING fulltext OPTIONS {}");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3916_ok_none ON E3916K (body) USING fulltext");
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3916_ok_plain ON E3916L (name)");
    // ENG-3906's WITH-clause contract is a different clause and must be
    // untouched by this change.
    try h.checkAccepted(&failures, gpa, "CREATE INDEX e3916_ok_with ON E3916M (emb) USING vector WITH (metric = 'cosine')");

    if (failures.items.len != 0) {
        std.debug.print("\n[ENG-3916] {d} index-OPTIONS contract violation(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.IndexOptionsContractViolated;
    }
}
