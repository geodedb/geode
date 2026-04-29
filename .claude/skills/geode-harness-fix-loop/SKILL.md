---
name: geode-harness-fix-loop
description: Run the full ../geode-test-harness suite under OTel monitoring, triage failures and performance bottlenecks from span/metric data, iterate fixes against geode until the suite is 100% green and the load test meets baseline. Invoke whenever the user asks to "run the test harness", "fix the test failures", "monitor performance / find bottlenecks", "load test geode", or any phrasing that combines harness execution with bug-fix or perf-tuning intent.
---

# Geode harness — fix-and-tune loop

This skill drives the recurring developer workflow of running the integration
suite + load tests against geode, watching OTel spans/metrics live, fixing
each failure or bottleneck at the source, and iterating until the suite is
100% green and load-test KPIs are at or above baseline.

## When to invoke

Activate on phrases like:

- "run the harness", "run the full test suite", "run test-everything"
- "fix the test failures until 100%", "fix everything until it passes"
- "load test geode", "run loadtest"
- "find the bottleneck", "what's slow", "monitor performance"
- "the harness is failing", "why is it timing out"

## High-level loop

```
[1] start collector  →  [2] run suite  →  [3] tail spans + metrics  →  [4] triage failure
                                                                           ↓
                              [7] redeploy  ←  [6] commit + build  ←  [5] fix at source
                                  ↑                                       ↓
                                  └──────────────── re-run ───────────────┘
```

Stop only when:

- `make test-everything` returns exit 0 with all spec lines green, AND
- `make loadtest-compare` shows no regression vs `benchmarks/loadtest/baseline.jsonl`, AND
- `make otel-verify` confirms spans landed (i.e. monitoring itself didn't drop).

## Step-by-step

### Step 1 — bring up the OTel collector + run the suite

```bash
cd ../geode-test-harness

# One-shot: collector → run-all → verify → stop
make test-everything-otel GEODE_BINARY=/usr/bin/geode
```

If you need finer control (e.g. iterating a single failing spec):

```bash
make otel-start                 # docker collector on :44318/:44317
GEODE_OTEL=1 make test-spec SPEC=geodetestlab-cli/specs/<file>.yml -v
make otel-tail                  # in another shell — live span/metric stream
```

The collector writes:

| Artefact | Path | Purpose |
|---|---|---|
| OTLP/JSON spans + metrics | `reports/spans.jsonl` | Post-run analysis (`jq` filterable) |
| Drained collector log | `reports/otel-collector.log` | Debug exporter stdout |
| Sourced env vars | `reports/.otel-env` | Reproduce a single test run |

### Step 2 — triage failures from the harness output

Failures show up in two channels:

1. **harness stdout/JSON** — `reports/results.json` for the integration suite,
   stderr lines from `run_all_tests.sh` for shell + load.
2. **OTel spans** — `reports/spans.jsonl`, filterable by scope/name.

For each failing spec, get both perspectives:

```bash
# What spec said
jq '.specs[] | select(.status=="failed")' reports/results.json | head

# What spans said in the same window (replace span name as needed)
jq -c '.resourceSpans[].scopeSpans[].spans[]
       | select(.status.code=="STATUS_CODE_ERROR")
       | {name, scope: input_filename, status, attributes}' reports/spans.jsonl | head
```

### Step 3 — map common error phrases to canonical fixes

Use this table FIRST before deep-diving. Most production issues hit one of these.

| Symptom | Span/metric signature | Canonical fix |
|---|---|---|
| `chunk failed: driver: bad connection` (parallel seed) | `quic_active_connections` drops to 0; server log has `processInitial: sendHandshakePackets failed: NoHandshakeKeys` | Bump `quic` pin in geode `build.zig.zon` to upstream HEAD that includes the `setCurrentConnection` race fix; then bump `geode_client_zig` pin so it resolves the same quic SHA. See `gitlab.com/devnw/zig/quic` commits `8a2f032`, `d6b6089`, `beb08b2`. |
| `expected BEGIN response` | desync race; client error verbatim is the OLD message — post-fix is `expected BEGIN response, got <variant>` | Update the loader to use `geode-client-go @ 299dabf` or later (HasBufferedData guard + markConnFailed). |
| `orphan-txn rolled back on stream close` | server-side warning, repeating per pinned conn at the moment of failure | Companion to the above two — the txn rollback is correct behavior; the trigger is the desync above. |
| `quic_min_smoothed_rtt_ns=12297829382473034410` | `0xAAAA…` uninit-stat sentinel | Cosmetic — gate the stat on `have_sample`. Already fixed in `555dcd4a`; if reappearing, check the metrics commit didn't get reverted. |
| Hung 2-3 minutes mid-batch then `connection is already closed` | server `quic_active_connections=0` while client still drives | Same NoHandshakeKeys race as row 1 — the hang is the client-side QUIC idle timeout. Fix is upstream quic pin bump. |
| REPL exits on `/use <typo>` or other slash-cmd error | error escapes `ReplLoop.run` → `cli/main.zig:3030` `process.exit` | Already fixed in `79fc47ce`. If reappearing, audit any `try repl_dispatch.handleMetaCommand(...)` for missing catch wrapper. |
| `error: 'options' has no member named 'with_otel'` (downstream consumer with `-Dwith_otel=true`) | protobuf observability.zig binds wrong `build_options` | Already mitigated by `@hasDecl` gate in `gitlab.com/devnw/zig/protobuf @ 3518081`. If a different lib trips it, mirror the same gate. |

### Step 4 — performance bottleneck identification

Use the OTel pipeline to find slow paths instead of `printf`-debugging:

```bash
# Top 20 slowest spans by InstrumentationScope
jq -r '.resourceSpans[].scopeSpans[]
       | .scope.name as $scope
       | .spans[]
       | [$scope, .name, ((.endTimeUnixNano|tonumber) - (.startTimeUnixNano|tonumber))/1000000] | @csv' \
  reports/spans.jsonl \
  | sort -t, -k3 -rn | head -20
```

Common bottleneck patterns and where to fix them:

| Hot span | Likely cause | First place to look |
|---|---|---|
| `geode.query.execute` slow + `gql.execute.PARSE` fast | Plan / execute bottleneck | `src/execution.zig`, `src/planner/`, RLS filter overhead in `src/execution/match_operations.zig` |
| `gql.execute.PARSE` slow | Lexer or recursive parser hot path | `src/gql/parser.zig`, `src/gql/lexer.zig` — typically token-stream allocation |
| `wal.append_batch` slow | Group-commit contention | `src/storage/group_commit.zig`, `src/wal.zig` (manual_sync vs fsync) |
| `geode.graph_store.create_node` slow | Storage rwlock saturation OR shard routing | `src/graph_store.zig` (per-graph rwlock), `src/storage/graph_storage_adapter.zig` (sharded lock acquire path) |
| `geode.graph_store.get_nodes_by_label` slow | Label index full scan | `src/graph_store.zig:label_index` lookup; verify the composite key path isn't allocating |
| QUIC metrics: `quic_total_bytes_in_flight` plateauing | cwnd-limited, not server-limited | `src/transport/quic.zig` flow-control headroom |

### Step 5 — fix at the source

**Never** mock or simulate around a real failure — the project's CLAUDE.md
explicitly forbids it:

> NO MOCK DATA, NO SIMULATION, IMPLEMENT THE COMPLEX FEATURES

Fix loop:

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode

# 1. Edit the actual source. Use ../geode-test-harness/reports/spans.jsonl
#    and harness stdout to confirm the layer.
# 2. Build.
zig build -Dotel_use_devnw_tls=true

# 3. Reinstall against the systemd service if you need to re-run end-to-end:
sudo systemctl stop geode.service
sudo make install-otel
sudo systemctl start geode.service

# 4. Re-run the failing spec under OTel:
cd ../geode-test-harness
GEODE_OTEL=1 make test-spec SPEC=<the-failing-spec>

# 5. Confirm the previously-failing span is now status.code=STATUS_CODE_OK in
#    reports/spans.jsonl, and the harness reports green.
```

### Step 6 — load test + baseline compare

After integration is green, confirm no perf regression:

```bash
cd ../geode-test-harness
# Real load test (hits a fresh geode launched by run_all_tests.sh's loadtest section)
GEODE_ADMIN_PASSWORD=<pw> LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<pw>" \
  make loadtest-go

# Compare against benchmarks/loadtest/baseline.jsonl
cd ../geode
make loadtest-compare
```

Regression thresholds (`make loadtest-compare`):

- QPS regression: current < baseline × 0.8
- p50 latency regression: current > baseline × 1.2
- Error-rate regression: current > 10% AND baseline < 5%

If the comparison passes AND there's a measurable improvement, run
`make loadtest-save-baseline` and commit the updated `baseline.jsonl`
alongside the perf fix.

## Concrete commands you'll run, in order

```bash
# 0. Make sure binary is current
cd /data/home/benji/src/devnw/codepros/geode/geode
zig build -Dotel_use_devnw_tls=true

# 1. Full suite under OTel
cd ../geode-test-harness
make test-everything-otel GEODE_BINARY=$PWD/../geode/zig-out/bin/geode

# 2. If failures, triage from spans.jsonl + results.json (see step 2 above)
# 3. Fix at source (step 5), rebuild, reinstall if running against systemd
# 4. Re-run only the failing spec(s) until green:
GEODE_OTEL=1 make test-spec SPEC=<spec>
# 5. Once integration is 100% green, full loadtest:
make loadtest
# 6. Baseline compare:
cd ../geode && make loadtest-compare
# 7. Stop collector
cd ../geode-test-harness && make otel-stop
```

## InstrumentationScopes you'll see (after `5609bc79`)

| Scope | Origin | Where it fires |
|---|---|---|
| `com.geodedb.geode` | geode itself | transport.request, query.execute, graph_store.{create_node,get_nodes_by_label}, gql.execute.PARSE, wal.{create,update,delete}_* |
| `wal` | DevNW wal | replay, append (×2), append_batch (×2), commit, checkpoint, truncate |
| `gql` | DevNW gql | parser entry |
| `dns` | DevNW dns | client/recursive/stub query lookups |
| `vulkan` | DevNW vulkan | GPU compute ops |
| `thread_pool` | DevNW thread-pool | task lifecycle |
| `repl` | DevNW repl | REPL command execution |
| `protobuf`, `slog` | DevNW | bound, no internal spans |

## Anti-patterns — do not do these

- **Don't** mock or stub server responses in the harness to make a spec pass.
- **Don't** add `--no-verify` to a `git push` to bypass the cross-compile or
  CANARY hooks; the gateguard hook will reject it anyway. Fix the underlying
  cause.
- **Don't** disable `OTEL_TRACES_EXPORTER=otlp` to "make geode faster" during
  load tests — the overhead is sub-percent and you lose the diagnostic
  channel that tells you which span is slow.
- **Don't** bump `thread_pool` directly without bumping the libs (`quic`,
  `grpc_zig`, `mcp`, etc.) that pin it transitively — you'll trip "file
  exists in modules" and the diamond-dep error cascade.
- **Don't** assume "the libs aren't emitting spans" without first checking
  whether the running geode binary post-dates the `bindLibraryGlobals` work
  (md5 of `/proc/<pid>/exe` vs `zig-out/bin/geode`). Stale binary is the
  most common cause of "no traces in GitLab".

## References

- `../geode-test-harness/CLAUDE.md` — collector defaults, env overrides,
  artefact locations, debugging recipes (deep dive)
- This repo's `CLAUDE.md` — InstrumentationScopes table + canonical
  debugging recipes (mirrors the table here)
- `scripts/test-otel-tracing.sh` (in this repo) — local-only smoke test for
  the OTLP/HTTP path against an ephemeral collector, useful when iterating
  on the geode tracer wiring itself
- `docs/otel-updates.md` — full OTel rollout plan + InstrumentationScope spec
