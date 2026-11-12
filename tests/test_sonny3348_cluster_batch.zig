// SONNY-3348 round 19 (the round 18 review's I1): on a cluster leader, a
// statement commits all of its writes in ONE Raft entry, or none.
//
// A statement that writes once per row or per iteration (`FOR … CREATE`,
// `MATCH … MERGE`) proposed one entry per row and waited for each to commit:
// when the last row then failed (a limit, any error), the rows before it were
// committed on every node. The leader writes nothing locally, so the statement
// undo record had nothing to undo. The leader now holds the statement's
// writes (`statement_proposals`) and proposes them once the statement has
// evaluated completely: as one GBAT batch entry (`cluster_replication`), or
// not at all.
//
// An in-process 3-node Raft cluster (the coordinators wired through the raft
// library's in-process transport, driven on a thread of their own), the
// leader installed as the process's coordinator, every node applying
// committed entries to the process store (idempotently, by id), and the
// statements sent through the real gRPC handler in process. The evaluator's
// test seam (`eval.test_force_limit_error`) fails the marker literal on the
// last row only.
//
// CANARY: REQ=REQ-SONNY-3348-CLUSTER-BATCH; FEATURE="DistributedCluster"; ASPECT=StatementBatchRegression; STATUS=TESTED; TEST=tests/test_sonny3348_cluster_batch.zig; OWNER=distributed; UPDATED=2026-09-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const eval = geode.eval;
const cluster_mod = geode.distributed.cluster;
const ClusterCoordinator = cluster_mod.ClusterCoordinator;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const repl = geode.distributed.cluster_replication;

const L = "'" ++ eval.test_force_limit_marker ++ "'";
/// Swallowed into false by EXISTS; the relay then fails the statement (54001).
const EX = "EXISTS { MATCH (m:Src) WHERE " ++ L ++ " = 'x' }";
const TE = error.ExpressionTooDeep;

const ch = @import("sonny3348_cluster_harness.zig");
const Cluster = ch.Cluster;
const Harness = ch.Harness;
const Run = ch.Run;
const runOn = ch.runOn;
const rowsOf = ch.rowsOf;
const expectRan = ch.expectRan;
const nowMs = ch.nowMs;

/// Entries the leader committed while `query` ran (after every node applied
/// them), and the statement's outcome.
const Outcome = struct { run: Run, entries: u64 };

fn runCounted(h: *Harness, query: []const u8, force: ?eval.EvalError) !Outcome {
    const before = try h.cl.settle();
    const r = try runOn(h.ga(), h.s, query, force);
    const after = try h.cl.settle();
    return .{ .run = r, .entries = after - before };
}

fn expectAtomicFailure(h: *Harness, name: []const u8, query: []const u8, force: ?eval.EvalError, check: []const u8) !void {
    const o = try runCounted(h, query, force);
    const left = try rowsOf(h.ga(), h.s, check);
    const failed = o.run.code != null or o.run.err != null;
    if (!failed or left != 0 or o.entries != 0) {
        std.debug.print("SONNY-3348 r19 {s}: code={s} err={s} | entries committed={d} rows left={d} (want a failure, 0 entries, 0 rows)\n   q: {s}\n", .{
            name, o.run.code orelse "ran", if (o.run.err) |e| @errorName(e) else "-", o.entries, left, query,
        });
    }
    try testing.expect(failed);
    try testing.expectEqual(@as(usize, 0), left);
    try testing.expectEqual(@as(u64, 0), o.entries);
}

const seed_src = [_][]const u8{
    "CREATE (:Src {k: 0})",
    "CREATE (:Src {k: 1})",
    "CREATE (:Src {k: 2})",
};

test "SONNY-3348 r19 cluster leader: FOR ... CREATE with a limit on the last iteration commits nothing; without it, one entry" {
    var h: Harness = .{};
    try h.init(&seed_src);
    defer h.deinit();

    // I1's B9: iterations 1 and 2 were committed through Raft before the
    // third recorded the limit.
    try expectAtomicFailure(&h, "B9 FOR ... CREATE, limit on i = 3", "FOR i IN [1, 2, 3] CREATE (:U {i: i, w: CASE WHEN i = 3 THEN " ++ EX ++ " ELSE true END})", TE, "MATCH (u:U) RETURN u");
    try testing.expectEqual(@as(usize, 0), geode.distributed.statement_proposals.heldCount());

    // The same statement without the limit: all three rows, in ONE entry.
    const batches0 = geode.distributed.statement_proposals.batches_proposed_total.load(.monotonic);
    const ok = try runCounted(&h, "FOR i IN [1, 2, 3] CREATE (:U {i: i, w: true})", null);
    if (ok.run.code) |c| std.debug.print("SONNY-3348 r19 B9 unforced refused {s}\n", .{c});
    try testing.expect(ok.run.code == null and ok.run.err == null);
    try testing.expectEqual(@as(u64, 1), ok.entries);
    try testing.expectEqual(batches0 + 1, geode.distributed.statement_proposals.batches_proposed_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (u:U) RETURN u"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(h.ga(), h.s, "MATCH (u:U {i: 3}) RETURN u"));
    // Every create of the batch has an id of its own, in the batch band.
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (u:U) WHERE id(u) >= 18014398509481984 RETURN DISTINCT id(u)"));

    // A retry of the failed statement, then the check: applied once.
    try expectAtomicFailure(&h, "B9 again", "FOR i IN [1, 2, 3] CREATE (:V {i: i, w: CASE WHEN i = 3 THEN " ++ EX ++ " ELSE true END})", TE, "MATCH (v:V) RETURN v");
    try expectRan(h.ga(), h.s, "FOR i IN [1, 2, 3] CREATE (:V {i: i})");
    _ = try h.cl.settle();
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (v:V) RETURN v"));

    // One write: the lone entry, as before (not a batch).
    const batches1 = geode.distributed.statement_proposals.batches_proposed_total.load(.monotonic);
    const one = try runCounted(&h, "CREATE (:W {k: 1})", null);
    try testing.expect(one.run.code == null and one.run.err == null);
    try testing.expectEqual(@as(u64, 1), one.entries);
    try testing.expectEqual(batches1, geode.distributed.statement_proposals.batches_proposed_total.load(.monotonic));
}

test "SONNY-3348 r19 cluster leader: MATCH ... MERGE with a limit on the last row commits nothing; without it, one entry" {
    var h: Harness = .{};
    try h.init(&seed_src);
    defer h.deinit();

    // I1's B6: MERGE per MATCH row, the limit in ON CREATE SET on row 3.
    try expectAtomicFailure(&h, "B6 MATCH ... MERGE ON CREATE SET, limit on row 3", "MATCH (s:Src) MERGE (t:T {k: s.k}) ON CREATE SET t.w = CASE WHEN s.k = 2 THEN " ++ EX ++ " ELSE true END", TE, "MATCH (t:T) RETURN t");
    // B6b: the limit in the MERGE key.
    try expectAtomicFailure(&h, "B6b MATCH ... MERGE, limit in the key on row 3", "MATCH (s:Src) MERGE (t:T {k: CASE WHEN s.k = 2 THEN " ++ EX ++ " ELSE s.k END})", TE, "MATCH (t:T) RETURN t");

    const ok = try runCounted(&h, "MATCH (s:Src) MERGE (t:T {k: s.k}) ON CREATE SET t.w = true", null);
    if (ok.run.code) |c| std.debug.print("SONNY-3348 r19 B6 unforced refused {s}\n", .{c});
    try testing.expect(ok.run.code == null and ok.run.err == null);
    try testing.expectEqual(@as(u64, 1), ok.entries);
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (t:T) WHERE t.w = true RETURN t"));

    // MERGE again: every row matches, nothing is proposed.
    const again = try runCounted(&h, "MATCH (s:Src) MERGE (t:T {k: s.k})", null);
    try testing.expect(again.run.code == null and again.run.err == null);
    try testing.expectEqual(@as(u64, 0), again.entries);
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (t:T) RETURN t"));

    // Three rows MERGE the same key: the second and third match the first
    // row's create, which the statement holds (not yet applied): one node.
    const same = try runCounted(&h, "MATCH (s:Src) MERGE (:K {k: 1})", null);
    if (same.run.code) |c| std.debug.print("SONNY-3348 r19 same-key MERGE refused {s}\n", .{c});
    try testing.expect(same.run.code == null and same.run.err == null);
    try testing.expectEqual(@as(u64, 1), same.entries);
    try testing.expectEqual(@as(usize, 1), try rowsOf(h.ga(), h.s, "MATCH (k:K) RETURN k"));

    // ... and with ON MATCH SET on the held create: its id is not known
    // before the entry commits, so the statement is refused, whole.
    const on_match = try runCounted(&h, "MATCH (s:Src) MERGE (j:J {k: 1}) ON MATCH SET j.seen = true", null);
    try testing.expect(on_match.run.code != null);
    try testing.expectEqualStrings("40001", on_match.run.code.?);
    try testing.expectEqual(@as(u64, 0), on_match.entries);
    try testing.expectEqual(@as(usize, 0), try rowsOf(h.ga(), h.s, "MATCH (j:J) RETURN j"));
}

test "SONNY-3348 r19 cluster leader: a read an earlier row's held write could change is refused, whole" {
    var h: Harness = .{};
    try h.init(&seed_src);
    defer h.deinit();

    // Row 2 sets the node row 1 set: per row it read row 1's value; the
    // batch cannot (it is not applied yet). Refused, nothing proposed.
    const same_node = try runCounted(&h, "FOR i IN [1, 2] MATCH (n:Src {k: 0}) SET n.v = i", null);
    if (same_node.run.code == null) std.debug.print("SONNY-3348 r19: FOR ... MATCH ... SET of one node twice ran\n", .{});
    try testing.expect(same_node.run.code != null);
    try testing.expectEqualStrings("40001", same_node.run.code.?);
    try testing.expectEqual(@as(u64, 0), same_node.entries);
    try testing.expectEqual(@as(usize, 0), try rowsOf(h.ga(), h.s, "MATCH (n:Src) WHERE n.v IS NOT NULL RETURN n"));

    // Different nodes, a key the SET does not match on: one entry.
    const other = try runCounted(&h, "FOR i IN [0, 1, 2] MATCH (n:Src {k: i}) SET n.v = i", null);
    if (other.run.code) |c| std.debug.print("SONNY-3348 r19: FOR ... MATCH ... SET of three nodes refused {s}\n", .{c});
    try testing.expect(other.run.code == null and other.run.err == null);
    try testing.expectEqual(@as(u64, 1), other.entries);
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (n:Src) WHERE n.v = n.k RETURN n"));

    // A MATCH that would see a node an earlier iteration created.
    const sees_create = try runCounted(&h, "FOR i IN [1, 2] MATCH (n:Src {k: 0}) CREATE (:Src {k: 10 + i})", null);
    try testing.expect(sees_create.run.code != null);
    try testing.expectEqual(@as(u64, 0), sees_create.entries);
    try testing.expectEqual(@as(usize, 3), try rowsOf(h.ga(), h.s, "MATCH (n:Src) RETURN n"));
}

// ---------------------------------------------------------------------------
// The batch codec, on a store of its own.
// ---------------------------------------------------------------------------

fn countLabel(st: *geode.graph_store.GraphStore, label: []const u8) usize {
    return fx.countLabel(st, "default", label);
}

test "SONNY-3348 r19 GBAT: a batch applies every entry in order, ids of its own, idempotently; a version it does not know applies nothing" {
    const a = testing.allocator;
    var store = try geode.graph_store.GraphStore.init(a);
    defer store.deinit();

    const n1 = try repl.serializeNodeCreate(a, "default", &.{"B"}, &.{.{ .key = "i", .value = .{ .Int = 1 } }});
    defer a.free(n1);
    const n2 = try repl.serializeNodeCreateKeyed(a, "default", &.{"B"}, &.{.{ .key = "i", .value = .{ .Int = 2 } }}, "client-key");
    defer a.free(n2);
    const n3 = try repl.serializeMultiCreate(a, "default", &.{
        .{ .labels = &.{"B"}, .props = &.{.{ .key = "i", .value = .{ .Int = 3 } }} },
        .{ .labels = &.{"C"}, .props = &.{} },
    }, &.{.{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R", .props = &.{} }});
    defer a.free(n3);
    const entries = [_]repl.BatchEntry{
        .{ .mutation = .create, .graph = "default", .data = n1 },
        .{ .mutation = .create, .graph = "default", .data = n2 },
        .{ .mutation = .create, .graph = "default", .data = n3 },
    };
    const batch = try repl.serializeBatch(a, "stmt-key", &entries);
    defer a.free(batch);
    try testing.expectEqual(@as(usize, 3), try repl.batchEntryCount(a, batch));

    // Through the Raft command codec and the apply dispatch, as a node
    // applies a committed entry.
    const cmd = raft_consensus.Command{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = batch, .txn_id = null } };
    const r1 = try raft_apply.applyCommand(a, &store, cmd, 7);
    a.free(r1);
    try testing.expectEqual(@as(usize, 3), countLabel(&store, "B"));
    try testing.expectEqual(@as(usize, 1), countLabel(&store, "C"));
    // The entries' ids: position p of the batch at index 7.
    try testing.expect(store.getNodePtr(repl.batchLaneBase(7, 0)) != null);
    try testing.expect(store.getNodePtr(repl.batchLaneBase(7, 1)) != null);
    try testing.expect(store.getNodePtr(repl.batchLaneBase(7, 2)) != null);
    try testing.expect(store.getNodePtr(repl.batchLaneBase(7, 2) + 1) != null);

    // Re-applied (a restart replay): nothing new.
    const r2 = try raft_apply.applyCommand(a, &store, cmd, 7);
    a.free(r2);
    try testing.expectEqual(@as(usize, 3), countLabel(&store, "B"));

    // A version this build does not know: logged, skipped, nothing applied.
    const future = try a.dupe(u8, batch);
    defer a.free(future);
    future[4] = repl.BATCH_VERSION + 1;
    try testing.expectError(error.UnsupportedBatchVersion, repl.batchEntryCount(a, future));
    const r3 = try raft_apply.applyCommand(a, &store, .{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = future, .txn_id = null } }, 9);
    a.free(r3);
    try testing.expectEqual(@as(usize, 3), countLabel(&store, "B"));
    try testing.expect(store.getNodePtr(repl.batchLaneBase(9, 0)) == null);

    // A corrupt entry refuses the whole batch before any entry applies.
    const bad = try a.dupe(u8, batch);
    defer a.free(bad);
    const pos = std.mem.indexOf(u8, bad, "GNC2").?;
    bad[pos] = 'X';
    try testing.expectError(error.CorruptPayload, raft_apply.applyCommand(a, &store, .{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = bad, .txn_id = null } }, 11));
    try testing.expect(store.getNodePtr(repl.batchLaneBase(11, 0)) == null);

    // A build before round 19 routes the batch (a `.create` with a magic it
    // does not know) to its unknown-create-payload arm, which applies
    // nothing: the magic is none of the lone-entry magics.
    try testing.expect(!repl.isNodeCreatePayload(batch) and !repl.isMultiCreatePayload(batch) and !repl.isKeyedPayload(batch));
}
