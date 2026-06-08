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
