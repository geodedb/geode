# geode 3-node k8s Raft cluster elects a leader but can't hold quorum or replicate (writes time out)

**Date:** 2026-06-04
**Image:** `geodedb/geode:0.6.19` (commit `e7e447e4` — contains the GAP-0838 election fixes AND the cert-honoring fix from `docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md`)
**Environment:** arda cluster (`company.arda-ca.net`, bare-metal/flannel VXLAN MTU 1450, `local-path` PVC storage), namespace `geode-qa`, real 3-replica `StatefulSet`, `podManagementPolicy: Parallel`, headless-service FQDN peers, cert-manager CA-signed cluster cert, `GEODE_CLUSTER_TOKEN` + `GEODE_AUTH_HMAC_KEY` from Vault, `GEODE_CLUSTER_CA_CERT` pinned to a `CA:TRUE` anchor, CPU 2000m req / 4000m limit per pod.
**Severity:** **BLOCKER** for distributed/clustered mode on Kubernetes. The cluster forms a leader but is not usable: no stable quorum, no replicated writes.
**Relationship to prior bugs:** This is the *next* failure after the TLS layer is fixed. With 0.6.19 (`--cert` honored), space-separated flags (geode's parser ignores `--flag=value` — see note below), and a proper `CA:TRUE` trust anchor, peers now complete the QUIC/TLS handshake and **a leader is elected** (term advances past 0, `state=leader`/`state=follower` observed at term 1–3). The remaining defect is in the **Raft consensus / transport layer itself**, above TLS.

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

### Root cause #2 — graph writes bypass Raft entirely (the "no replication" defect)

`executeCreate` / `CreateGraph` write directly to the local graph store; `ClusterCoordinator.proposeWrite` had **zero non-test callers** (the propose path was disabled at the executor). Confirmed locally with a healthy 3-node cluster: `CREATE (:ReplTest {v:1})` on the leader returns success (exit 0 — **not** a hang) and the row appears only on the leader (`count=1`), never on followers (`count=0`). The Raft apply path (`raft_apply.applyGraphMutation`) was an **MVP skeleton** (`create` → an *unlabelled* node with raw bytes in a `_raft_data` property; `delete`/`update`/`merge` unimplemented). So replication was not merely "disabled" — the replicated state machine for graph data did not exist. (The doc's "CREATE hangs / exit 124" was the real-k8s no-stable-leader case; with a stable leader the local write returns immediately.) **Being addressed** — see the replication commit that follows: writes route through `proposeWrite` → ordered deterministic apply on every node.

### Root cause #3 — leader-flap under CPU pressure (transport architecture)

Did NOT reproduce on a healthy single host (leader held). The transport is fragile under contention: a **single** outbox drain thread serializes every peer send behind a blocking `waitForHandshake(1)` (`raft_consensus.zig:902`; inconsistent with `cluster.zig`'s 10s), evicts the cached connection on any transient send error (`:733`/`:743`), never calls the dead `preconnectPeer` (`:673`), and opens one QUIC stream per RPC. Under CPU contention a slow handshake to one peer starves heartbeats to **all** peers → followers time out → flap. **Naively raising the 1s timeout would worsen this** (the single thread blocks longer); the correct fix is to stop serializing sends behind blocking handshakes (eager preconnect + async connect + per-peer dispatch + no evict-on-transient). Scoped as a follow-up — unreproducible/unverifiable on a single healthy host.
