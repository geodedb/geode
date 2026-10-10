// CANARY: REQ=REQ-SONNY-3348-CLUSTER-BATCH; FEATURE="DistributedCluster"; ASPECT=StatementProposalBatch; STATUS=TESTED; TEST=tests/test_sonny3348_cluster_batch.zig; OWNER=distributed; UPDATED=2026-09-29
//! SONNY-3348 (round 19): a statement on a cluster leader commits all of its
//! writes in one Raft entry, or none.
//!
//! The replicated write paths (`crud_operations.clusterReplicate*`) evaluate a
//! write and serialize it; they proposed it and waited for it to commit at
//! once. A statement that writes once per row or per iteration (`FOR …
//! CREATE`, `MATCH … MERGE`, a `CALL { … }` per row) so committed its first
//! rows before a later row failed, on every node, and a leader never writes
//! locally, so the statement undo record (`statement_undo`) had nothing to
//! undo.
//!
//! While the outermost statement scope on a thread is open
//! (`execution.executeStatementWithContext`,
//! `planned_read_runtime.executeProfiledIfSupported`), a write is held here
//! instead (`submit`). When the statement has evaluated completely without an
//! error, its held writes are proposed as ONE entry (`flush`): the lone entry
//! as it always was, or a GBAT batch (`cluster_replication.serializeBatch`)
//! for more than one. A statement that fails proposes nothing
//! (`finishFailed`). Nothing proposed is ever undone: a proposal that then
//! fails to commit in time answers its error, as a lone write always did.
//!
//! The leader no longer sees a statement's earlier rows when a later row
//! reads the store: those are not applied until the statement's entry
//! commits. A write that reads (MERGE's match, the MATCH of `MATCH … SET`,
//! `MATCH … DELETE` and `MATCH … CREATE`) is therefore checked against what
//! the statement holds (`checkRead`, `mergeMatch`): where a held write could
//! change what it reads (a node it would match, an id it touches, a property
//! or label its pattern names), the statement is refused with
//! `error.ClusterWriteNotReplicable` before anything is proposed. A MERGE
//! whose node a held create makes is answered as matched.
//!
//! Outside a statement scope (a write path with no statement around it) a
//! write is proposed at once, as before.

const std = @import("std");
const builtin = @import("builtin");
const cluster_mod = @import("cluster.zig");
const raft_consensus = @import("raft_consensus.zig");
const cluster_replication = @import("cluster_replication.zig");

pub const Prop = cluster_replication.Prop;
pub const MutationType = @FieldType(raft_consensus.GraphMutation, "mutation_type");

/// The held writes' allocator (the leak checker sees it under test).
const backing: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

/// What a statement's writes fail with here: not replicable (nothing
/// proposed), not the leader, the proposal refused, its commit not confirmed
/// in time (the outcome unknown), out of memory.
pub const Error = error{ ClusterWriteNotReplicable, ClusterNotLeader, ClusterProposeFailed, Timeout, OutOfMemory };

fn narrow(err: anyerror) Error {
    return switch (err) {
        error.ClusterNotLeader, error.NotLeader => error.ClusterNotLeader,
        error.ClusterWriteNotReplicable => error.ClusterWriteNotReplicable,
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.OutOfMemory,
        else => blk: {
            @import("logging").scoped("cluster").err("the statement's entry could not be proposed", &.{@import("logging").Attr.string("error", @errorName(err))});
            break :blk error.ClusterProposeFailed;
        },
    };
}

const Held = struct {
    mutation: MutationType,
    graph: []const u8,
    data: []const u8,
    effect: cluster_replication.Effect,
    key: ?[]const u8,
};

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Held) = .empty,
    bytes: usize = 0,
};

threadlocal var t_active: bool = false;
threadlocal var t_batch: ?*Batch = null;

/// SONNY-3348 (round 19): statements whose writes were proposed together
/// (batches of two or more) and statements whose held writes were dropped
/// because they failed. For tests and diagnostics.
pub var batches_proposed_total: std.atomic.Value(u64) = .init(0);
pub var statements_withheld_total: std.atomic.Value(u64) = .init(0);

/// Test seam: when set (test builds only), a proposal goes here instead of to
/// the Raft log, which it would reach through `ClusterCoordinator.proposeWrite`
/// and `waitForCommittedThenApplied`. The seam sees exactly the entries the
/// leader would propose, one call per proposal.
pub const ProposeHook = *const fn (cmd: raft_consensus.Command) anyerror!void;
pub var test_propose_hook: ?ProposeHook = null;

/// Open the statement's batch for the scope `owns` opened. A nested scope
/// (`owns` false) adds to its enclosing statement's batch.
pub fn begin(owns: bool) void {
    if (!owns) return;
    discard();
    t_active = true;
}

/// The statement that opened the scope `owns` failed: nothing it held is
/// proposed.
pub fn finishFailed(owns: bool) void {
    if (!owns) return;
    t_active = false;
    if (t_batch) |b| {
        if (b.items.items.len > 0) _ = statements_withheld_total.fetchAdd(1, .monotonic);
    }
    discard();
}

/// The statement that opened the scope `owns` evaluated without an error:
/// propose what it holds, as one entry, and wait for it to commit.
pub fn flush(owns: bool) Error!void {
    if (!owns) return;
    t_active = false;
    defer discard();
    const b = t_batch orelse return;
    const items = b.items.items;
    if (items.len == 0) return;
    if (items.len == 1) {
        return proposeNow(.{ .graph_mutation = .{
            .graph = items[0].graph,
            .mutation_type = items[0].mutation,
            .data = items[0].data,
            .txn_id = null,
        } });
    }
    const entries = try b.arena.allocator().alloc(cluster_replication.BatchEntry, items.len);
    var key: ?[]const u8 = null;
    for (items, entries) |h, *e| {
        e.* = .{ .mutation = @enumFromInt(@intFromEnum(h.mutation)), .graph = h.graph, .data = h.data };
        if (key == null) key = h.key;
    }
    const payload = cluster_replication.serializeBatch(b.arena.allocator(), key, entries) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClusterWriteNotReplicable,
    };
    _ = batches_proposed_total.fetchAdd(1, .monotonic);
    return proposeNow(.{ .graph_mutation = .{
        .graph = items[0].graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } });
}

/// Is a statement's batch open on this thread?
pub fn holding() bool {
    return t_active;
}

/// Writes the open batch holds (tests).
pub fn heldCount() usize {
    const b = t_batch orelse return 0;
    return b.items.items.len;
}

/// Propose the write `data` (a lone-entry payload of `mutation`), or hold it
/// for the statement's batch. `reads`: the write read the store to decide
/// what it writes (see `checkRead`).
pub fn submit(mutation: MutationType, graph: []const u8, data: []const u8, reads: ?ReadFootprint) Error!void {
    if (!t_active) {
        return proposeNow(.{ .graph_mutation = .{ .graph = graph, .mutation_type = mutation, .data = data, .txn_id = null } });
    }
    const b = try batch();
    const a = b.arena.allocator();
    const effect = cluster_replication.effectOf(a, data) catch return error.ClusterWriteNotReplicable;
    if (reads) |fp| try checkRead(graph, fp, effect);
    // Bounded as the batch is (`serializeBatch` checks the exact size): a
    // statement that writes more than one entry holds is refused, whole.
    const entry_bytes = data.len + graph.len + 7;
    if (b.items.items.len >= cluster_replication.MAX_BATCH_ENTRIES or
        b.bytes + entry_bytes > cluster_replication.MAX_BATCH_BYTES)
        return error.ClusterWriteNotReplicable;
    const data_copy = try a.dupe(u8, data);
    // The effect borrows from the payload: decode it again from the copy.
    const held_effect = cluster_replication.effectOf(a, data_copy) catch return error.ClusterWriteNotReplicable;
    try b.items.append(a, .{
        .mutation = mutation,
        .graph = try a.dupe(u8, graph),
        .data = data_copy,
        .effect = held_effect,
        .key = cluster_replication.idempotencyKeyOf(data_copy),
    });
    b.bytes += entry_bytes;
}

/// What a replicated write read to decide what it writes: the labels and
/// inline property keys of the pattern it matched (`any_unlabeled`: a node
/// of it names no label), whether the pattern has relationships, and whether
/// a WHERE filtered it.
pub const ReadFootprint = struct {
    labels: []const []const u8 = &.{},
    prop_keys: []const []const u8 = &.{},
    any_unlabeled: bool = false,
    has_hops: bool = false,
    has_where: bool = false,
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn intersects(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| if (contains(b, x)) return true;
    return false;
}

fn containsId(list: []const u64, id: u64) bool {
    return std.mem.indexOfScalar(u64, list, id) != null;
}

/// Refuse a write whose read a held write of the same graph could have
/// changed, had it been applied: a node it creates the read could match, an
/// edge it creates or deletes a relationship pattern could match, a node or
/// edge the new write touches that a held one touches, a property key or
/// label the read names (or any, under a WHERE) that a held one writes.
fn checkRead(graph: []const u8, fp: ReadFootprint, new_effect: cluster_replication.Effect) Error!void {
    const b = t_batch orelse return;
    for (b.items.items) |h| {
        if (!std.mem.eql(u8, h.graph, graph)) continue;
        const e = h.effect;
        for (e.created) |c| {
            if (fp.any_unlabeled or intersects(c.labels, fp.labels)) return error.ClusterWriteNotReplicable;
        }
        if (fp.has_hops and (e.creates_edges or e.deletes_edges)) return error.ClusterWriteNotReplicable;
        for (new_effect.ids) |id| if (containsId(e.ids, id)) return error.ClusterWriteNotReplicable;
        if (e.written_keys.len > 0 or e.written_labels.len > 0) {
            if (fp.has_where or fp.any_unlabeled) return error.ClusterWriteNotReplicable;
            if (intersects(e.written_keys, fp.prop_keys)) return error.ClusterWriteNotReplicable;
            if (intersects(e.written_labels, fp.labels)) return error.ClusterWriteNotReplicable;
        }
        // A node or edge a held write deleted is gone from the read's view
        // only once applied; one the read resolved (its ids) is checked above.
    }
}

/// `checkRead` before the write resolved what it reads: a MATCH that finds
/// nothing proposes nothing, so it is checked here too.
pub fn checkPendingRead(graph: []const u8, fp: ReadFootprint) Error!void {
    if (!t_active) return;
    return checkRead(graph, fp, .{});
}

pub const MergeVerdict = enum {
    /// Nothing held changes MERGE's decision.
    unaffected,
    /// A held create makes the node MERGE looks for: it is matched.
    matched_held,
};

fn propEql(a: cluster_replication.Prop, b: cluster_replication.Prop) bool {
    if (!std.mem.eql(u8, a.key, b.key)) return false;
    return switch (a.value) {
        .Null => b.value == .Null,
        .Int => |x| b.value == .Int and b.value.Int == x,
        .Float => |x| b.value == .Float and b.value.Float == x,
        .Bool => |x| b.value == .Bool and b.value.Bool == x,
        .String => |x| b.value == .String and std.mem.eql(u8, b.value.String, x),
        else => false,
    };
}

/// MERGE of a node with `labels` and `props` in `graph`, which the store
/// answered with `matched_id` (null: no node), against what the statement
/// holds. A held create of such a node is a match; a held write to the node
/// MERGE matched, or to a property key or label it matches on, refuses the
/// statement (the leader cannot tell what MERGE would have matched).
pub fn mergeMatch(graph: []const u8, labels: []const []const u8, props: []const Prop, matched_id: ?u64) Error!MergeVerdict {
    if (!t_active) return .unaffected;
    const b = t_batch orelse return .unaffected;
    var verdict: MergeVerdict = .unaffected;
    for (b.items.items) |h| {
        if (!std.mem.eql(u8, h.graph, graph)) continue;
        const e = h.effect;
        for (e.created) |c| {
            var all_labels = true;
            for (labels) |l| {
                if (!contains(c.labels, l)) all_labels = false;
            }
            var all_props = true;
            for (props) |p| {
                var found = false;
                for (c.props) |cp| {
                    if (propEql(p, cp)) found = true;
                }
                if (!found) all_props = false;
            }
            if (all_labels and all_props) verdict = .matched_held;
        }
        if (matched_id) |id| {
            if (containsId(e.ids, id)) return error.ClusterWriteNotReplicable;
        }
        for (props) |p| if (contains(e.written_keys, p.key)) return error.ClusterWriteNotReplicable;
        if (intersects(e.written_labels, labels)) return error.ClusterWriteNotReplicable;
    }
    if (verdict == .matched_held and matched_id != null) {
        // The store has one and the statement made another: MERGE would
        // have found the store's first; nothing to decide between.
        return .unaffected;
    }
    return verdict;
}

fn batch() error{OutOfMemory}!*Batch {
    if (t_batch) |b| return b;
    const b = try backing.create(Batch);
    b.* = .{ .arena = std.heap.ArenaAllocator.init(backing) };
    t_batch = b;
    return b;
}

fn discard() void {
    const b = t_batch orelse return;
    t_batch = null;
    b.arena.deinit();
    backing.destroy(b);
}

fn proposeNow(cmd: raft_consensus.Command) Error!void {
    if (builtin.is_test) {
        if (test_propose_hook) |hook| {
            hook(cmd) catch |err| return narrow(err);
            return;
        }
    }
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;
    // Lost leadership between the role check and the propose: fail closed.
    const idx = coord.proposeWrite(cmd) catch |err| return narrow(err);
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT
    // (apply is then guaranteed); error.Timeout only when commit cannot be
    // confirmed in budget. A proposal is never undone.
    coord.waitForCommittedThenApplied(idx, 5000) catch |err| return narrow(err);
}
