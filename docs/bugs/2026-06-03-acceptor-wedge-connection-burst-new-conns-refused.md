# Bug: stream-acceptor / accept-path **wedge** under connection-burst — new QUIC connections refused (≫30 s) until pod restart

**Status:** **AUTO-RECOVERY SHIPPED (2026-06-05) — the no-auto-recovery OUTAGE
is resolved; the underlying wedge can still occur (root quic `Endpoint.mu`
contention OPEN).** Three layers now apply:

1. **Amplifier fixed** (`303c9d38`, v0.6.17+): the 30 s owner-thread bail that
   pinned capped concurrency slots while a wedged acceptor was waited out.
2. **geode-side self-heal** (`7264eaba`, §9 — verified 2026-06-05): an rx_queue
   watchdog on the metrics loop self-restarts the pod (`exit 70`) when the
   `:3141` UDP `rx_queue` stays ≥ 8 MiB for ≥ 30 s. Triage confirmed it covers
   the documented 12.6 MB compound-burst re-occurrence (threshold 8 MiB <
   12,648,409 B; sampled every ~5 s → fires within ~30–35 s), the
   `/proc/net/udp` parser is unit-tested against the exact wedged row
   (port `0x0C45`, rx `0x00C103D9`), and 8/8 watchdog tests pass
   (`zig build test-acceptor-watchdog`). Env-tunable via
   `GEODE_ACCEPTOR_WATCHDOG_RX_BYTES` / `_DEADLINE_MS` / `_DISABLE`.
3. **k8s probe detection** (`divelife-argo 2205c22`, §8): a real QUIC
   round-trip (`RETURN 1`) liveness/readiness probe so kubelet restarts a
   wedged-but-Running pod independently of the watchdog.

What remains OPEN: the residual upstream `Endpoint.mu` poll-vs-acceptStream
contention **can still wedge the acceptor under sufficiently heavy burst**
(confirmed on v0.6.19 2026-06-05). Layers 2+3 turn that wedge from a
manual-`kubectl delete pod` outage into an automatic ~30–60 s self-restart;
they do not eliminate the wedge itself. Eliminating it requires reworking the
quic dependency's poll-vs-accept locking (§7) — tracked separately. See §2b
(2026-06-05 evidence), §8 (probe), and §9 (watchdog).

---

## Resolution (geode-side amplifier fixed)

**Mechanism (geode-level):** `shutdownAcceptorOwner` (`src/server/quic_connection_handler.zig`)
runs on the first-stream **owner** thread — a *capped* stream-pool worker /
first-stream detach-gate slot. When the per-connection acceptor wedges (blocked
inside the QUIC library, never observing `ctx.shutdown`), the owner used to wait
**30 s** for it before deferring to the leaked-conn reaper, pinning that capped
slot the entire time. A burst of closing+wedged connections exhausts the
pool/gate, so NEW connections can no longer be admitted → `transport dial …
timeout: no recent network activity` until a pod restart. The inline test comment
at the old code (`"main accept loop starved on ep.mu"`, 2026-04-28) already
recorded this amplifier.

**Fix:** cap the owner-side wait at a short, env-tunable **bail deadline**
(default **1 s**, override `GEODE_ACCEPTOR_BAIL_MS`, clamped to [50 ms, 60 s])
and defer the still-wedged connection to the **already-safe** leaked-conn reaper
(the `86d58fdb` UAF-safe path). A healthy acceptor exits in ≤100 ms
(`server_handler_wait_for_poll_ns`), so normal closes are unaffected; only
genuinely-wedged acceptors hit the deadline, and they now free the capped slot
**~30x faster**. The accept path therefore survives a connection-burst instead of
starving, and the reaper reclaims each wedged conn once its acceptor finally
exits (or at the QUIC idle timeout) — i.e. recovery is automatic, no pod restart.

**Wait loop extracted** to a pure, unit-testable `waitForAcceptorExit`; env parse
is the pure `parseAcceptorBailMs`. Regression cover: inline tests in
`src/server/quic_connection_handler.zig` ("acceptor bail deadline: …") and the
focused `zig build test-acceptor-bail` step — pinning (a) a wedged acceptor bails
within the short deadline (not 30 s), (b) a timely acceptor exit does NOT bail,
(c) the default stays short + env parse clamps (guard against reverting to 30 s).

**Residual (upstream):** under extreme burst the QUIC-library `Endpoint.mu`
contention between the poll thread (`ep.pollWithStats`, delivering new Initials)
and per-connection `api.acceptStream` can still slow handshakes; eliminating that
needs poll sharding / lock-splitting in the `quic` dependency (documented in
`pollLoop`). The geode-side fix removes the worker-starvation amplifier that
turned that contention into a hard, restart-only outage.

---

**Original status:** OPEN — reported 2026-06-03 from `divelife-qa`.

**Relationship to the resolved crash report:** This is the **still-open root
trigger** behind
[`2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md`](./2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md).
That report's §0 **RESOLVED** fix (`86d58fdb`, in **v0.6.15 / v0.6.16**) makes
the 30 s acceptor-bail path **memory-safe** — it defers `conn_state` teardown
to the leaked-conn reaper instead of freeing under a live acceptor, so the
downstream `@memcpy`-alias / `recovery.onPacketSent` corruption can no longer
fire. **It does NOT prevent the acceptor from wedging in the first place.** The
crash doc's own Verification note says the repro reproduced "the **wedge**
precursor — `proto_reader` stall ≫ 30 s — but not the fatal corruption," and §3
records the only "stable" state as "a server that had been up long enough to be
*wedged but not yet crashed* — new connections hung." That wedge is this bug.

On **0.6.16** the symptom therefore changes from *crash* → *hang*: instead of
SIGSEGV-ing, geode stays `1/1 Running` but **silently stops accepting new QUIC
connections** under a connection-burst, leaking the wedged connections and
recovering only at the QUIC idle timeout or a **pod restart**.

---

## 1. Symptom

Under a burst of concurrent QUIC handshakes + close-churn (an application
connection pool warming up, a pod-restart storm, or a load/e2e run), the
stream-acceptor wedges:

- The server keeps existing connections alive but **refuses new ones**. Fresh
  clients fail the QUIC handshake with `transport dial to
  geode…:3141: timeout: no recent network activity`.
- `geode-0` does **not** restart or crash (on 0.6.16) — `kubectl get pod`
  shows `1/1 Running`, restart count unchanged.
- The server logs the stall and explicitly tells the operator to restart:
  `main.zig:2291` → `"proto_reader stall detected: idle_ms={d}
  pending_handlers={d} (handlers wedged downstream of
  BufferedProtoReader.nextMessage; restart pod to recover)"`, and the
  per-stream line `"per-stream proto_reader stall: stream_id=… idle_ms=…
  (this stream wedged while others may still be progressing; restart pod or
  wait for client retry)"`.
- There is **no automatic recovery** — "restart pod to recover" is the
  documented remedy in the log string itself.

## 2. Observed on divelife-qa (2026-06-03)

Single-node geode StatefulSet, image `geodedb/geode:0.6.14` (pre-fix; same
acceptor/accept code paths are present unchanged at HEAD `54cecd24` / v0.6.16 —
`quic_connection_handler.zig` acceptor-bail + `main.zig:2291` stall log +
`quic_connection_handler.zig:7016` *"stuck acceptor wedged the
connection-handler thread forever"*).

1. **Initial wedge (long-lived):** `geode-0` had a `per-stream proto_reader
   stall … idle_ms=47056635` (~13 h). Every `divelife-api` / `divelife-pds`
   pod was in `CrashLoopBackOff` with `transport dial … timeout: no recent
   network activity` — the server was up but not accepting. (On this 0.6.14
   image it had also previously been hitting the now-fixed
   `sendExecuteError` SIGSEGV; restart count 76.)
2. **A pod restart cleared it:** deleting `geode-0` let it come up fresh
   (`QUIC transport listening`, `server ready`), after which `api`/`pds`
   handshakes succeeded and the api booted `1/1` (`/healthz` →
   `{"geode":"ok"}`). So a freshly-started server is fine **until** the next
   burst.
3. **Re-wedged under load within ~45 min:** running the application's
   Playwright e2e suite (multiple workers → the api's geode connection pool
   issuing concurrent first-stream handshakes + error-bearing queries)
   re-wedged the accept path. `geode-0` stayed `1/1 Running` (no restart, no
   crash) but again refused new handshakes — `api` dropped to `0/1` and `pds`
   returned to `CrashLoopBackOff`, both with the same `dial … timeout`.
   Restarting `geode-0` again recovered the whole stack.

The **lower-fanout client survives, the higher-fanout one trips it** pattern
from the crash report holds: `pds` (fewer conns) rode out longer than `api`
(pool + worker + healthz conns handshaking together).

## 2b. 2026-06-05 — re-occurrence on v0.6.19 (geode-side bail-deadline fix shipped)

**Image:** `geodedb/geode:0.6.19` (includes `303c9d38` — bail capped at 1 s).

**Trigger combination (compound burst):**

- Three `qa-seed` Kubernetes Jobs ran simultaneously (a dkron-bootstrap cron
  triggered them all at once). Each job opens its own geode connection pool.
- Two `divelife-api` + two `divelife-pds` pods were already in
  `CrashLoopBackOff` with exponential back-off retrying connections — each
  retry attempt opens a QUIC handshake.
- Combined: ~5+ connection-burst sources simultaneously → `Endpoint.mu`
  contention overwhelmed the shortened (1 s) bail path.

**Observed symptoms:**

- `geode-0` stayed `1/1 Running`, restart count unchanged — **no automatic
  recovery**.
- Both `divelife-api` (27 restarts) and both `divelife-pds` pods (27
  restarts) in `CrashLoopBackOff` with `geodex open: geode: transport dial
  to geode.divelife-qa.svc.cluster.local:3141: timeout: no recent network
  activity`.
- `/proc/net/udp` **rx_queue for port 3141 (0x0C45): `0x00C103D9` =
  12,648,409 bytes (~12 MB)** — the UDP socket buffer filled to capacity
  with unprocessed QUIC Initial packets the wedged acceptor was not
  draining.
- The existing liveness probe (`grep -q ":0C45 " /proc/net/udp`) **passed**
  throughout, so kubelet never triggered an automatic restart.

**Recovery steps taken:**

1. Deleted the 3 running qa-seed jobs (`kubectl delete jobs ...`).
2. `kubectl delete pod geode-0 -n divelife-qa` — forced geode restart.
3. `kubectl rollout restart deployment/api deployment/pds -n divelife-qa` —
   cleared the CrashLoopBackOff back-off timer.
4. Verified with `geode query --server localhost:3141 --insecure-tls-skip-verify
   -U geode -P "$GEODE_ADMIN_PASSWORD" --timeout 5 "RETURN 1"` from inside
   the pod before declaring healthy.

**Time to recovery:** ~3–4 minutes from manual detection to all pods `1/1`.

**Why the bail-deadline fix didn't prevent it:** `303c9d38` removes the
**worker-starvation amplifier** (30 s → 1 s) that turned moderate burst into
a hard outage. Under the 2026-06-05 burst (3 seed jobs + 4 crashlooping
pods retrying simultaneously), the QUIC-library `Endpoint.mu` contention was
extreme enough that new connections timed out before any freed slot could
service them — the amplifier was shorter, but the underlying lock contention
still fully saturated the accept path.

**rx_queue diagnostic** (run from inside the geode pod):

```sh
kubectl exec -n <namespace> geode-0 -- \
  awk '/[0-9A-Fa-f]+:0C45[[:space:]]/{split($5,a,":");
       printf "rx_queue: 0x%s = %d bytes\n", a[2], ("0x"a[2])+0}' \
  /proc/net/udp
```

Normal (healthy): rx_queue = 0–~4096 bytes.
Wedged: rx_queue grows to megabytes as unprocessed Initials back up.

---

## 3. Why this matters independently of the crash fix

- It makes geode **unavailable for new connections** under exactly the loads a
  production deployment generates: connection-pool warmup, HPA scale-up /
  rolling restart, and any concurrency spike. A leaked-but-running server that
  never accepts again is, operationally, down — and needs a manual pod restart.
- It **blocks the QA e2e suite**: any multi-worker run re-wedges the single
  node, so the run can't get a clean signal. (This is the immediate blocker:
  full-suite e2e against QA cannot pass until the accept path survives a
  connection-burst, even on 0.6.16 where it no longer crashes.)
- Clustering (0.6.16) does not by itself fix this: a wedged accept path on each
  node is still a per-node availability hole; under burst, nodes can wedge
  independently.

## 4. Mechanism (from the resolved crash report's root-cause analysis)

`handleQuicConnection`'s stream-acceptor can block in `tryAcceptStream` /
`Endpoint.mu` contention under a connection-burst + close-churn. When
`shutdownAcceptorOwner` then waits up to **30 s** for the acceptor to exit and
it does not, the bail path logs *"acceptor wait deadline exceeded; leaking conn
to avoid UAF"*, registers the connection with the leaked-conn reaper, and
returns. The `86d58fdb` fix makes that bail **safe** (defers teardown to the
reaper after `acceptor_ctx.done` instead of freeing under the live acceptor),
but the acceptor is **still wedged** — so the connection-handler thread / accept
path stays stuck and new Initials are not serviced. `quic_connection_handler.zig:7016`
documents this directly: *"stuck acceptor wedged the connection-handler thread
forever."*

The underlying contention (acceptor blocked in `tryAcceptStream` / holding or
waiting on `Endpoint.mu` while a per-connection stream is stalled downstream of
`BufferedProtoReader.nextMessage`) is what needs fixing — not just the teardown
safety around it.

## 5. Reproduction sketch (for the geode team)

1. Start a single geode node (`v0.6.16`), TLS on, QUIC `:3141`.
2. Drive a **connection-burst**: open a pool of ~8–16 connections that each
   open a first stream and issue a query the server errors on (e.g. a
   duplicate DDL / failing evaluation), plus a few short-lived conns that
   close mid-handshake (close-churn). A faithful trigger is the
   `divelife-api` boot (pool + worker + healthz conns + a schema-apply) or a
   Playwright e2e multi-worker run against the api.
3. Optionally add `tc netem` 10 % loss (the crash report reproduced the wedge
   precursor this way).
4. **Expect:** within minutes, `proto_reader stall detected … restart pod to
   recover` in the logs, the acceptor wedged, and **new** `connect()`s failing
   with `timeout: no recent network activity` while **existing** connections
   keep working. The process stays up (0.6.16); no crash.

## 6. Suggested investigation / fix directions

- Make the accept hot path **non-blocking / bounded with backpressure** so a
  single stalled per-connection stream (or `Endpoint.mu` contention) cannot
  starve `tryAcceptStream` for the whole endpoint. New-connection acceptance
  should be isolated from per-connection stream progress.
- Reduce `Endpoint.mu` hold time on the accept path (or split the lock) so a
  burst of Initials + concurrent stream churn doesn't serialize behind a
  wedged handler.
- Add an **acceptor watchdog** that, on the 30 s deadline, *recreates/resets*
  the acceptor (or the endpoint's accept loop) rather than only leaking the
  one connection and leaving the accept path dead — i.e. make recovery
  automatic instead of "restart pod to recover."
- Bound `proto_reader` per-stream stalls with a deadline that frees the stream
  and releases whatever the acceptor is contending on, so a wedged downstream
  handler self-heals.

## 7. Cross-references

- [`2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md`](./2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md)
  — RESOLVED crash (`86d58fdb`, v0.6.15/v0.6.16); this wedge is its un-fixed
  precursor.
- `src/server/main.zig:2291` — the `proto_reader stall detected … restart pod
  to recover` log.
- `src/server/quic_connection_handler.zig:7016` — *"stuck acceptor wedged the
  connection-handler thread forever"*; the acceptor-bail / leaked-conn-reaper
  path.
- GAP-0838 (cluster TLS) — the active QUIC/TLS hardening line this belongs near.

---

## 8. K8s liveness probe detection gap and operational fix

### The gap

The standard Kubernetes liveness probe for geode checks only that the UDP
socket is bound:

```yaml
livenessProbe:
  exec:
    command: ["/bin/sh", "-c", "grep -q ':0C45 ' /proc/net/udp"]
```

**This probe passes even when the QUIC acceptor is fully wedged.** The UDP
socket stays bound (geode does not close it when wedged) so `/proc/net/udp`
always shows port 3141. Kubelet never sees a liveness failure and never
triggers an automatic pod restart — the pod stays `1/1 Running` with a 12 MB
rx_queue and refuses every new connection indefinitely.

This is why the 2026-06-03 and 2026-06-05 incidents required manual
intervention (`kubectl delete pod geode-0`).

### The fix (divelife-argo `2205c22`, 2026-06-05)

Replace the liveness and readiness probes with an actual QUIC round-trip
that fails when the acceptor is wedged:

```yaml
# Startup: keep the cheap UDP-bind check — geode isn't ready to serve
# queries yet during initial boot.
startupProbe:
  exec:
    command: ["/bin/sh", "-c", "grep -q ':0C45 ' /proc/net/udp"]
  periodSeconds: 5
  failureThreshold: 30
  timeoutSeconds: 3

# Liveness: QUIC round-trip — fails if the acceptor is wedged.
livenessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - 'geode query --server localhost:3141 --insecure-tls-skip-verify
         -U geode -P "$GEODE_ADMIN_PASSWORD" --timeout 5 "RETURN 1" > /dev/null'
  periodSeconds: 15
  failureThreshold: 4   # restart after ~60 s wedged
  timeoutSeconds: 8     # outer timeout > --timeout 5 so the query fails first

# Readiness: same — removes pod from load-balancer within ~20 s.
readinessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - 'geode query --server localhost:3141 --insecure-tls-skip-verify
         -U geode -P "$GEODE_ADMIN_PASSWORD" --timeout 5 "RETURN 1" > /dev/null'
  periodSeconds: 10
  failureThreshold: 2
  timeoutSeconds: 8
```

**Why this works:** `geode query --server localhost:3141 ... --timeout 5` opens
a new QUIC connection to the local server. If the QUIC acceptor is wedged,
`Endpoint.acceptStream` never returns → the 5 s `--timeout` fires → the command
exits non-zero → probe fails. After `failureThreshold` consecutive failures
kubelet restarts the pod, clearing the wedge automatically.

**Why `--insecure-tls-skip-verify`:** the probe runs inside the container
against `localhost`. The server certificate covers the in-cluster Service DNS
(`geode.divelife-qa.svc.cluster.local`), not `localhost`, so TLS verification
would fail for a different reason. Skip-verify is safe for a same-pod exec
probe because the network path is the loopback interface — no third party can
intercept it.

**Secret expansion:** `$GEODE_ADMIN_PASSWORD` expands inside the `/bin/sh -c`
wrapper because the pod's env var is already in scope. No additional secret
mounts are needed.

### Recommended geode documentation / release note

For any k8s deployment guide or Helm chart: document that the default probe
(`/proc/net/udp` bind check) does not detect the QUIC acceptor wedge, and
provide the `geode query --timeout 5 "RETURN 1"` probe pattern as the
recommended liveness/readiness check.

### Verify the probe works

1. Apply the updated StatefulSet / Helm values.
2. Confirm `kubectl describe pod geode-0` shows the new liveness probe.
3. Simulate a wedge (or wait for a burst) — after at most 4×15 = 60 s the
   liveness probe fails and kubelet restarts the pod automatically.
4. After restart, run inside the pod to confirm QUIC is healthy:

   ```sh
   geode query --server localhost:3141 --insecure-tls-skip-verify \
     -U geode -P "$GEODE_ADMIN_PASSWORD" --timeout 5 "RETURN 1"
   ```

   Expected: `{"rows":[{"expr":1}],...}` with exit code 0.

---

## 9. Geode-side auto-recovery — accept-path wedge watchdog (FIXED)

The k8s probe (§8) is the deployment-side detector. geode now also **self-heals
without depending on the probe**: a watchdog on the existing 5 s metrics-loop
tick samples the listener UDP socket's `rx_queue` depth (the same
`/proc/net/udp` signal as §2b's diagnostic). A healthy acceptor keeps rx_queue
at 0–few KB; a wedged one lets it grow to megabytes and never recede. When
rx_queue stays **continuously at/above a threshold for longer than a deadline**,
geode logs a loud `ACCEPTOR WEDGE: …` line and performs a controlled
`std.process.exit(70)`, so the Kubernetes `restartPolicy` restarts the pod
automatically — converting the silent, manual-`kubectl delete pod` outage into
automatic recovery within the deadline.

- **Module:** `src/server/acceptor_watchdog.zig` — pure, unit-tested
  `parseUdpRxQueueBytes` (find the listener's rx_queue row in `/proc/net/udp`),
  `parseConfig` (env), and `WedgeTracker.update` (the streak/deadline decision,
  time injected). The single side effect (read `/proc/net/udp`; exit) lives in
  the `main.zig` metrics loop. Mirrors the existing
  `parseAcceptorBailMs` / `waitForAcceptorExit` split.
- **Tuning (env):** `GEODE_ACCEPTOR_WATCHDOG_RX_BYTES` (default 8 MiB —
  far above any transient burst, well below the observed ~12.6 MB wedge),
  `GEODE_ACCEPTOR_WATCHDOG_DEADLINE_MS` (default 30 000, clamped
  [1 000, 600 000]), `GEODE_ACCEPTOR_WATCHDOG_DISABLE=1` to opt out.
- **Scope:** Linux-only (reads `/proc/net/udp`); a no-op elsewhere and when the
  listener port can't be resolved. It does **not** fix the upstream
  `Endpoint.mu` contention that *causes* the wedge (that remains a `quic`
  dependency fix — §6) — it makes recovery automatic so the wedge is no longer a
  restart-only outage. Tests: `zig build test-acceptor-watchdog`.

## 9. Fix (partial, geode-side): bound the `drainPendingDestroy` `ep.mu` hold (2026-06-14)

Implements §6 bullet 2 ("reduce `Endpoint.mu` hold time on the accept path") for
the one `ep.mu`-hold source that lives in **geode** rather than the vendored
`quic` lib.

**Root-cause refinement.** The accept loop (`src/server/main.zig` serve loop)
calls `QuicTransport.drainPendingDestroy()` every iteration. That function
acquired `ep.mu` (which the vendored poll path — `ep.pollWithStats`, the thing
that actually drains the listener UDP socket — also acquires; see the GAP-0203
comment at the `ep.mu` lock) and then looped over the **entire**
`pending_destroy` backlog calling `api.destroy(ep, conn)` for each. Under the
sustained-churn signature (rapid leader-kill / reschedule storms) the backlog
reaches thousands, so a single drain parked **every** poll worker on `ep.mu` for
the whole batch — the listener `rx_queue` then backed up to MiB (the wedge),
AppendEntries stopped being accepted, and the candidate froze.

**Fix.** `src/transport/quic.zig`: cap the per-call batch
(`drain_pending_destroy_batch`, default 64; `0` = unbounded/pre-fix; tunable at
runtime via `GEODE_QUIC_DESTROY_BATCH` for k8s churn validation without a
rebuild). drainPendingDestroy now processes at most that many destroys per call
and keeps the remainder; the accept loop's existing slot-freed wake re-enters it
within the ≤5 ms admission park, so a backlog is reaped across cycles at far
above the churn rate while `ep.mu` is never held more than ~`batch` `api.destroy`
calls. The split is a pure, unit-tested helper (`drainBatchSplit`, inline test in
`quic.zig`).

**Status.** Addresses the geode-side `ep.mu`-hold contributor only. The
poll-vs-`tryAcceptStream` contention and per-stream-stall amplifier (§6 bullets
1 and 4, upstream `quic`) can still wedge under extreme burst. Compiles +
existing transport regressions green (`test-perf-d-admission-wake`,
`test-quic-streams`, `test-quic-pollsync-wake`); **wedge-efficacy validation is
owed on the k8s sustained-churn repro** (local netns repro is blocked by an
unrelated cluster-TLS sync failure). The acceptor watchdog (§8) remains the
backstop until the upstream pieces land.

## 10. Fix (root cause, lib-side): O(N)→O(keys) batch connection teardown (2026-06-14)

§9 capped the *backlog* factor of the `ep.mu` hold; this closes the **other,
dominant factor** and supersedes §9's "upstream piece owed" status.

**Root cause (measured, not assumed).** The vendored `quic` poll/accept paths
are already well-architected — lock-free socket recv, narrow per-datagram global
locks (mu released between datagrams), a per-slot short-header route cache, and a
lock-free futex accept-wait. The one thing that held `ep.mu` long enough to
starve the 16 poll workers was **`api.destroy`** (`quic/src/quic/api.zig`): to
evict a connection it did a **linear scan of the entire connection map, repeated
once per CID** the connection held (`while (true) { iterate conns; remove }`).
geode's `drainPendingDestroy` ran that per-connection under `ep.mu`, so draining
a churn backlog of `B` connections from a map of `N` entries was **O(B × N)
under the lock**. That is what wedged the listener `rx_queue`.

**Fix.** `devnw/zig/quic` **v0.1.27** (`2e66508`): `Endpoint.destroyConnections`
/ `api.destroyBatch` mark every batch member `endpoint_destroying` (which drains
in-flight RX refs), then evict **all** their map keys in **one O(N + keys)
sweep**, drop them from `accepted`/`retired` in one pass each, and free them.
Exhaustive-removal semantics are identical to the old per-conn scan (every map
entry whose owner is a batch member is removed before any free → no dangling
pointer); OOM falls back to the per-conn scan. `api.destroy` now delegates to the
single-element batch. Regression test `REQ-QUIC-HC-099` in the lib
(`test_endpoint_pto_handshake_uaf_regression.zig`).

geode (`src/transport/quic.zig`): `drainPendingDestroy` now removes the per-conn
side-set entries for the whole batch, then calls `api.destroyBatch(ep, doomed)`
**once**. Combined with the §9 batch bound, the per-call `ep.mu` hold is now
O(`batch` + N) with `batch ≤ 64`, and the O(N) **per-destroy** multiplier — the
real killer — is gone entirely. `build.zig.zon` bumped to quic v0.1.27.

**Validation.** Lib `zig build test` green incl. the new test (3/3 in
`test_pto_uaf`); geode builds against v0.1.27 and the transport regressions pass
(`test-quic-streams`, `test-quic-pollsync-wake`, `test-perf-d-admission-wake` —
15/15 steps, 10/10 tests). **Wedge-efficacy under the k8s sustained-churn repro
(arda geode-qa) is still owed** before push — staged per the cluster-change
discipline (commit local, validate on k8s, then push the quic tag + the geode
bump together). The acceptor watchdog (§8) remains the backstop until then.

## 11. Local e2e validation (netns, 2026-06-14) — no-regression confirmed; wedge needs k8s scale

Attempted the local cluster-churn repro on the fixed binary. The netns test
(`tests/cluster/netns_cluster_membership_churn_test.sh`) was previously blocked
at M1 by the GAP-0838-class verified inter-node TLS handshake bug (node3 couldn't
backfill). **Routing around it with `GEODE_CLUSTER_INSECURE=1` (debug-only) on the
node launch unblocks M1** — confirming that blocker *was* the TLS bug, not a
backfill defect:

```
# in a copy of the test, swap the launch env: GEODE_CLUSTER_CA_CERT="$WORK/ca.crt" -> GEODE_CLUSTER_INSECURE=1
sudo PHASES="M1 M2" NETNS_TEST_WORK=/tmp/... bash <copy> <fixed-binary>
#  PASS M1a: late node backfilled M1pre   PASS M1b: post-join write replicated to node3   RESULT: PASS
```

**M9 (sustained back-to-back churn = the k8s 3×4-kill signature), extended to 6
rounds (2× the documented 4th-burst wedge point), with the fixed binary
(`destroyBatch`, geode 44b0af1e):** `PASS M9: sustained 1 leader / 0 candidates +
write replicated to all 3` (term=16, healthy) — no stranded candidate, no
watchdog exit. **No regression: the fix handles sustained cluster churn cleanly.**

**Honest limit:** the pre-fix binary (`2fba2b1d`, batch-bound only) *also* passes
6 rounds at netns scale. So **netns (3 nodes) cannot reproduce the wedge** —
because the documented wedge is a `:3141` *client/acceptor* rx_queue phenomenon
under k8s-scale client churn, not the Raft `:4242` membership churn M9 drives, and
the O(B×N) destroy backlog only piles past the drain rate at the larger pod/conn
scale. This **substantiates** (rather than defers) that wedge-*prevention*
efficacy must be measured on the **arda geode-qa sustained-churn repro** at scale.
Local evidence to date: correctness unit test (REQ-QUIC-HC-099), the structural
O(B×N)→O(N+B) collapse, cross-repo build/test (geode-client-zig 422/422; geode
transport 15/15·10/10), and this netns no-regression run.

## 12. Fix (root cause, lib-side): bound the rx-queue independent of teardown — drain cap decoupled from processing budget (2026-06-14)

§9/§10 cut the **teardown** cost of the wedge (O(B×N)→O(N+B) `destroyBatch`,
bounded `drainPendingDestroy`), but the decisive arda re-validation of that build
(`v0.6.27-28-g4986ef2d`, see the raft-quorum bug doc's matching dated section)
showed the wedge **still fires at k8s scale** — `destroyBatch` reduced teardown
cost but **did not bound the rx-queue growth itself**. Pushing past it (5×4-kill
bursts) also fell into a no-leader all-candidate livelock (the raft RC-B half,
fixed separately in `devnw/zig/raft` v0.1.8). This closes the transport half.

**Root cause (measured against the vendored `quic` poll loop).** `pollWithStats`
(`quic/src/quic/endpoint.zig`) used a **single master cap**
(`maxPacketsPerPollCycleForRole`, server = `UdpBatchCap*4` = 256) for BOTH how
many datagrams it *read* from the socket AND how many Initials it *processed*.
The "shed surplus Initials" fast path (read-and-discard; client PTO retransmits)
was designed to keep draining the kernel socket cheaply past the expensive
Initial-processing budget — but because the Initial processing budget *equalled*
the master read cap, **the loop stopped reading at the exact point it stopped
processing, so the shed path never ran**. Under a connection-kill / reconnect
storm (slow handshakes → client PTO retransmits → more Initials → positive
feedback), each poll cycle processed 256 expensive Initials and then *stopped
reading*, leaving the rest in the kernel FIFO. The `:3141` UDP `rx_queue` backed
up to the 8 MiB / 30 s geode acceptor-watchdog threshold → `exit(70)`.

**Fix.** `devnw/zig/quic` **v0.1.28** (`8ed9425`): add
`maxSocketDrainPacketsForRole` — a separate, larger **server socket-DRAIN cap**
(default `UdpBatchCap*64` = 4096, enough to drain a full 16 MiB `SO_RCVBUF` in a
couple of cycles) used as the master read cap; the Initial/short-header
**processing** budgets are unchanged. Surplus Initials beyond the processing
budget are now cheaply **shed**, so the kernel rx_queue drains **independent of
how much expensive processing — or teardown — the cycle can afford**. Client
behaviour is unchanged (one-batch fairness budget). Runtime-tunable for k8s churn
validation without a rebuild via `setServerSocketDrainPackets` (geode
`GEODE_QUIC_DRAIN_PACKETS`, wired in `main.zig`). Regression
`tests/test_acceptor_drain_budget.zig` (RED when drain cap == processing budget).

**Validation.** quic lib: `zig build test` green, targeted
`-Dtest-filter=acceptor_drain_budget` 2/2 (RED→GREEN proven by reverting the cap
to equal the processing budget), pto-handshake-uaf (§10 test) green. geode builds
against v0.1.28; transport regressions green (`test-quic-streams`,
`test-quic-pollsync-wake`, `test-perf-d-admission-wake`, `test-acceptor-watchdog`,
`test-acceptor-bail`). **Wedge-prevention efficacy under the arda k8s sustained-churn
repro is still owed** before push — staged per the cluster-change discipline
(commit local, validate on k8s, then push the quic+raft tags + the geode bump
together). The acceptor watchdog (§9) remains the backstop until then.
