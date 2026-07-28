# Bug: same `Endpoint.mu` acceptor wedge reproduces in CI (mentats e2e), and the default watchdog threshold never fires at CI traffic volume

**Status:** OPEN — observed in `apps/mentats` CI, project 84122478, pipeline
`2713043400`, job `ui-e2e-playwright` (id `15583129160`), 2026-07-28. Image
`geodedb/geode:main` (mentats' `docker-compose.yml` floating dev tag — not the
`0.8.4` release pinned in mentats' production overlay, so this is independent of
that version bump).

This is the same wedge already tracked in:

- [2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md](2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md)
- [2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md](2026-06-10-dev-v0.6.26-still-wedges-plus-batch-ingest-bad-connection.md)
- [2026-06-21-sustained-single-conn-ingest-wedge-checkpoint-rwlock-deadlock.md](2026-06-21-sustained-single-conn-ingest-wedge-checkpoint-rwlock-deadlock.md) (fixed by `9bd9b81b`, in this image, not the cause here)
- [2026-07-26-prod-v0.6.26-idle-acceptor-wedge-watchdog-94min-late.md](2026-07-26-prod-v0.6.26-idle-acceptor-wedge-watchdog-94min-late.md) — the volume-based-watchdog detection gap this report confirms in a third environment.

## What's new here

The 2026-07-26 report showed the volume-based acceptor watchdog (`rx_queue >= 8
MiB for 30s`) took 94 minutes to fire against near-idle production traffic. This
CI run shows the same watchdog **never fired at all** across the test job's
9.3-minute window, because a Playwright e2e suite against a single local stack
generates far less than 8 MiB of queued backlog even while continuously
retrying. The job did not recover; it ran out the suite's own test timeouts and
failed.

## Timeline (from job artifacts, `ui/test-results/compose.log`)

| Time (UTC) | Event |
|---|---|
| 19:12:47 | `geode-1` QUIC transport listening, server ready |
| 19:13:17 – 19:14:03 | normal traffic; `msgs_delivered` climbs to 618 |
| ~19:14:03 | last message delivered (`total=618` never advances again) |
| 19:14:12 onward | `mentats-server-1`: `usergraph: RecordActivity: geode: transport dial to geode:3141: timeout: no recent network activity`, repeating every 5–10s |
| 19:17:58 | last real geode-1 log line (`periodic WAL-triggered light checkpoint fired checkpoints_total=16`) — after this, only the 5s metrics-thread heartbeat continues, `proto_idle_ms` climbing, `total=618` frozen |
| 19:23:11 – 19:23:13 | Playwright's own test/suite timeouts expire; `mentats-server-1` logs `http_handler_err` on `/v1/strategy-core/projects`, `/v1/analytics/exposure-estimates`, `/v1/analytics/country-risk-scores`, `/v1/analytics/geopolitical-events`, `/v1/analytics/trade-disruption-indicators`, `/v1/workflow/review-cycles` — every backend call that touches geode fails |
| 19:23:15 | job's `after_script` tears the compose stack down; no `ACCEPTOR WEDGE` self-restart line ever appeared in `geode-1`'s log |

Same signature as the prior reports: `msgs_delivered`/`total` freeze while the
5s metrics tick keeps running, dependent (`mentats-server`) loses connectivity
within seconds, and — per the 2026-07-26 report's Watchdog B analysis — the
volume trigger (8 MiB) is unreachable at this traffic scale, so detection never
happens inside the job's lifetime at all, not just late.

## Effect

`board-pack-journey.spec.ts` and both `kit-scanners.spec.ts` "no console errors"
checks failed with backend 500s / seed timeouts once the wedge hit partway
through the 18-test run; one `a11y` test flaked with a 90s timeout for the same
reason. This is the same intermittent `ui-e2e-playwright` failure pattern
already seen on mentats' `v0.1.1` release pipeline (different individual specs
failed there, same root cause class).

## Mitigation applied

Per the existing operator-side mitigation in the 2026-07-26 report, added
`GEODE_ACCEPTOR_WATCHDOG_RX_BYTES` / `GEODE_ACCEPTOR_WATCHDOG_DEADLINE_MS` to
`apps/mentats-source/docker-compose.yml`'s `geode` service, sized for CI's much
lower traffic volume than even the idle-production case (64 KiB / 15s instead of
the doc's suggested 128 KiB / 30s), so a wedge self-restarts within the job's
per-test timeout instead of silently consuming the rest of the suite. This is a
mitigation, not the fix — the correct detection predicate is still
progress-based (§3 of the 2026-07-26 report), not volume-based.
