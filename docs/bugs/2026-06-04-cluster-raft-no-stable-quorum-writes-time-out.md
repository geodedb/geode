# geode 3-node k8s Raft cluster elects a leader but can't hold quorum or replicate (writes time out)

**Date:** 2026-06-04
**Image:** `geodedb/geode:0.6.19` (commit `e7e447e4` — contains the GAP-0838 election fixes AND the cert-honoring fix from `docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md`)
**Environment:** arda cluster (`company.arda-ca.net`, bare-metal/flannel VXLAN MTU 1450, `local-path` PVC storage), namespace `geode-qa`, real 3-replica `StatefulSet`, `podManagementPolicy: Parallel`, headless-service FQDN peers, cert-manager CA-signed cluster cert, `GEODE_CLUSTER_TOKEN` + `GEODE_AUTH_HMAC_KEY` from Vault, `GEODE_CLUSTER_CA_CERT` pinned to a `CA:TRUE` anchor, CPU 2000m req / 4000m limit per pod.
**Severity:** **BLOCKER** for distributed/clustered mode on Kubernetes. The cluster forms a leader but is not usable: no stable quorum, no replicated writes.
**Relationship to prior bugs:** This is the *next* failure after the TLS layer is fixed. With 0.6.19 (`--cert` honored), space-separated flags (geode's parser ignores `--flag=value` — see note below), and a proper `CA:TRUE` trust anchor, peers now complete the QUIC/TLS handshake and **a leader is elected** (term advances past 0, `state=leader`/`state=follower` observed at term 1–3). The remaining defect is in the **Raft consensus / transport layer itself**, above TLS.

---

## ✅ STATUS: RESOLVED (2026-06-05) — write replication works; no raft library change

The Raft write-replication defect is fixed **entirely in geode** (the pinned raft
library `v0.1.5` was correct all along — see the 2026-06-05 correction on root
cause #3). On a 3-node distinct-IP CA-signed-TLS cluster (clean build, **pinned**
raft, zero instrumentation), a leader `CREATE (:T {v:1})` now replicates to and
reads back as `count=1` on **both** followers and the leader, all stable at
term 2:

```
leader=node2  create_exit=0
node1 (follower term=2): read_count=1
node2 (leader   term=2): read_count=1
node3 (follower term=2): read_count=1
```

The fix is four stacked geode bugs (details under root causes #3 and #4 below):

1. proto wire boundary dropped all AppendEntries log entries (`RaftLogEntry.command_bytes`),
2. the bridge use-after-free'd a freshly-proposed entry's command (deep-copy into `owned_wire_bytes`),
3. newly-proposed entries were buried behind an unbounded heartbeat backlog (per-peer outbox coalescing),
4. the cluster orphaned a node addressed via a loopback alias (precise self-skip).

Regression coverage: `tests/test_cluster_3node_steady_state.zig` (Phase 3 now
**asserts** replication to a follower) and `tests/test_raft_envelope_roundtrip.zig`
(AppendEntries-with-entries proto round-trip). **Still open:** root cause #5
(leader-flap under CPU pressure / blocking-handshake send serialization) —
secondary, unreproducible on a healthy host, verify under real k8s CPU limits.

---

## ❌ RE-OPENED on real Kubernetes (2026-06-06, geode `0.6.23`)

The fixes above were verified **only on one host** (three processes on distinct
loopback IPs `127.0.0.11/12/13`). Deployed to the **real arda k8s cluster**
(`geodedb/geode:0.6.23`, 3-pod StatefulSet, distinct pod IPs across 3 nodes,
CA-signed TLS, 2000m/4000m CPU, the binary confirmed to contain the fix —
`grep -a graph_mutation/command_bytes/RaftLogEntry $(command -v geode)` matches),
**the cluster still does not work**:

- **Replication does NOT happen.** On a clean fresh-PVC boot the cluster *did*
  elect a stable leader (geode-0 leader, geode-1/2 followers, all `term=1`, 0
  HandshakeErrors, held steadily — a real improvement over 0.6.19's flapping).
  But a leader `CREATE (:RaftRepl {v:123})` reads back `count=1` on the **leader
  only**; **both followers stay `count=0`** even after 15s. On disk the nodes
  have **divergent tenant/graph IDs** (each `<data-dir>/<tenant>/graphs/<id>` set
  is different per pod) — i.e. each node bootstrapped its own local state and
  nothing is being applied from the leader's log. No raft log file is present
  under the data dir on any node.
- **The write is non-deterministic:** with one leader the `CREATE` returned
  `exit 0` fast (committed locally, never replicated); with a different leader it
  **hung (`timeout 15` → exit 124)** — i.e. sometimes it can't even commit.
- **`SHOW CLUSTER STATUS` hangs** (client `timeout 10` → exit 124) on the leader,
  while plain client queries (`RETURN 1`, single-graph `MATCH`) on `:3141` work
  fine throughout — so the `:4242` cluster-coordination path is what stalls.
- **Election is itself non-deterministic.** After a rolling restart (a routine
  `kubectl set env` / pod roll) the cluster fell back to the original failure:
  **all three nodes stuck `state=candidate term=0`** for minutes, raft loop alive
  (`iter` climbs to 11k–13k) but `term` never advances and no leader is ever
  elected — with **0 HandshakeErrors** and correct node ids (`node_id=1/2/3`
  match the `$HOSTNAME` positions). This is the GAP-0838 "Bug B" end-state again,
  reached with the transport healthy, so RequestVote/AppendEntries are not being
  delivered+counted across pods even though the QUIC connections are up.

**Net:** raft control + log messages are not reliably delivered/applied between
**distinct-IP pods**, even though the TLS handshake succeeds (0 errors) and small
heartbeats keep followers nominally attached. The loopback (`127.0.0.1x`,
single-host) steady-state and envelope round-trip tests pass but **do not
reproduce the real multi-pod transport**, which is exactly where both the
election convergence and the AppendEntries-with-entries delivery fail.

**Suggested next step:** a CI/integration test on a real multi-node Kubernetes
(or at least separate network namespaces with distinct routable IPs, not
loopback) that asserts (a) a single leader is elected and **survives a rolling
restart of any one pod**, and (b) a leader write reads back on **both** followers.
Instrument the raft transport to log, per outbound message, the message type +
entry count + bytes + send result, so a multi-pod run shows whether
AppendEntries-with-entries and RequestVote are leaving the leader and arriving at
followers (the current logs expose neither at any level). Likely suspects remain
in `raft_consensus.zig` (per-peer outbox coalescing dropping non-heartbeat frames
on the real transport; the `waitForHandshake(1)`/evict loop serializing sends) and
the `cluster.zig` coordination path that backs `SHOW CLUSTER STATUS`.

---

## ✅ RE-RESOLVED (2026-06-06) — cluster write-routing gate (no silent divergence)

The re-opened "replication does NOT happen / divergent state" failure was
reproduced **faithfully** with Linux network namespaces — the distinct-routable-IP,
non-loopback topology the report explicitly asked for: 3 nodes, each in its own
netns with a distinct routable IP on a bridge, **wildcard `0.0.0.0` cluster bind**
(exactly as the k8s StatefulSet leaves it), MTU 1450 (flannel VXLAN parity), a
DNS server resolving k8s-style FQDN peers, **hostname-derived node identity**, and
CA-signed TLS. Committed as `tests/cluster/netns_cluster_replication_test.sh`,
with CI-friendly assertions also added to the loopback subprocess test
`tests/test_cluster_3node_steady_state.zig` (Phases 3–5).

### Root cause — graph writes silently bypassed Raft and were applied to ONE node

The Raft transport + apply path were **correct**: a bare `CREATE (:L {lit})` with
NO `RETURN` replicated to both followers in every faithful topology (IP peers and
FQDN+DNS+hostname). The defect was a **too-narrow write-routing gate in the
executor** — only a pure single-node `CREATE` with no `RETURN` was routed through
Raft. Everything else fell through to the node's **local** graph store:

- `CREATE (...) RETURN ...` (the original repro shape, and the common write shape)
  was written **leader-local only** → followers stayed empty (the re-open's
  "count=1 on the leader only"). A `RETURN` clause made the routing decline.
- A write sent to a **follower** was applied to that follower's local store and
  never proposed (the re-open's "exit 0 fast, committed locally, never
  replicated" — run against a non-leader).
- `MERGE` / `DELETE` / `INSERT` / multi-node / relationship creates likewise wrote
  local-only.

So every non-trivial write silently diverged the cluster — exactly the "each node
bootstrapped its own local state, nothing applied from the leader's log".

### Fix (`src/execution/crud_operations.zig`)

A cluster write-routing gate now governs every graph-data mutation. In cluster
mode it is **fail-closed — a write is either replicated through Raft or rejected;
it is NEVER applied to a single node's local store**:

- On a **follower/candidate**: graph-data writes return `error.ClusterNotLeader`
  (clients retry the leader — standard Raft client semantics). No local apply.
- On the **leader**: an eligible single-node `CREATE` — now **including a constant
  `RETURN`**, and now resolving **parameter-valued** props (not just literals) — is
  proposed through Raft and replicated to every node. Shapes outside that slice
  (`MERGE`/`DELETE`/`INSERT`, multi-node, relationship hops, or a `RETURN` that
  references the created node) return `error.ClusterWriteNotReplicable` instead of
  diverging.

Regression coverage:

- `tests/cluster/netns_cluster_replication_test.sh` (distinct-IP netns,
  **deterministic PASS**): (A2) a bare `CREATE` replicates to both followers,
  (A3) a `CREATE ... RETURN` replicates to both followers, (A4) a follower write
  is rejected with no divergence.
- `tests/test_cluster_3node_steady_state.zig` Phases 3–5 — loopback subprocess CI
  coverage of the same three properties (re-resolves the leader per write and
  polls for replication so commit latency does not flake the assertion).

### Still open (characterized, secondary — reliability hardening, NOT divergence)

- **Commit latency under CPU pressure (root cause #5).** Under heavy host load
  (and the report's k8s CPU limits) a leader write's commit can exceed the
  leader's `waitForApplied` budget and surface a `Timeout` to the client even
  though the entry replicates shortly after — the re-open's "writes hang / time
  out". With the gate this is **correct-but-slow** (the write still replicates; it
  is never silently local-only). The underlying transport latency — the single
  outbox-drain thread serializing peer sends behind `waitForHandshake`, one QUIC
  stream per RPC — is the next change; reproduce with the netns harness under
  `cgroup`/`cpulimit` pressure.
- **Restart re-apply / no persisted raft log (root cause #6, newly found).** The
  cluster `RaftNode` uses `raft_lib.InMemoryStorage` — there is **no `raft_log.bin`
  on disk**, matching the report's "no raft log file present". After a pod restart
  the node re-applies committed entries from the leader and, because the apply path
  is not idempotent, can **duplicate** rows (reproduced: a rescheduled-with-new-IP
  node read back `count=2` for a single replicated node). The raft library already
  ships a crash-safe `FileStorage`; wiring it (plus applied-index/snapshot
  coordination with the persisted graph store) is the fix. Reproduce with the netns
  rolling-restart harness.

Neither remaining item reintroduces the silent-divergence defect this section
closes; both are reliability hardening on top of the now-correct replication path.

---

## ✅ VERIFIED on real Kubernetes (2026-06-08, geode `0.6.25`)

Deployed `geodedb/geode:0.6.25` (binary confirmed to contain `af5188cd`, the
write-routing gate) to the real arda 3-pod StatefulSet (distinct pod IPs across 3
nodes, wildcard `0.0.0.0` cluster bind, CA-signed TLS, 2000m/4000m CPU), fresh
PVCs. **The silent-divergence defect is fixed in real k8s:**

- **Replication works.** A clean boot elects a stable leader (geode-2) + 2
  followers, all `term=1`. A leader `CREATE (:RaftR1 {v:1}) RETURN 1 AS ok` (the
  exact `…RETURN…` shape that previously diverged) and a bare `CREATE (:RaftR2)`
  both read back `count=1` on **the leader and every reachable follower** (one
  follower returned `count=1` immediately; the third caught up after a few seconds
  of replication lag — `geode.raft_apply raft apply: replicated node create … graph=default`).
- **Fail-closed gate works.** A `CREATE … RETURN 1` sent to a non-leader returns
  `error_code 58000 ClusterNotLeader` (no silent local apply — `FollW` count stays
  0 everywhere). `MERGE (...)` on the leader returns `58000 ClusterWriteNotReplicable`.
- **Restart did not duplicate (#6 not reproduced here).** A same-IP `kubectl delete
  pod` of a follower (PVC persists) read back `count=1` after rejoin — the
  `count=2` duplication is specific to the *rescheduled-with-new-IP* path, not a
  plain restart.

### ⚠️ Root cause #5 (transport hardening) reproduces in real k8s — not just under synthetic CPU limits

A 3-node cluster reaches a **stable leader + one stable follower (2/3 quorum,
fully functional for writes/reads), but the THIRD node degrades to a stuck
`candidate`** and becomes unavailable (its `:3141` queries return `ERR`/time out),
even though replication to it had worked moments earlier. Over a steady-state
window the **leader** logs, per ~120s:

```
geode-2 (leader):   OutOfStreams = 14   HandshakeError = 19
geode-0 (follower):  0                   0
geode-1 (stuck cand):0                   0          # term=1, never reverts to follower
```

`raft transport getStream failed; evicting cached peer connection error=OutOfStreams peer=3`
and `QUIC poll cycle slow — query path degraded (sustained-load liveness-kill risk) cycle_ms≈1200`
fire on the leader. So the leader's raft transport — **one QUIC stream per RPC**,
a **single outbox-drain thread** serializing peer sends behind `waitForHandshake`,
connection **evict-on-`OutOfStreams`/timeout** — exhausts streams to one peer under
the combined heartbeat + AppendEntries load, starving that peer's heartbeats →
election timeout → it parks as a candidate. The cluster keeps quorum and keeps
replicating (the divergence fix holds), but it tolerates the degraded node like a
permanent 1-node failure and would lose quorum if a second node degraded.

This is the in-k8s confirmation the RE-RESOLVED note asked for ("reproduce under
real k8s CPU limits"). The fix is the transport rework already named under #5:
multiplex raft RPCs over a bounded set of long-lived QUIC streams per peer (stop
opening one stream per RPC and evicting on `OutOfStreams`), and stop serializing
all peer sends behind a single `waitForHandshake`-blocking drain. The
`QUIC poll cycle slow` warning (added in the 0.6.25 sustained-load gate) is the
built-in signal to assert against.

---

## ⚠️ Phase 1 of the #5 fix on real k8s (2026-06-08, `dev` = `v0.6.25-4-g1d691968`)

Tested the dev build that contains **Phase 1** of the stream-starvation fix
(`0d66594d fix(raft): don't evict peer connection on transient OutOfStreams
backpressure`, per `c4906117 docs(plan): phased fix …`) on the real arda 3-pod
cluster.

- **Phase 1 does what it says — the transport churn is GONE.** Across multiple
  steady-state windows, **0** `OutOfStreams`, **0** `evicting cached peer`, **0**
  `HandshakeError`, **0** `QUIC poll cycle slow` on all three pods (was
  `OutOfStreams=14`/`HandshakeError=19` per 120s on 0.6.25). The evict-loop is
  fixed.
- **But the cluster now fails to converge at all — a regression in outcome.**
  Across two clean fresh-PVC boots it never reached a healthy 3-node state, and at
  least one node was always isolated **with 0 transport errors**:
  - boot 1: `geode-1` a partitioned leader stuck at `term=2` while `geode-0`
    (candidate) and `geode-2` climbed terms together to **22+** without electing a
    leader between themselves (and never delivering the higher term to the stuck
    `geode-1`);
  - boot 2: `geode-2` leader `term=1`, `geode-1` stuck `candidate term=1`,
    `geode-0` stuck `candidate term=0` (never advanced — never joined).
  No functional quorum, no replication possible. 0.6.25 (without Phase 1) was
  strictly *better* here: it formed a stable leader + 1 follower and replicated to
  2/3 (degraded, but usable).
- **Likely cause — Phase 1 traded "churn" for "stall".** Without eviction, a
  stream-exhausted / wedged peer connection is now *kept*, and — because the
  stream-multiplexing phase isn't in yet (still one stream per RPC, single
  `waitForHandshake`-blocking outbox drain) — raft frames to that peer **silently
  stall** instead of churning. The old evict+re-handshake at least pushed *some*
  frames through (that's how 0.6.25 kept 2/3 replicating); now a peer simply stops
  getting heartbeats/votes and isolates, with nothing logged (no error, no
  eviction). So Phase 1 is necessary but not sufficient: the later phase — a
  **bounded set of long-lived multiplexed QUIC streams per peer** with a
  non-blocking drain (don't serialize all sends behind `waitForHandshake`, and
  refresh a genuinely-wedged connection on a liveness signal rather than on
  `OutOfStreams`) — is what actually has to deliver the frames.

Repro is deterministic (the *which* node isolates varies per boot; *that* one
isolates does not). Reproduce in the netns harness by exhausting a peer's stream
budget under sustained AppendEntries load and asserting all three nodes hold a
single leader + a leader write reaches both followers.

---

## TL;DR

After every TLS/identity prerequisite is satisfied and a leader is elected, the 3-node cluster **will not stay converged and will not commit writes**:

- The leader does not persist. Nodes repeatedly drop from `follower` back to `candidate`; over a few minutes the cluster degrades to **all three nodes `candidate` at split terms** (e.g. `node 1 term=0`, `node 2 term=1`, `node 3 term=1`) — i.e. no leader at all.
- **Writes on the leader time out and never replicate.** `CREATE (:T) RETURN 1` on the leader hangs (client `timeout 15` → exit 124); the same row read on a follower returns `count=0`; only the leader's *local* store shows it.
- This persists **even with zero TLS handshake errors** (see CPU note), so the convergence failure is in the Raft message/consensus layer, not only the transport.
- **Client QUIC on `:3141` works fine** the whole time (auth, `RETURN 1`, single-node queries succeed). The failure is specific to the **`:4242` Raft mesh** and consensus.

The in-repo loopback subprocess tests (`tests/test_cluster_3node_subprocess.zig`) pass, but they do not reproduce a real multi-pod, TLS, distinct-IP cluster under steady-state load, which is where this fails.

---

## What is already correct (do not re-investigate these)

Getting to "leader elected" required fixing the deployment, not geode — listed so the consensus defect can be isolated:

1. **0.6.19 honors `--cert`** (this bug's predecessor). Boot now logs `using operator-provided TLS certificate /cluster-tls/tls.crt`.
2. **Flags must be space-separated.** geode's `parseArgsFromSlice` matches `std.mem.eql(u8, arg, "--cert")` + the *next* argv element; the `--cert=VALUE` form is silently ignored (the entry never matches, the value is dropped, defaults apply). `--cert /cluster-tls/tls.crt` works; `--cert=/cluster-tls/tls.crt` self-signs. *(Worth its own fix: accept `--flag=value`, or reject unknown `--flag=...` tokens loudly instead of ignoring them. Single-node masks this because the `--listen`/`--cluster-port` defaults happen to match.)*
3. **A `CA:TRUE` trust anchor is required.** A cert-manager *self-signed non-CA leaf* used as its own anchor (`GEODE_CLUSTER_CA_CERT` = the leaf, `basicConstraints CA:FALSE`) is rejected → `HandshakeError`. A proper selfSigned-Issuer → CA cert → leaf chain, with `GEODE_CLUSTER_CA_CERT` = the CA, lets handshakes verify and the election succeed.
4. **CPU headroom matters for the mesh.** At a 500m CPU request the `:4242` mesh logged constant `getOrCreatePeerConnection failed error=HandshakeError`, asymmetric and **moving to different peer pairs on each reboot** (ruling out a fixed node-pair network problem). Raising to 2000m/4000m drove `HandshakeError` to ~0 — implicating the tight 1s handshake timeout under CPU contention (see below). **But the cluster still does not converge with 0 handshake errors**, which is the core of this report.

---

## Symptoms & evidence

### 1. Leader does not persist; cluster degrades to all-candidates

Observed transitions over a few minutes on an otherwise-healthy (0 `HandshakeError`/30s) cluster:

```
# shortly after a roll:
geode-0: node 1 state=leader   term=1
geode-1: node 2 state=follower term=1
geode-2: node 3 state=candidate term=1      # one node already isolated

# minutes later, same pods:
geode-0: node 1 state=candidate term=0      # never advanced past 0
geode-1: node 2 state=candidate term=1
geode-2: node 3 state=candidate term=1      # NO leader anywhere
```

The identity contract is satisfied (node ids 1/2/3 match the `$HOSTNAME` positions; the `[cluster-identity]` diagnostic prints only the informational DNS note, no error). So this is not the GAP-0838 node_id mismatch — the election simply does not stay converged.

### 2. Writes time out and do not replicate

With a leader present and a follower at the same term (a 2/3 quorum), a write still hangs:

```
# on the leader, real admin creds (from the GEODE_DSN secret, user=geode):
geode query --server 127.0.0.1:3141 --insecure-tls-skip-verify -U geode -P '***' \
  'CREATE (:ReplTest {v:1}) RETURN 1'
# -> client timeout (exit 124); never returns/commits

# read back:
leader   : MATCH (n:ReplTest) RETURN count(n)  -> 1   (local only, in an earlier run)
follower : MATCH (n:ReplTest) RETURN count(n)  -> 0   (never replicated)
```

A leader that cannot commit a write to a present follower indicates AppendEntries replication / commit-index advancement is not completing across pods.

### 3. Handshake instability (transport) — reduced but informative

Before the CPU bump, `:4242` `getOrCreatePeerConnection failed error=HandshakeError` fired ~1/s per failing pair, **persistently** (no self-heal across the 1s retry), and the failing pair **changed between reboots** (geode-0↔geode-2 one boot, geode-1↔others the next). The generic `HandshakeError` carries no underlying QUIC/TLS detail in the logs, so timeout-vs-verification could not be distinguished from logs alone. Raising CPU removed it — consistent with the 1s `waitForHandshake` timeout being exceeded under contention, then the connection being evicted and re-handshaked in a fail loop.

---

## Code areas to investigate

- **`src/distributed/raft_consensus.zig` — Transport connection cache + eviction.**
  - `getOrCreatePeerConnection` (~`:785`) builds/caches one outbound `PeerConnection` per peer; `evictPeerConnection` removes it; `connectWithTLS` (~`:814`) does the handshake.
  - `connectWithTLS` ends with **`try qc.waitForHandshake(1)` (`:902`)** — a hard 1-second handshake deadline (comment cites "post-quantum key exchange" + first-boot races). On any send failure the send path **evicts the cached connection** (`:733`, `:743`) so the *next* send pays a full re-handshake. Under any latency spike that 1s deadline fails → evict → re-handshake → fail, a **persistent per-peer loop** (matches the observed per-pair stuck failures and the CPU sensitivity). Suggest: adaptive/larger handshake budget, do not evict on a single transient timeout, and reuse a **bidirectional** QUIC connection per peer pair instead of a separate per-direction outbound that must independently handshake (today follower→leader and leader→follower are distinct connections that can fail independently, so a one-directional handshake failure starves AppendEntries acks).
- **`src/distributed/cluster.zig` — second transport with a different timeout.**
  - `sendToNode` (`:1956`) uses **`client.waitForHandshake(10)` (`:1983`, `:2300`)** — a *10-second* deadline, inconsistent with the raft path's 1s. Two separate transports/timeouts for the same mesh is a smell; reconcile onto one robust layer.
- **Consensus convergence with 0 transport errors.** The all-candidates-at-split-terms end state with **no** `HandshakeError` means RequestVote/AppendEntries are not reliably delivered+counted across pods even when the connection succeeds (or heartbeats are not landing within the election timeout). Worth verifying, on a real 3-pod cluster: are RequestVote responses tallied by `from`+`term`, are AppendEntries heartbeats actually delivered within the follower election timeout, and does the commit index advance once a quorum acks. (The pinned raft lib logic and the protobuf bridge were validated on loopback in GAP-0838; the gap is the real multi-pod transport feeding them.)

---

## Suggested regression test

The existing loopback subprocess election test does not catch this. Add a **real 3-process, distinct-IP, TLS (CA-signed certs), steady-state** integration test that asserts:

1. a single leader is elected and **remains leader for ≥ N seconds** (no flap to all-candidates), and
2. a write on the leader **replicates to a quorum** — read it back from a follower and assert it is present, and assert the leader's commit index advanced.

Drive it under mild CPU pressure / artificial latency to surface the `waitForHandshake(1)` eviction loop and the convergence flap.

---

## Reproduction (arda / any k8s)

1. Deploy the 3-node clustered StatefulSet (geode-argo-arda `manifests/components/clustered` + `overlays/qa/cluster-certificate.yaml`): image `0.6.19`, space-separated flags, `GEODE_PEERS` FQDNs, `GEODE_CLUSTER_PORT=4242`, `GEODE_CLUSTER_TOKEN`/`GEODE_AUTH_HMAC_KEY`, a CA-signed leaf at `/cluster-tls` with `GEODE_CLUSTER_CA_CERT=/cluster-tls/ca.crt`, CPU ≥ 2000m.
2. `kubectl logs` each pod and grep `\[raft\] node . state=`: a leader appears, then nodes flap to `candidate`; within minutes it reaches all-`candidate` at split terms.
3. `CREATE` on the leader over `:3141` (creds from the `GEODE_DSN` secret) → client times out; the row never appears on a follower.

## Deployment status

The geode-argo-arda manifests are now correct (TLS/identity/flags/CPU all resolved). The clustered component is left enabled on **qa**; **prod is untouched (single-node 0.6.14)** and must not be switched to clustered until a geode build elects-and-holds a leader and commits replicated writes on a real multi-pod cluster.

---

## Investigation findings (2026-06-04) — local 3-process distinct-IP CA-TLS repro

Reproduced locally with three real `geode serve` processes on **distinct loopback IPs** (127.0.0.11/12/13), same cluster port 4242, with a CA + CA-signed leaf (SANs for the three IPs) and `GEODE_CLUSTER_CA_CERT` pinned to the CA — i.e. the arda secure-TLS model, not loopback-insecure. Three distinct root causes, in order of how they surface:

### Root cause #1 — cluster listener hardcoded to `0.0.0.0:<port>` (FIXED)

`cluster_bootstrap.zig` hardcoded `listen_address = "0.0.0.0"` with no override, and `QuicTransport` binds that address. On a single host, three processes all bind `0.0.0.0:4242`, which the kernel allows via **SO_REUSEPORT** — and then load-balances/misroutes peer handshake datagrams between the three co-located sockets, so handshakes land on the wrong process → persistent `HandshakeError`, no leader. (In real k8s each pod has its own netns, so `0.0.0.0` is fine there; this specifically blocked any faithful multi-node-on-one-host test, and would block any non-k8s multi-node-per-host deployment.)

**Fix:** added a `GEODE_CLUSTER_LISTEN_ADDRESS` env knob (default `0.0.0.0`, unchanged for k8s), plumbed `main.zig` → `cluster_bootstrap` → `ClusterCoordinator.Config.listen_address`. With each node bound to a distinct address, **a full 3-node cluster elects and HOLDS a single leader for 40s+ with zero handshake errors** on a healthy host. Regression test: `tests/test_cluster_3node_steady_state.zig` (`zig build test-cluster-steady-state`) — passing.

### Root cause #2 — graph writes bypass Raft entirely (FIXED for the apply path + single-node)

`executeCreate` / `executeCreateQuery` wrote directly to the local graph store; the QUIC handler's "first-stream mutation fast path" (`executeBulkSimpleCreate`) wrote straight to the storage adapter; `ClusterCoordinator.proposeWrite` had **zero non-test callers**. On top of that, **`deserializeCommand` had no case for `CMD_TAG_GRAPH_MUTATION`** — any proposed graph mutation fell through to `else => .{ .write = data }` and was applied as an inert no-op (but still counted as "applied", so `waitForApplied` returned success and the write vanished). And the apply handler (`raft_apply.applyGraphMutation`) was an **MVP skeleton** (`create` → an *unlabelled* node with raw bytes in a `_raft_data` property).

**Fixed:**

- `raft_consensus.deserializeCommand` now decodes `CMD_TAG_GRAPH_MUTATION` (the missing wire-format case — this alone was silently discarding every graph mutation, including 2PC txn commands).
- New `src/distributed/cluster_replication.zig`: a self-describing single-node-create codec + deterministic apply (`createNodeWithGraph` + `setNodeProperty`).
- `raft_apply.applyGraphMutation` replays the codec payload (real labels + properties), replacing the `_raft_data` skeleton.
- `crud_operations.executeCreate` / `executeCreateQuery`: in cluster mode on the leader, an eligible simple `CREATE (:Label {literal})` is proposed to Raft (not written locally); the apply callback creates the node on every node in log order (deterministic IDs).
- `quic_connection_handler`: the two simple-mutation fast paths are skipped when a cluster coordinator is active, so writes reach the executor's Raft hook.

**Verified:** a single-node cluster (`GEODE_CLUSTER_TOKEN` set, 1 peer) now commits and applies a `CREATE` through Raft (`MATCH … RETURN count(n)` → 1). **Multi-node replication is blocked by root cause #3 below** (the leader cannot commit), so a leader `CREATE` on a 3-node cluster currently returns a `Timeout` (surfacing the unreplicated state instead of silently diverging).

### Root cause #3 — the leader cannot commit / replicate log entries (THE core consensus defect)

Reproduced **deterministically** on a healthy 3-node distinct-IP cluster (NOT a flap, NOT CPU-dependent): a leader is elected and holds, but **no log entry ever replicates to a follower and commit never advances**, so every write times out. Instrumented evidence (leader=node2, followers=node1/3, term=2, 0 handshake errors):

- Leader log: `last=2 commit=0 applied=0` — 2 entries in the leader's log (the election no-op + a proposed write), but commit is stuck at 0.
- Followers: `last=0` forever — their logs are **empty**; they never receive a single entry (not even the election no-op).
- The leader DOES receive the followers' responses (≈1020 `append_entries_response`, `success=true match=0`) — the reverse path works.
- The followers DO receive heartbeats, but **every** one is `prev_idx=0 prev_term=0 nentries=0 leader_commit=0` — the leader ships an **empty** AppendEntries even though `next_index=1` and it has entries at indices 1–2.

> **⚠️ 2026-06-05 CORRECTION — the original root-cause-#3 diagnosis below was WRONG.**
> The pinned raft library is **CORRECT**. Re-instrumenting `buildAppendEntries`,
> `slice()`, `lastIndex()` and `stableTo()` directly (local path-override build)
> proved the library ships the entry properly: `buildAppendEntries` returns
> `ship=true` with the entry, `slice(next,hi)` returns 1 entry, and
> `stableTo(2)` correctly advances `cached_storage_last_index` to 2. The earlier
> "empty AppendEntries / slice yields 0 despite lastIndex==2" reading was an
> artifact of instrumenting the wrong layer. **No raft library change, version
> bump, or `build.zig.zon` update is needed.** The defect was entirely in
> geode's raft bridge, in three stacked places — see RESOLVED below.

**Original (incorrect) hypothesis, retained for history:** "the raft library's
`ReplicationState.buildAppendEntries` returns an empty entry list — `slice(next,
hi)` yields 0 entries despite `lastIndex()==2` … a library change + version
bump." This was not the case.

### Root cause #3 — RESOLVED: geode's raft bridge dropped / freed / buried the log entries (three stacked geode bugs)

The raft library produced the AppendEntries with the entry correctly. geode then
lost it, in three independent places between the library and the wire. Each was
necessary; only all three together make a leader write replicate. Verified
end-to-end on the 3-node distinct-IP CA-TLS harness, clean build, **pinned**
raft: a leader `CREATE (:T {v:1})` is read back as `count=1` on **both**
followers (and the leader), all at term 2.

1. **The protobuf wire boundary carried no entries.** `messageToProto` /
   `protoToMessage` (`raft_consensus.zig`) built the `RaftMessage.AppendEntries`
   with `entries = .empty` / `&.{}` — a documented shortcut from when only
   RequestVote/heartbeat traffic crossed the wire. So *every* AppendEntries went
   out empty, even the election no-op. **Fix:** carry each entry's canonical
   `serializeCommand` bytes in a new proto field `RaftLogEntry.command_bytes`
   (`raft_schema.zig`); `messageToProto` serializes it, `protoToMessage`
   deserializes it back (owning the bytes via `LogEntry.owned_wire_bytes`,
   freed in `freeMessage`). Regression: `tests/test_raft_envelope_roundtrip.zig`
   ("AppendEntries carrying one log entry").
2. **Use-after-free of the command payload.** `raftLibMessageToGeode` set the
   geode `LogEntry.command` by `deserializeCommand(e.data)` *aliasing* the raft
   library's entry bytes. For a freshly-proposed entry those are the leader's
   **unstable** log buffer, which `RaftLog.stableTo` FREES on the very next
   `advance()` — which runs immediately after the send is enqueued. Because the
   outbox is **asynchronous**, the message is encoded much later on the drain
   thread, reading freed memory; the command serialized to empty/garbage. Only
   entries already in stable storage from a prior term survived. **Fix:**
   `raftLibMessageToGeode` deep-copies `e.data` into `owned_wire_bytes` and
   deserializes from that private copy; freed in `freeOutboundMessage`.
3. **Newly-proposed entries buried behind an unbounded heartbeat backlog.** The
   raft tick enqueues an AppendEntries to every peer on a short cadence; when the
   single drain thread can't keep up (multi-peer cluster, slow handshake) the
   outbox grows thousands of stale heartbeats. A just-proposed entry's
   AppendEntries lands at the **tail** and is drained minutes later — or never,
   before the leader steps down. Measured: 2544 entry-carrying messages
   produced, only 68 reached the encoder. **Fix:** `enqueueOutbound` coalesces
   AppendEntries per peer — a newer one supersedes any older still-pending one
   (AppendEntries is idempotent + cumulative), bounding the outbox to ~one per
   peer and putting the just-proposed entry on the wire next tick. Votes /
   responses / snapshots are never coalesced.

A fourth, smaller change reduced wire fragility: `writeRaftFrame` now emits the
4-byte length prefix and the payload as **one** `writeAll` (one STREAM frame /
datagram) instead of two, so the receiver gets the frame atomically.

### Root cause #4 — RESOLVED (prerequisite): cluster orphaned a node addressed via a loopback alias

`cluster_bootstrap.appendPeer`'s self-skip blanket-matched the documented
loopback aliases (`127.0.0.1` / `0.0.0.0` / `localhost` / `::1`) on a port
collision, regardless of this node's own bind address. With distinct loopback
IPs (the faithful multi-node-on-one-host model, and the steady-state test), a
node bound to `127.0.0.2` wrongly skipped the *different* peer at `127.0.0.1`,
orphaning it at `state=candidate term=0` with no transport error. **Fix:** the
alias heuristic now only applies when this node's own bind address is a wildcard
(`0.0.0.0` / `::` / unset — `isWildcardBindAddress`); a concrete bind address is
matched precisely by host equality. The authoritative position-based
`peer_id == self_node_id` skip is unchanged. With this, all three nodes join and
hold a single leader reliably (k8s, which uses distinct pod IPs and `0.0.0.0`
binds, was never affected — this only unblocked distinct-loopback-IP hosts).

### Root cause #5 — leader-flap under CPU pressure (transport architecture, secondary, still open)

Did NOT reproduce on a healthy single host (leader held 40s+). The transport is
fragile under contention: the outbox drain thread serializes peer sends behind a
blocking `waitForHandshake(1)` (`raft_consensus.zig`; inconsistent with
`cluster.zig`'s 10s), evicts the cached connection on any transient send error,
and opens one QUIC stream per RPC. Under CPU contention a slow handshake to one
peer can starve heartbeats to all peers → followers time out → flap. The
per-peer outbox coalescing (#3.3) reduces the pressure but does not remove the
blocking-handshake serialization. Scoped as a follow-up; verify under real k8s
CPU limits before closing.

---

## ✅ ROOT CAUSE #5 RESOLVED (2026-06-08) — bounded multiplexed raft streams

Root cause #5 ("leader-flap under CPU pressure / blocking-handshake send
serialization") is fixed. Confirmed mechanism (via the netns faithful repro,
`tests/cluster/netns_cluster_replication_test.sh` A5): `Transport.send` opened a
**fresh QUIC bidi stream per RPC**. Under sustained write load, AppendEntries-with-
entries exhausted the peer's `max_streams_bidi` credit → the next `getStream()`
returned `OutOfStreams` → `send` **dropped the RPC**. When the dropped RPC was a
heartbeat (empty AppendEntries) or RequestVote/Response, the control plane starved
→ election timeout → term advance → **split-brain** (A5 baseline: node2 leader
term=1, node3 leader term=2, node1 candidate; `LoadFinal=0`).

**Fix (commits `77767dd1`, `e845b039`):** send ALL raft frames over **one bounded
long-lived bidirectional stream per peer** (`PeerConnection.send_stream`, reused
under `client_mutex`, never `finish()`'d per RPC; closed+nulled+reopened only on a
real send error), and the receiver loops length-delimited frames
(`dispatchRaftFrameFromAdaptedStream` reads until `EndOfStream`). Frames were
already 4-byte length-prefixed, so no wire change. This bounds per-peer stream use
to 1 → `OutOfStreams` can no longer drop control messages.

**Evidence (netns A5, after fix):** A1–A4 PASS (election + at-rest CREATE /
CREATE…RETURN replication + follower-write rejection); under 6 writers / 45s the
**split-brain is gone** — exactly **1 leader, 0 candidates, 0 OutOfStreams, 0
evict-on-error lines**. Adversarial code review confirmed no UAF/double-free,
correct A6f lock discipline, and a bounded (non-busy-spin) WouldBlock re-park in
the receiver loop (required so the receiver's `seen_streams` dedup does not wedge a
re-queued stream_id). In-process raft tests (election/propose-write/per-peer-drain)
and the 4 no-regression shards all pass.

### ⚠️ Residual: A5 `LoadFinal` still fails — but on a DIFFERENT root cause (#2)

With the split-brain eliminated, A5's final assertion (`LoadFinal` — the last write
replicating under load) still fails, and triage shows it is **NOT** the raft
transport: the leader logs show **0 OutOfStreams, 0 raft errors, replication
flowing** throughout the load. The failure is **client-plane QUIC poll-loop
saturation** — `proto_reader stall stream_id=0 peer=…:3141` (the test driver's
client connection on port 3141, NOT the raft cluster transport on 4242) wedges
under the 6-writer load, so the LoadFinal `CREATE` can't commit; accompanied by
"QUIC poll cycle slow — query path degraded (sustained-load liveness-kill risk)".
This is the **single-QUIC-poll-loop contention** bug tracked in
`docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md`
(its scoped-but-unshipped Phase 2: `Endpoint.mu` rework + safe stream reaping) — a
separate, deeper QUIC-core change to be done carefully on its own, NOT bundled here.

### Minor follow-ups (non-blocking)

- M1: add an explicit `self.shutdown` check at the top of the receiver frame loop
  (`dispatchRaftFrameFromAdaptedStream`) for prompt teardown — currently it exits
  indirectly via connection teardown (not a hang risk).
- M2: a genuinely half-open dead peer holds a `connection_pool` worker until the
  QUIC idle timeout reaps it (benign in a live cluster: heartbeats keep the stream
  active far under the idle timeout).

### ⚠️ NEW residual on real k8s (2026-06-09, `dev` = `f653bdb`) — cluster does NOT survive pod restart / staggered start

The multiplexed-stream fix was verified on the netns A5 harness, which is
**steady-state**: all 3 nodes start, *then* load runs — membership never changes.
Deployed to the real arda 3-pod StatefulSet, the **transport fix holds** but a
membership-change defect is exposed that A5 cannot see, and it is **fatal in k8s**
(where pods start staggered and restart constantly):

- **Steady-state confirmed good.** A clean boot reached a stable leader (geode-2) +
  follower (geode-0), **0 OutOfStreams / 0 HandshakeError / 0 `poll cycle slow`**,
  and a leader `CREATE (:DevRepl) RETURN 1` read back `count=1` on the leader **and
  the follower** (replication works — #5 transport churn is genuinely gone).
- **A node that starts late or restarts cannot (re)join.** With `Parallel`
  podManagement + `local-path` PVC provisioning, geode-1 came up ~60s after the
  other two; it parked at **`candidate term=0`** and **never joined** — the leader
  reaches geode-0 (heartbeats → follower term=1) but never geode-1. Deleting geode-1
  so it restarts into the *already-stable* cluster did **not** help: it came back at
  `candidate term=0` and stayed isolated. Both sides log **nothing** (0 errors, 0
  connection lines) — the raft frames to/from the late/restarted peer simply never
  flow.
- **Restarting the leader breaks the whole cluster.** `kubectl delete pod` of the
  leader → all three go `candidate`, and **no leader re-elects for 80s+** (the two
  restarted/new-IP nodes stuck at `term=0`, the survivor stuck `candidate term=1`),
  again with 0 transport errors. So the cluster cannot recover from a single pod
  restart — disqualifying for k8s, where the StatefulSet, node drains, image rolls,
  and OOM all restart pods routinely.

**Likely cause:** the new model keeps **one long-lived `PeerConnection.send_stream`
per peer, reopened only on a real send error**. A pod **restart reschedules the
peer to a new IP** (and a late peer was absent at first connect), but a cached
connection to the old/absent endpoint does not surface a "real send error" that
triggers reopen — and even on reopen it must **re-resolve the peer FQDN to the new
pod IP**. So a peer that changes identity/appears-late is never (re)connected: the
survivor keeps a wedged stream to a dead IP, and the fresh node can't establish its
own outbound streams against the current membership (it sits at `term=0`). The
steady-state A5 test never restarts a node, so it cannot catch this.

**Suggested test + fix.** Extend the netns/k8s harness with a **membership-churn**
phase: (a) start nodes staggered, assert the late one joins as a follower and
replicates; (b) restart a follower, assert it rejoins (follower at the leader's
term + a subsequent leader write reaches it); (c) restart the **leader**, assert a
single new leader elects and all three reconverge + replicate. Fix direction:
drive peer-connection liveness from the **heartbeat path** (not only send-error) —
when frames stop being acked / the stream is half-open, **re-resolve the peer FQDN
and reopen `send_stream` to the current endpoint**; and ensure a freshly-started
node (re)establishes its long-lived streams against the live membership rather than
a one-shot connect at boot. Until this lands, a k8s cluster only works on a
single, simultaneous, never-restarted boot — which it never gets in practice.

---

## ✅ RESOLVED (2026-06-09) — periodic peer FQDN re-resolution (reschedule-aware transport)

The membership-change defect is fixed in geode (no raft library change). A
faithful, deterministic netns reproduction was built FIRST and confirmed RED on
the pre-fix binary, then GREEN after the fix.

### Root cause (confirmed by reproduction, not just inference)

The multiplexed-stream transport (root cause #5) keys a long-lived
`Transport.PeerConnection` by **node-id** and only ever rebuilds it on a *send
error* (`shouldEvictOnSendError`). When a pod is **rescheduled to a new IP**, the
old IP becomes a **silent blackhole**: the survivors' cached QUIC connection keeps
"sending" to the departed IP, the datagrams are dropped with **no ICMP and no send
error**, so the evict-on-send-error path NEVER fires and the FQDN is NEVER
re-resolved. `getOrCreatePeerConnection`'s fast path (`raft_consensus.zig`) returns
the cached `established` connection without ever re-resolving `peer.endpoint`.

Reproduced deterministically with Linux netns (distinct routable IPs, wildcard
`0.0.0.0` bind, FQDN+DNS, hostname identity, CA-TLS — the faithful k8s topology),
modelling a reschedule by moving a node's veth IP, repointing a mutable DNS zone,
and installing a **bogus permanent ARP entry** for the old IP in the surviving
peers so it is a true silent blackhole. The pre-fix binary: a follower-reschedule
leaves the cluster **flapping** (a survivor whose stale cached connection points
at the departed IP can never exchange votes — `0` re-resolve lines, `0` transport
errors, the new IP never appears via the connect path); a leader-reschedule
**collapses** the whole cluster to all-candidates. A staggered start with NO IP
change (`M1`) joins fine — confirming the defect is specifically the **stale-IP
cached connection**, not late arrival per se. The inbound/outbound asymmetry is
why an inbound-liveness signal is insufficient: a node cannot observe its own dead
*outbound* from *inbound* traffic (inbound uses the peer's outbound — a different
connection), so the recovery trigger must be **re-resolution of the FQDN**, not
"have I heard from this peer."

### Fix (`src/distributed/raft_consensus.zig`, `src/transport/quic.zig`)

`clientPollLoop` now runs a **periodic peer IP-change reaper** (every ~3 s, gated
well above the 2 ms poll cadence and well below any election timeout): for each
cached peer connection it re-resolves the peer FQDN (`quic.resolveHostIpAlloc`, a
new owned-string resolver) and, if it now maps to a **different IP** than the live
connection (`PeerConnection.resolved_ip`, captured at connect time), evicts the
stale connection (`evictPeerConnection`). The next `send` rebuilds it via
`connectWithTLS`, which resolves the FQDN to the **current** IP. This recovers
**every** direction and scenario (follower restart, leader restart, staggered
start) regardless of which side's connection went stale, and only reconnects on an
**actual** IP change (an IP-literal/loopback cluster resolves to itself and never
churns — so steady-state A1–A5 are unaffected). The reschedule is logged at
`warn` (the report complained churn was invisible at `info`): `raft transport peer
rescheduled to a new IP; evicting stale connection old_ip=… new_ip=… peer=…`.

### Evidence

- **Reproduction harness:** `tests/cluster/netns_cluster_membership_churn_test.sh`
  (`make test-cluster-netns-churn`). Phases: **M1** staggered start, **M2**
  follower restart with NEW IP, **M3** leader restart with NEW IP. Each asserts
  SUSTAINED health (1 leader / 0 candidates held for ≥8 s — an instantaneous check
  races a flapping node) + a write replicating to all 3.
- **Pre-fix:** M2/M3 RED (flap / collapse; `0` re-resolve lines).
- **Post-fix:** M1+M2+M3 **GREEN**; the reaper fires exactly on each IP change
  (`old_ip=10.90.0.11 new_ip=10.90.0.21 peer=1`,
  `old_ip=10.90.0.12 new_ip=10.90.0.22 peer=2`) and all three reconverge to a
  single leader + replicate.
- **No regression:** the steady-state netns regression (`A1–A5`,
  `netns_cluster_replication_test.sh`) and the in-process cluster/raft tests
  (`test-cluster-steady-state`, `test-cluster-3node-election`,
  `test-raft-per-peer-drain`, `test-cluster-propose-write`,
  `test-raft-envelope-roundtrip`) all pass — the reaper does not churn a healthy
  same-IP cluster.

### Still open (characterized, secondary — NOT membership re-resolution)

- **Restart re-apply / no persisted raft log (root cause #6).** Unchanged: the
  cluster `RaftNode` uses `InMemoryStorage`, so a rescheduled-with-new-IP node can
  duplicate already-applied rows. Now that new-IP rejoin actually *works*, this
  surfaces more often and should be scheduled next (wire `FileStorage` +
  applied-index coordination).
- **Dead-write budget (`quic.zig client_writer_max_blocked_ns = 60 s`).** Not
  required for recovery here (the ~3 s reaper evicts well before a write hard-blocks
  on a healthy host), but for k8s faithfulness the raft outbound write should carry
  a heartbeat-scaled deadline so a drain thread never parks 60 s on a wedged peer.

### ✅ Verified on real k8s (2026-06-09, `dev` = `v0.6.26-2-gc1a95a4`) — membership churn survives; #6 confirmed

Deployed to the real arda 3-pod StatefulSet. The membership re-resolution fix
**works on real k8s** — the cluster now survives the cases that were fatal on
`f653bdb`:

- **Leader restart self-heals.** `kubectl delete pod` of the leader → a clean
  re-election (term 1 → 2) and **all three reconverge** (geode-0 leader,
  geode-1/geode-2 followers, `term=2`, stable), then a new leader write
  (`CREATE (:Heal) RETURN 1`) replicates to **all three** (`Heal=1` everywhere).
  On `f653bdb` this left all three `candidate`/no-leader for 80s+.
- **Late-joiner + follower restart rejoin.** The initially-late geode-2 joined as a
  follower and got the replicated row; a follower restart came back at `term=1`
  (sees the cluster term — vs stuck `term=0` before) and was pulled in by the next
  election. Replication to all three at rest is confirmed.

**Root cause #6 now surfaces, exactly as predicted above.** Every restart
duplicates already-committed rows: after geode-2 and geode-1 were each restarted,
a single earlier `CREATE (:M1 {v:1})` reads back **`count=2` (`v=[1,1]`)** on both
**restarted** nodes but **`count=1`** on the never-restarted leader (geode-0). So
on restart the node re-applies the leader's committed log on top of its already
persisted graph store (no `raft_log.bin` / `InMemoryStorage`, non-idempotent
apply). This is now the top blocker for a production k8s cluster — wire
`FileStorage` + applied-index/snapshot coordination so a restarted node does not
re-apply entries it already has. (Verify with the membership-churn harness:
restart a node, assert the replicated row count is **unchanged**, not doubled.)

---

## ✅ RESOLVED (2026-06-09) — root cause #6: restart re-apply no longer duplicates rows

The restart-duplication defect is fixed **entirely in geode** (no raft library
change, no `build.zig.zon` bump). A faithful, deterministic netns reproduction was
built FIRST and confirmed RED on the pre-fix binary, then GREEN after the fix.

### Root cause (confirmed by the explorer, not just inference)

Three facts composed into the duplicate:

1. The live cluster `RaftNode` backs consensus with `raft_lib.InMemoryStorage`
   (`raft_consensus.zig`), so the raft log + applied-index are lost on restart and
   reset to 0.
2. The GNC1 replicated-create payload **carries no node id** — the apply path
   (`cluster_replication.applyNodeCreatePayload`) called `createNodeWithGraph`,
   which mints a **fresh wall-clock `generateTimeBasedId()`** on every apply. (The
   module comment claiming a "monotonic, deterministic counter" was stale/wrong —
   each node already minted *different* ids for the same replicated node, a latent
   cross-node divergence.)
3. The raft library resets `applied = snapshot_index` on init (0 with no
   snapshot), so after a restart **every committed entry is re-delivered** to the
   apply callback. Re-applying a create with a fresh id → a **second node** →
   `count=2` / `v=[1,1]` (the real-k8s symptom).

### Fix — idempotent apply keyed by the committed Raft log index

The deliberate decision was **not** to take the report's suggested
`FileStorage` + snapshot/compaction path: the pinned raft library
(`v0.1.5`) **never auto-drives `InstallSnapshot`** — `node.zig`'s
`buildAppendEntries` returns `null` on `StorageError.Compacted` and falls through
to an empty heartbeat, and `buildInstallSnapshotMessages` has no caller — so
compacting the leader's log would **strand any lagging follower**. A persisted
applied-index *watermark* also has a crash window (an entry checkpointed into the
graph store but not yet in the watermark would re-apply and duplicate).

Instead, the fix makes apply **idempotent**, which is strictly more robust and
closes the crash window: derive the replicated node's id from the committed
entry's **Raft log index**, which is globally unique and **identical on every
node** (Raft Log Matching Property). Then:

- **Cross-node determinism (bonus fix):** every node mints the *same* id for a
  given committed entry — the latent divergence above is also fixed.
- **Restart idempotency (the fix):** re-applying committed entry `N` →
  `createNodeWithId(N, …)` → the id already exists in the **persisted** graph store
  → `error.NodeAlreadyExists` → no-op (properties idempotently overwrite, which
  also repairs a partial first-apply). **The persisted graph store is the dedup
  oracle** — no snapshot, no watermark, no FileStorage required for correctness.

Collision-safety: `generateTimeBasedId()` ids are `≈ now_ms<<16` (≥ ~1e17); raft
indices are small integers, so the two id spaces never collide, and
`createNodeWithId` only advances `next_node_id` when `id >= next_node_id`.

Changes (minimal): `raft_consensus.zig` (`apply_callback` gains the committed
`entry.index`); `raft_apply.zig` + `cluster_replication.zig` (thread the index;
`createNodeWithId` + idempotent property set on both the GNC1 and legacy paths);
`graph_store.zig` (`createNodeWithIdInternal` now does the existence check
*before* creating the storage-adapter slot — previously a re-create on an existing
id leaked a phantom adapter slot, a latent bug that would itself have re-duplicated
on reload).

### Evidence

- **Reproduction / regression harness:** `tests/cluster/netns_cluster_membership_churn_test.sh`
  gained an **M4** phase + `assert_no_duplicate`: seed `CREATE (:M4dup {v:1})`,
  confirm it replicates to all 3, restart a follower **in place with its PVC
  preserved** (the exact re-apply trigger), then assert the row reads back
  **EXACTLY 1 on every node** (sampled repeatedly to catch a jump to 2). RED on the
  pre-fix binary (`count=2`), GREEN after.
- **In-process regression:** `tests/test_raft_apply_restart_idempotent.zig` —
  re-applying the same committed create yields ONE node (was 2, RED→GREEN);
  deterministic `id == raft_index`; distinct indices → distinct nodes (no
  over-dedup); property idempotency. Plus a new in-file idempotency test in
  `tests/test_raft_apply.zig`.
- **Full clean netns churn run (`make test-cluster-netns-churn`, in isolation):**
  `M1` (staggered start) PASS, `M2` (follower restart, NEW IP) PASS, `M3` (leader
  restart, NEW IP) PASS, `M4` (in-place restart, PVC preserved)
  `PASS no-dup: M4dup count is EXACTLY 1 on all 3 nodes after restart` →
  `RESULT: PASS`. The membership-churn fix (`c1a95a48`, M1–M3) is **not regressed**.
- **No regression:** `test-cluster-propose-write`, `test-cluster-3node-election`,
  `test-raft-per-peer-drain`, `test-cluster-steady-state`,
  `test-raft-envelope-roundtrip`, `test-drainready-dispatch`, and the full sharded
  `zig build test` all pass; `zig fmt` clean.

### Still open (characterized, secondary — NOT data divergence)

- ~~**No durable raft log / hard-state (FileStorage).**~~ **RESOLVED 2026-06-09**
  — see section below.
- **Re-apply storm efficiency.** ~~Blocked on the pinned raft library (`v0.1.5`)
  never auto-driving `InstallSnapshot`.~~ **LIBRARY GAP FIXED 2026-06-09** — raft
  `v0.1.6` (lib commits `77010f5` fix + `a18e743` repro tests, tag `v0.1.6`) now
  auto-drives `InstallSnapshot`: when a follower's `next_index` falls behind the
  leader's compaction boundary, all three replication-driver sites (sequential
  heartbeat, parallel heartbeat, AppendEntries-rejection retry) escalate to a
  throttled snapshot send instead of an empty heartbeat; pending state clears on
  ack and normal AppendEntries resumes. The lib also fixed a latent follower-side
  gap: installed snapshots are now persisted to storage in `advancePersist`
  (before, the backing store kept a stale `snapshot_index`, desyncing offsets).
  Geode's pin updated to `v0.1.6`. **Geode-side residual:** geode never calls
  `reportSnapshot`, so its raft log never compacts and the storm remains until an
  applied-watermark + snapshot-content design lands geode-side (careful: a
  marker-only snapshot blob would let a fresh follower skip entries it never
  applied — the snapshot must carry, or safely imply, the full applied state).
  Correctness is unaffected (re-applies are idempotent no-ops).
- ~~**Edge / delete / merge replication idempotency.**~~ **RESOLVED 2026-06-09**
  — see "Edge/delete/merge/SET replication" section below.

---

## ✅ RESOLVED (2026-06-09) — Edge/delete/merge/SET replication with idempotent apply

All four previously non-replicable mutation classes now replicate through Raft
with deterministic, restart-idempotent apply (4 slices, commits `c612711c`,
`e6d91f56`, `4aec072c`, `ed75e2ce`; failing-first repro tests in `7b168f62`):

- **Edge CREATE** (`GNC2` payload): one committed entry mints up to 32 nodes +
  32 edges via positional id derivation in a disjoint band (`MULTI_ID_BASE =
  1<<40` — collision-free vs GNC1 plain-raft-index ids and far below the
  `generateTimeBasedId` ~1.17e17 floor; unit sweep enforces this). Endpoints
  encode as `{position, absolute_id}` so later slices reference pre-existing
  nodes.
- **DELETE / DETACH DELETE** (`GDEL`): the leader resolves the MATCH set to
  explicit stable node/edge id arrays (followers NEVER re-run MATCH), validates
  `NodeHasEdges` semantics locally before proposing, apply deletes edges before
  nodes and no-ops on absent ids (restart re-apply is clean).
- **MERGE** (`GMRG` + reuse of create codecs): match-or-create is decided ONCE
  on the leader and shipped as an outcome — matched-without-ON-MATCH
  short-circuits as a no-op; not-matched rides the idempotent create apply.
  Concurrent-MERGE race documented (bounded by single-writer-leader
  propose+waitForApplied).
- **MATCH…SET / REMOVE** (`GUPD`): this path was previously **completely
  ungated** — a leader SET silently mutated only the leader (silent divergence,
  the highest-severity finding of the audit). Now: followers reject with
  `ClusterNotLeader`; the leader evaluates SET expressions to concrete scalars
  and ships `{node_id, set/remove props, add/remove labels}` (≤4096 nodes per
  entry).
- **Mixed-version safety**: the legacy opaque `.create` fallback (which created
  junk `_raft_data` nodes for unknown payloads) is removed — unknown payload
  magic logs-and-skips on every mutation type.
- **Fail-closed scope** (unchanged semantics, precise errors): INSERT,
  multi-chain patterns, non-scalar property values, `SET n = {map}`,
  edge-property SET (`SET r.x`), relationship-MERGE, MERGE/SET with RETURN
  projections, >4096-id updates/deletes.

**Evidence**: `tests/test_cluster_replicable_mutations.zig` (4 real-process
3-node tests, all red→green: edge create, DETACH DELETE, MERGE×2 idempotent,
SET convergence); `tests/test_raft_apply.zig` 27/27 (codec round-trips,
apply-twice idempotency, cross-store convergence, id-band sweep, unknown-magic
skips); full pre-push gate (4 shards, 1887+ tests) green; netns churn harness
extended with **M5/M6/M7** restart-no-dup phases (`1e2028c2`) — M5 standalone
PASSES (edge + endpoints stay EXACTLY 1 after in-place restart durable-log
re-apply).

**Note on full M1–M7 netns runs**: intermittently blocked by the pre-existing
**root cause #5** transport wedge — a node restarted in place can fail its
outbound verified-TLS QUIC handshake to exactly one (healthy) peer forever
(`getOrCreatePeerConnection failed error=HandshakeError`, never recovers,
parks as perpetual candidate; reproduced 3 ways including an M1–M4-only run on
unmodified phases, so it is independent of this change). That liveness defect
remains the top open transport-hardening item (`connectWithTLS` /
`waitForHandshake` in `src/distributed/raft_consensus.zig`).

---

## ✅ RESOLVED (2026-06-09) — FileStorage follow-up: durable raft hard-state + log

The "no durable raft log / hard-state" follow-up from the root-cause-#6 section
is now fixed. `RaftNode` storage is a tagged union: `null` storage_dir keeps the
prior `InMemoryStorage` path (all 16 in-process test callers + the raft.zig shim
are unchanged); a non-null `storage_dir` roots the pinned raft library's
crash-safe `FileStorage` at `<data_dir>/raft` (hard_state tmp+fsync+rename,
entries.wal, exclusive .lock flock). The library restores term/vote on init and
persists them on every change automatically.

### What was broken

A restarted `RaftNode` backed by `InMemoryStorage` forgot `currentTerm`/`votedFor`
(Raft election-safety violation — could double-vote in one term, risking two
concurrent leaders) and lost its raft log entirely (the leader re-shipped every
committed entry from index 1 on every restart). The "no raft log file on disk" in
the original report was exactly this.

### Fix

- `RaftNode.storage_backing`: tagged union `{ in_memory: *InMemoryStorage, file:
  *FileStorage }`. Both variants are heap-allocated and owned by `RaftNode`;
  `deinit` frees the correct one (FileStorage.deinit releases the .lock flock).
- New `RaftNode.initWithStorageDir(…, storage_dir: ?[]const u8)`: `null` →
  `InMemoryStorage` (unchanged behavior); non-null → `FileStorage` at that path.
  `init` and `initWithClock` are unchanged thin wrappers (`null` dir).
- **Flock retry**: a 15s bounded retry bridges the graceful-shutdown handoff
  window (the OS flock releases the instant the holder exits, even on SIGKILL;
  the retry window covers normal SIGTERM→drain). A genuinely-live holder (operator
  misconfiguration or leaked kernel lock) returns `error.RaftStorageDirLocked`
  with a clear log message. Previously any raft-init error was mislabeled
  `InvalidNodeId`.
- **Plumbing**: `Config.data_dir` → `cluster_bootstrap.maybeStart(data_dir)` →
  `main.zig` passes the configured data dir. All test callsites pass `null` and
  are untouched.

### Netns churn harness improvements

`restart_in_place` now reaps the prior process (SIGTERM → 5s grace → SIGKILL →
`waitpid`) **before** starting the replacement. This faithfully models k8s
termination/PVC-remount ordering and exposed the **separate pre-existing
hung-SIGTERM-shutdown bug** (thread-pool `deinit` timeout): the prior incarnation
hangs in shutdown, holding the `.lock` flock until reaped by SIGKILL. The bounded
retry (above) bridges this. `assert_raft_state_persisted` (M1) verifies
`hard_state` + `entries.wal` exist on disk after the cluster starts.

### Evidence

- **Unit test RED→GREEN**: `tests/test_raft_hardstate_durability.zig` — a
  `FileStorage`-backed node driven to term 5, `deinit`'d, re-init'd on the same
  dir restores `currentTerm==5`. With `InMemoryStorage` (before fix) the term
  resets to 0 and the assertion FAILS (RED). With `FileStorage` (after fix) the
  persisted hard-state is loaded and the assertion PASSES (GREEN). The
  `initWithStorageDir(null)` path (in-memory) is also tested — term stays 0 and
  `tick()` does not crash.
- **On-disk artifacts confirmed**: `entries.wal` and `hard_state` written under
  `<data_dir>/raft/` for all three cluster nodes during the integration test run.
- **Netns churn M1–M4 all PASS**: on-disk raft files present (M1 new assert),
  membership churn unregressed (M2–M3), M4 in-place restart reloads durable state
  with replicated row count EXACTLY 1 on all 3 nodes.
- **Build**: `zig build` clean; `zig fmt` passes; all pre-commit hooks pass.

### Remaining secondary follow-ups

- Re-apply storm efficiency (see above — blocked on InstallSnapshot gap in the
  pinned raft lib; correctness is unaffected).
- Edge/delete/merge replication idempotency (unchanged from prior section).
- Hung-SIGTERM-shutdown bug (separate issue — thread-pool `deinit` timeout on
  graceful stop; tracked in liveness-kill doc; the flock retry makes it safe but
  it should be fixed independently).
