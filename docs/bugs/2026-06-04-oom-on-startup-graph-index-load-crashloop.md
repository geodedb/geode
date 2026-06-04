# Bug: geode **OOMKilled on startup** loading the full graph property index → crash-loop as the on-disk graph grows

**Status:** **OPEN** — reported 2026-06-04 from `divelife-qa` (geode `0.6.14`).

**Severity:** High for any deployment whose graph grows over time under a fixed
memory limit. The failure mode is a hard crash-loop that takes the whole
dependent stack down (api/pds CrashLoopBackOff) and does **not** self-recover —
the only fixes are raising the container memory limit or shrinking/compacting
the on-disk graph.

---

## 1. Symptom

A single geode pod (`geode-0`, single-node QA StatefulSet, container memory
`limit: 2Gi`) entered `CrashLoopBackOff` after a long-running e2e marathon
(~12 h, hundreds of authenticated screens each issuing reads/writes). Pod
status:

```
exit code 137  reason=OOMKilled  restarts=6
```

The crash is **on startup, during graph load**, not under live query load. Every
restart prints a clean, identical boot sequence and then gets OOMKilled a few
seconds later:

```
[startup] raised RLIMIT_NOFILE soft 1024 -> 524288 (hard 524288)
[startup] user store initialized (0ms)
[startup] certificates ready (0ms)
info(graph_storage_adapter): opened existing graph '__geode_security' (property index loaded from disk)
info(graph_storage_adapter): opened existing graph 'default' (property index loaded from disk)
[startup] server initialized (4792ms)
[startup] auth cache configured (0ms)
{"component":"transport","transport":"quic", ... "status":"listening"}
[startup] QUIC transport listening (2ms)
# … then OOMKilled (137) shortly after, before/while serving
```

The log line `opened existing graph 'default' (property index loaded from
disk)` is the relevant one: the **entire property index is loaded into memory
on open**. Once the persisted graph grew past what fits under the 2Gi limit
together with the rest of the resident set, the process is killed by the kernel
OOM killer while (or just after) finishing load, before it can serve traffic —
so it can never make progress and crash-loops indefinitely.

## 2. Trigger / how to reproduce

1. Run geode single-node with a modest container memory limit (here `2Gi`).
2. Drive sustained write+read load that grows the persisted `default` graph
   (a long e2e suite, a seed + many hours of test writes, etc.).
3. Restart the pod (or let the [acceptor wedge](./2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md)
   force a restart).
4. On restart geode loads the now-larger property index into memory and is
   OOMKilled (137) during/after load → `CrashLoopBackOff`.

The graph size at which this trips is purely a function of
`memory.limit` vs. `sizeof(property index in memory)`; there is no back-pressure
or partial-load path, so the crossover is a hard cliff.

## 3. Impact

- **No self-recovery.** Unlike the acceptor wedge (recovers on restart), this
  state is stable across restarts — every boot re-loads the too-big index and
  re-OOMs.
- **Blast radius = whole stack.** Dependent services (`api`, `pds`) go
  `CrashLoopBackOff` because their startup schema-apply + first query can't
  reach geode.
- **Operational fix is out-of-band:** raise the memory limit (we bumped QA
  `2Gi → 6Gi`, request `1Gi → 2Gi`, and the pod booted cleanly with 0 restarts)
  or compact/reset the on-disk graph. Neither is a code fix; both require an
  operator.

## 4. Suspected root cause

`graph_storage_adapter` eagerly loads the **full** property index for each graph
into resident memory at open time (`property index loaded from disk`). Memory
footprint therefore scales O(graph size) with no:

- streaming / lazy / paged index load,
- memory budget or high-water check that fails *gracefully* (refuse-with-error
  or load-partial) instead of being OOM-killed,
- startup log of the index size / projected memory so operators can size the
  limit before the cliff.

## 5. Suggested fixes (geode side)

1. **Lazy / paged property-index load** so startup memory is bounded
   independent of graph size (load on demand, evict under pressure).
2. **Memory-budget awareness at open:** read the cgroup memory limit
   (`/sys/fs/cgroup/memory.max`), log the projected index footprint, and fail
   with a clear actionable error (“graph index N MiB exceeds M MiB budget; raise
   memory limit or compact”) instead of being silently OOM-killed mid-load.
3. **Emit index/graph size metrics** (`geode_graph_property_index_bytes`,
   `geode_graph_node_count`) so dashboards can alert *before* the cliff.
4. Document a **recommended memory-limit → graph-size** sizing guideline.

## 6. Workaround (operator)

Raise the container memory limit (and request) until geode boots; then compact
or reset the graph if the growth was unintended (e.g. accumulated e2e test
data). For QA this was a divelife-argo change:
`manifests/base/geode.yaml` resources `limit 2Gi → 6Gi`, `request 1Gi → 2Gi`.

## 7. Environment

- geode image `geodedb/geode:0.6.14`, single-node StatefulSet, namespace
  `divelife-qa`.
- Container resources at failure: `requests.memory=1Gi`, `limits.memory=2Gi`.
- Node: 64 GiB, <15% allocated — ample host headroom; the kill is the
  **container** cgroup limit, not node pressure.
- Graph grown by a ~12 h Playwright e2e marathon (130 seeded users + many hours
  of authenticated writes) on top of the standard QA seed.

## 8. Cross-references

- [`2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md`](./2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md)
  — the wedge frequently *causes* the restart that then surfaces this OOM.
- [`2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md`](./2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md)
  — the (resolved) crash that first motivated restarts.
