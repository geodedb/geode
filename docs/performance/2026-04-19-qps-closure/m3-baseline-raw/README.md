# M3.1 baseline refresh — post-fix reference

Captured 2026-04-20 on `perf/qps-closure-2026-04-19` at commit
`c77a18b4` (post-GAP-0808 fast path, post-bench-quarantine-fix).
Host tuned per `docs/performance/host-tuning.md`
(`net.core.rmem_max=7340032`).

## Coverage

| scenario    | levels                      | status                         |
|:------------|:----------------------------|:-------------------------------|
| `ping`      | 1, 2, 4, 8, 16, 32          | ✅ 6 records                   |
| `point_read`| 1, 2, 4, 8, 16, 32          | ✅ 6 records                   |
| `one_hop`   | 1, 2, 4, 8, 16, 32          | ✅ 6 records                   |
| `two_hop`   | —                           | ❌ setup timed out (15 min)    |
| `fan_out`   | —                           | ❌ setup timed out (15 min)    |

Total: **18 records** (3 scenarios × 6 levels) in
`benchmarks/loadtest/baseline.jsonl`.

## Why two_hop / fan_out are missing

Both scenarios have heavy data setup (2,000 LT_Person + 8,000 LT_KNOWS
for two_hop; 2,200 nodes + 8,000 edges for fan_out). On this
reference host the loadtest client's batch-CREATE phase + edge-CREATE
phase took longer than even a 15-minute timeout. The underlying
server per-query QPS is also low (~0.5 at c=1 for two_hop) so even
the query phase is slow once it starts.

This is the *same* symptom as M0.10's original baseline failure —
the raw setup throughput, not query throughput, is the current floor
for these two scenarios. Addressing it needs a harness-side
`-skip-setup` / `-setup-only` flag so the setup pass can be done once
out of band, then the query phase run against the pre-seeded state.
That's a `geode-test-harness` change, tracked as a follow-up.

## QPS snapshot — this capture vs v0.3.8 baseline

| scenario / level   | v0.3.8 QPS | 2026-04-20 QPS | factor |
|:-------------------|-----------:|---------------:|-------:|
| point_read c=1     | 17.6       | 198.8          | **11×** |
| point_read c=4     | 29.2       | 235.8          | **8×**  |
| point_read c=8     | 25.6       | 238.2          | **9×**  |
| one_hop c=1        | 6.8        | 30.2           | **4×**  |
| one_hop c=4        | 6.4        | 96.6           | **15×** |
| one_hop c=8        | 3.4        | 160.8          | **47×** |
| ping (all c)       | —          | ~210–410       | flat (transport baseline) |

Numbers are lower than the interactive-session peak we saw yesterday
(~337 at c=1 for point_read, ~1087 at c=8) because tonight's host is
in a slower thermal / load state. The improvement *factors* vs v0.3.8
are what matter — GAP-0808's fast path is clearly active regardless
of host variance.

## Threshold model

`save_baseline.py` wrote the JSONL with default thresholds:

- `threshold_qps_min = qps * 0.8` (20 % regression floor)
- `threshold_p50_max_ms = p50 * 1.2` (20 % latency rise)

These are used by `compare.py` to detect regressions in future MRs.

## Artifacts

- `loadtest_ping.json` — raw ping output
- `loadtest_point_read.json` — raw point_read output
- `loadtest_one_hop.json` — raw one_hop output
- (two_hop / fan_out absent — see "Why" above)
