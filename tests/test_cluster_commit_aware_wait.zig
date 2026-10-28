// RED reproduction tests — "committed write → client Timeout → retry double-insert"
// ROOT CAUSE 1 (RC-1): the post-propose wait uses the WRONG SIGNAL. It busy-polls
// the node's LOCAL apply index with a flat 5000 ms budget and returns
// `error.Timeout` for an entry that IS committed — apply lag under churn is
// misreported as "did not replicate", driving the client to retry a write that
// already durably committed (→ the double-insert when paired with RC-3).
//
// THE BUG (triage complete; file:line verified against HEAD 43031cb7):
//   * src/distributed/cluster.zig:2537-2546 — `waitForApplied(index, deadline_ms)`
//     loops on `self.raft.appliedIndex()` only; on a flat deadline it returns
//     `error.Timeout` WITHOUT EVER consulting the COMMIT index. Raft guarantees a
//     committed entry applies (once, in the current term), so a committed entry
//     whose LOCAL apply merely lags is NOT a replication failure.
//   * src/execution/crud_operations.zig:1959-1967 — the lone call site
//     (`try coord.waitForApplied(idx, 5000)`) carries the misleading comment
//     "a timeout means the write did not durably replicate, so surface it" — the
//     exact wrong inference this RC fixes.
//   * src/distributed/raft_consensus.zig:3288-3324 — `proposeCommand` already
//     returns the assigned index, and the inner raft log exposes a `committed`
//     watermark (`self.inner.log.committed`, the same field the lib's
//     replication.zig uses) distinct from `applied` — so a commit-aware wait is
//     buildable from data the wrapper already holds.
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//   The post-propose wait becomes COMMIT-AWARE:
//     * If the entry's COMMIT is confirmed (committed_index >= target), the call
//       returns SUCCESS — it waits as long as needed for local apply (or returns
//       success on commit). A committed entry is NEVER reported as Timeout.
//     * `error.Timeout` is returned ONLY when COMMIT ITSELF cannot be confirmed
//       within budget (committed_index < target AND budget exhausted) — a genuine
//       unknown (this node could not confirm the write reached a quorum).
//
//   So the decision over (committed_index, applied_index, target, budget_exhausted) is:
//     | committed>=target | applied>=target | budget_exhausted | outcome                |
//     |-------------------|-----------------|------------------|------------------------|
//     | yes               | yes             | *                | success (applied)      |
//     | yes               | no              | *                | success/keep-waiting   |  <- the FIX
//     | no                | no              | no               | keep waiting           |
//     | no                | no              | yes              | Timeout (commit unknown)|
//
// REQUIRED NEW SURFACE (the fixer implements these; EXACT names are the fixer's
// call so long as the CONTRACT holds — these tests probe the most likely names
// and assert behavior. If the fixer chooses different names, update ONLY the
// `@hasDecl` probe strings, never loosen an assertion):
//
//   // On ClusterCoordinator (src/distributed/cluster.zig):
//   /// The committed watermark on this node (distinct from appliedIndex()).
//   pub fn committedIndex(self: *ClusterCoordinator) u64 { ... }
//
//   /// Commit-aware replacement for waitForApplied: returns success once the
//   /// target index is CONFIRMED COMMITTED (waiting further for local apply as
//   /// needed); returns error.Timeout ONLY when commit cannot be confirmed in
//   /// budget. A committed-but-apply-lagged entry MUST NOT time out.
//   pub fn waitForCommittedThenApplied(self: *ClusterCoordinator, index: u64, deadline_ms: u64) !void { ... }
//
//   // A PURE, unit-testable decision sibling (mirrors the stall-detector decision
//   // functions in raft_consensus.zig and the inbound-reap decision in
//   // test_raft_inbound_pool_occupancy.zig). The fixer factors the wait outcome
//   // into this so the wrong-signal logic is testable without a live cluster:
//   pub const WaitOutcome = enum { applied, committed_apply_pending, keep_waiting, commit_unknown_timeout };
//   pub fn waitOutcomeForState(
//       committed_index: u64,
//       applied_index: u64,
//       target_index: u64,
//       budget_exhausted: bool,
//   ) WaitOutcome { ... }
//
// RED MECHANISM: every test is guarded by `comptime @hasDecl(...)`. Until the
// fixer adds the named symbols the guard's else-branch returns an error, so the
// test FAILS while the file still COMPILES. Once the symbols exist, the real
// behavioral assertions run; implement the contract WRONG and a test stays red on
// the assertion. Do not edit these tests to make them pass; implement the
// contract.
//
// CANARY: REQ=REQ-DIST-CLUSTER-COMMIT-AWARE-WAIT; FEATURE="DistributedCluster"; ASPECT=CommitAwarePostProposeWait; STATUS=TESTED; TEST=tests/test_cluster_commit_aware_wait.zig; OWNER=distributed; UPDATED=2026-06-12

const std = @import("std");
const geode = @import("geode");

const cluster = geode.distributed.cluster;
const ClusterCoordinator = cluster.ClusterCoordinator;
const raft_lib = geode.distributed.raft;
const raft_consensus = geode.distributed.raft_consensus;

// ===========================================================================
// RC-1 PURE-DECISION (RED): the wrong-signal logic, isolated.
// ===========================================================================

// ---------------------------------------------------------------------------
// (RC-1.1) THE BUG, distilled: an entry that is COMMITTED but whose LOCAL apply
// lags, WITH the budget exhausted, must NOT be a Timeout. Pre-fix waitForApplied
// returns error.Timeout in exactly this state (committed yet apply-lagged) — the
// wrong inference that drives the client retry. The commit-aware decision must
// report "committed, apply pending" (a success-class outcome), NEVER the
// commit-unknown timeout.
// ---------------------------------------------------------------------------
test "RC-1 decision: committed-but-apply-lagged is NOT a commit-unknown timeout" {
    if (comptime @hasDecl(cluster, "waitOutcomeForState") and @hasDecl(cluster, "WaitOutcome")) {
        // target committed (committed >= target) but not yet applied locally, and
        // the flat budget has elapsed. Pre-fix: Timeout. Post-fix: a success class.
        const outcome = cluster.waitOutcomeForState(
            10, // committed_index >= target
            7, //  applied_index  <  target  (apply lag)
            10, // target_index
            true, // budget_exhausted
        );
        // MUST NOT be the commit-unknown timeout — the write DID commit.
        try std.testing.expect(outcome != cluster.WaitOutcome.commit_unknown_timeout);
        // And it must be the committed/apply-pending success class specifically.
        try std.testing.expectEqual(cluster.WaitOutcome.committed_apply_pending, outcome);
    } else {
        return error.WaitOutcomeForStateNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-1.2) GENUINE UNKNOWN: when commit itself is NOT confirmed (committed <
// target) AND the budget is exhausted, error.Timeout IS the correct outcome —
// the node genuinely cannot confirm the write reached a quorum. Pins the boundary
// so the fix does not swallow real unknowns.
// ---------------------------------------------------------------------------
test "RC-1 decision: commit-not-confirmed past budget is a genuine timeout" {
    if (comptime @hasDecl(cluster, "waitOutcomeForState") and @hasDecl(cluster, "WaitOutcome")) {
        const outcome = cluster.waitOutcomeForState(
            6, //  committed_index < target (commit NOT confirmed)
            6, //  applied_index   < target
            10, // target_index
            true, // budget_exhausted
        );
        try std.testing.expectEqual(cluster.WaitOutcome.commit_unknown_timeout, outcome);
    } else {
        return error.WaitOutcomeForStateNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-1.3) ALREADY APPLIED: the happy path — applied >= target is success
// regardless of budget. (Guard so the fix keeps the fast path.)
// ---------------------------------------------------------------------------
test "RC-1 decision: already-applied is success" {
    if (comptime @hasDecl(cluster, "waitOutcomeForState") and @hasDecl(cluster, "WaitOutcome")) {
        const outcome = cluster.waitOutcomeForState(10, 10, 10, false);
        try std.testing.expectEqual(cluster.WaitOutcome.applied, outcome);
        // Even with the budget exhausted, an applied entry is success, never timeout.
        const outcome2 = cluster.waitOutcomeForState(10, 12, 10, true);
        try std.testing.expectEqual(cluster.WaitOutcome.applied, outcome2);
    } else {
        return error.WaitOutcomeForStateNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-1.4) WITHIN BUDGET, not yet committed: keep waiting (do not prematurely
// time out while there is still budget). Guard for the wait loop's progress
// condition.
// ---------------------------------------------------------------------------
test "RC-1 decision: not-yet-committed within budget keeps waiting" {
    if (comptime @hasDecl(cluster, "waitOutcomeForState") and @hasDecl(cluster, "WaitOutcome")) {
        const outcome = cluster.waitOutcomeForState(6, 6, 10, false);
        try std.testing.expectEqual(cluster.WaitOutcome.keep_waiting, outcome);
    } else {
        return error.WaitOutcomeForStateNotImplemented;
    }
}

// ===========================================================================
// RC-1 LIVE-CLUSTER (RED): the commit-aware coordinator API on a real 3-node
// in-process cluster (same driver style as test_cluster_propose_write.zig).
// ===========================================================================

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

fn driveUntil(
    a: std.mem.Allocator,
    coords: []*ClusterCoordinator,
    ipt: *raft_lib.InProcessTransport,
    deadline_ms: i64,
    done: *const fn (coords: []*ClusterCoordinator) bool,
) !void {
    while (nowMillis() < deadline_ms) {
        for (coords) |c| {
            c.raft.tick() catch |err| return err;
        }
        for (1..@as(u64, @intCast(coords.len + 1))) |id| {
            const msgs = ipt.drain(@intCast(id), a) catch |err| return err;
            defer a.free(msgs);
            if (msgs.len == 0) continue;
            const target_idx = id - 1;
            for (msgs) |msg| {
                const inferred_from = inferSender(msg, @intCast(id));
                coords[target_idx].raft.stepInner(inferred_from, msg) catch |err| {
                    freeMsgPayload(a, msg);
                    return err;
                };
                freeMsgPayload(a, msg);
            }
        }
        if (done(coords)) return;
        sleepMs(10);
    }
    return error.Timeout;
}

fn allHaveLeader(coords: []*ClusterCoordinator) bool {
    var leader_count: u8 = 0;
    var follower_count: u8 = 0;
    for (coords) |c| {
        switch (c.role()) {
            .leader => leader_count += 1,
            .follower => follower_count += 1,
            else => {},
        }
    }
    return leader_count == 1 and follower_count + 1 == coords.len;
}

const CommittedTarget = struct {
    var index: u64 = 0;
};

fn allCommittedTarget(coords: []*ClusterCoordinator) bool {
    // Probe via the new committedIndex() surface; if it is absent this driver is
    // never reached (the test's @hasDecl guard returns first).
    if (comptime @hasDecl(ClusterCoordinator, "committedIndex")) {
        for (coords) |c| {
            if (c.committedIndex() < CommittedTarget.index) return false;
        }
        return true;
    } else {
        return true;
    }
}

// ---------------------------------------------------------------------------
// (RC-1.5) LIVE: propose on the leader, drive the cluster until the entry is
// COMMITTED on every node, then assert the commit-aware wait returns SUCCESS for
// that index. This is the contract the wrong-signal bug violates: a committed
// entry must be reported as success, never error.Timeout. (Under InProcess
// transport commit and apply coincide, so this also exercises the applied fast
// path — the point is the commit-aware API exists and succeeds for a committed
// index, which is what crud_operations must call instead of the apply-only wait.)
// ---------------------------------------------------------------------------
test "RC-1 live: commit-aware wait returns success for a committed index" {
    if (comptime @hasDecl(ClusterCoordinator, "waitForCommittedThenApplied") and
        @hasDecl(ClusterCoordinator, "committedIndex"))
    {
        const a = std.testing.allocator;

        const port_base: u16 = 22030; // distinct band from propose-write (22000)
        const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };

        var peer_lists: [3][2]ClusterCoordinator.PeerConfig = undefined;
        inline for (0..3) |i| {
            var pi: usize = 0;
            inline for (0..3) |j| {
                if (i == j) continue;
                peer_lists[i][pi] = .{ .id = j + 1, .address = "127.0.0.1", .port = ports[j] };
                pi += 1;
            }
        }

        var coords_storage: [3]*ClusterCoordinator = undefined;
        var alive: usize = 0;
        errdefer {
            for (coords_storage[0..alive]) |c| {
                c.deinit();
                a.destroy(c);
            }
        }
        for (0..3) |i| {
            const cfg = ClusterCoordinator.Config{
                .peers = peer_lists[i][0..],
                .listen_address = "127.0.0.1",
                .cluster_port = ports[i],
                .cluster_token = "test-3node-commit-aware",
                .cluster_name = "test-cluster",
                .election_timeout_ms = 250,
            };
            coords_storage[i] = try a.create(ClusterCoordinator);
            errdefer a.destroy(coords_storage[i]);
            coords_storage[i].* = try ClusterCoordinator.init(a, @intCast(i + 1), cfg);
            alive += 1;
        }
        defer {
            for (coords_storage) |c| {
                c.deinit();
                a.destroy(c);
            }
        }
        const coords: []*ClusterCoordinator = coords_storage[0..];

        var ipt = raft_lib.InProcessTransport.init(a);
        defer ipt.deinit();
        for (1..4) |id| try ipt.register(id);
        const transport = ipt.transport();
        for (coords) |c| c.raft.setInnerTransport(transport);

        try driveUntil(a, coords, &ipt, nowMillis() + 10_000, allHaveLeader);

        var leader: ?*ClusterCoordinator = null;
        for (coords) |c| {
            if (c.role() == .leader) {
                leader = c;
                break;
            }
        }
        try std.testing.expect(leader != null);

        const idx = try leader.?.proposeWrite(raft_consensus.Command{ .noop = {} });
        try std.testing.expect(idx >= 1);

        // Drive until the entry is COMMITTED on every node.
        CommittedTarget.index = idx;
        try driveUntil(a, coords, &ipt, nowMillis() + 10_000, allCommittedTarget);

        // The commit-aware wait MUST report success for a committed index on every
        // node — never error.Timeout. (Generous budget; commit is already done.)
        for (coords) |c| {
            try c.waitForCommittedThenApplied(idx, 5_000);
            try std.testing.expect(c.committedIndex() >= idx);
        }
    } else {
        return error.WaitForCommittedThenAppliedNotImplemented;
    }
}

fn inferSender(msg: raft_lib.Message, recipient_id: u64) u64 {
    return switch (msg) {
        .request_vote => |rv| rv.candidate_id,
        .append_entries => |ae| ae.leader_id,
        .install_snapshot => |is| is.leader_id,
        .request_vote_response,
        .append_entries_response,
        .install_snapshot_response,
        => blk: {
            var i: u64 = 1;
            while (i <= 3) : (i += 1) {
                if (i != recipient_id) break :blk i;
            }
            break :blk recipient_id;
        },
    };
}

fn freeMsgPayload(allocator: std.mem.Allocator, msg: raft_lib.Message) void {
    switch (msg) {
        .append_entries => |ae| {
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        else => {},
    }
}
