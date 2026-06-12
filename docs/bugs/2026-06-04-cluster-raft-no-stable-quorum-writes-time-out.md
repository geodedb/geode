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

---

## ✅ VERIFIED on real Kubernetes (2026-06-10, `dev` = `v0.6.26-16-gd8c1adb`) — restart-survival + edge/merge/delete/SET replication all hold; ❌ ONE new silent-divergence hole found

Clean-slate roll of the latest `dev` onto the real arda 3-pod StatefulSet
(geode-2 leader, geode-0/geode-1 followers, `term=2`, stable). **All of the
2026-06-09 fixes above now hold on real k8s** — this is the first build where the
cluster both replicates AND survives restarts on a real cluster:

- **`FileStorage` durable raft state on disk** — `/data/raft` (`hard_state` +
  `entries.wal`) present on every pod.
- **Edge CREATE replicates (create-pattern shape).** A leader
  `CREATE (a:M5A {k:1})-[:M5L]->(b:M5B {k:2})` reads back `M5L=1` on **all three**
  nodes. Restarting a follower (`kubectl delete pod geode-1`, PVC preserved) leaves
  `M5L` **EXACTLY 1 on all three** — root-cause-#6 restart-no-dup holds for edges on
  real k8s.
- **Single-node CREATE / MERGE / MATCH…SET / DELETE** all replicate to all three
  and survive an in-place restart with no duplication (re-confirmed this roll).
- **Fail-closed gate works for the gated shapes.** A follower
  `CREATE (x)-[:R]->(y)` correctly returns `58000 ClusterNotLeader`; MERGE/SET/
  DELETE on a follower likewise reject.

### ❌ NEW (uncovered write path) — `MATCH … CREATE (a)-[:R]->(b)` bypasses the cluster write-gate on EVERY node → silent divergence

The fail-closed write-routing gate (`af5188cd`, "route every graph write through
Raft on the leader; fail closed") is keyed on the **statement handler**: the gate
(`clusterWriteRole()` → `clusterReplicate*`) is installed on the standalone
`CREATE` handler (`crud_operations.zig:1201`, `:2101`), MERGE (`:2789`),
`MATCH…SET` (`:3653`), and DELETE (`:3667`). The **`MATCH … CREATE`** path — a
`CREATE` clause that adds a **relationship between variables already bound by a
preceding `MATCH`** — is dispatched to a *different* executor path that reaches
`store.createEdgeWithGraph` (`crud_operations.zig:764` / `:928`) **with no
`clusterWriteRole()` guard at all.**

Consequence (worst form of divergence — confirmed on the live 3-pod cluster, two
`MT` nodes pre-seeded and replicated to all three first):

```
# on the LEADER (geode-2):
MATCH (a:MT {id:1}),(b:MT {id:2}) CREATE (a)-[:MTL]->(b)
  -> {"status_class":"00000", ... "nodes_created":1}        # SUCCESS, not ClusterWriteNotReplicable
  read back:  geode-2(leader) MTL=1   geode-0 MTL=0   geode-1 MTL=0   # leader-only

# on a FOLLOWER (geode-0) — the gate should reject, but:
MATCH (a:MT {id:1}),(b:MT {id:2}) CREATE (a)-[:MTLF]->(b)
  -> {"status_class":"00000", ... "nodes_created":1}        # SUCCESS on a FOLLOWER
  read back:  geode-0 MTLF=1   geode-1 MTLF=0   geode-2(leader) MTLF=0  # follower-only
# (contrast: a standalone `CREATE (x)-[:R]->(y)` on that same follower DOES return 58000 ClusterNotLeader)
```

So this single query shape:

1. **Is not replicated** — the edge is written to one node's local store only, never
   proposed to the Raft log; the other two never see it.
2. **Does not fail closed** — it returns `00000` success on *both* a leader and a
   follower, defeating the `ClusterNotLeader` / `ClusterWriteNotReplicable`
   guarantee that every other write path enforces.
3. **Diverges on whichever node received it** — leader-only OR follower-only,
   permanently, with no error surfaced to the client.

This is the same severity class as the original MATCH…SET silent-divergence finding
(the highest-severity item of the write-routing audit) — just on a different
uncovered clause. The `Edge CREATE (GNC2)` slice from the 2026-06-09 work covers the
**standalone create-pattern** edge (`CREATE (a)-[:R]->(b)` minting both endpoints,
verified above), but **not** the match-then-create-edge shape (endpoints bound by a
preceding `MATCH`).

Secondary anomaly: the result reports `nodes_created: 1` for a pure edge create
between two already-matched nodes (should be `0` nodes / `1` edge) — the
result-counter for the MATCH-bound CREATE-edge path is also wrong, independent of
the replication hole. *(Fixed 2026-06-10, commits `1aa12b7e`/`758ecc7c` — see the
closure note below; regression in `tests/test_match_create_counters.zig`.)*

**Fix direction:** route the `MATCH…CREATE` path through the same
`clusterWriteRole()` gate as the other handlers. On the leader, the CREATE clause's
edges (and any nodes it creates) must propose through Raft against the
MATCH-resolved **stable node ids** (resolve the binding on the leader, ship explicit
endpoint ids exactly as the `GDEL`/`GUPD` slices already do — followers must NEVER
re-run the MATCH); on a follower it must return `ClusterNotLeader`; any shape
outside the replicable slice must return `ClusterWriteNotReplicable`. Until then, a
3-node cluster silently diverges on any `MATCH … CREATE (a)-[:rel]->(b)` write —
the single most common way an application attaches a relationship between two
existing nodes.

**Regression test:** extend `tests/test_cluster_replicable_mutations.zig` with a
match-then-create-edge case (seed two nodes, `MATCH … CREATE` an edge between them
on the leader, assert the edge reads back on all three) and a follower
fail-closed case (same query on a follower → `ClusterNotLeader`). The netns churn
harness should add an M8 phase asserting a match-created edge stays EXACTLY 1 on
all three across an in-place restart.

---

## ✅ RESOLVED — verified on real Kubernetes (2026-06-11, `dev` = `a25a6f5`) — MATCH…CREATE-edge now replicates; ❌ #5 transport wedge is the sole remaining blocker

The MATCH…CREATE-edge silent-divergence hole documented immediately above is
**fixed and verified on the real arda 3-pod cluster** — and better than the
"fail-closed" floor I suggested: the common single-edge shape now **replicates**.

Tested with **fresh, never-before-used labels** (the QA PVCs retain prior-session
state — the first pass read stale `MTL=1`/`MTLF=1` divergent rows left over from the
2026-06-10 run, which is itself a reminder that the pre-fix divergence is *durable*
until the data is wiped):

- ✅ **Leader `MATCH (a:Q11A {k:1}),(b:Q11B {k:2}) CREATE (a)-[:Q11M]->(b)`** → `00000`
  success and the edge reads back **`Q11M=1` on all three** nodes. The match-bound
  CREATE-edge path now routes through Raft.
- ✅ **Follower** same query → `58000 ClusterNotLeader`, and **nothing is written
  anywhere** (`Q11N=0/0/0`). Fail-closed on followers.
- ✅ **Ambiguous multi-match** (`MATCH {id:1},{id:2}` matching several stale nodes →
  cross-product of edges) → `58000 ClusterWriteNotReplicable`, fail-closed (this is
  why the polluted first pass returned `ClusterWriteNotReplicable` — correct, not a
  regression).
- ✅ **Restart-no-dup holds**: after restarting a node, the match-created `Q11M` and
  create-pattern `Q11L` edges read back **EXACTLY 1** on every reachable node — no
  duplication, no loss.
- ✅ **create-pattern edge unregressed**: `CREATE (x)-[:R]->(y)` and three repeats
  all replicate `1/1/1` (one transient first-write `Timeout` *response* whose write
  nonetheless committed + replicated — a commit-ack latency blip, not divergence).

With this, **every graph-write shape exercised now either replicates to all three or
fails closed** — the silent-divergence class of bugs (the through-line of this entire
report, from the original MATCH…SET hole to this match-create-edge hole) is closed on
real k8s.

### ❌ Sole remaining blocker — root cause #5 (transport): a leader restart can strand the third node as a silent stuck-candidate

On this same run, restarting the leader pod (`kubectl delete pod geode-1`; it came
back with a **new pod IP** `10.244.1.231` and won re-election as leader at `term=12`)
left the third node **geode-2 stuck as a candidate at `term=12` indefinitely** (iter
climbed past 51 800 over ~5+ minutes, never stepping down to follower, never
self-healing within the observation window):

- The leader (geode-1) logs **no** send failures to peer=3, and considers itself a
  healthy term-12 leader. geode-2 logs **no** transport errors in the post-restart
  window either. The heartbeat path leader→geode-2 is **silently not delivered** —
  geode-2 never receives (or never accepts) the same-term leader's AppendEntries, so
  it never steps down. This is the **silent-stall** signature of #5 (a long-lived
  multiplexed stream to a peer that wedges without surfacing an error), distinct from
  the **noisy** signature (the `getOrCreatePeerConnection failed
  error=InvalidAddress|HandshakeError peer=2` churn that geode-2 logged for ~15 s
  during the *initial* boot at 14:29–14:30, before the restart — the FQDN/handshake
  fragility while a peer's pod is first coming up).
- **The cluster stays correct and available at 2/3 quorum throughout.** geode-0
  (follower) + geode-1 (leader) commit and replicate new writes
  (`CREATE (z)-[:QQL]->(w)` → `QQL=1` on geode-0 and geode-1); geode-2 simply lags
  (it holds its last consistent state — `Q11M=1`, `Q11L=1` — and misses only writes
  made while partitioned). geode-2's `:3141` client interface still answers
  (`RETURN 1` → `00000`); only its raft membership is wedged. No data is lost or
  duplicated.
- **Not observed to self-heal.** Unlike the `c1a95a48` membership-re-resolution
  result (where a leader restart cleanly re-elected and all three reconverged), here
  the post-restart re-election left geode-2 permanently out. The difference: there
  the re-resolution reaper fired on the IP change; here geode-2 never re-establishes
  the leader's heartbeat stream and the reaper never logs a re-resolve for the new
  leader's IP. A pod roll of geode-2 would rejoin it, but a healthy cluster must
  survive a single leader restart without operator intervention.

**Status:** the write-path correctness work is **complete and verified on real
k8s** — this is the first build where every write shape replicates-or-fails-closed
*and* survives restart without divergence. The **only** thing standing between this
and a production-eligible 3-node cluster is the #5 transport wedge: a leader (or
any peer) restart must reliably re-establish the heartbeat stream to every peer so
no node is stranded as a silent candidate. Recommend prioritizing the leader→peer
heartbeat-stream liveness/reconnect path (`getOrCreatePeerConnection` /
`connectWithTLS` / the long-lived multiplexed send stream in
`src/distributed/raft_consensus.zig` + `src/transport/quic.zig`): detect a stalled
stream (no ack within N heartbeat intervals) and force a teardown + FQDN re-resolve

- reconnect, exactly as the noisy-error path already does on a hard send failure.
prod remains UNTOUCHED (single-node 0.6.14).

---

## ❌ RE-OPENED on real Kubernetes (2026-06-11, `dev` = `78bb908`) — the #5 stall-detector OVER-CORRECTS into a permanent all-candidate election livelock

The `1637bcf8` stall-detector fix is **present and works at the transport layer**
(the silent blackhole is gone — stalls are now detected and logged at warn), but on
real k8s it **over-evicts and deadlocks the whole cluster on a leader restart**,
which is strictly worse than the `a25a6f5` behavior it replaced (that retained a
functional 2/3 quorum; this elects no leader at all).

### Reproduction (the exact verification the fix doc said was owed)

Rolled qa to `78bb908` (carries `1637bcf8`). Clean boot elected geode-2 leader at
`term=13` (term restored from the prior session's **FileStorage** durable hard-state
on the reused PVCs). Then `kubectl delete pod geode-2` (the leader). Outcome after
~10 minutes: **all three nodes are wedged as candidates at `term=13`, the term never
advances, no leader is ever elected, every write returns `ClusterNotLeader`, and it
does not self-heal.**

```
node 1 (geode-0) state=candidate term=13 iter=45700   # max term ever reached: 13
node 2 (geode-1) state=candidate term=13 iter=51400   # max term ever reached: 13
node 3 (geode-2) state=candidate term=13 iter=35100   # max term ever reached: 13
# CREATE on any node -> ClusterNotLeader ; RETURN 1 -> ok (client iface alive)
```

### Root cause — the stall detector evicts the connections an election needs, on a cadence shorter than the election itself

The smoking gun is in the logs — **every node evicts BOTH its peers every ~3 s,
indefinitely**:

```
WARN geode.raft raft transport peer stalled (no progress within budget); evicting stale connection endpoint=geode-1... peer=2
WARN geode.raft raft transport peer stalled (no progress within budget); evicting stale connection endpoint=geode-2... peer=3
```

`shouldEvictOnStall` treats **absence of inbound AppendEntries-type progress** as a
dead stream. That assumption holds only in steady state *with a leader*. During a
leader-election window there is **legitimately no AppendEntries traffic** — yet
`frames_sent > 0` (candidates are sending `RequestVote`), so every peer trips the
`peer_stall_budget_ms` (3000 ms) and gets evicted. Evicting tears down the QUIC
connection the in-flight `RequestVote` / `RequestVoteResponse` ride on; rebuilding it
(`connectWithTLS` + TLS handshake) takes long enough that the next 3 s pass with
still no AppendEntries progress → evict again. The election can never gather a
majority, so no leader emerges, so AppendEntries never resumes, so the stall clock
never refreshes — a **self-perpetuating livelock**. Because the term only advances
when an election makes progress, it is frozen at the FileStorage-restored `term=13`
forever.

The fix doc's own tuning note is the bug: `peer_stall_budget_ms = 3000 ms`,
deliberately set **"≤ the 5000 ms election-timeout ceiling."** A stall budget
*below* the election timeout **guarantees** the detector fires in the middle of any
election that takes more than one round — which, under restart churn, is the norm.

### Two distinct problems, ranked

1. **(Blocker, NEW) The stall detector evicts during elections.** Inbound
   `RequestVote` / `RequestVoteResponse` (and ideally *any* decoded raft frame, plus
   "I am a candidate / there is no leader" state) must count as liveness, and/or the
   stall budget must be **well above** the worst-case election convergence time
   (several × the election timeout), not below it. Best: suppress the stall check
   entirely while this node is a candidate or while there is no established leader —
   a stalled *stream* is only meaningful to detect when you actually expect periodic
   traffic (steady state under a leader). As written, the recovery mechanism is the
   outage.
2. **(Pre-existing, exposed) A leaderless start from FileStorage-restored
   hard-state does not reliably re-elect.** Even setting the eviction storm aside,
   all three coming up as candidates pinned at the persisted `term=13` (each having
   persisted `votedFor` from the prior term) needs the normal Raft escape — election
   timeout → `currentTerm++` → fresh `RequestVote`. The term never advanced past 13
   here; confirm the candidate election-timeout path increments the term when the
   durable `votedFor` for the current term is already spent. (This may be entirely a
   downstream symptom of #1 starving every election before it can complete — fix #1
   first, then re-test before chasing #2.)

### Also observed — write-commit was already failing at baseline, before the restart

The pre-restart seed (leader geode-2 + 2 followers, all `term=13`)
`CREATE (a:R13)-[:R13L]->(b)` did **not** replicate (`R13L=0/0/ERR`) — the leader
could not commit even with two followers present. Consistent with the stall detector
already churning the leader↔follower connections in steady state once the 3 s budget
elapses between writes (the heartbeat is 50 ms, but if `notePeerProgress` only
counts data-bearing AppendEntries and not idle heartbeats, an idle-then-write gap
> 3 s evicts mid-propose). Worth checking whether **heartbeats refresh the stall
clock** — if only non-empty AppendEntries do, any cluster idle for > 3 s will evict
all peers and stall the next write too.

### Recommendation

`1637bcf8` needs to be reworked before any further k8s cluster testing: the stall
detector must not evict connections that are healthy-but-quiet during an election or
between writes. Until then a leader restart (or even an idle period) takes the whole
cluster down — a worse failure than the silent-stall wedge it was built to fix. The
correctness work (replication, fail-closed, restart-no-dup, MATCH…CREATE) remains
sound and is unaffected; this is purely the transport-liveness reaper over-firing.
prod remains UNTOUCHED (single-node 0.6.14); do NOT enable prod clustering.

---

## ✅ CLOSED (2026-06-10) — `MATCH … CREATE` silent divergence fixed; counter fix; fail-closed sweep + FTS apply symmetry as related hardening

The `MATCH … CREATE (a)-[:R]->(b)` hole above is **fixed on `main`**:

- **Dispatch gate + leader replication slice** (commits `96b73499`, `763d1f15`,
  `c0786dc7`): the MATCH…CREATE path is now routed through the cluster
  write-gate in `query_execution.zig`, and on the leader
  `clusterReplicateMatchCreate` (`crud_operations.zig`) proposes a zero-node
  **GNC2** entry carrying the MATCH-resolved **absolute node ids** as edge
  endpoints — followers apply by id and NEVER re-run the MATCH (same posture as
  the `GDEL`/`GUPD` slices). The GNC2 absolute-id apply path is pinned
  in-process by `tests/test_raft_apply.zig` (commits `17a8f933`, `493a6bbd`).
- **Replicable slice scope** (anything outside it fails closed with
  `ClusterWriteNotReplicable`; a follower always gets `ClusterNotLeader`;
  zero-match is a no-op): head-only named MATCH chains where each variable
  resolves to EXACTLY one node; CREATE endpoints are pure variable references;
  no RETURN/WITH/FILTER/SET/REMOVE/DELETE in the statement; scalar edge
  properties only; ≤32 edges per statement. Documented residuals that fail
  closed by design: Cartesian shapes (a MATCH variable matching >1 node) and a
  new node minted inside the CREATE pattern (`CREATE (a)-[:R]->(new:X)`) in
  cluster mode.
- **Regression tests**: `tests/test_cluster_replicable_mutations.zig` Tests 5+6
  (red at `97e2ddba` → green) — leader MATCH…CREATE reads back on all three
  nodes; follower MATCH…CREATE is refused with `ClusterNotLeader`. The netns
  churn harness gained an **M8 phase**
  (`tests/cluster/netns_cluster_membership_churn_test.sh`) per the request
  above: seeded endpoints, leader MATCH…CREATE → edge EXACTLY 1 on all three,
  follower-directed MATCH…CREATE → `ClusterNotLeader` with no leaked edge, and
  the edge stays EXACTLY 1 everywhere across an in-place restart.
- **Secondary anomaly (counter) fixed** (commits `1aa12b7e`, `758ecc7c`): the
  MATCH…CREATE summary now reports `nodes_created` and `relationships_created`
  correctly (pure edge create → 0 nodes / 1 relationship), and the latent
  silent no-op `MATCH (a) CREATE (a)-[:R]->(new:X {k:1})` (standalone mode) now
  actually creates the new node WITH its properties. Regression:
  `tests/test_match_create_counters.zig`.

### Related hardening landed the same day (2026-06-10)

- **Fail-closed doctrine for every sliceless write surface**
  (`cluster.gateUnreplicatedWrite()`; commits `6d553fdc`, `ecb2bc68`,
  `36fc76fd`, `6b1227d2`, `d7a9597a`): in cluster mode, writes with no
  replication slice are refused — follower → `ClusterNotLeader`, leader →
  `ClusterWriteNotReplicable` — instead of silently applying node-locally.
  Covers `geode.ts.insert`/`insert_many`, auth DDL + mutating `geode.auth.*`,
  policy DDL, tenant create/drop/set_quota, CREATE/DROP INDEX, CREATE/DROP
  GRAPH, constraints, and mutating TDE/CDC/FLE procedures. Standalone mode is
  unaffected. e2e: `tests/test_cluster_replicable_mutations.zig`
  ("cluster: unreplicated write surfaces fail closed", red `5444c87e` → green,
  7/7 suite).
- **FTS apply-path symmetry** (commits `e280c526`, `3cd4e1a3`, `05c7944e`):
  raft apply (GNC1/GNC2/GMRG/GUPD/GDEL) now fires FTS live-maintenance on
  followers via a callback seam, and snapshot install rebuilds FTS indexes
  (seam-level; `installSnapshotData` has no production caller yet —
  `reportSnapshot` wiring pending). Also fixed a latent fts-storage
  segment-flush doc-id delta overflow on descending ids surfaced by GNC2's id
  band. Test: `tests/test_fts_apply_symmetry.zig` (3 tests).

Verification at closure: cluster suite 7/7 green; 4-shard `zig build test`
sweep green; named steps `test-raft-apply` (28/28),
`test-match-create-counters`, `test-fts-apply-symmetry` (3/3),
`test-cluster-coord-config` (6/6) green.

---

## ✅ FIX LANDED (2026-06-11) — root cause #5 transport wedge: stalled-stream liveness detector (pending real-k8s verification)

The #5 silent-stall wedge ("leader restart strands the third node as a
permanent stuck-candidate, zero transport errors on either side") is **fixed
on `main`** (commits `6b4647c0` red-phase tests, `1637bcf8` fix).

**Root cause (file:line confirmed):** the transport had exactly two recovery
triggers, and the wedge provably escaped both:

1. Hard-send-error eviction (`shouldEvictOnSendError` →
   `evictPeerConnection` → next-send `connectWithTLS` FQDN re-resolve) never
   fired, because `Transport.send` is fire-and-forget — a frame written onto
   the long-lived `send_stream` of a stale/half-open QUIC connection buffers
   locally and **returns success**. That is exactly why neither side logged
   an error.
2. The IP-change reaper (`maybeReconnectOnIpChange`, ~3s cadence) evicts only
   when the *peer's* fresh FQDN resolution differs from `pc.resolved_ip`. The
   strand victim (geode-2) never restarted — its IP never changed — so the
   reaper declined to act every pass.

**The fix — a third recovery trigger, sibling to the IP-change reaper, same
~3s `clientPollLoop` cadence** (`src/distributed/raft_consensus.zig`):

- `PeerConnection` gains `last_progress_ms` + `frames_sent` atomics, stamped
  at connect time (stall clock resets on reconnect — no re-evict loop).
- `Transport.send` increments `frames_sent` on every successful frame write
  (send "success" is explicitly NOT trusted as liveness — that's the wedge).
- `notePeerProgress(peer_id, now_ms)` — peer-id keyed, `peers_mutex` tier-3
  only — is called from the inbound dispatch (`cluster.zig`
  `applyDecodedRaftFrame`) **after** the cluster-token + nonce gates, so a
  follower observing AppendEntries from the leader and a leader observing
  AppendEntriesResponse from a follower both refresh the stall clock on the
  OUTBOUND `PeerConnection` for that peer; a forged/replayed frame can never
  hide a stall.
- `shouldEvictOnStall` (pure, clock-injectable): evict iff `frames_sent > 0`
  AND no progress for > `peer_stall_budget_ms` (3000 ms — several reaper
  passes, ≤ the 5000 ms election-timeout ceiling, 60× the 50 ms heartbeat
  cadence). Idle peers (nothing ever sent) are never evicted.
- `maybeReconnectOnStall` logs at **warn** (the wedge is no longer silent)
  and calls `evictPeerConnection`; the next send rebuilds via
  `connectWithTLS`, which **re-resolves the FQDN** — identical mechanics to
  the IP-change path. `maybeReconnectOnIpChange` and the send-error
  classification are unchanged.

**Verification at closure:** `zig build test-raft-stall-detector` 5/5
(`tests/test_raft_stall_detector.zig` + in-file blocks; red-phase commit
`6b4647c0` proved the stalled-peer and progress-stamp tests fail without the
fix). Distributed suite green: `test-raft-per-peer-drain`,
`test-cluster-3node-election`, `test-cluster-steady-state`,
`test-cluster-propose-write`, `test-raft-envelope-roundtrip`,
`test-drainready-dispatch`, `test-cluster-replicable-mutations` (7/7). Full
debug build + `zig fmt` clean.

**Residuals / follow-ups:**

- **Real-k8s verification owed:** redo the 2026-06-11 reproduction (delete
  the leader pod, assert the non-restarted third node reconverges to
  follower within the election budget instead of parking as a candidate) on
  the next dev build carrying `1637bcf8`. The in-process tests pin the
  detector logic; only real k8s exercises the genuine silent-blackhole QUIC
  topology.
- **netns M9 phase** ("leader restart must not strand the third node",
  ideally wedging the stream *without* an IP change so the stall reaper —
  not the IP reaper — is what recovers it) — designed during triage,
  deferred (needs root + minutes).
- `client_writer_max_blocked_ns = 60s` dead-write budget
  (`src/transport/quic.zig:274`) — secondary hardening, unchanged.

prod remains UNTOUCHED (single-node 0.6.14).

---

## ✅ REWORKED (2026-06-11) — stall detector gated on leadership + 15s budget + two-strike eviction (closes the livelock; real-k8s verification owed)

The `78bb908` all-candidate election livelock above is **fixed on `main`**
(commits `c7d07e2a` red-phase tests, `3aeb0fcc` rework). Triage **confirmed
the over-fire but corrected the mechanism**:

- The tester's response-path hypothesis ("the leader never observes follower
  progress because responses ride the unread inbound stream") is **refuted**:
  the raft lib emits ALL output — votes, heartbeats, and every response type —
  via `sendMsg` → the transport bridge → the responder's OWN outbound
  connection, so every inbound frame (including RequestVote/Response and
  heartbeat AppendEntriesResponse) already landed in `applyDecodedRaftFrame`
  and stamped `notePeerProgress`. Progress stamping was symmetric all along.
- The REAL three-part mechanism: **(1)** `peer_stall_budget_ms = 3000` was
  derived against the wrong number — the "5000 ms election timeout" is config
  ms, but `election_tick = election_timeout_ms/50 = 100` ticks × the 10 ms
  raft loop = **1000–2000 ms per election round** (randomized ×2), multi-round
  under churn, so the budget sat BELOW election convergence while the reaper
  interval (3000 ms) EQUALLED the budget — the check window measured itself.
  **(2)** The check was armed regardless of raft role: during a leaderless
  window there is legitimately no AppendEntries flow, `frames_sent > 0` from
  RequestVote, so every peer tripped. **(3)** Eviction destroyed its own
  clear-evidence: `notePeerProgress` no-ops for an evicted (map-absent) peer,
  and the ~1 s `connectWithTLS` rebuild lands votes/responses in dead windows
  — so each eviction manufactured the next "no progress" observation. The
  same instability explains the pre-restart baseline write failure
  (`R13L=0/0/ERR`): heartbeats DO stamp progress every ~10 ms, but one
  eviction-induced stamp-loss window tripped the next eviction mid-propose.

**The rework** (`src/distributed/raft_consensus.zig`, `cluster.zig`):

- **Leader-only arming**: `shouldEvictOnStall(pc, now_ms, is_leader)` returns
  false off-leader. A stalled stream is only meaningfully detectable in
  steady state under a leader expecting AppendEntriesResponse flow — which is
  exactly the original #5 silent-blackhole case. Election-window eviction is
  now structurally impossible. No coverage lost: the IP-change reaper still
  recovers moved peers regardless of role. The leader flag is injected via
  `Transport.setLeaderSource` (wired in `ClusterCoordinator.start`, closure
  over `raft.role() == .leader`); unwired (standalone) defaults to false —
  the detector never arms outside cluster mode.
- **Budget 3000 → 15000 ms**, decoupled from the 3000 ms reaper interval:
  ≥7× the corrected 2000 ms worst-case election round, 5× the reaper
  interval. The old "≤ 5000 ms election ceiling" sizing note was the bug.
- **Two-strike eviction** (`recordStallPass`, `peer_stall_strikes_required=2`):
  one stalled reaper pass records a strike; only consecutive stalled passes
  evict; any `notePeerProgress` resets strikes to 0. A single lost-stamp
  window from a rebuild can no longer trip eviction. The eviction warn now
  logs strikes/budget/stall-age for operators.

**Verification at closure:** `zig build test-raft-stall-detector` 9/9 (4 new
red tests at `c7d07e2a` — leader-gating, budget-vs-convergence assertion,
two-strike, strike-reset — all green at `3aeb0fcc`; the 5 original detector
tests stay green, adapted to the new API). Distributed suite green 7/7:
`test-raft-per-peer-drain`, `test-cluster-3node-election` (real election —
leader-source wiring exercised), `test-cluster-steady-state`,
`test-cluster-propose-write`, `test-raft-envelope-roundtrip`,
`test-drainready-dispatch`, `test-cluster-replicable-mutations`. Full build +
`zig fmt` clean.

**Owed on real k8s (next dev build carrying `3aeb0fcc`):**

1. Delete the leader pod → a new leader is elected (term advances), all three
   nodes reconverge, writes succeed; NO `peer stalled … evicting` warn during
   the election window.
2. Re-run the ORIGINAL #5 silent-strand repro (leader restart, new IP) and
   confirm the detector still catches the genuine blackhole: on the new
   leader, eviction fires once after ~2 strikes (~18–21 s worst case) and the
   stranded node reconverges — recovery, not a storm.
3. Baseline steady-state write replicates with zero eviction churn; an idle
   gap > 15 s followed by a write does not evict.
4. If a FileStorage-restored high-term start still fails to re-elect AFTER
   the storm is gone, that is a SEPARATE bug (candidate election path) — do
   not conflate.

prod remains UNTOUCHED (single-node 0.6.14) until (1)–(3) pass.

---

## ✅ VERIFIED on real Kubernetes (2026-06-11, `dev` = `c42853c`) — stall-detector rework holds; owed items (1)–(3) PASS; item (4) reproduced as predicted (dirty-durable-state recovery)

The `3aeb0fcc` stall-detector rework is **verified on the real arda 3-pod
cluster**. The owed checklist (1)–(3) passes, and the separate bug the rework doc
anticipated in item (4) is confirmed real — which also **corrects the attribution
in my `78bb908` RE-OPEN above**.

### ⚠️ First, the methodology correction (why the `78bb908` report read as catastrophic)

`78bb908` and the first `c42853c` pass were tested on **week-old reused PVCs**. With
`FileStorage` now persisting the raft log + hard-state across rolls, those PVCs
carried **divergent durable raft state** accumulated across ~7 days of forced-restart
testing on buggy interim builds — both clusters booted at `term=13`/`term=14`
(not a clean `term=1`) with inconsistent per-node logs. On `c42853c` (pre-wipe) the
result was a stable-but-broken **leader + two stuck candidates**, term frozen at 14,
writes timing out (`C14L=0/0/0`) — and, crucially, **with the stall-evict storm
already gone** (0 `peer stalled` warns in steady state). That is exactly the rework
doc's **item (4)**: "a FileStorage-restored high-term start still fails to re-elect
AFTER the storm is gone → a SEPARATE bug (candidate election path) — do not
conflate." My `78bb908` RE-OPEN conflated the two: the stall **storm** was real on
`78bb908` (it fired every ~3 s), but the *term-frozen non-convergence* was
substantially this durable-state recovery bug, not the detector.

### A clean-slate boot (PVCs wiped) — everything works

Wiped all three `data-geode-*` PVCs (`scale sts → 0`, `delete pvc`, `scale → 3`) for
a genuine clean boot:

- **Clean convergence**: all three elect immediately (iter 1) → geode-2 leader,
  geode-0/1 followers, **`term=1`** (low term confirms fresh durable state).
- **Replication**: leader `CREATE (a)-[:CLNL]->(b)` → `CLNL=1/1/1`.
- **Zero transport churn**: across the entire clean-cluster lifetime (boot + 3
  restarts below), **0** `peer stalled` / `evicting stale` / `HandshakeError` /
  `InvalidAddress` warns on any node.

### Owed item (1) + (3) — PASS (leader restart no longer strands; no election-window eviction)

- **Leader restart self-heals** (the exact #5 repro). `kubectl delete pod geode-2`
  (leader) → geode-0 elected leader at **`term=2`**, and **all three reconverge**
  (the restarted geode-2 rejoins as a follower) in ~40 s. A post-restart leader
  `CREATE (a)-[:PR1L]->(b)` → `PR1L=1/1/1`.
- **Repeatable**: restarted the leader again (→ geode-2 leader `term=3`, reconverged
  ~40 s) and then a follower (reconverged, slower ~2.5 min but clean). After all
  three restarts: healthy 1 leader + 2 followers, a fresh `CREATE (:FIN)` →
  `FIN=1/1/1`, and the pre-restart `CLNL` row stays **EXACTLY 1** (no duplication;
  the intermittent `ERR` reads are a brief post-restart query warm-up timeout on the
  just-rebooted node, not loss/dup).
- **Item (1) "NO `peer stalled … evicting` warn during the election window"**:
  confirmed — **0** such warns cluster-wide across every restart's election window.
  The leader-only arming + 15 s budget + two-strike rework structurally eliminated
  the election-window eviction.
- **Item (3)**: baseline + post-restart writes replicate with **zero** eviction
  churn.

### Owed item (2) — NOT exercised (no genuine blackhole occurred to recover from)

On the clean cluster the restarted node **reconnected cleanly**, so the detector
never needed to fire — there was no silent-blackhole stream to catch, hence no
"single eviction after ~2 strikes (~18–21 s)" recovery event to observe. The
genuine-stall *recovery* path (the original #5 case) therefore remains
**unverified on real k8s** — it requires reproducing an actual half-open/silent
stream (e.g. the netns M9 phase, or a deliberately black-holed peer), not just a
pod restart that re-resolves cleanly. The *correctness* of the leader-only gate and
two-strike logic is pinned by the 9/9 in-process tests; only the live blackhole is
owed.

### Owed item (4) — CONFIRMED as a separate, still-open bug: no recovery from divergent durable raft state

The pre-wipe behavior above is the standalone repro: starting all three from
`FileStorage`-restored **inconsistent** high-term logs (`term=13`/`14`), the cluster
elects a leader but the other two never latch as followers — they sit as candidates,
the term does not advance, and writes time out **with zero transport churn** (so it
is NOT the stall detector). Wiping the PVCs and booting clean resolves it entirely.

This is a real robustness gap, distinct from #5: **a 3-node cluster cannot recover
from divergent persisted raft state via a rolling restart — it requires a manual PVC
wipe.** Under normal operation (graceful restarts, single failures, a consistent log
prefix) a cluster should not reach this state, and it did not arise in any clean-boot
test; it accumulated only from this doc's week of deliberately abusive forced-leader
kills on pre-fix builds. But the durable layer should still self-heal a follower
whose log diverges from the leader's (truncate-and-refill from the leader, or
`InstallSnapshot`) rather than wedging as a perpetual candidate. **Suggested
follow-up:** a netns/3-node test that seeds deliberately divergent on-disk raft logs
(or force-kills the leader mid-append repeatedly) and asserts the cluster
re-converges from durable state without a wipe. Likely related to the still-pending
`reportSnapshot`/compaction wiring (a lagging/divergent follower that cannot be
caught up by plain AppendEntries needs `InstallSnapshot`, which has no production
caller yet).

### Bottom line

The stall-detector livelock (`78bb908`) is **fixed and verified** — on a clean
cluster `c42853c` converges, replicates, and **survives leader restarts with all
three reconverging and no eviction churn**, which is the milestone #5 was blocking.
Two items remain before a production 3-node cluster: **(a)** exercise the genuine
silent-blackhole recovery path on real k8s (owed item 2), and **(b)** the
divergent-durable-state recovery gap (owed item 4) so a cluster self-heals without a
PVC wipe. prod remains UNTOUCHED (single-node 0.6.14).

---

## ✅ OWED ITEM 4 FIX LANDED (2026-06-11) — candidate-armed stall detector + frozen-term visibility (divergent-state wedge; k8s re-verify owed)

The "divergent persisted raft state → all-candidate frozen-term wedge" (owed
item 4 above) is **fixed on `main`** (commits `79f60b8d` red tests, `67d0d1cc`
fix). Triage **refuted the divergent-log hypothesis** with an in-process
reproduction against the pinned raft lib (v0.1.6, lib FileStorage + TestCluster
harness):

- Under **reliable delivery**, severely divergent durable logs at high terms
  (conflicting tails, spent votedFor, term 13/14) re-elect a leader within ~2
  rounds and divergent followers are truncated-and-refilled by the standard
  AppendEntries consistency check. The lib is correct; **InstallSnapshot /
  `reportSnapshot` wiring is NOT implicated** (no compaction ever runs, so no
  follower's next_index can fall below a log start).
- The wedge needs **two interacting mechanisms**: (1) vote frames silently
  undelivered at restart (the same stale/half-open-QUIC-stream class as owed
  item 2) while the stall detector was **leader-only gated** (3aeb0fcc) — so
  nothing detects or recovers the stall exactly when votes must flow; and
  (2) `pre_vote=true` (geode config) **freezes the term** — pre-vote does not
  increment the term until a pre-vote is WON (`raft/src/node.zig:751-758`), so
  a candidate whose votes vanish retries elections forever at an unchanging
  term with zero log output. Reproduced in-process: full silent partition +
  pre_vote=true → all three frozen at term 13 forever; same partition with
  pre_vote=false → term advances 13→27.

**The fix** (`67d0d1cc`):

- **Stall detector arming widened from leader-only to leader-OR-candidate**
  (`shouldEvictOnStallArmed(pc, now_ms, arm)`; only `.follower` is
  suppressed). Safe against the old livelock by construction: the 15000 ms
  budget + two-strike machine means eviction takes ≥ ~18–30 s vs 1–2 s healthy
  election rounds — a progressing election always delivers frames long before
  the budget. A follower stays suppressed (it expects inbound heartbeats; its
  outbound health is the leader-side detector's job; the IP-change reaper
  covers moved peers for every role). The leader-source injection became a
  role source (`Transport.setRoleSource`, wired in `ClusterCoordinator.start`;
  unwired/standalone → `.follower` → never arms).
- **Frozen-term visibility**: `FrozenCandidateTracker` polled from the raft
  loop (~1 s cadence) emits a rate-limited warn when a node has been a
  candidate at an UNCHANGING term for > 15 s ("possible vote-delivery stall or
  divergent durable state; check peer connectivity"). The silent-by-design
  pre-vote freeze is now operator-visible.
- **Green pin added**: `tests/test_raft_divergent_state_recovery.zig`
  (`zig build test-raft-divergent-state-recovery`) seeds 3 FileStorage dirs at
  divergent terms 7/9/11 and asserts an in-process 3-node cluster (real
  loopback QUIC) elects a leader with the term advancing past the restored
  value — pinning lib+geode divergent-state recovery under healthy transport.

**Verification at closure:** `test-raft-stall-detector` 20/20 (4 red →
green), `test-raft-divergent-state-recovery` green, distributed suite green
(per-peer-drain, 3node-election, steady-state, propose-write,
envelope-roundtrip, drainready-dispatch, replicable-mutations,
hardstate-durability, apply-restart-idempotent). Full build + fmt clean.

**Owed on real k8s (next dev build carrying `67d0d1cc`):**

1. The pre-wipe reused-PVC scenario (divergent durable logs at high terms):
   rolling restart must reconverge WITHOUT a PVC wipe — the candidate-armed
   detector should evict the wedged streams after ~18–30 s and the election
   should then complete; the frozen-term warn should fire in any window where
   it can't.
2. Owed item 2 (unchanged): the genuine silent-blackhole recovery on a LEADER
   (original #5 case) still needs a live half-open stream to verify.

**Deferred residuals:** netns M9 divergent-state phase; upstream lib-repo
regression scenario (divergent FileStorage election — the lib has no coverage
of restored-divergent-log elections today); boot-time durable-state
validation (cluster-identity check on restore); de-swallowing repeated lib
errors in the raft loop (rate-limited escalation).

prod remains UNTOUCHED (single-node 0.6.14).

---

## ⚠️ PARTIAL on real Kubernetes (2026-06-12, `dev` = `3ddb3f7`, carries `67d0d1cc`) — frozen-term warn + candidate-arming both fire, but a node stranded a term behind still does NOT recover; leader-side stall detector is fooled by the stranded candidate's vote traffic

`3ddb3f7` carries `67d0d1cc` (verified by behavior, below). The good news first:
the basics and observability are solid; the gap is now a deeper, precisely-located
one-directional recovery hole.

### What PASSES (clean cluster — no regression vs `c42853c`)

Clean-slate boot (PVCs wiped): converges immediately at **`term=1`** (1 leader + 2
followers); a leader edge write replicates `CB7L=1/1/1`; a **single leader restart
self-heals** — new leader elected, all three reconverge, post-restart write
replicates, restart-no-dup holds; **zero** stall-evict churn.

### What the `67d0d1cc` mechanisms DO deliver (both confirmed firing on real k8s)

- ✅ **Frozen-term visibility works.** The `FrozenCandidateTracker` fires exactly as
  designed: `WARN geode.cluster raft candidate frozen at term — possible
  vote-delivery stall or divergent durable state; check peer connectivity node=2
  term=6 frozen_for_ms=45255` … escalating to `frozen_for_ms=166108`. The
  previously-silent wedge is now operator-visible — a real improvement.
- ✅ **Candidate-armed stall detector fires.** The stranded candidate (geode-1) armed
  its own detector and evicted its peer streams 16× (leader-only gating is gone).

### What still FAILS — a node stranded a term behind after churn does not rejoin

Repro: on the healthy clean cluster, **4 rapid successive leader kills** (kill leader
→ wait only until it's Ready → kill the new leader, ×4). Outcome:

- The cluster does **NOT** fully collapse (a real improvement over `78bb908`): a
  stable **2/3 quorum holds** — geode-2 leader `term=7`, geode-0 follower `term=7` —
  and writes still commit + replicate to the quorum (`STORM7=1/1` on geode-0+geode-2,
  `post-storm write: ok`).
- But **geode-1 is stranded as a candidate at `term=6` — a full term behind the
  quorum — and never rejoins** (observed frozen 166 s+, iter climbing past 31 700,
  the frozen-term warn firing the whole time). The candidate-armed eviction fires
  repeatedly and **does not fix it.**

**Root cause (precisely located): the recovery acts on the wrong direction.** The
broken stream is **leader → geode-1** (the leader's AppendEntries/heartbeats are not
reaching the stranded node, so geode-1 never receives the `term=7` heartbeat that
would step it down to follower and catch it up). But:

1. geode-1's *own* candidate-armed detector evicts geode-1's **outbound** streams —
   the healthy direction — which does nothing for the broken inbound one.
2. The **leader never evicts/reconnects its outbound stream to geode-1**, because the
   leader's stall detector is **fooled**: geode-1, spinning as a candidate, keeps
   sending `RequestVote`/pre-vote frames to the leader; each inbound frame stamps
   `notePeerProgress(peer=2)` on the leader, so the leader believes its connection to
   geode-1 is making progress and the stall budget never trips. (Confirmed: the
   leader logged only 2 `peer stalled` for peer=2, both from the kill window, none
   while geode-1 was wedged.)

So "progress = ANY inbound decoded raft frame" is too coarse: a peer that floods
`RequestVote` but never acknowledges the leader's `AppendEntries` looks healthy to
the leader-side detector, masking a dead outbound heartbeat stream.

### Suggested fix

Make the leader-side liveness **per-direction / per-message-type**: the leader should
track whether its outbound `AppendEntries` to a peer are being **acknowledged**
(`AppendEntriesResponse` / matching `match_index` advance), not merely whether *any*
inbound frame (including `RequestVote`) arrives. A peer that sends only votes and
never an `AppendEntriesResponse` to a leader's heartbeats is a stalled *outbound*
stream → evict + FQDN re-resolve + reconnect. Equivalently: a leader seeing a peer it
believes should be a follower instead persistently `RequestVote`-ing at a stale term
should force-reconnect that peer's stream. The frozen-term warn already detects the
victim side; the leader side needs the symmetric trigger.

### Secondary (recurring) — `Timeout` response on a write that actually committed

Seen again here: the clean baseline `CREATE (a)-[:CB7L]->(b)` returned a client
`Timeout` yet replicated `CB7L=1/1/1` (committed on all three). The leader commits +
replicates but the client-facing ack exceeds the client timeout. This is not
divergence, but it makes writes non-idempotent from the client's view — a
retry-on-timeout would double a `CREATE`. Worth a look at the `waitForApplied` /
client-ack path latency under cluster mode (distinct from the liveness wedge above).

### Scope / caveat

This needs **aggressive** churn (4 rapid kills) to induce; a single leader restart
recovers cleanly. And owed **item 1** (rolling-restart reconvergence from genuinely
*pre-divergent* reused PVCs, without a wipe) was not directly retried this run — the
PVCs were clean — but this stranded-term-behind repro is the same family and shows
the candidate-arming alone is insufficient. Owed **item 2** (genuine silent-blackhole
recovery on a leader) likewise remains unexercised. prod remains UNTOUCHED
(single-node 0.6.14).

---

## ✅ PER-DIRECTION LIVENESS FIX LANDED (2026-06-12) — response-only progress stamping (stranded-term-behind wedge; k8s re-verify owed)

The "stranded a term behind despite both mechanisms firing" wedge above is
**fixed on `main`** (commits `cc4b716c` red tests, fix on this commit). The
tester's diagnosis was confirmed exactly in code:

- The stamp at `cluster.zig:applyDecodedRaftFrame` fired for EVERY inbound
  frame type. A stranded candidate re-sends RequestVote every 1–2 s
  (election timeout [1.0 s, 2.0 s)); each vote stamped the LEADER's
  outbound-to-that-peer clock, so the 15 s stall budget never elapsed and
  the leader never evicted/rebuilt its genuinely-wedged outbound stream.
  Meanwhile the stranded node's own candidate-armed detector evicted its own
  (healthy) outbound streams — the wrong direction by construction (the
  documented inbound/outbound asymmetry: a node cannot observe its own dead
  INBOUND; only the sender can fix it).

**The fix — per-direction liveness:** progress for peer X is now stamped
ONLY by RESPONSE frames (`request_vote_response`,
`append_entries_response`, `install_snapshot_response`) — a response can
only exist if OUR outbound request reached X. Inbound REQUESTS
(RequestVote/AppendEntries/InstallSnapshot, pre-vote included) prove only
X's outbound path and no longer refresh our clock. Implemented as the pure
classifier `frameProvesOurOutboundDelivered(body)` (raft_consensus.zig)
gating the stamp site (cluster.zig), after the token+nonce gates as before.

Why this is safe for healthy links: the leader heartbeats every ~10 ms and
a caught-up follower acks EVERY AppendEntries (including empty heartbeats)
with `append_entries_response` — verified in the lib (node.zig:949-953,
:1034-1041) — so a healthy leader↔follower pair refreshes constantly. A
candidate's clock refreshes on vote RESPONSES. Followers remain suppressed
from eviction entirely. Expected k8s behavior for the stranded-term-behind
scenario: the leader's clock for the wedged peer goes stale in 15 s, two
strikes evict at ~18–21 s, the rebuilt stream delivers term-7 AppendEntries,
and the stranded node steps down — bounded recovery instead of a 166 s+
permanent strand.

**Verification at closure:** `test-raft-stall-detector` 22/22 (2 new red →
green: the 6-variant classification table and the transport-level
"request does not refresh / response does" contract),
`test-raft-divergent-state-recovery` green, distributed suite green
(per-peer-drain, 3node-election, steady-state, propose-write,
envelope-roundtrip, drainready-dispatch, replicable-mutations,
hardstate-durability, apply-restart-idempotent). Full build + fmt clean.

**New characterized residual — client-retry idempotency gap (from the same
k8s run):** a write that COMMITS but exceeds the 5000 ms `waitForApplied`
budget returns `Timeout` to the client (busy-poll wait at 2 ms granularity,
`cluster.zig:waitForApplied`; budget hardcoded at the 7 `clusterReplicate*`
call sites). The latency itself is the already-tracked QUIC poll-loop
saturation work (`docs/bugs/2026-06-07-…liveness-kill-503.md`). The novel
gap: a CLIENT RETRY of a timed-out-but-committed write mints a NEW raft
index, which the index-keyed apply dedup (root cause #6) does NOT catch —
a retried CREATE can double-insert. Needs a client-visible idempotency key
or a propose-level dedup; until then operators should treat Timeout on
cluster writes as "unknown outcome", not "failed".

**Owed on real k8s (next dev build):** (1) the aggressive-churn repro
(4 rapid leader kills) — the stranded node must rejoin within ~30 s with
the leader logging a stall-evict for it; (2) owed item 2 (genuine leader
silent-blackhole) remains unexercised; (3) reused-PVC rolling restart
without a wipe (owed item 1) still to be retried directly.

prod remains UNTOUCHED (single-node 0.6.14).

---

## ⚠️ real Kubernetes (2026-06-12, `dev` = `a765c9f`) — NEW: release build breaks the health probes (deployment blocker, fixed in argo); clean-boot convergence is now FLAKY; aggressive churn still wedges all-candidate frozen-term

### New deployment blocker — release-build `geode query` refuses `--insecure-tls-skip-verify` → all probes fail → pods never Ready

`a765c9f` is a **release build**, and a release build's `geode query` now **refuses
`--insecure-tls-skip-verify`**:

```
SECURITY: refusing --insecure-tls-skip-verify — TLS certificate verification cannot be
disabled under production conditions (release build or GEODE_ENV=production). … Use
--ca-cert <path> to trust a private CA, or set GEODE_ALLOW_INSECURE_TLS=1 …
```

The k8s **startup, liveness, and readiness probes** (`manifests/base/geode.yaml`) all
shell out `geode query … --insecure-tls-skip-verify … "RETURN 1"`. On a release build
every probe now exits non-zero, so **the StatefulSet pods never report Ready** even
though the raft cluster underneath is running (geode-0 was an elected leader at a high
term while k8s showed `0/3` Ready). This is an intended security hardening, but it is a
**breaking change for any deployment whose health checks (or clients) use insecure
TLS** — and it is on the **prod upgrade path**: prod's single-node 0.6.14 → any release
build will hit the same probe failure unless the probes are migrated off
`--insecure-tls-skip-verify` first.

**Fix (geode-argo-arda, clustered component, commit `ed0852a`, committed local):**
the clustered pods already mount the issuing CA at `/cluster-tls/ca.crt`, so the 3
probe commands now verify against it via `--ca-cert /cluster-tls/ca.crt` (the
build-sanctioned secure path; `GEODE_ALLOW_INSECURE_TLS=1` is the other, less-safe
escape hatch). After this, pods go Ready. **The single-node base probes still use
`--insecure-tls-skip-verify` and must be migrated before prod upgrades to a release
build** (single-node has no mounted CA — it needs its own server cert exposed as a
`--ca-cert`, or `GEODE_ALLOW_INSECURE_TLS=1`). All of my test queries also had to move
to `--ca-cert`. (ArgoCD auto-sync was paused for qa to apply the live probe fix; it
must be re-enabled once the argo change is pushed, else a sync reverts the probes and
re-breaks the pods.)

### Cluster behavior on `a765c9f` (clean-slate, PVCs wiped, probes fixed)

- **Single leader restart: PASS** (parity with `c42853c`/`3ddb3f7`) — kill the leader →
  reconverge to 1 leader + 2 followers, post-restart write `ok`. (Minor: a restarted
  node showed catch-up lag — a post-restart write read back `0` on the just-rebooted
  node for a while.)
- **Clean-boot convergence is now FLAKY** (a reliability regression vs `c42853c`,
  which converged deterministically on clean PVCs in prior runs). Across three fresh
  starts on the same wiped PVCs: boot 1 converged 1+2 `term=1` and replicated
  (`AB7L=1/1/1`); **boot 2 stranded geode-0 as a candidate at `term=1` and the
  remaining 2/3 quorum could not commit a write** (leader query timed out, `Q23L`
  never replicated; geode-0's frozen-term warn fired); boot 3 converged cleanly again.
  A plain pod restart recovered the stranded boot-2 state.
- **Aggressive churn (4 rapid leader kills): still wedges, no recovery.** All three
  end as candidates **frozen at `term=5`** (max term reached = 5; never advances),
  **no leader, writes fail** (`NO LEADER`, `ACH7=0/0/0`), and it does **not** self-heal
  (watched several minutes; **transport is quiet — zero peer-connection errors** in
  steady state). The `67d0d1cc` mechanisms fire (frozen-term warns 1/4/2 across nodes;
  candidate-armed stall-evicts 2/11/6) — so the wedge is **visible and the recovery
  path engages — but eviction+reconnect still does not restore vote delivery**, so the
  pre-vote term stays frozen. Same all-candidate frozen-term family as `78bb908`, just
  now instrumented.
- **Recurring (unchanged): `Timeout` response on a committed write.** Even the healthy
  converged 3/3 cluster returns a client `Timeout` on a `CREATE` that nonetheless
  replicates `1/1/1` (`AB7L`, `HLL`); in the degraded boot-2 state the same path timed
  out *and* failed to commit. The client-facing ack latency needs attention
  independently — a `Timeout` is currently ambiguous (may have committed).

### Net

`a765c9f` adds a correct security hardening that, as a side effect, **breaks the
existing health-probe contract** (now fixed for the cluster overlay; the single-node
base + prod path still need the same migration). On cluster behavior it is **not an
improvement** over `c42853c`/`3ddb3f7`: a single restart still recovers, but clean-boot
convergence became flaky (a node can strand even at `term=1`, taking the 2/3 quorum's
writes down with it) and aggressive churn still ends in the all-candidate frozen-term
wedge — the recovery mechanisms are visible but ineffective at restoring vote delivery.
The core unresolved item remains the same: **after connection churn, peer vote/heartbeat
delivery is not reliably re-established, and the eviction/reconnect path does not fix
it** (a leader-side per-direction liveness signal — track AppendEntries *acks*, not any
inbound frame — plus a delivery-restoring reconnect, is still owed). prod remains
UNTOUCHED (single-node 0.6.14).

## 2026-06-12 — churn-recovery fix landed: receiver reap + rebuild probation + directional follower eviction (`80ed0539` + `14b7295e`)

Triage of the `a765c9f` k8s findings located **three root causes** behind "eviction +
reconnect does not restore vote delivery", and all three are now fixed on main. The
key reframe: the wedge was never a sender-side detection problem (dacf4771 was
correct) — **recovery could not work because the receiver was starved**.

- **RC1 — receiver-side worker-pool starvation (the foundational one;
  `src/distributed/cluster.zig`).** Every accepted inbound cluster connection pinned
  one of only **4** connection-pool worker threads, and the handler's accept loop
  never exited for a half-open peer — it parked on `WouldBlock` until the **300 s**
  QUIC idle timeout. Four rapid kills left zombie inbound connections pinning all
  workers, so rebuilt outbound connections carrying current-term votes were **never
  serviced**. This is why every sender-side fix (eviction, per-direction liveness)
  failed to move the wedge. Fix: `handleQuicConnection` stamps `last_activity_ms` on
  every accepted stream / dispatched frame and **reaps an idle inbound connection
  after 30 s** (`GEODE_CLUSTER_INBOUND_IDLE_MS` overridable), releasing the worker.
  Pure decision fn `shouldReapIdleInboundConnection`; tests
  `test-raft-receiver-reap` (6/6).
- **RC2 — rebuild clock-reset re-eviction chase (`raft_consensus.zig`).** A
  stall-triggered rebuild stamped `last_progress_ms = now`, i.e. a forced rebuild
  counted as proof of health — with all 6 directed connections stale, rebuilds chased
  each other on phase-shifted 15 s clocks and never converged. Fix: `RebuildProbation`
  — a rebuild enters probation (NOT progress proof), measured from `rebuilt_at_ms`
  against an escalating budget (15 s → 30 s → 60 s capped); only a real
  `*_response` frame (or implicit ack, below) clears it. Tests
  `test-raft-rebuild-probation` (6/6).
- **RC3 — follower response-direction suppression (`raft_consensus.zig`).** The
  stall reaper suppressed eviction for followers entirely, so a follower whose
  *response-carrying* outbound was dead kept answering AppendEntries into a dead
  buffer while the leader never got acks — exactly the boot-2 "geode-0 stranded,
  2/3 quorum can't commit" signature. Fix: `directionalEvictAllowed` — a follower
  that is actively receiving request frames while having no outbound-delivery proof
  for the budget may now evict/rebuild its outbound. To keep a HEALTHY follower from
  churning: an inbound AppendEntries whose `prev_log_index`/`leader_commit`
  **advances** is an implicit ack (stamps proof), and — the churn guard (`14b7295e`)
  — a non-advancing **empty heartbeat** also stamps proof; only a non-advancing
  **retransmit with entries** (the actual ack-loss signature) leaves the follower
  eviction-eligible. Tests `test-raft-follower-response-eviction` (10/10).

Accepted residual (documented in code): an idle cluster whose follower outbound dies
silently is indistinguishable from healthy-idle at the follower until the next write
turns the loss into retransmits — leader-side per-direction liveness (dacf4771)
covers detection meanwhile. The client-retry idempotency residual (committed write →
client `Timeout` → retry double-insert) is **unchanged and still owed** — it is a
propose-level idempotency-key problem, independent of delivery.

Local verification: all four new/changed suites green (`test-raft-receiver-reap`
6/6, `test-raft-rebuild-probation` 6/6, `test-raft-follower-response-eviction`
10/10, `test-raft-stall-detector` 22/22 unchanged), `test-raft-divergent-state-recovery`,
`test-cluster-replicable-mutations` 7/7, distributed unit + cluster smoke steps all
pass. **k8s validation owed**: clean-boot ×N flake check, 4-kill aggressive churn,
and the previously owed live-blackhole + reused-PVC roll, on the next release build.

---

## ✅ VERIFIED on real Kubernetes (2026-06-12, `dev` = `3466751`) — churn-recovery fix HOLDS (liveness milestone); ❌ but it unmasks a NEW edge data-integrity bug under churn (`EdgeSlotMappingMissing`)

`3466751` carries the `80ed0539`+`14b7295e` churn-recovery fix. On real arda (clean
PVCs, `--ca-cert` probes) the owed k8s validation **passes** — this is the first build
that genuinely survives the 4-kill aggressive churn — but surviving long enough to
*query afterward* exposed a separate, serious edge-durability defect.

### ✅ Owed item — clean-boot ×N flake check: PASS

Three fresh starts on wiped PVCs all converged 1 leader + 2 followers (term 1). The
`a765c9f` boot-2 stranding (geode-0 stuck candidate, 2/3 quorum couldn't commit) did
**not** reproduce — RC1 (receiver-reap) + RC3 (directional follower eviction) resolved
it.

### ✅ Owed item — 4-kill aggressive churn: PASS (liveness/recovery)

**Three independent churn rounds, each = 4 rapid leader kills, all RECOVERED:**

| round | result | term after | post-churn write | node replication |
|------|--------|-----------|------------------|------------------|
| A | reconverged 1+2 (~iter 4) | 9 | `ok` | `1/1/1` |
| B | reconverged 1+2 (~iter 5) | 12 | `ok` | `1/1/1` |
| C | reconverged 1+2 (~iter 5) | 16 | `ok` | `1/1/1` |

The **term advances** every round (9 → 12 → 16; no frozen-term freeze), all three
reconverge to one leader + two followers, and a post-churn write commits and replicates
to all three. The all-candidate frozen-term wedge (`78bb908`/`a765c9f`) and the
stranded-term-behind wedge (`3ddb3f7`) are both **gone**. The receiver worker-pool
starvation (RC1) was indeed the foundational blocker — vote delivery now recovers.
Frozen-term warns dropped to ~0 sustained (a couple transient stamps during churn, then
clear).

### ❌ NEW data-integrity bug — aggressive churn corrupts pre-existing EDGES (`EdgeSlotMappingMissing`), nodes survive

Now that the cluster survives churn, post-churn queries are reachable — and they reveal
that **edges created before the churn are corrupted**. Reproduced twice,
deterministically:

- A baseline edge `CREATE (a:BW)-[:BWL]->(b:BW)` (replicated `1/1/1` before the churn) →
  after 3 churn rounds, `MATCH ()-[r:BWL]->() RETURN count(r)` returns
  **`58000 EdgeSlotMappingMissing` on ALL three nodes**, while the endpoint nodes
  survive (`MATCH (n:BW) → count=2` on all three).
- Isolated repro: created a fresh edge `FEL` on the stable cluster (queried `1/1/1`,
  healthy), then ran **one** 4-kill churn round → `FEL` → **`EdgeSlotMappingMissing` on
  all three**, `FE` nodes intact (`count=2`). A brand-new edge created on the *stable*
  cluster always works (`1/1/1`); it is specifically **survival across churn** that
  corrupts it.

So: **nodes durably survive aggressive restart churn; edges do not** — an edge's slot
mapping is lost (`EdgeSlotMappingMissing`) after enough restart/re-apply cycles,
consistently on every replica (deterministic, not a one-node corruption). The edge is
effectively unqueryable/lost while its endpoints remain. This was *masked* on every
prior build because the cluster never survived churn long enough to query the edge
afterward; the liveness fix exposed it.

**Likely area:** the edge-create apply / FileStorage restart-reapply path
(`GNC2` edge payload, idempotent apply). On restart the committed edge-create entry is
re-applied: the endpoint nodes idempotently already-exist, but the edge→slot mapping is
evidently not reliably rebuilt/persisted across repeated re-applies, so after several
restart cycles the slot lookup is missing. Suspect the edge-slot index reconstruction on
durable-log replay (or the idempotent-skip path skipping the edge while not ensuring its
slot mapping), as opposed to the node path which is keyed by stable id and survives.
Recommend a netns/3-node regression: seed an edge, restart all nodes N× (PVCs preserved),
assert `MATCH ()-[r]->()` still returns the edge (not `EdgeSlotMappingMissing`) and
`count` is unchanged.

### ⚠️ Recurring (acknowledged/owed) — `Timeout` response on a committed write

Still present: the baseline `CREATE (a)-[:BWL]->(b)` returned client `Timeout` yet
replicated `1/1/1`. This matches the doc's noted "committed write → client `Timeout` →
retry double-insert" propose-level idempotency residual — unchanged, still owed.

### Net

The churn-recovery fix is a **genuine milestone**: clean-boot is reliable and the
cluster now survives 4-kill aggressive churn (recovers, replicates, term advances) on
real k8s — the central liveness blocker of this entire report is resolved. The remaining
blockers before a production 3-node cluster are now **(1) edge durability under churn
(`EdgeSlotMappingMissing`)** — a data-integrity bug, the new top priority — and **(2)**
the committed-write client-`Timeout` idempotency residual. (Owed item — genuine
live-blackhole recovery — still unexercised; reused-PVC divergent-roll likewise.) prod
remains UNTOUCHED (single-node 0.6.14).

---

## ✅ 2026-06-12 — Edge churn durability fixed (orphan slot on idempotent re-apply; hydration self-heal)

### Root cause

`createEdgeWithIdInternal` (`src/storage/graph_store.zig:2371`) minted the durable
adapter edge slot **before** the in-memory idempotency check — the opposite of the
node path. On every raft-log re-apply after a restart the in-memory edge already
existed (idempotency guard fired), so the function returned early; but the adapter
slot had already been minted without a `__geode_internal_edge_id` property. After N
restart cycles each re-apply left one additional orphan physical slot. Hydration
skipped orphan slots (no public-id property, no legacy mapping entry) so the
edge's canonical slot was never registered → `EdgeSlotMappingMissing` on query.

### Fix

Two-part — commits ab700319 / 2cdc053a / 11c97371:

1. **Existence check before slot mint** (`2cdc053a`): adapter slot is now only minted
   when the edge does not already exist, matching the node path. No new orphans
   are created by re-apply under new binaries.

2. **Hydration orphan-slot self-heal** (`2cdc053a`): on startup hydration, any edge
   slot missing the `__geode_internal_edge_id` property AND having no legacy
   mapping entry is deleted (not the canonical edge, not legitimate parallel edges —
   guarded by property presence + mapping lookup). PVCs already corrupted by old
   binaries repair on first restart under the new binary.

### Evidence

- `zig build test-edge-durability-churn-repro`: **3/3** (was 2 RED — idempotent
  re-apply orphan + orphan query failure; now includes RED-with-repair-disabled
  check that proves the self-heal path is exercised under the test).
- Related suites all green: cluster-replicable-mutations 51/51,
  raft-apply-idempotent 366/366, fts-apply-symmetry, gap0509, gap0891,
  graph-store, adapter-registry-restart.

### Net

The edge durability bug — previously the new top-priority data-integrity blocker —
is **closed**. Legitimate edges and legitimate parallel edges are preserved; corrupted
PVCs from old binaries self-heal on first restart under the new binary.

### ⚠️ Residuals (unchanged/owed)

- **k8s re-validation on arda** (owed): seed an edge, run churn rounds, assert the
  edge still queries; also exercise existing corrupted PVCs self-healing on restart.
  Canonical regression: `MATCH ()-[r]->()` must return the edge (not
  `EdgeSlotMappingMissing`) after N restart cycles with PVCs preserved.
- **Committed-write client-`Timeout` idempotency residual** (unchanged): a write
  committed at raft level but returning `Timeout` to the client can be retried and
  applied twice — still open, still owed.

---

## ✅ VERIFIED on real Kubernetes (2026-06-12, `dev` = `v0.6.27-5-gd84cb40`) — edge churn-durability fix HOLDS; liveness degrades only under SUSTAINED extreme churn

`v0.6.27-5-gd84cb40` carries the edge-durability fix (`2cdc053a` et al.). The owed
arda re-validation **passes** — edges now survive aggressive churn, closing the
`3466751` top blocker on real k8s.

### ✅ Edge churn-durability — FIXED (the owed canonical regression, on real k8s)

Clean-slate boot (PVCs wiped). Seeded an edge `ED1` (`CREATE (a:ED)-[:ED1]->(b:ED)`,
replicated `1/1/1`), then ran **three** 4-kill aggressive-churn rounds, re-checking the
edge after each:

| after churn round | `ED1` (`MATCH ()-[r:ED1]->()`) | endpoint nodes |
|---|---|---|
| round 1 | `1/1/1` | `2/2/2` |
| round 2 | `1/1/1` | `2/2/2` |
| round 3 | `1/1/1` | `2/2/2` |

`ED1` survived **all three rounds** as `1/1/1` on every node — **no
`EdgeSlotMappingMissing`**. Two additional edges seeded mid-test (`EBL`, `ECL`) also end
`1/1/1` on all three. The exact prior repro (an edge that existed before churn) — which
deterministically corrupted to `EdgeSlotMappingMissing` on `3466751` after a single
round — now holds. The existence-check-before-slot-mint + hydration self-heal works in
the real cluster.

### ⚠️ Liveness — recovers for moderate churn, but degrades under SUSTAINED extreme churn

Across the three back-to-back rounds (12 leader kills with no settle time between),
recovery **slowed monotonically**: round A reconverged ~immediately, round B at ~iter 20,
round C did **not** reconverge within the window — it ended with **geode-0 stranded as a
candidate at the quorum's term** (`term=14`, watched ~70 s+, not stepping down to
follower), while geode-1 + geode-2 held a **2/3 quorum that still commits and replicates**
(`CREATE (:FINOK)` → `ok`, `FINOK` on geode-1+geode-2; geode-0 partitioned out). So data
stays correct and the cluster stays available at 2/3 throughout, but full 3/3 health is
not restored under sustained extreme churn. This is the same stranded-candidate family as
`3ddb3f7` — the `80ed0539`/`14b7295e` churn-recovery fix handles a single 4-kill burst
cleanly (verified on `3466751` and here), but consecutive bursts can still strand a node.
A pod roll of the stranded node rejoins it. (12 rapid kills is well beyond realistic
operation; the realistic single-burst case recovers.)

### ⚠️ Recurring (owed) — committed write → client `Timeout`

Unchanged: the baseline edge `CREATE` returned client `Timeout` while replicating `1/1/1`
— the acknowledged propose-level idempotency residual.

### Net

The edge churn-durability data-integrity bug is **closed on real k8s** — the verification
the fix doc owed. Remaining before a production 3-node cluster: **(1)** liveness under
sustained/repeated churn (a node can still strand as a candidate after consecutive bursts;
2/3 quorum stays functional) and **(2)** the committed-write client-`Timeout` idempotency
residual. (Genuine live-blackhole recovery and reused-PVC divergent-roll remain
unexercised.) prod remains UNTOUCHED (single-node 0.6.14).

---

## ✅ 2026-06-12 (later) — Sustained-churn stranded-candidate fixed (RC-A: inbound-pool aggregate starvation; accept-time clocks + independent sweeper)

### Symptom (v0.6.27-5-gd84cb40 k8s, three back-to-back 4-kill rounds)

Round A reconverged instantly, round B at ~iter 20, round C stranded geode-0 as a
candidate at the 2/3 quorum's term 14 for 70 s+. The 2/3 quorum stayed healthy and
committed writes throughout; a pod roll of geode-0 rejoined it. Monotonic recovery
degradation across rounds — distinct from the single-burst case (`3466751`, which
recovered cleanly).

### Root cause RC-A (`src/distributed/cluster.zig`) — inbound-pool aggregate starvation

The cluster inbound connection pool has **4 workers**. Each accepted connection pinned
one worker for its lifetime inside `handleQuicConnection`. The existing 30 s idle-reap
ran **inside** the pinned worker's loop with `last_activity` stamped at
worker-ACQUISITION time, not at accept time. A zombie connection queued but not yet
picked up (worker unavailable) **never started its reap clock** — it sat in the queue
indefinitely. Four kills in rapid succession accumulated 4+ zombies; successive kill
rounds accumulated them faster than the 4×30 s drain (backlog carried across rounds =
the monotonic signature). With all 4 workers occupied by zombies, the node's only path
to `raft.handleMessage` was starved — it never saw the leader's AppendEntries and never
reached `node.zig:937` (the raft lib's sole same-term candidate step-down). A
discrete-event model predicted 87–180 s starvation from exactly 12 kills; the single
4-kill burst fits the 4-worker pool exactly (matching "single burst recovers cleanly").

### Fix (commits `42c319e9` + `65a5c668`)

**Accept-time idle clocks + independent sweeper** (`42c319e9`): on `accept()` each
connection is registered in `InboundConnRecord` with `accepted_ms` stamped at that
moment. A sweeper fires off `healthLoop` every ~1 s, independent of the worker pool —
it inspects every registered connection (queued AND pinned) via a per-conn atomic and
flags zombies that have been idle longer than the reap budget. The pinned worker polls
the atomic on its ~200 µs heartbeat and unwinds. The sweeper never touches QUIC state
directly (no UAF). `inboundReapCountForCapacity` / `freshActiveConnServiceableWithin`
are the pure decision surface — the latter bounds fresh-connection service budget to
1000 ms (well under any election timeout). RC1 30 s idle semantics preserved.

### Evidence

- `zig build test-raft-inbound-pool-occupancy` **8/8** (was 8 RED) — new suite pins
  the accept-time clock and sweeper behaviour under sustained churn.
- Existing suites unchanged green: receiver-reap 6/6, rebuild-probation 6/6,
  follower-response-eviction 10/10, stall-detector 22/22, raft-apply 28/28,
  cluster-replicable-mutations 7/7, steady-state shards all green.
- **netns M9 NEW sustained-churn phase** (3 back-to-back 4-kill rounds, no settle
  between): 1 leader + 2 followers `term=10`, write replicated 3/3. **PASS**.

### RC-B noted (defense-in-depth, lib follow-up — not required for this fix)

The raft lib's only same-term candidate step-down is inbound `AppendEntries`
(`node.zig:937`). Pre-vote denials from a quorum (`node.zig:837-854`) carry no
live-leader signal, so a candidate denied quorum pre-votes remains in the election loop
indefinitely without a direct delivery path. This is a defense-in-depth gap that
becomes visible when the delivery path (the inbound pool) is restored — the fix above
re-establishes that path, making RC-B non-urgent. An issue has been filed against
`devnw/zig/raft` (see below) proposing etcd-style candidate demotion on quorum
pre-vote rejections or a denial response carrying `leader_id`/`term`.

### Owed

- **Real k8s arda re-validation** — sustained churn (3+ back-to-back rounds) → 3/3
  reconverges, no monotonic degradation. Commit the next stable release build and
  re-run the arda churn sequence.
- **Committed-write client-`Timeout` idempotency residual** — unchanged, still open.
