# Bug: stream-acceptor / accept-path **wedge** under connection-burst — new QUIC connections refused (≫30 s) until pod restart

**Status:** **MITIGATED (geode-side) 2026-06-03.** The dominant geode-level
amplifier — the 30 s owner-thread bail that pins capped concurrency slots while a
wedged acceptor is waited out — is fixed (see *Resolution* below). The deepest
root cause (QUIC-library `Endpoint.mu` poll-vs-acceptStream contention) is a
documented **upstream** concern (`pollLoop` notes "deeper sharding requires
upstream QUIC-library changes"); it is out of scope for a geode patch and tracked
separately.

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
