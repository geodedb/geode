# QUIC High-Concurrency Operations

This page records the current Geode QUIC high-concurrency gate, diagnostics,
and tuning controls. It is the operator-facing companion to
`docs/audit/quic-high-concurrency-2026-05-29.md`.

## Current Gate

The current no-retry high-concurrency regression gate is 4096 parallel clients,
one operation per client, mixed reads and mutations at a 3:1 read/write ratio,
and a 1000 us request stagger:

```sh
GEODE_HC_WORKERS=4096 \
GEODE_HC_OPS_PER_WORKER=1 \
GEODE_HC_MUTATION_STRIDE=4 \
GEODE_HC_READ_QUERY='MATCH (n:HCParallel) RETURN count(n) AS c' \
GEODE_HC_CONNECT_STAGGER_US=1000 \
GEODE_HC_REQUEST_STAGGER_US=1000 \
GEODE_HC_EXEC_TIMEOUT_SECS=10 \
GEODE_HC_EXEC_RETRIES=0 \
GEODE_HC_POLL_WORKERS=16 \
timeout 1200s zig build -Doptimize=ReleaseFast test-quic-high-concurrency-e2e --summary all
```

The accepted 2026-05-29 run completed all 4096 operations with zero setup
retries, zero execute retries, zero reconnects, and 990.41 QPS.

## Diagnostic Ceiling

The 4096-worker mixed workload with `GEODE_HC_REQUEST_STAGGER_US=250` is a
diagnostic ceiling probe, not a passing gate. It is intentionally aggressive and
currently exposes first-response timeout tail after the accepted 1000 us gate is
stable.

Use the 250 us probe to localize the next bottleneck. Do not use it as release
criteria until it clears without increasing the 10s execute timeout.

## Core Knobs

- `GEODE_QUIC_POLL_WORKERS`: server endpoint poll workers. Keep at `16` for the
  current QUIC dependency line; higher values contend on serialized crypto
  polling.
- `GEODE_QUIC_MUTATION_ADMISSION_CAP`: cooperative first-stream mutation window.
  Leave unset in normal operation. The default cap is `4`; wider windows
  regressed mixed read/write fanout.
- `GEODE_HC_POST_WRITE_POLL`: high-concurrency harness client flush behavior.
  Defaults to true below 1024 workers and false at 1024+ workers. Set `1` only
  for legacy immediate post-write poll comparisons.
- `GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS`: harness override for server
  cooperative first-stream workers. The server clamps the production value to
  512.
- `GEODE_HC_REQUEST_STAGGER_US`: offered-load shaping across already connected
  clients. The accepted gate is `1000`; `250` remains a ceiling probe.

## Reading Timing Output

The high-concurrency E2E harness emits a single timing line after each run.
The most important fields are:

- `avg_ready_to_first_execute_ms`: local harness wake/scheduling lag after the
  configured request stagger.
- `avg_execute_write_ms`: total client-side EXECUTE encode, stream write, and
  optional post-write poll time.
- `avg_execute_prepare_ms`: client-side serialization and framing time.
- `avg_execute_stream_write_ms`: `stream.writeAll` elapsed time, excluding the
  follow-up endpoint poll.
- `avg_execute_post_write_poll_ms`: immediate client endpoint `poll(0)` time.
  This is expected to be near zero for 1024+ harness fanout unless
  `GEODE_HC_POST_WRITE_POLL=1` is set.
- `first_response_timeouts`: operations that timed out before the first response
  message arrived.
- `avg_first_response_wait_ms`: client-observed time from EXECUTE write
  completion to the first response message.
- `avg_response_message_read_ms`: average per-message response read time across
  all response messages.

When `avg_execute_post_write_poll_ms` is high, the local same-process client
driver is contributing to the measurement. When `avg_execute_write_ms` is low
and `first_response_timeouts` remains high, shift the investigation to server
polling, cooperative first-stream scheduling, query execution, response write
latency, or kernel UDP drops.

## Server Metrics

Scrape these runtime metrics when a ceiling probe has high first-response tail:

- `quic_stream_write_elapsed_ns_total`
- `quic_stream_write_elapsed_max_ns`
- `quic_poll_cycle_max_ns`
- `quic_poll_transport_max_ns`
- `quic_poll_recv_short_frame_process_max_ns`
- `quic_poll_recv_short_ack_send_max_ns`
- `quic_poll_overrun_total`

The response write metrics split server-side `stream.writeAll` latency from
query execution and receive/admission stalls. Poll metrics identify endpoint
poll saturation and short-header processing stalls.

## Dependency State

As of this cycle, Geode pins:

- QUIC: `a68d36e06dc9a0815a7a02d5e18b9d8d06e9ad6b`
- `geode-client-zig`: `e96ca352c11b36c55c3df517a0d9a3b0112145ab`

Dependency changes must be made in the upstream worktrees under
`~/src/devnw/zig/*` before Geode is repinned.

## Host Tuning

Before formal performance gates, apply the UDP buffer and host hygiene from
`docs/performance/host-tuning.md`. Undersized UDP buffers can look like QUIC
or scheduler stalls because packet loss inflates first-response tail.
