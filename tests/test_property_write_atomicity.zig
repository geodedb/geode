// Reproduction + regression tests — PROPERTY-WRITE ATOMICITY.
//
// THE DEFECT CLASS. A write statement that fails PART-WAY THROUGH leaves the
// database holding the part that already landed. Autocommit has no statement
// rollback: the per-statement engine txn (`beginStatementTxn`) is an
// fsync-BATCHING device pinned to ONE round-robin shard, its `abort` is
// WAL-discard only, and ~15/16 sub-ops route to a different shard where the
// adapter opens-and-commits its OWN txn. The in-memory `GraphStore` mirror is
// mutated unconditionally on top of that. So:
//
//   * a CREATE whose 2nd property is refused persists the node with only the
//     1st property,
//   * a relationship CREATE whose right endpoint is refused persists BOTH
//     endpoints as orphans and no edge,
//   * `MERGE ... ON CREATE SET` whose SET is refused persists the node without
//     the property,
//   * `SET a = .., b = ..` whose 2nd assignment is refused commits the 1st.
//
// Independently (RC-4, the sharpest one): `StorageAdapter.setNodeProperty`
// removed the exact-index posting for the OLD value BEFORE the fallible
// `putPropertyTxn`, and only re-added it after success. Any failure therefore
// left DURABLE index/value divergence — the row stays in the store with its
// old value but is INVISIBLE to `MATCH (n:L {k: <old>})`. It survives restart.
// That is an availability/authorization-shaped bug, not a cosmetic one.
//
// THE FAILURE TRIGGER USED HERE. Since graph-storage v0.4.0 a property value
// that does not fit a property page SPILLS to a VarStore overflow chain and
// SUCCEEDS; the only value-size refusal left is
// `GraphConfig.max_property_value_bytes` (default 1 MiB) →
// `error.PropertyValueTooLarge`. So the oversized value used to provoke a
// mid-statement failure must be >1 MiB, which is why these tests build it in
// Zig (a CLI/harness spec cannot ship a >1 MiB literal: ARG_MAX). The
// atomicity contract itself is failure-source agnostic — the same shapes fall
// out of TypeMismatch on a later assignment, a vector dimension refusal, or a
// write-budget refusal.
//
// THE FIX PINNED HERE. A statement-level PRE-PASS validates every property
// entry the statement could write BEFORE the first store mutation
// (`graph_storage_adapter.checkPropertyEntryFits` + the
// `write_precheck.check*` wrappers), and `setNodeProperty` /
// `setNodePropertiesBatch` no longer drop the old exact-index posting until
// the put has SUCCEEDED.
//
// CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=StatementAtomicity; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const index_manager = geode.index_manager;
const StorageAdapter = adapter_mod.StorageAdapter;
const Value = geode.value_types.Value;

/// `GraphConfig.max_property_value_bytes` default. The engine refuses an
/// encoded value strictly above this.
const VALUE_CAP: usize = 1024 * 1024;
/// A string whose ENCODED size (5 + len, see `gs.property.encodedSize`) is
/// comfortably above the cap.
const OVER_CAP_LEN: usize = VALUE_CAP + 1024;
/// A string that is large (well past the ~8142-byte inline page budget that
/// used to refuse it) but still UNDER the cap: v0.4.0 must keep storing it.
const UNDER_CAP_LEN: usize = 1000 * 1000;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn filledString(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    @memset(buf, 'x');
    return buf;
}

// ---------------------------------------------------------------------------
// Executor harness: real parser + executor + engine-backed global store, with
// a TRUE restart (drop the store + adapter, re-open the same data dir).
// ---------------------------------------------------------------------------

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    /// Mirrors `ServerState.in_txn`: the QUIC handler carries the transaction
    /// state ACROSS statements, so the harness has to as well or `ROLLBACK`
    /// would see `.None` and replay nothing.
    in_txn: bool = false,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        // The index manager is a PROCESS global that `deinitGlobalStore` does
        // not touch, so an index created by an earlier test would outlive its
        // store and be walked against freed memory here.
        index_manager.cleanupGlobalIndexManager();

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

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        index_manager.cleanupGlobalIndexManager();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// TRUE restart: checkpoint, tear the whole global store + adapter down,
    /// then re-open the SAME data dir — exactly what a server process does.
    fn restart(self: *Harness) !void {
        if (graph_store.getGlobalAdapter()) |ad| try ad.checkpointAll();
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        graph_store.setDataDirOverride(self.allocator, self.data_dir);
        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        return self.execParams(query, &.{}, &.{});
    }

    fn execParams(
        self: *Harness,
        query: []const u8,
        param_names: []const []const u8,
        param_values: []const Value,
    ) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        var ctx = self.ctx;
        ctx.session_state = &self.session;
        ctx.query_param_names = param_names;
        ctx.query_param_values = param_values;
        ctx.transaction_state = if (self.in_txn) .Active else .None;
        return execution.executeProgramWithContext(aa, &parsed.program, ctx);
    }

    /// Explicit transaction, driven the way the QUIC handler drives it: the
    /// engine session txn is ended after the undo log replays (SONNY-6529).
    fn begin(self: *Harness) !void {
        try self.run("BEGIN");
        self.in_txn = true;
    }

    fn rollback(self: *Harness) !void {
        try self.run("ROLLBACK");
        if (graph_store.getGlobalAdapter()) |ad| ad.endSessionTxn();
        self.in_txn = false;
    }

    fn run(self: *Harness, query: []const u8) !void {
        var r = try self.exec(query);
        r.deinit(self.arena.allocator());
    }

    /// Number of nodes carrying `label`, straight through the executor.
    fn countLabel(self: *Harness, label: []const u8) !i64 {
        const q = try std.fmt.allocPrint(self.arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
        var r = try self.exec(q);
        defer r.deinit(self.arena.allocator());
        if (r.rows.len != 1) return error.ExpectedOneRow;
        return switch (r.rows[0][0]) {
            .Int => |c| c,
            else => error.UnexpectedValueTag,
        };
    }

    /// Single scalar of a single-row/single-column query. The result is NOT
    /// deinit'd: the returned `Value` may point into it (a `.Str` does), and
    /// everything here is arena-backed, so the harness teardown reclaims it.
    fn scalar(self: *Harness, query: []const u8) !Value {
        const r = try self.exec(query);
        if (r.rows.len != 1) return error.ExpectedOneRow;
        if (r.rows[0].len != 1) return error.ExpectedOneColumn;
        return r.rows[0][0];
    }
};

fn expectNoNodes(h: *Harness, label: []const u8, comptime phase: []const u8) !void {
    const n = try h.countLabel(label);
    if (n != 0) {
        std.debug.print(
            "\n[atomicity] {s}: a FAILED write left {d} :{s} node(s) behind ({s}).\n" ++
                "            A statement that returned an error must not have written anything.\n",
            .{ phase, n, label, phase },
        );
        return error.PartialWritePersisted;
    }
}

// ---------------------------------------------------------------------------
// (a) A CREATE refused on its 2nd property must leave NO node — not in memory,
//     and not after a restart.
// ---------------------------------------------------------------------------
test "atomicity (a): a failed oversized CREATE leaves no node, before and after restart" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    const res = h.execParams(
        "CREATE (n:AtomA {ok: 1, big: $big})",
        &.{"big"},
        &.{Value{ .Str = big }},
    );
    try testing.expectError(error.PropertyValueTooLarge, res);

    try expectNoNodes(&h, "AtomA", "in memory");
    try h.restart();
    try expectNoNodes(&h, "AtomA", "after restart");
}

// ---------------------------------------------------------------------------
// (b) The bulk-ingest fast path (`adapter.bulkInsertNode`, the QUIC handler's
//     single-label scalar-prop CREATE dispatch) must not create the node
//     before its properties are known to be storable. It skips the undo log by
//     design, so a partial write there is a PHANTOM: visible in memory,
//     absent after restart.
// ---------------------------------------------------------------------------
test "atomicity (b): a failed bulkInsertNode leaves no node, before and after restart" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    const ad = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const kvs = [_]StorageAdapter.PropKV{
        .{ .key = "ok", .value = .{ .Int = 1 } },
        .{ .key = "big", .value = .{ .String = big } },
    };
    try testing.expectError(
        error.PropertyValueTooLarge,
        ad.bulkInsertNode("default", &[_][]const u8{"AtomB"}, &kvs, null),
    );

    try expectNoNodes(&h, "AtomB", "in memory");
    try h.restart();
    try expectNoNodes(&h, "AtomB", "after restart");
}

// ---------------------------------------------------------------------------
// (c) A relationship CREATE refused while populating the RIGHT endpoint must
//     leave neither endpoint nor the edge.
// ---------------------------------------------------------------------------
test "atomicity (c): a failed relationship CREATE leaves no endpoints and no edge" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    const res = h.execParams(
        "CREATE (a:AtomCL {x: 1})-[r:ATOM_REL {w: 2}]->(b:AtomCR {big: $big})",
        &.{"big"},
        &.{Value{ .Str = big }},
    );
    try testing.expectError(error.PropertyValueTooLarge, res);

    try expectNoNodes(&h, "AtomCL", "in memory");
    try expectNoNodes(&h, "AtomCR", "in memory");
    {
        const c = try h.scalar("MATCH ()-[r:ATOM_REL]->() RETURN count(r) AS c");
        try testing.expectEqual(@as(i64, 0), c.Int);
    }

    try h.restart();
    try expectNoNodes(&h, "AtomCL", "after restart");
    try expectNoNodes(&h, "AtomCR", "after restart");
}

// ---------------------------------------------------------------------------
// (d) `MERGE ... ON CREATE SET` refused on the SET must not leave the node the
//     MERGE minted.
// ---------------------------------------------------------------------------
test "atomicity (d): a failed MERGE ON CREATE SET leaves no node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    const res = h.execParams(
        "MERGE (n:AtomD {k: 'one'}) ON CREATE SET n.big = $big",
        &.{"big"},
        &.{Value{ .Str = big }},
    );
    try testing.expectError(error.PropertyValueTooLarge, res);

    try expectNoNodes(&h, "AtomD", "in memory");
    try h.restart();
    try expectNoNodes(&h, "AtomD", "after restart");
}

// ---------------------------------------------------------------------------
// (e) A multi-assignment SET is all-or-nothing: a refusal on the LAST
//     assignment must leave every earlier assignment unapplied — AND must not
//     destroy the exact-index posting of the value it was about to overwrite
//     (RC-4: the row must stay findable by its OLD value).
// ---------------------------------------------------------------------------
test "atomicity (e): a failed multi-assignment SET applies nothing and keeps the old value indexed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    try h.run("CREATE (n:AtomE {name: 'abc', tag: 'keep'})");

    const res = h.execParams(
        "MATCH (n:AtomE {name: 'abc'}) SET n.tag = 'changed', n.name = $big",
        &.{"big"},
        &.{Value{ .Str = big }},
    );
    try testing.expectError(error.PropertyValueTooLarge, res);

    // The earlier assignment in the same clause list must NOT have committed.
    {
        const tag = try h.scalar("MATCH (n:AtomE) RETURN n.tag AS t");
        try testing.expectEqualStrings("keep", tag.Str);
    }

    // RC-4: the row is still reachable by an equality match on the OLD value.
    {
        const c = try h.scalar("MATCH (n:AtomE {name: 'abc'}) RETURN count(n) AS c");
        if (c.Int != 1) {
            std.debug.print(
                "\n[atomicity] RC-4: after a failed SET, MATCH (n:AtomE {{name: 'abc'}}) found {d} row(s);\n" ++
                    "            the node still holds name='abc' but its exact-index posting was dropped.\n",
                .{c.Int},
            );
            return error.ExactIndexDivergedFromValue;
        }
    }

    try h.restart();
    {
        const c = try h.scalar("MATCH (n:AtomE {name: 'abc'}) RETURN count(n) AS c");
        try testing.expectEqual(@as(i64, 1), c.Int);
        const tag = try h.scalar("MATCH (n:AtomE) RETURN n.tag AS t");
        try testing.expectEqualStrings("keep", tag.Str);
    }
}

// ---------------------------------------------------------------------------
// (e2) RC-4 in isolation, at the adapter — the layer where the index/value
//      divergence is actually produced. The statement-level pre-pass cannot
//      cover this: any OTHER fallible put (a WAL error, a full disk, a
//      shard-local txn failure) reaches the same code. Both the single-set and
//      the batch path must hold the posting until the put has succeeded.
//
//      Runs against a purpose-built adapter whose `max_property_value_bytes`
//      is 4 KiB, which both makes the test cheap and proves the predicate
//      reads the CONFIGURED cap rather than a hardcoded 1 MiB.
// ---------------------------------------------------------------------------
fn cappedConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
        .max_property_value_bytes = 4096,
    };
}

test "atomicity (e2): a failed setNodeProperty must not drop the old exact-index posting" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(path);

    const over = try filledString(allocator, 8192);
    defer allocator.free(over);

    const ad = try StorageAdapter.init(allocator, path, cappedConfig());
    defer ad.deinit();

    const graph = "rc4_graph";
    const node_id = try ad.createNode(graph, &[_][]const u8{"L"});
    try ad.setNodeProperty(graph, node_id, "k", .{ .String = "abc" });

    {
        const hits = try ad.getCandidateNodesByLabelAndProperty(graph, "L", "k", .{ .String = "abc" }, allocator);
        defer allocator.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
    }

    // Single-set path.
    try testing.expectError(
        error.PropertyValueTooLarge,
        ad.setNodeProperty(graph, node_id, "k", .{ .String = over }),
    );
    {
        const hits = try ad.getCandidateNodesByLabelAndProperty(graph, "L", "k", .{ .String = "abc" }, allocator);
        defer allocator.free(hits);
        if (hits.len != 1) {
            std.debug.print(
                "\n[atomicity] RC-4 (setNodeProperty): the failed write dropped the posting for the OLD\n" ++
                    "            value — exact-index lookup on 'abc' now returns {d} candidate(s).\n",
                .{hits.len},
            );
            return error.ExactIndexDivergedFromValue;
        }
    }
    // The stored value itself is unchanged.
    {
        const got = try ad.getNodeProperty(graph, node_id, "k", allocator);
        defer if (got) |v| adapter_mod.freeOwnedStorageProperty(allocator, v);
        try testing.expectEqualStrings("abc", got.?.string);
    }

    // Batch path (setNodePropertiesBatch) — same contract.
    const entries = [_]StorageAdapter.BatchPropertyEntry{
        .{ .key = "other", .value = .{ .Int = 7 } },
        .{ .key = "k", .value = .{ .String = over } },
    };
    try testing.expectError(
        error.PropertyValueTooLarge,
        ad.setNodePropertiesBatch(graph, node_id, &entries),
    );
    {
        const hits = try ad.getCandidateNodesByLabelAndProperty(graph, "L", "k", .{ .String = "abc" }, allocator);
        defer allocator.free(hits);
        if (hits.len != 1) {
            std.debug.print(
                "\n[atomicity] RC-4 (setNodePropertiesBatch): the failed batch dropped the posting for\n" ++
                    "            the OLD value — lookup on 'abc' now returns {d} candidate(s).\n",
                .{hits.len},
            );
            return error.ExactIndexDivergedFromValue;
        }
    }
}

// ---------------------------------------------------------------------------
// (f) CONTROL — v0.4.0 overflow must keep working. A large-but-under-cap
//     string and a 2048-dim vector (both far past the old ~8142-byte inline
//     page budget) still store and read back. This is the guard that the fix
//     does not turn into an over-eager refusal.
// ---------------------------------------------------------------------------
test "atomicity (f) control: large-but-under-cap values still store and survive restart" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big_ok = try filledString(testing.allocator, UNDER_CAP_LEN);
    defer testing.allocator.free(big_ok);

    var ok_res = h.execParams(
        "CREATE (n:AtomF {id: 1, blob: $blob})",
        &.{"blob"},
        &.{Value{ .Str = big_ok }},
    ) catch |err| {
        std.debug.print("\n[atomicity] control: a {d}-byte (under-cap) value was refused: {s}\n", .{ UNDER_CAP_LEN, @errorName(err) });
        return err;
    };
    ok_res.deinit(h.arena.allocator());

    // 2048-dim VECTOR<f32>: 8 KB payload, spills to an overflow chain, stores.
    {
        var q = std.ArrayList(u8).empty;
        defer q.deinit(testing.allocator);
        try q.appendSlice(testing.allocator, "CREATE (n:AtomFV {vec: vectorf32('[");
        var i: usize = 0;
        while (i < 2048) : (i += 1) {
            if (i > 0) try q.appendSlice(testing.allocator, ",");
            try q.appendSlice(testing.allocator, "1.0");
        }
        try q.appendSlice(testing.allocator, "]')})");
        try h.run(q.items);
    }

    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomF"));
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomFV"));

    try h.restart();
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomF"));
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomFV"));
    {
        const len = try h.scalar("MATCH (n:AtomF) RETURN size(n.blob) AS s");
        try testing.expectEqual(@as(i64, @intCast(UNDER_CAP_LEN)), len.Int);
    }
}

// ---------------------------------------------------------------------------
// (i) The same atomicity contract for a NON-SIZE mid-statement refusal: a
//     vector whose dimension disagrees with the HNSW index covering the
//     property (GAP-0918). That check used to fire at the write chokepoint —
//     i.e. after the node and its earlier properties already existed — so a
//     refused CREATE left an orphan carrying its `tag`. This is also the only
//     shape of this defect class reachable through the CLI, so it is what the
//     harness spec property_write_atomicity.yml drives end to end.
// ---------------------------------------------------------------------------
test "atomicity (i): a CREATE refused for vector dimension leaves no partial node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE INDEX atom_vec_idx ON AtomI (emb) USING HNSW WITH (metric = 'l2')");
    // Establishes the index dimension at 4.
    try h.run("CREATE (:AtomI {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");

    // `tag` is written BEFORE `emb`, so a chokepoint-only refusal commits it.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:AtomI {id: 2, tag: 'partial', emb: vectorf32('[1.0, 2.0, 3.0]')})"),
    );

    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomI"));
    {
        const c = try h.scalar("MATCH (n:AtomI {id: 2}) RETURN count(n) AS c");
        if (c.Int != 0) {
            std.debug.print(
                "\n[atomicity] a CREATE refused for VectorDimensionMismatch left {d} partial :AtomI node(s)\n" ++
                    "            carrying the properties written before the refused one.\n",
                .{c.Int},
            );
            return error.PartialWritePersisted;
        }
    }

    try h.restart();
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomI"));
}

// ---------------------------------------------------------------------------
// (j) The multi-assignment SET counterpart of (i): a single-variable
//     `MATCH … SET a = .., b = ..` where the LAST assignment is refused for
//     vector dimension must leave the earlier one unapplied.
// ---------------------------------------------------------------------------
test "atomicity (j): a multi-assignment SET refused for vector dimension applies nothing" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE INDEX atom_vec_idx_j ON AtomJ (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("CREATE (:AtomJ {id: 1, tag: 'keep', emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");

    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("MATCH (n:AtomJ {id: 1}) SET n.tag = 'changed', n.emb = vectorf32('[9.0, 9.0]')"),
    );

    const tag = try h.scalar("MATCH (n:AtomJ) RETURN n.tag AS t");
    try testing.expectEqualStrings("keep", tag.Str);
}

// ---------------------------------------------------------------------------
// (g) GUARD — an explicit BEGIN … ROLLBACK batch is already atomic (the undo
//     log is active for it). The fix must not regress that.
// ---------------------------------------------------------------------------
test "atomicity (g) guard: an explicit transaction still rolls back a failed batch whole" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const big = try filledString(testing.allocator, OVER_CAP_LEN);
    defer testing.allocator.free(big);

    try h.begin();
    try h.run("CREATE (a:AtomG {v: 1})");
    try testing.expectError(error.PropertyValueTooLarge, h.execParams(
        "CREATE (b:AtomGBad {v: 1, big: $big})",
        &.{"big"},
        &.{Value{ .Str = big }},
    ));
    try h.rollback();

    try expectNoNodes(&h, "AtomG", "after rollback");
    try expectNoNodes(&h, "AtomGBad", "after rollback");
}

// ---------------------------------------------------------------------------
// (k) An explicit transaction rolls back what MERGE created, as it does what
//     CREATE created: the node of a node MERGE, the endpoints and edge of a
//     relationship MERGE, and an edge MERGE'd between existing nodes. MERGE
//     wrote no undo entry, so ROLLBACK kept all of them (found by the
//     SONNY-2816 test, where a bulk-ingest MERGE in a transaction now takes
//     the executor).
// ---------------------------------------------------------------------------
test "atomicity (k): an explicit transaction rolls back the nodes and edges MERGE created" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE (:AtomKEnd {k: 1})");
    try h.run("CREATE (:AtomKEnd {k: 2})");

    try h.begin();
    try h.run("MERGE (n:AtomK {k: 1}) SET n.v = 'merged'");
    try h.run("MERGE (a:AtomKA {k: 1})-[:AtomKR]->(b:AtomKB {k: 1})");
    try h.run("MATCH (a:AtomKEnd {k: 1}), (b:AtomKEnd {k: 2}) MERGE (a)-[:AtomKM]->(b)");
    // Inside the transaction the changes are there.
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomK"));
    try testing.expectEqual(@as(i64, 1), (try h.scalar("MATCH ()-[r:AtomKM]->() RETURN count(r) AS c")).Int);
    try h.rollback();

    try expectNoNodes(&h, "AtomK", "after rollback");
    try expectNoNodes(&h, "AtomKA", "after rollback");
    try expectNoNodes(&h, "AtomKB", "after rollback");
    try testing.expectEqual(@as(i64, 0), (try h.scalar("MATCH ()-[r:AtomKR]->() RETURN count(r) AS c")).Int);
    try testing.expectEqual(@as(i64, 0), (try h.scalar("MATCH ()-[r:AtomKM]->() RETURN count(r) AS c")).Int);
    // What the transaction did not create stays.
    try testing.expectEqual(@as(i64, 2), try h.countLabel("AtomKEnd"));

    // Committed, the same MERGEs stand.
    try h.begin();
    try h.run("MERGE (n:AtomK {k: 1}) SET n.v = 'merged'");
    try h.run("MATCH (a:AtomKEnd {k: 1}), (b:AtomKEnd {k: 2}) MERGE (a)-[:AtomKM]->(b)");
    try h.run("COMMIT");
    h.in_txn = false;
    try testing.expectEqual(@as(i64, 1), try h.countLabel("AtomK"));
    try testing.expectEqual(@as(i64, 1), (try h.scalar("MATCH ()-[r:AtomKM]->() RETURN count(r) AS c")).Int);
}

// ---------------------------------------------------------------------------
// (h) The shared predicate itself. It is the single place that decides whether
//     an entry is storable, so its boundaries are pinned directly.
// ---------------------------------------------------------------------------
test "atomicity (h): checkPropertyEntryFits honours the configured value cap" {
    const allocator = testing.allocator;
    const cap: u32 = 4096;

    // gs.property.encodedSize(.string) == 5 + len, so `cap - 5` is the largest
    // string that fits and `cap - 4` is the first that does not.
    const at_cap = try filledString(allocator, cap - 5);
    defer allocator.free(at_cap);
    const over_cap = try filledString(allocator, cap - 4);
    defer allocator.free(over_cap);

    try adapter_mod.checkPropertyEntryFits("k", .{ .string = at_cap }, cap);
    try testing.expectError(
        error.PropertyValueTooLarge,
        adapter_mod.checkPropertyEntryFits("k", .{ .string = over_cap }, cap),
    );

    // Scalars are always well under any sane cap.
    try adapter_mod.checkPropertyEntryFits("k", .{ .int = 42 }, cap);
    try adapter_mod.checkPropertyEntryFits("k", .null, cap);

    // The cap is READ, not hardcoded: the same value passes under a larger cap.
    try adapter_mod.checkPropertyEntryFits("k", .{ .string = over_cap }, cap * 2);
}

test "atomicity (h): checkPropertyEntryFits pins the property-key length boundary" {
    const allocator = testing.allocator;
    const cap: u32 = 1024 * 1024;

    // The storage layer refuses a key strictly above u16 max.
    const at_limit = try filledString(allocator, std.math.maxInt(u16));
    defer allocator.free(at_limit);
    const over_limit = try filledString(allocator, std.math.maxInt(u16) + 1);
    defer allocator.free(over_limit);

    try adapter_mod.checkPropertyEntryFits(at_limit, .{ .int = 1 }, cap);
    try testing.expectError(
        error.PropertyKeyTooLong,
        adapter_mod.checkPropertyEntryFits(over_limit, .{ .int = 1 }, cap),
    );

    // An oversized KEY keeps its own identity even when the VALUE is also
    // oversized — the two refusals must never be collapsed.
    const big_val = try filledString(allocator, cap + 16);
    defer allocator.free(big_val);
    try testing.expectError(
        error.PropertyKeyTooLong,
        adapter_mod.checkPropertyEntryFits(over_limit, .{ .string = big_val }, cap),
    );
}
