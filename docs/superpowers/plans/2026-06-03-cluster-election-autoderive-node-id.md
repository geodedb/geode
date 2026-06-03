# Cluster Election Auto-Derive node_id Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a 3-node geode Raft cluster elect a leader on Kubernetes without a hand-set `GEODE_NODE_ID`, by auto-deriving the node's raft id from the `$HOSTNAME`-matched position in `GEODE_PEERS`.

**Architecture:** Each peer's raft id is its 1-based position in the shared `GEODE_PEERS` list, and a node stamps its own id as `from` on outgoing frames. The pinned `raft-0.1.4` lib silently drops `RequestVote`/`RequestVoteResponse` frames whose `from` is not a known voter (`node.zig:801-809,877-882`), so a wrong/unset `GEODE_NODE_ID` → no quorum → stuck `state=candidate term=0` (pre-vote never advances term, `node.zig:729-731`). On loopback the node self-identifies by `(host,port)`; with k8s DNS peer names that skip can't fire. The merged `cluster_identity.hostMatchesSelf`/`hostLabel` already match a pod's `$HOSTNAME` against a peer entry and `cluster_bootstrap.maybeStart` already computes `self_position_by_hostname` for the diagnostic. This plan promotes that position from *diagnostic-only* to **authoritative**: the effective `node_id` becomes the hostname-matched position (derived when `GEODE_NODE_ID` is unset, corrected+warned when it disagrees). With `node_id` == position, the existing position-based self-skip and `from`-stamping work and votes are counted.

**Tech Stack:** Zig 0.16, `src/server/cluster_bootstrap.zig`, `src/server/cluster_identity.zig`, `tests/test_cluster_bootstrap.zig`, `tests/test_cluster_3node_subprocess.zig`. Build: `zig build test-cluster-bootstrap`, `zig build test-cluster-identity`.

---

## File Structure

- `src/server/cluster_bootstrap.zig` — add pure `resolveNodeId` + `computeSelfIdentity` helpers; make `GEODE_NODE_ID` optional when a hostname match supplies the id; reorder `maybeStart` so identity is resolved before peers are appended and the coordinator is built; log derivation/correction.
- `tests/test_cluster_bootstrap.zig` — unit tests for the two new pure helpers (the fix logic).
- `tests/test_cluster_3node_subprocess.zig` — unchanged; the loopback election regression that must stay green (proves the explicit-`GEODE_NODE_ID` path still works).

---

### Task 1: Pure `resolveNodeId` resolver

**Files:**
- Modify: `src/server/cluster_bootstrap.zig` (add `NodeIdSource`, `ResolvedNodeId`, `pub fn resolveNodeId` near the `Error` decl, ~line 44)
- Test: `tests/test_cluster_bootstrap.zig` (append tests)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_cluster_bootstrap.zig`:

```zig
test "resolveNodeId: hostname match with no explicit id derives the position" {
    const r = cluster_bootstrap.resolveNodeId(null, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.derived_from_hostname, r.source);
}

test "resolveNodeId: explicit id that agrees with hostname is env_explicit" {
    const r = cluster_bootstrap.resolveNodeId(2, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_explicit, r.source);
}

test "resolveNodeId: explicit id that disagrees with hostname is corrected to the hostname position" {
    // THE BUG: GEODE_NODE_ID=1 on the geode-1 pod (position 2). Hostname wins.
    const r = cluster_bootstrap.resolveNodeId(1, 2).?;
    try std.testing.expectEqual(@as(u64, 2), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_corrected_by_hostname, r.source);
}

test "resolveNodeId: no hostname match falls back to the explicit id (loopback/non-k8s)" {
    const r = cluster_bootstrap.resolveNodeId(3, null).?;
    try std.testing.expectEqual(@as(u64, 3), r.node_id);
    try std.testing.expectEqual(cluster_bootstrap.NodeIdSource.env_explicit, r.source);
}

test "resolveNodeId: neither signal present returns null (caller errors MissingNodeId)" {
    try std.testing.expectEqual(@as(?cluster_bootstrap.ResolvedNodeId, null), cluster_bootstrap.resolveNodeId(null, null));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-cluster-bootstrap`
Expected: FAIL — `root source file struct 'cluster_bootstrap' has no member named 'resolveNodeId'`.

- [ ] **Step 3: Write minimal implementation** — in `src/server/cluster_bootstrap.zig`, after the `Error` decl (~line 44):

```zig
/// Where the effective raft node_id came from (for startup logging).
pub const NodeIdSource = enum {
    /// Used the explicit GEODE_NODE_ID (no hostname match, or it agreed).
    env_explicit,
    /// Derived from the $HOSTNAME-matched position; GEODE_NODE_ID was unset.
    derived_from_hostname,
    /// GEODE_NODE_ID was set but disagreed with the $HOSTNAME-matched position;
    /// the hostname position (what every peer uses for this node) overrode it.
    env_corrected_by_hostname,
};

pub const ResolvedNodeId = struct { node_id: u64, source: NodeIdSource };

/// Resolve the effective raft node_id. The hostname-matched position is what
/// every other node will assign this node, so it is AUTHORITATIVE: derive from
/// it when no explicit GEODE_NODE_ID was given, and override a mismatched
/// explicit value (the k8s bug where a hand-set GEODE_NODE_ID != position leaves
/// the cluster hung at `state=candidate term=0`). Fall back to the explicit
/// value only when there is no hostname match (loopback / non-k8s). Returns null
/// when neither signal is available — the caller surfaces MissingNodeId.
/// See docs/bugs/2026-06-02-cluster-0.6.14-k8s-still-fails.md (Bug B).
pub fn resolveNodeId(explicit: ?u64, self_position_by_hostname: ?usize) ?ResolvedNodeId {
    if (self_position_by_hostname) |pos| {
        const p: u64 = @intCast(pos);
        if (explicit) |e| {
            return .{ .node_id = p, .source = if (e == p) .env_explicit else .env_corrected_by_hostname };
        }
        return .{ .node_id = p, .source = .derived_from_hostname };
    }
    if (explicit) |e| return .{ .node_id = e, .source = .env_explicit };
    return null;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-cluster-bootstrap`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/server/cluster_bootstrap.zig tests/test_cluster_bootstrap.zig
git commit -m "feat(cluster): pure resolveNodeId — hostname position is authoritative over GEODE_NODE_ID"
```

---

### Task 2: Pure `computeSelfIdentity` (hostname → position + any_dns)

**Files:**
- Modify: `src/server/cluster_bootstrap.zig` (add `SelfIdentity` + `pub fn computeSelfIdentity`)
- Test: `tests/test_cluster_bootstrap.zig`

- [ ] **Step 1: Write the failing tests** — append to `tests/test_cluster_bootstrap.zig`:

```zig
test "computeSelfIdentity: k8s DNS peers match $HOSTNAME by leading label" {
    const specs = [_][]const u8{
        "geode-0.geode.geode-qa.svc.cluster.local:4242",
        "geode-1.geode.geode-qa.svc.cluster.local:4242",
        "geode-2.geode.geode-qa.svc.cluster.local:4242",
    };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "geode-1");
    try std.testing.expectEqual(@as(?usize, 2), id.self_position);
    try std.testing.expect(id.any_dns_peer);
}

test "computeSelfIdentity: loopback peers yield no hostname match and any_dns=false" {
    const specs = [_][]const u8{ "127.0.0.1:14242", "127.0.0.1:14243", "127.0.0.1:14244" };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "geode-0");
    try std.testing.expectEqual(@as(?usize, null), id.self_position);
    try std.testing.expect(!id.any_dns_peer);
}

test "computeSelfIdentity: empty hostname never matches" {
    const specs = [_][]const u8{ "geode-0.geode:4242", "geode-1.geode:4242" };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "");
    try std.testing.expectEqual(@as(?usize, null), id.self_position);
    try std.testing.expect(id.any_dns_peer);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-cluster-bootstrap`
Expected: FAIL — `no member named 'computeSelfIdentity'`.

- [ ] **Step 3: Write minimal implementation** — in `src/server/cluster_bootstrap.zig`, after `resolveNodeId`:

```zig
pub const SelfIdentity = struct {
    /// 1-based position of the first peer entry whose host matched $HOSTNAME.
    self_position: ?usize,
    /// At least one peer host is a non-loopback (DNS) name.
    any_dns_peer: bool,
};

/// Scan the peer specs for this node's own entry by matching each host against
/// `$HOSTNAME` (exact or leading-label, via cluster_identity.hostMatchesSelf),
/// and note whether any peer uses a DNS name. Pure: no allocation, no I/O.
pub fn computeSelfIdentity(specs: []const []const u8, hostname: []const u8) SelfIdentity {
    var self_pos: ?usize = null;
    var any_dns = false;
    for (specs, 0..) |spec, i| {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse continue;
        const host = spec[0..colon];
        if (!cluster_identity.isLoopbackAlias(host)) any_dns = true;
        if (self_pos == null and cluster_identity.hostMatchesSelf(host, hostname)) self_pos = i + 1;
    }
    return .{ .self_position = self_pos, .any_dns_peer = any_dns };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-cluster-bootstrap`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/server/cluster_bootstrap.zig tests/test_cluster_bootstrap.zig
git commit -m "feat(cluster): pure computeSelfIdentity — match \$HOSTNAME against GEODE_PEERS"
```

---

### Task 3: Wire auto-derive into `maybeStart`

**Files:**
- Modify: `src/server/cluster_bootstrap.zig:118-205` (defer node_id parse; resolve identity before appendPeer; log derivation/correction)

- [ ] **Step 1: Make `GEODE_NODE_ID` optional + parse it without erroring.** Replace lines 124-125:

```zig
    const node_id_str = node_id_str_opt orelse return Error.MissingNodeId;
    const node_id = std.fmt.parseInt(u64, node_id_str, 10) catch return Error.InvalidNodeId;
```

with:

```zig
    // GEODE_NODE_ID is now OPTIONAL: when peers use $HOSTNAME-matchable DNS
    // names the id is auto-derived from position below. Parse it if present.
    const explicit_node_id: ?u64 = if (node_id_str_opt) |s|
        (std.fmt.parseInt(u64, s, 10) catch return Error.InvalidNodeId)
    else
        null;
```

- [ ] **Step 2: Resolve identity from `$HOSTNAME` BEFORE appending peers.** The `specs` list is built at lines 158-172. Immediately AFTER it (before the `var self_skips` loop at line 174), insert:

```zig
    // Resolve this node's identity. On k8s the pod's $HOSTNAME (StatefulSet pod
    // name, e.g. geode-1) matches one GEODE_PEERS entry; that entry's 1-based
    // position is the raft id every peer assigns us, so it is authoritative over
    // a hand-set GEODE_NODE_ID. This is what lets a StatefulSet form a cluster
    // with NO GEODE_NODE_ID, and auto-corrects a mis-set one instead of hanging.
    const own_hostname = env.get("HOSTNAME") orelse "";
    const self_identity = computeSelfIdentity(specs, own_hostname);
    const resolved = resolveNodeId(explicit_node_id, self_identity.self_position) orelse return Error.MissingNodeId;
    const node_id = resolved.node_id;
    switch (resolved.source) {
        .derived_from_hostname => std.debug.print(
            "[cluster-identity] INFO: derived GEODE_NODE_ID={d} from $HOSTNAME '{s}' (1-based position in GEODE_PEERS); no GEODE_NODE_ID was set.\n",
            .{ node_id, own_hostname },
        ),
        .env_corrected_by_hostname => std.debug.print(
            "[cluster-identity] WARN: GEODE_NODE_ID={d} disagrees with $HOSTNAME '{s}' position {d} in GEODE_PEERS; using {d} (the position every peer assigns this node) so the election can form. Fix GEODE_NODE_ID to silence this.\n",
            .{ explicit_node_id.?, own_hostname, node_id, node_id },
        ),
        .env_explicit => {},
    }
```

- [ ] **Step 3: Use the resolved `self_identity` in the diagnostic block.** The block at lines 185-205 recomputes `any_dns`/`self_pos` and parses `node_id` from env. Replace that block's recomputation so it reuses the values already resolved above — change lines 185-205 to:

```zig
    // GAP-0838 (Bug B): boot-time identity-contract self-check (safety net). The
    // id is already auto-derived above, so on a healthy k8s config this emits
    // only the informational DNS-contract note; it still flags out-of-range ids.
    logIdentityDiagnostics(allocator, .{
        .node_id = node_id,
        .total_entries = specs.len,
        .self_skips = self_skips,
        .resulting_peers = peer_configs_list.items.len,
        .any_dns_peer = self_identity.any_dns_peer,
        .self_position_by_hostname = self_identity.self_position,
    });
```

(Delete the old `const own_hostname = ...; var any_dns ...; var self_pos ...; for (specs...) {...}` recomputation at 186-196 — `own_hostname`, `any_dns`, `self_pos` now come from Step 2's `self_identity`. The `var self_skips`/`for (specs...) appendPeer` loop at 174-178 stays, and now runs with the resolved `node_id`.)

- [ ] **Step 4: Verify the whole module compiles + unit tests pass**

Run: `zig build test-cluster-bootstrap`
Expected: PASS (all Task 1/2 tests + existing bootstrap tests).

- [ ] **Step 5: Verify the binary builds**

Run: `zig build`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/server/cluster_bootstrap.zig
git commit -m "fix(cluster): auto-derive node_id from \$HOSTNAME so k8s StatefulSets elect a leader (GAP-0838 Bug B)"
```

---

### Task 4: Regression — loopback 3-node election still converges

**Files:**
- Verify only: `tests/test_cluster_3node_subprocess.zig` (sets explicit `GEODE_NODE_ID`; no `$HOSTNAME` match against `127.0.0.1` peers, so `resolveNodeId` returns `.env_explicit` — behaviour unchanged).

- [ ] **Step 1: Run the loopback 3-node election test**

Run: `zig build test-cluster-3node-subprocess` (or the registered step name; check `grep 'test-cluster-3node' build.zig`)
Expected: PASS — a node reaches `state=leader` with non-zero term; the others become followers.

- [ ] **Step 2: Run the identity diagnostic unit tests (unchanged module still green)**

Run: `zig build test-cluster-identity`
Expected: PASS (7/7).

- [ ] **Step 3: No commit** (verification only).

---

## Self-Review

- **Spec coverage:** auto-derive when unset (Task 1 `derived_from_hostname` + Task 3 Step 2) ✓; correct+warn on mismatch (Task 1 `env_corrected_by_hostname` + Task 3 Step 2 WARN print) ✓; reuse `cluster_identity.hostMatchesSelf` (Task 2) ✓; pure testable resolver (Tasks 1-2) ✓; reorder `maybeStart` (Task 3) ✓; loopback regression (Task 4) ✓.
- **Type consistency:** `NodeIdSource`, `ResolvedNodeId`, `SelfIdentity` are defined in Task 1/2 and used identically in Task 3. `computeSelfIdentity`/`resolveNodeId` signatures match their call sites.
- **No placeholders:** all steps contain concrete code + exact commands.
- **Residual:** a true k8s DNS-resolved election isn't reproducible in a unit test (peers must resolve); the pure-resolver unit tests + the loopback election regression are the in-repo coverage. End-to-end k8s validation is a deployment step (re-enable the 3-node kustomize component in geode-argo-arda).
