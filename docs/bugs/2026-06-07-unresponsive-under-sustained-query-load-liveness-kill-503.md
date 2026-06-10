# Bug: geode goes unresponsive under sustained parallel **query** load → liveness-probe SIGKILL (137) → pod restart → cluster-wide API **503s**

**Status:** **PARTIALLY RESOLVED (outage mitigated; durable fix scoped) — 2026-06-07.**
The headline harm (liveness-kill → cluster-wide 503) is mitigated by the out-of-band
`/health` liveness endpoint (§9) and the new slow-poll warning makes the degradation
observable before a kill (§10). The durable QUIC-core contention fix (`Endpoint.mu`
rework + safe stream reaping) is **scoped and load-test-gated** in
`docs/superpowers/plans/2026-06-07-quic-sustained-load-liveness-kill.md` — see §10.
Originally reproduced repeatedly on `geodedb/geode:0.6.23` (single-node
QA, 2026-06-07). Under sustained parallel *read* load (≈11 concurrent QUIC
connections from one API replica + a Playwright e2e suite), geode's QUIC
event loop degrades so badly — multi-**second** per-packet processing and
60–70 s per-stream `proto_reader` stalls — that the `RETURN 1` liveness probe
times out, kubelet SIGKILLs the pod (exit **137**, reason **`Error`**, *not*
`OOMKilled`), and every geode-backed API call (including **user login**) returns
**503** for the ~30–60 s restart + reconnect window. Observed **3 restarts** in
~30 min of load. This is the *same residual* `Endpoint.mu` poll-vs-stream
contention tracked in
[2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md], but reached
by a different trigger (sustained query concurrency, not a connection burst) and
with a different terminal symptom (the **liveness probe that was added to detect
wedges now kills a busy-but-progressing pod**, amplifying load into an outage).

> **Update 2026-06-10 — STILL OPEN on latest `:dev`.** Re-confirmed on
> `geodedb/geode:dev` `sha256:24c1702a` = `v0.6.26-16-gd8c1adb` (16 commits past
> v0.6.26, byte-identical to the current registry `:dev`). Two QA databases hit
> **39** and **70** SIGKILL(137) restarts; fresh `proto_reader` stalls up to
> `idle_ms=16337061` (~4.5 h idle) and `quic_first_stream_packet_process_max_ns=1.42 s`
> under e2e load; plus a new write-path symptom (`driver: bad connection`
> mid-`batch exec`). Full latest-dev evidence:
> [2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md](2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md).

---

## 1. Symptom

A single API replica under load (the divelife-api serving the divelife-ui
Playwright e2e suite, ~2 parallel browser workers walking 1248 specs) drives
geode into a state where:

- `quic_first_stream_packet_process_max_ns = 6_146_168_138` (**6.15 s** to
  process a single QUIC packet),
- `proto_reader stall: stream_id=0 peer=10.244.2.51 idle_ms=64925 … 69925`
  (an established stream — here the **PDS** replica — wedged in `proto_reader`
  for **65–70 s**),
- `quic_first_stream_mutation_deferrals_total = 674`, `quic_active_connections = 11`,
  `quic_poll_cycle_max_ns = 171_384_918` (171 ms poll cycles).

The k8s liveness/readiness probes both run a real round-trip query:

```
geode query --server localhost:3141 --insecure-tls-skip-verify -U geode \
  -P "$GEODE_ADMIN_PASSWORD" --timeout 5 "RETURN 1"
# liveness:  timeoutSeconds=8, periodSeconds=15, failureThreshold=4
# readiness: timeoutSeconds=8, periodSeconds=10, failureThreshold=2
```

When the loop is spending seconds per packet, this `RETURN 1` cannot complete
within 8 s for 4 consecutive liveness probes (~60 s), so kubelet kills the pod:

```
lastState.terminated: exitCode=137  reason="Error"
  startedAt = 2026-06-07T14:45:43Z   finishedAt = 2026-06-07T14:55:58Z   (~10 min)
restartCount: 0 → 3   (2 of the 3 restarts occurred under e2e load on 2026-06-07)
```

`reason="Error"` (not `OOMKilled`) + **no panic / OOM / abort in the container
log** confirms this is a **liveness-probe SIGKILL of a live process**, not a
cgroup memory kill and not a crash. (Distinct from the *startup* OOM in
[2026-06-04-oom-on-startup-graph-index-load-crashloop.md], which is `OOMKilled`.)

During each restart window the API loses its geode connection and returns
**HTTP 503** to clients. Concretely, `POST /api/v1/auth/login` (and every other
geode-backed endpoint) 503'd while a human was trying to log in; the moment the
e2e load was stopped, geode stabilized and login returned 200 again (3/3).

Notably, the *post-restart* container then carried a **localhost** probe stream
wedged for the entire container lifetime:
`proto_reader stall: stream_id=0 peer=127.0.0.1 idle_ms=19_433_130` (**5.4 h**) —
i.e. a `RETURN 1` probe connection itself opened a stream that wedged and was
never reaped, even while later probes succeeded.

## 2. Trigger / how to reproduce

1. Single-node geode (`0.6.23`), one divelife-api replica connected.
2. Apply sustained parallel **read** load. Reliable repro: run the divelife-ui
   Playwright suite against QA —
   `TEST_WEB_MODE=1 BASE_URL=https://qa.divelife.org pnpm exec playwright test
   --workers=2` (1248 tests; ~11 concurrent QUIC streams incl. the API + PDS).
3. Watch `kubectl get pod geode-0 -w` and the API: within minutes geode's
   `quic_first_stream_packet_process_max_ns` climbs into the multi-second range,
   `proto_reader stall …` lines appear for established streams, the liveness
   probe starts failing, and the pod restarts (exit 137 / `Error`). API calls
   503 across the restart. It recurs every few minutes while load continues.

A connection *burst* is **not** required — steady query concurrency from a
single client is sufficient. Lowering to `--workers=1` greatly reduces (but does
not formally eliminate) the recurrence.

## 3. Impact

- **Availability, whole-DB blast radius.** A liveness-kill takes the *entire*
  single-node database offline for ~30–60 s; every API endpoint 503s. On QA this
  repeatedly knocked out interactive login during a routine e2e run.
- **Self-inflicted by legitimate load.** The load here is modest (one API
  replica + a test browser pool, ~11 QUIC conns). Real production read traffic of
  similar concurrency would trigger the same restarts.
- **Probe paradox.** The `RETURN 1` liveness probe was introduced to *recover*
  from acceptor wedges; under heavy-but-healthy load it instead *causes* outages
  by killing a pod that is slowly making progress. Detection and amplification
  share the same in-band, contended query path.

## 4. Suspected root cause

1. **QUIC event-loop / `Endpoint.mu` contention under concurrency (primary).**
   The same poll-vs-`acceptStream` lock contention documented in the acceptor-wedge
   bug serializes packet processing. Under N concurrent streams the loop head-of-line
   blocks: a single expensive packet (here 6.15 s) stalls *all* streams, including
   the localhost health-probe stream. `proto_reader` stalls of 60–70 s on
   established streams are the visible symptom.
2. **No fairness / admission shaping on the hot path.** `mutation_deferrals=674`
   and 171 ms poll cycles suggest work is queueing without backpressure or
   per-connection fairness, so one busy client can starve the control path.
3. **Health checking is in-band.** Liveness/readiness ride the *same* QUIC query
   path that is saturated, so "is the process alive?" is conflated with "is the
   query path fast right now?" — guaranteeing kills exactly when load is highest.
4. **Wedged probe streams are not reaped** (the 5.4 h localhost `stream_id=0`
   stall) — leaked health-probe streams accumulate.

## 5. Suggested fixes (geode side)

- **Make the poll loop non-blocking per packet / per stream.** Bound the work a
  single packet or stream can do inside the lock; yield between streams so one
  slow query can't stall the whole endpoint (the §7 `Endpoint.mu` rework already
  tracked for the acceptor wedge is the durable fix).
- **Provide an out-of-band, cheap liveness signal** that does not traverse the
  contended query path — e.g. a lightweight TCP/UDP health port, an HTTP
  `/healthz` on the admin listener, or a control-plane stream serviced on a
  dedicated thread — so kubelet can distinguish "process up" from "query path
  momentarily slow."
- **Per-connection fairness / admission control** on the QUIC accept+poll path so
  one client's concurrency can't starve others or the health path.
- **Reap wedged/idle streams** (incl. the leaked localhost probe `stream_id=0`),
  bounding `idle_ms` before forced close.
- **Emit an explicit "slow poll / stall" warning + metric** when
  `packet_process_ns` exceeds a threshold, so this state is observable before the
  liveness kill (today it is only inferable from the metrics dump).

## 6. Workaround (operator)

Until the geode-side fix lands, the outage is mitigated (not eliminated) by:

- **Don't run the full e2e suite against a shared/production geode at workers≥2.**
  Run it against an isolated local stack, or at `--workers=1`, or off-peak.
- **Separate liveness from readiness, and make liveness cheaper/looser.** A busy
  geode is *alive*; only readiness should gate traffic. Options in
  `divelife-argo`: raise liveness `timeoutSeconds`/`failureThreshold` substantially
  (so transient multi-second slowness doesn't kill), or point liveness at a
  cheaper check than a full `RETURN 1` round-trip. Keep readiness strict so a
  truly-wedged pod still drops out of endpoints without being killed mid-query.
- **Scale geode out (raft cluster)** so a single node's stall doesn't 503 the
  whole API — currently blocked by the cross-pod TLS handshake issue
  (geode GAP-0838 / single-node QA).

## 7. Environment

- Image: `geodedb/geode:0.6.23`, single-node StatefulSet (`geode-0`),
  namespace `divelife-qa`.
- Resources: `requests {cpu:1, memory:2Gi}`, `limits {cpu:4, memory:6Gi}`.
- Probes (both): `geode query localhost:3141 … "RETURN 1"`, `timeoutSeconds=8`;
  liveness `periodSeconds=15 failureThreshold=4`, readiness `periodSeconds=10
  failureThreshold=2`.
- Clients during repro: 1× divelife-api replica, 2× divelife-pds replica,
  Playwright e2e (2 workers). `quic_active_connections=11` at peak.
- Date: 2026-06-07.

## 9. Resolution (geode side) — out-of-band liveness endpoint

geode already serves `GET /health` on the metrics HTTP server
(`src/monitoring/metrics_server.zig`, `serveHealth`). This endpoint:

- Returns `HTTP/1.1 200 OK` with body `{"status":"ok"}` (15 bytes, static).
- Runs on its **own OS thread** (the metrics server accept loop), completely
  independent of the QUIC event loop and the `Endpoint.mu` poll lock. A
  saturated query path cannot delay or block it.
- Is activated by setting `GEODE_METRICS_PORT=<port>` at server startup. The
  bind address defaults to `127.0.0.1`; set `GEODE_METRICS_BIND=0.0.0.0` to
  make it reachable from outside the pod.
- As of 2026-06-07 (`feat(server): advertise out-of-band /health liveness
  endpoint at startup`), geode logs the URL at startup so operators can
  discover it without reading source:

  ```
  level=info msg="Out-of-band liveness endpoint available ..." liveness_endpoint=/health port=<N>
  ```

**Recommended k8s probe split:**

```yaml
# Liveness — cheap, out-of-band.  Fails only if the process is truly dead.
livenessProbe:
  httpGet:
    path: /health
    port: 9091          # GEODE_METRICS_PORT value
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 3
  failureThreshold: 4

# Readiness — in-band RETURN 1.  A slow-but-alive pod drops out of
# Endpoints but is NOT killed; it recovers when load subsides.
readinessProbe:
  exec:
    command:
    - geode
    - query
    - --server=localhost:3141
    - --insecure-tls-skip-verify
    - -U geode
    - -P
    - $(GEODE_ADMIN_PASSWORD)
    - --timeout=5
    - RETURN 1
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 8
  failureThreshold: 3
```

This separates "is the process alive?" (liveness, off the hot path) from "is
the query path accepting work right now?" (readiness, in-band). A pod that is
slow under load fails readiness and sheds traffic, but is not SIGKILLed, so
it can drain and recover without a 503-inducing restart.

The durable QUIC-side fix (poll-loop fairness / `Endpoint.mu` rework, §5) is
still required to eliminate the contention that causes the slowness in the
first place.

## 10. Status / fix landed (2026-06-07)

Worked under `/bug:fix` + `superpowers:writing-plans` + `superpowers:subagent-driven-development`
on branch `bug/quic-sustained-load-liveness-kill`. Plan:
`docs/superpowers/plans/2026-06-07-quic-sustained-load-liveness-kill.md`.

**Landed (Phase 1 — bounded, low-risk, unit-tested):**

1. **Out-of-band liveness advertised at startup** (commit `391870d7`, §5 bullet 2 / §9). geode
   already serves a static `200 {"status":"ok"}` at `/health` on `GEODE_METRICS_PORT`, on its own
   OS thread, independent of the QUIC poll loop. Startup now logs the URL so operators adopt the
   §9 probe split (cheap out-of-band liveness; in-band `RETURN 1` as readiness only). **This
   removes the liveness-kill → 503 amplification** — a busy-but-progressing pod sheds traffic via
   readiness instead of being SIGKILLed.
2. **Slow-poll warning + metric** (commit `63c02d14`, §5 bullet 5). `observePollCycle` emits a
   rate-limited (1 s threshold, 5 s window) `WARN "QUIC poll cycle slow — query path degraded"`
   with the dominant sub-phase, so the degradation is visible in logs *before* a kill. Unit test:
   `tests/test_quic_slow_poll_warning.zig`. (Confirmed firing 10× under the repro below.)
3. **Liveness breadcrumb actually reaches stdout/stderr** (commit on branch). A CPU-constrained
   repro (below) caught that `391870d7`'s advertisement used `log.info`, which does NOT surface on
   the serve path — the same sink gap that hid the first-boot admin-password breadcrumb. Replaced
   with a reliable `std.debug.print("[startup] out-of-band liveness ready: GET …/health …")`.
   Regression: `tests/test_liveness_endpoint_breadcrumb.zig`.

**Empirical validation (repro harness `tests/quic/quic_sustained_load_repro.sh`, `make
repro-quic-liveness`).** CPU-constrained (CPUQuota=200%, N=16, 2000 nodes), the in-band `RETURN 1`
probe climbs to **2.7–3.4 s then times out (>8 s) repeatedly** while the out-of-band `/health`
stays at **~18 ms throughout** — i.e. Phase 1's probe split provably prevents the SIGKILL.
`quic_poll_cycle_max_ns` hits **3.3–4.0 s** and `quic_first_stream_packet_process_max_ns` hits
**18.8 s** (single heavy 1500-row result), confirming the §4.1 "one expensive packet
head-of-line-blocks the loop" mechanism. This harness is the Phase 2 acceptance gate.

**Scoped, load-test-gated (Phase 2 — durable QUIC-core fix), with source evidence it must not be
rushed:**

- The root cause is the coarse `Endpoint.mu` (`~/src/devnw/zig/quic/src/quic/endpoint.zig:512`)
  held across poll packet-processing **and** `acceptStream` (§4.1). The durable fix bounds
  per-poll work / splits the lock + adds per-connection fairness + safe stream reaping.
- **Stream reaping (§5 bullet 4) cannot be done safely as a watchdog force-close today**:
  `QuicStream.close` (`transport.zig:741`) is env-gated to *avoid vendor close by default to
  reduce teardown races*; cross-thread close races `quic_stream_id` against a concurrent `read()`;
  and the proto-reader registry **deliberately never aborts** a possibly-mid-transaction stream
  (`proto_reader_registry.zig:25-27`). The blocking read path *already* self-reaps at 300 s
  (`quic_connection_handler.zig:1293`); the observed 5.4 h leak is in the no-cap cooperative
  scheduler path and must be reaped by the scheduler thread that owns the stream.
- Phase 2 is therefore gated behind a **CPU-constrained concurrency reproduction harness**
  (cgroup v2 / `systemd-run --property=CPUQuota=400%` + `tests/e2e_quic_high_concurrency.zig` or
  the harness Go loadtest + a probe stream) that proves the failing baseline and validates the fix
  with no regression in `test-quic-high-concurrency-e2e`. Details in the plan's Phase 2 section.

**Downstream assessment:**

- `~/src/devnw/zig` (vendored QUIC lib): this is where the durable Phase 2 fix lands
  (`endpoint.zig` lock work + `transport.zig` per-stream close synchronization). Scoped, not yet
  changed — load-test-gated as above.
- `../geode-client-zig`: **no change required.** This is a server-side transport/contention bug;
  the §9 resolution is a k8s probe-config split against the existing server `/health`, needing no
  client API change.

## 8. Cross-references

- [2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md] — same
  residual `Endpoint.mu` poll-vs-`acceptStream` contention; that doc's
  trigger is a connection **burst**, this one is sustained **query** concurrency.
  The `RETURN 1` liveness probe documented there (layer 3, divelife-argo
  `2205c22`) is the mechanism that does the killing here.
- [2026-06-04-oom-on-startup-graph-index-load-crashloop.md] — the *other* 137
  failure mode (`OOMKilled` at startup, graph index load). This bug is **not**
  OOM (`reason="Error"`, no memory kill); the two are independent.
- [2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md] — QUIC
  initial-packet crash path; cross-referenced for the QUIC stack context.
