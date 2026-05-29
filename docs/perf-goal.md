# Geode High-Concurrency Performance Goals

This is the single-instance enterprise-readiness target set for Geode QUIC E2E
mixed database workloads. It complements the current run log in
`docs/performance/quic-high-concurrency.md` and the 2026-05-29 audit trail in
`docs/audit/quic-high-concurrency-2026-05-29.md`.

## Current baseline

As of the 2026-05-29 high-concurrency cycle:

```text
Current passing sustained gate: 2048x8 mixed QUIC E2E
Current failing ceiling:        4096x8 mixed QUIC E2E
Current next acceptance gate:   4096x8 mixed QUIC E2E clean pass
Longer-term enterprise target:  16384x8 mixed QUIC E2E at 10k+ QPS
```

The 4096x8 ceiling must be raised without increasing the 10s execute timeout
or relying on retries to hide first-response stalls.

## Recommended goal profile

### Tier 1 — Near-term stability gate

This is the next milestone.

```text
4096x8 mixed QUIC E2E
32,768 attempted ops
100% completed ops
0 first-response timeouts
25% mutations minimum
p50 < 25 ms
p95 < 100 ms
p99 < 250 ms
QPS >= 2,500
error rate < 0.1%
```

This proves the current failing ceiling has been fixed.

---

### Tier 2 — Credible beta benchmark

This is a good external-facing target.

```text
8192x8 mixed QUIC E2E
65,536 attempted ops
100% completed ops
0 first-response timeouts
25% mutations minimum
p50 < 20 ms
p95 < 100 ms
p99 < 300 ms
QPS >= 5,000
error rate < 0.05%
```

This would be a credible “single-node high-concurrency beta” number.

---

### Tier 3 — Enterprise single-instance target

This is the stronger goal I would aim for before making serious enterprise performance claims.

```text
16384x8 mixed QUIC E2E
131,072 attempted ops
>= 99.95% completed ops
0 first-response timeouts
25% mutations minimum
p50 < 15 ms
p95 < 75 ms
p99 < 250 ms
p99.9 < 1,000 ms
QPS >= 10,000
error rate < 0.01%
```

This is the point where the single-instance story starts sounding enterprise-grade, assuming the workload is real and not trivial.

---

## Minimum benchmark matrix

Do not rely on one mixed workload. Use this matrix:

| Workload                        |                     Target |
| ------------------------------- | -------------------------: |
| Read-only indexed point lookups |               25k–100k QPS |
| Read-heavy 95/5 read/write      |                15k–50k QPS |
| Mixed 75/25 read/write          |                   10k+ QPS |
| Write-heavy 50/50               |                 3k–10k QPS |
| Traversal-heavy graph workload  | 1k–10k QPS depending depth |
| Batch ingest                    |        measured separately |
| Cold-cache workload             |        measured separately |
| Hot-cache workload              |        measured separately |

For your current state, I would make **10k QPS on 75/25 mixed E2E QUIC** the big goal.

---

## Stability goals

These matter more than the headline QPS.

```text
No first-response timeouts below declared max concurrency
No correctness failures
No WAL/recovery corruption
No graph isolation failures
No leaked transactions
No unbounded queue growth
No memory growth after steady state
No connection/session leaks
Graceful rejection above capacity
```

Under overload, the system should do this:

```text
latency rises gradually
queue depth rises visibly
admission control activates
some requests receive clean retryable errors
the database remains healthy
recovery is not required
```

It should **not** do this:

```text
timeout cliff
worker starvation
connection collapse
stalled mutations
unbounded memory growth
process crash
corrupted WAL
partial committed transactions
```

---

## Latency SLOs

Use this as the public-facing standard:

```text
p50  < 20 ms
p95  < 100 ms
p99  < 250 ms
p99.9 reported, not hidden
```

For internal engineering:

```text
p99.9 < 1 second under supported load
p99.9 may exceed 1 second only above declared capacity
```

Do **not** advertise average latency as the primary number. Use p95 and p99.

---

## Concurrency goals

Given your current result, I’d use this roadmap:

```text
Current stable:     2048x8
Next goal:          4096x8 clean pass
Beta goal:          8192x8 clean pass
Enterprise goal:    16384x8 clean pass
Stretch goal:       32768x8 with graceful overload behavior
```

For each tier:

```text
0 first-response timeouts
>= 99.95% completion
bounded queue depth
bounded memory
no recovery required after test
```

---

## Durability and recovery goals

For an enterprise database, performance numbers are weak unless durability is proven.

```text
WAL fsync mode documented
crash during mutation test
restart recovery succeeds
no committed transaction lost
no partial transaction visible
recovery time < 30 seconds for normal test DB
recovery time measured for large DB
backup/restore verified
checksum/corruption detection verified
```

For the mixed workload benchmark, report whether it uses:

```text
durable writes on
fsync on
checksums on
encryption on/off
audit logging on/off
field-level encryption on/off
```

Otherwise the benchmark will not be taken seriously.

---

## Resource efficiency goals

Track these with every run:

```text
CPU utilization:       70–90% at saturation
Memory growth:         stable after warmup
RSS variance:          bounded
GC/allocator stalls:   measured
Disk write latency:    p95/p99 reported
WAL throughput:        MB/s reported
Queue depth:           p50/p95/p99 reported
Worker utilization:    reported
QUIC stream errors:    0 below capacity
```

A strong result is not just “QPS went up.” A strong result is:

```text
QPS increased
p95/p99 stayed bounded
timeouts stayed zero
CPU became the bottleneck
memory stayed flat
disk behavior was explainable
```

---

## The goal I’d put in the project tracker

Use this as the concrete performance epic:

```text
Goal: Single-instance QUIC E2E mixed workload enterprise readiness

Target:
- 16,384 clients x 8 operations
- 131,072 total operations
- 25% mutations minimum
- 100% successful completion preferred
- >= 99.95% completion required
- 0 first-response timeouts
- p50 < 20 ms
- p95 < 100 ms
- p99 < 250 ms
- p99.9 < 1,000 ms
- >= 10,000 QPS
- no correctness failures
- no WAL/recovery failures
- no graph isolation failures
- no unbounded memory growth
- clean shutdown and restart after test
```

And the immediate next acceptance gate:

```text
4096x8 mixed QUIC E2E must pass with:
- 32,768/32,768 operations completed
- 0 first-response timeouts
- p95 < 100 ms
- p99 < 250 ms
- >= 2,500 QPS
- no memory/session/transaction leaks
```

That is the one I would chase first.
