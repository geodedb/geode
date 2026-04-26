# Enterprise rwlock Fairness + Diagnostic Closure Implementation Plan

> **PLAN CLOSED — 2026-04-25 (post-fix re-diagnosis).** The premise of
> this plan ("the cascade is caused by `mg.rwlock` writer starvation
> under sustained 16-way SHARED traffic") has been **falsified twice**:
>
> 1. **Part 1 of `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md`**
>    refuted the hypothesis with contaminated stacks (1838 threads,
>    1802 of which were idle pool-leak workers), pointing instead at a
>    per-connection thread-pool leak.
> 2. **Part 2 of the same file** (added 2026-04-25 22:44 UTC, after the
>    upstream graph-storage Phase 1 dep bump reduced NLWP to 97)
>    refuted *both* the original rwlock hypothesis AND the mid-session
>    "rwlock as the remaining cause" interpretation that appeared in
>    `docs/performance/2026-04-25-shared-stream-pool/2026-04-25-graph-storage-bump-result.md`.
>    With clean stacks, **zero threads are in any rwlock acquisition
>    path** at cascade time. The frozen `mg_rwlock_exclusive_wait_ns_total`
>    metric is a historical artifact, not a live signal of starvation.
>
> **What is now known about the cascade:** at trigger time the server
> is in a no-progress state with all worker threads idle, all
> stream-query handlers idle in `BufferedProtoReader.nextMessage`, and
> the QUIC reactor running its 500 µs yield loop. The bottleneck is
> upstream of the database — somewhere at the QUIC transport / client
> protocol boundary. See Part 2 §"Recommended next investigation" in
> `stacks-analysis.md` for the candidate hypotheses (QUIC flow control,
> client retry storm, pinned-stream lifetime mismatch).
>
> **What stays from this plan:**
> - **Task 4** (coord_apply_* counter registration via `registerWithRuntimeMetrics`)
>   — committed at `aa9708d0`, valuable infrastructure regardless of
>   the cascade root cause. Keep.
> - **Task 6** (rwlock fairness regression test) — committed at
>   `fb5b3ea9`. Documents the rwlock invariant. Keep.
>
> **What is dropped:** Tasks 1, 2, 3, 5, 7. Task 5 in particular
> (apply writer-preferred / tryLock-with-backoff at each starved
> EXCLUSIVE call site) is not actionable — there are no starved
> EXCLUSIVE call sites to patch.
>
> **Next investigation thread:** A new plan should target the QUIC
> transport layer per Part 2's recommended next steps (capture
> connection-level send/recv window metrics during the 9-min hang,
> instrument `BufferedProtoReader` delivery rate, bisect the 9-min
> silence). That work is out of scope here.

---

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the residual `edges_contains` cascade (~10 min into the file under 16-way msft-graph ingest) by identifying every `mg.rwlock` EXCLUSIVE-acquirer that's being starved by sustained 16-way SHARED traffic, applying writer-preferred / tryLock-with-backoff semantics at each, and locking the result down with an integration test so the regression cannot reappear silently. Also resolves the orphan `coord_apply_*` counter registration so coordinator throughput is visible alongside `mg_rwlock_*` in the runtime_metrics output.

**Architecture:** Three coupled work items. (1) **Diagnose:** capture `gdb -p <pid> -batch -ex 'thread apply all bt'` stacks at the exact cascade-trigger moment during a fresh repro; classify every blocked EXCLUSIVE-acquirer thread by call site. (2) **Fix the registration order bug:** `ShardedCoordinator.start` registers `coord_apply_*` against `runtime_metrics.globalRegistry()` but the global is null at `start()` time for the first coordinator (verified empirically by the prior plan's Task 5 repro showing `mg_rwlock_*` counters but no `coord_apply_*` counters in the same `metrics:` line). Move registration so it's reachable from every `getOrStartCoordinator` return path. (3) **Apply per-call-site fairness:** for each diagnosed EXCLUSIVE acquirer that's blocking forever under 16 SHARED holders, route through the existing writer-preferred `acquireGraphWriteLockCancelable` (with a generous deadline) instead of bare `mg.rwlock.lockUncancelable`, OR add explicit `tryLock` + bounded back-off if a fail-fast policy is appropriate. Lock down with a Zig integration test that fails if any EXCLUSIVE wait exceeds 30 s under 16-way SHARED contention.

**Tech Stack:** Zig 0.16. `std.Io.RwLock` (the OS-backed reader/writer lock; writer-preferred when `Add(writer)` is called before sleeping). `pooled.ThreadPool` for the ingest workers. `gdb` for stack capture (added to `make deps` in commit `44e1ff5d`). The diagnostic infrastructure landed in commits `ec2084e4` → `aa9708d0` (runtime_metrics), `14999b61` (mg.rwlock counters), `48fa595c` (persistence-loop interval clamp removal). Existing helpers we'll lean on: `acquireGraphWriteLockCancelable` (writer-preferred slow path at `src/storage/graph_storage_adapter.zig:3571`) and `monoNanosNow` (file-local helper in `graph_storage_adapter.zig`).

---

## File structure

**Create:**
- `/tmp/capture-cascade-stacks.sh` — scratch-only stack-capture wrapper for the live repro (NOT committed).
- `/tmp/run-rwlock-fairness-repro.sh` — scratch-only test driver (NOT committed).
- `tests/test_rwlock_fairness_under_load.zig` — Zig integration test asserting EXCLUSIVE acquires complete in bounded time under sustained 16-way SHARED contention.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-server.log` — full server log from the diagnostic repro.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-ingest.log` — msft-graph client log.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt` — gdb `thread apply all bt` capture at cascade time.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md` — human-readable classification of blocked threads, one section per identified EXCLUSIVE-acquirer call site.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log` — full msft-graph re-run after fairness fixes.
- `docs/performance/2026-04-25-enterprise-rwlock-fairness/CLOSURE.md` — final closure report referencing diagnosis + fix commits + post-fix run.

**Modify:**
- `src/storage/group_commit.zig` — fix `ShardedCoordinator`'s `coord_apply_*` registration so it's reachable from every `getOrStartCoordinator` return path (extract a `registerWithRuntimeMetrics(*ShardedCoordinator)` method; call from `getOrStartCoordinator`).
- `src/storage/graph_storage_adapter.zig` and/or `src/graph_store.zig` — at each EXCLUSIVE-acquirer call site identified in `stacks-analysis.md`, replace `mg.rwlock.lockUncancelable(io)` with a writer-preferred path. Either:
  - Switch the call to `acquireGraphWriteLockCancelable(graph_name, deadline)` with a generous deadline (e.g., 120 s), OR
  - If the call site is internal (e.g., persistence loop or checkpoint helper) where adding a deadline parameter is awkward, replace bare `lockUncancelable` with a small inline tryLock-with-bounded-backoff loop that yields back to the caller after N attempts.
- `build.zig` — register the new `test-rwlock-fairness-under-load` test target.

**Leave alone:**
- `runtime_metrics` itself (correct as-is from the prior plan's Task 1).
- `mg.rwlock` per-shard locks (`shard_locks[]`) — they're not contended in the same way; this plan targets the per-graph `mg.rwlock` only.
- `ShardedCoordinator`'s shard-routing or apply path (correct as-of Phase 2-final).

---

## Phase 0 — Set up the diagnostic harness

### Task 1: Stack-capture script

**Files:**
- Create (scratch, not committed): `/tmp/capture-cascade-stacks.sh`

This script tails the msft-graph client log for the cascade-trigger marker (`pipeline failed — retrying file in serial mode`) and runs `gdb -p <server_pid> -batch -ex 'thread apply all bt'` AT THAT MOMENT, before the parallel-pipeline failure cascade lets shard workers exit. The captured stacks are exactly what we need to identify which EXCLUSIVE-acquirer call sites are blocked.

- [ ] **Step 1.1: Write the script.**

  Create `/tmp/capture-cascade-stacks.sh` with EXACTLY this content:

  ```bash
  #!/bin/bash
  # Watches the msft-graph ingest log for the cascade trigger message
  # and snapshots all server threads' backtraces at that moment.
  #
  # Usage:
  #   /tmp/capture-cascade-stacks.sh <server_pid> <ingest_log_path> <out_stacks_path>
  set -e
  SERVER_PID="$1"
  INGEST_LOG="$2"
  OUT_PATH="$3"

  if [ -z "$SERVER_PID" ] || [ -z "$INGEST_LOG" ] || [ -z "$OUT_PATH" ]; then
      echo "usage: $0 <server_pid> <ingest_log> <out_path>"
      exit 1
  fi

  echo "[capture] watching $INGEST_LOG for cascade trigger" >&2
  echo "[capture] server pid=$SERVER_PID, will write stacks to $OUT_PATH" >&2

  while IFS= read -r line; do
      if echo "$line" | grep -q 'pipeline failed — retrying file in serial mode'; then
          ts=$(date -Iseconds)
          echo "[capture] cascade trigger detected at $ts" >&2
          {
              echo "=== stacks captured at $ts ==="
              echo "=== /proc/$SERVER_PID/status ==="
              cat /proc/$SERVER_PID/status 2>/dev/null | grep -E 'VmRSS|VmPeak|Threads|FDSize'
              echo ""
              echo "=== gdb thread apply all bt ==="
              gdb -p "$SERVER_PID" -batch -ex 'set pagination off' -ex 'thread apply all bt' -ex detach 2>&1
          } > "$OUT_PATH"
          echo "[capture] wrote stacks to $OUT_PATH" >&2
          break
      fi
  done < <(tail -n 0 -F "$INGEST_LOG" 2>/dev/null)
  ```

- [ ] **Step 1.2: Make it executable + verify gdb available.**

  ```bash
  chmod +x /tmp/capture-cascade-stacks.sh
  command -v gdb && echo "gdb present" || { echo "gdb missing — run 'make deps'"; exit 1; }
  ```

  Expected: `gdb present`. If missing, run `make deps` first (commit `44e1ff5d` added gdb to the install script).

- [ ] **Step 1.3: Smoke-test the gdb invocation against any running geode server.**

  ```bash
  mkdir -p /tmp/geode-gdb-smoke-$$
  GEODE_ADMIN_PASSWORD="Geode1234Abc" nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-gdb-smoke-$$ \
      --listen 127.0.0.1:3180 --log-level warn \
      > /tmp/geode-gdb-smoke-$$.log 2>&1 &
  PID=$!
  sleep 4
  echo "=== smoke gdb stacks ===" > /tmp/smoke-stacks.txt
  gdb -p $PID -batch -ex 'set pagination off' -ex 'thread apply all bt' -ex detach 2>&1 >> /tmp/smoke-stacks.txt
  kill -9 $PID 2>/dev/null || true
  wc -l /tmp/smoke-stacks.txt
  head -20 /tmp/smoke-stacks.txt
  ```

  Expected: at least a few hundred lines, with one `Thread <N> ... <function>` block per server thread. If `gdb` returns "ptrace: Operation not permitted", the kernel's `ptrace_scope` is set to 1+ — run `sudo sysctl kernel.yama.ptrace_scope=0` for the duration of the diagnostic session.

- [ ] **Step 1.4: No commit (scratch script).**

---

## Phase 1 — Diagnose

### Task 2: Reproduce + capture stacks at cascade time

**Files:**
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-server.log`
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt`
- Create (scratch, not committed): `/tmp/run-rwlock-fairness-repro.sh`

This task runs the same `edges_contains`-only repro from the prior plan, but with the stack-capture watcher attached. Result: a `cascade-stacks.txt` snapshot taken at the exact moment the parallel pipeline cascades to serial fallback.

- [ ] **Step 2.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 2.2: Write the repro driver.**

  Create `/tmp/run-rwlock-fairness-repro.sh`:

  ```bash
  #!/bin/bash
  set -e
  cd /data/home/benji/src/devnw/codepros/geode/geode

  REPRO_DIR=docs/performance/2026-04-25-enterprise-rwlock-fairness
  mkdir -p "$REPRO_DIR"
  SERVER_LOG="$REPRO_DIR/repro-server.log"
  INGEST_LOG="$REPRO_DIR/repro-ingest.log"
  STACKS="$REPRO_DIR/cascade-stacks.txt"

  pkill -9 -f "geode serve --data-dir /tmp/geode-rwlock-fairness" 2>/dev/null || true
  rm -rf /tmp/geode-rwlock-fairness && mkdir -p /tmp/geode-rwlock-fairness

  rm -rf /tmp/rwlock-fairness-data && mkdir -p /tmp/rwlock-fairness-data
  cp /data/home/benji/eagleg-topology-data-20/*.jsonl /tmp/rwlock-fairness-data/
  for f in /tmp/rwlock-fairness-data/edges_*.jsonl; do
      base=$(basename "$f")
      if [[ "$base" > edges_contains.jsonl ]]; then
          rm -f "$f"
      fi
  done

  GEODE_ADMIN_PASSWORD="Geode1234Abc" GEODE_GROUP_COMMIT=1 \
    nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-rwlock-fairness \
      --listen 127.0.0.1:3172 --log-level info \
      --idle-timeout 600000 \
      > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  echo "server_pid=$SERVER_PID" > "$INGEST_LOG"

  for attempt in $(seq 1 30); do
      if zig-out/bin/geode query --server 127.0.0.1:3172 --insecure-tls-skip-verify \
           -U geode -P Geode1234Abc --no-saved-session \
           "RETURN 1 AS ok" > /dev/null 2>&1; then
          echo "ready after $((attempt * 2))s" >> "$INGEST_LOG"
          break
      fi
      sleep 2
  done

  zig-out/bin/geode query --server 127.0.0.1:3172 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session \
    "CREATE GRAPH abs_eagleg" >> "$INGEST_LOG" 2>&1 || true

  /tmp/capture-cascade-stacks.sh "$SERVER_PID" "$INGEST_LOG" "$STACKS" &
  WATCH_PID=$!

  echo "ingest start: $(date -Iseconds)" >> "$INGEST_LOG"
  START=$(date +%s)
  timeout 1500 bash -c '
    GEODE_DSN="quic://127.0.0.1:3172/abs_eagleg?user=geode&pass=Geode1234Abc&insecure=true" \
      msft-graph seed --input /tmp/rwlock-fairness-data \
      --parallel --workers 16 --chunk-size 1000 2>&1
  ' >> "$INGEST_LOG" 2>&1 || echo "INGEST_TIMED_OUT_OR_FAILED exit=$?" >> "$INGEST_LOG"
  END=$(date +%s)
  echo "ingest end: $(date -Iseconds) wall_clock_s=$((END-START))" >> "$INGEST_LOG"

  sleep 5
  kill -9 $WATCH_PID 2>/dev/null || true
  kill -9 $SERVER_PID 2>/dev/null || true
  ```

- [ ] **Step 2.3: Run the repro (~25 min wall-clock to cascade).**

  ```bash
  chmod +x /tmp/run-rwlock-fairness-repro.sh
  bash /tmp/run-rwlock-fairness-repro.sh
  ```

  Expected: cascade trigger detected at ~10 min into edges_contains; `cascade-stacks.txt` written.

- [ ] **Step 2.4: Verify the stacks file is non-empty + readable.**

  ```bash
  wc -l docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt
  grep -c '^Thread' docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt
  head -20 docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt
  ```

  Expected: hundreds of `Thread <N>` blocks. If the file is short or `gdb`-failed, retry with `sudo sysctl kernel.yama.ptrace_scope=0` first.

- [ ] **Step 2.5: Commit.**

  ```bash
  git add docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-server.log \
          docs/performance/2026-04-25-enterprise-rwlock-fairness/repro-ingest.log \
          docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt
  git commit -m "docs(perf): cascade-time stack capture for rwlock fairness diagnosis (Task 2)"
  ```

### Task 3: Analyse stacks; write `stacks-analysis.md`

**Files:**
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md`

- [ ] **Step 3.1: Cluster threads by what they're blocked on.**

  Inspect `cascade-stacks.txt`. Extract for each `Thread <N>` block the top 3–5 frames. Group threads with identical top-frame patterns.

  Helper command for a quick group-by:

  ```bash
  awk '/^Thread/{block=""; print_block=1; nf=0} \
       print_block && nf < 4 {block=block"\n"$0; nf++} \
       /^$/ && nf >= 4 {print_block=0; print block; print "----"}' \
      docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt \
      | head -300
  ```

  Refine until you have ≤ 6 distinct cluster shapes.

- [ ] **Step 3.2: Identify EXCLUSIVE acquirers being starved.**

  For each cluster, look at the top frames. Threads blocked in:
  - `RwLock.lock_*` / `pthread_rwlock_wrlock` / `futex_wait` with `RwLock.lock` (not `lockShared`) in upper frames → EXCLUSIVE acquirer.
  - `RwLock.lockShared*` / `pthread_rwlock_rdlock` → SHARED holder (the 16 shard workers — expected; not the bug).

  For each EXCLUSIVE-acquirer cluster, walk up the stack until you reach a Geode source frame (`src/.../...zig:NNN`). That's the call site. Examples we expect to find (from the production code map):
  - `src/graph_store.zig:5840` — `acquireWholeGraphLock` (caller from main / checkpoint pass).
  - `src/storage/graph_storage_adapter.zig:3524` — `acquireGraphWriteLock` (bare `lockUncancelable`).
  - `src/storage/graph_storage_adapter.zig:4147` — `acquireWholeGraphExclusive`.
  - `src/storage/graph_storage_adapter.zig:3606` — `acquireGraphWriteLockCancelable` long-deadline branch.
  - Internal callers: `persistSplitPhase`, `checkpointAll`, recovery pump, snapshot helper.

- [ ] **Step 3.3: Write `stacks-analysis.md`.**

  Create the file with this structure (fill in cluster counts and call sites from the actual gdb output):

  ```markdown
  # Cascade-time stack analysis (2026-04-25)

  Source: `cascade-stacks.txt` (gdb thread apply all bt at cascade trigger).

  ## Thread-count summary

  Total threads at capture: <N>.
  Distinct top-3-frame clusters: <M>.

  ## Cluster A — 16 shard workers (SHARED holder, EXPECTED)

  Top frames:
      <paste top-3>

  Source call site: `src/storage/group_commit.zig:<NNN>` (`shardLoop` → `applyShardBatch` → `bulkInsertEdgeWithIdsShardLocked` → `mg.rwlock.lockSharedUncancelable`).

  Status: NOT THE BUG. These hold SHARED for the apply duration; that's correct.

  ## Cluster B — EXCLUSIVE acquirer #1: <name>

  Top frames:
      <paste top-3>

  Source call site: `<file>:<line>` (function `<name>`).
  Why it's blocked: <e.g., "16 SHARED holders never release simultaneously; reader-preferred RwLock keeps queueing this writer behind each new SHARED arrival">.
  Fix recommendation:
  - Option A: switch to `acquireGraphWriteLockCancelable(graph_name, mono_now() + 120 * std.time.ns_per_s)` (writer-preferred slow path).
  - Option B: convert to tryLock-with-backoff, surrender after N attempts and try again later.

  ## Cluster C — EXCLUSIVE acquirer #2: ...

  ...

  ## Recommended fix order

  1. Cluster B (highest impact: blocks core apply path).
  2. Cluster C (medium impact: blocks persistence).
  3. ...

  ## Coord_apply_* registration (side investigation)

  From the same captured stacks, look for any thread inside `ShardedCoordinator.start` or `getOrStartCoordinator` to confirm whether the `runtime_metrics.globalRegistry()` was non-null at registration time. If no thread was inside `start`, the registration ran at server-startup time before traffic — verify `setGlobalRegistry` was called BEFORE the first `getOrStartCoordinator`.
  ```

  **Be specific** — every cluster needs a `file:line` source pointer.

- [ ] **Step 3.4: Commit.**

  ```bash
  git add docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md
  git commit -m "docs(perf): rwlock cascade — stack analysis identifies starved EXCLUSIVE call sites (Task 3)"
  ```

---

## Phase 2 — Fix `coord_apply_*` registration (independent of diagnosis)

### Task 4: Make coord_apply_* counters visible

**Files:**
- Modify: `src/storage/group_commit.zig`

The Task 5 repro of the prior plan showed that `coord_apply_*` counters never appeared in the `metrics:` output, only `mg_rwlock_*`. The likely cause: `getOrStartCoordinator` returns an already-cached coordinator on subsequent calls; `start()` only runs ONCE per graph. If the registry was null at the FIRST `start()` call (because the coordinator gets cached during server startup before any traffic), registration is silently skipped — and there's no later attempt.

This task fixes the timing by:
1. Extracting the `register` block out of `start()` and into a separate `registerWithRuntimeMetrics(*ShardedCoordinator)` method.
2. Calling that helper from `getOrStartCoordinator` AFTER the coordinator is created or cache-loaded. Idempotent: re-registers a counter is fine (the registry's `register` doesn't dedupe; small leak per re-call but bounded by graph count).

- [ ] **Step 4.1: Locate the existing registration block.**

  Run: `grep -n 'coord_apply_batches_total\|register("coord_' src/storage/group_commit.zig`
  Expected: 1 hit inside `ShardedCoordinator.start`, 3 register calls.

- [ ] **Step 4.2: Extract into a `registerWithRuntimeMetrics` method.**

  In `src/storage/group_commit.zig`, find the existing block in `start()`:

  ```zig
          const runtime_metrics = @import("../server/runtime_metrics.zig");
          if (runtime_metrics.globalRegistry()) |reg| {
              reg.register("coord_apply_batches_total", &self.apply_batches_total) catch {};
              reg.register("coord_apply_ops_total", &self.apply_ops_total) catch {};
              reg.register("coord_apply_errors_total", &self.apply_errors_total) catch {};
          }
  ```

  Delete it from `start()`. Add a new method on `ShardedCoordinator`:

  ```zig
      /// Register the coordinator's throughput counters with the
      /// process-global runtime_metrics registry. Idempotent in the
      /// sense that a second call leaks a few `Counter` entries but
      /// does no harm. Caller is responsible for invoking this AFTER
      /// `runtime_metrics.setGlobalRegistry` has run; if the global
      /// registry is null at call time, this is a no-op.
      pub fn registerWithRuntimeMetrics(self: *ShardedCoordinator) void {
          const runtime_metrics = @import("../server/runtime_metrics.zig");
          const reg = runtime_metrics.globalRegistry() orelse return;
          reg.register("coord_apply_batches_total", &self.apply_batches_total) catch {};
          reg.register("coord_apply_ops_total", &self.apply_ops_total) catch {};
          reg.register("coord_apply_errors_total", &self.apply_errors_total) catch {};
      }
  ```

- [ ] **Step 4.3: Call the new method from `getOrStartCoordinator`.**

  Find `getOrStartCoordinator`: `grep -n 'pub fn getOrStartCoordinator' src/storage/group_commit.zig`. Locate the line just before each `return coord;` (there are typically two return paths: cache-hit return and create-then-return). Insert before each return:

  ```zig
      coord.registerWithRuntimeMetrics();
  ```

  This way EVERY caller of `getOrStartCoordinator` triggers registration if-and-only-if the global registry is currently set. Re-registration on cache hits is a no-op-shaped leak (a few `Counter` entries) — bounded by the number of distinct graphs × concurrent coord-start callers, very small.

- [ ] **Step 4.4: Verify build + sharded-coord tests.**

  ```bash
  zig build 2>&1 | tail -5
  zig build test-sharded-coordinator-routing test-sharded-coordinator test-sharded-coordinator-hub 2>&1 | tail -10
  ```

  Expected: clean + all PASS.

- [ ] **Step 4.5: Smoke-test that coord counters now appear under load.**

  ```bash
  mkdir -p /tmp/geode-coord-metrics-smoke-$$
  GEODE_ADMIN_PASSWORD="Geode1234Abc" nohup zig-out/bin/geode serve \
      --data-dir /tmp/geode-coord-metrics-smoke-$$ \
      --listen 127.0.0.1:3173 --log-level info \
      > /tmp/geode-coord-metrics-smoke-$$.log 2>&1 &
  PID=$!
  sleep 4
  zig-out/bin/geode query --server 127.0.0.1:3173 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session \
      "CREATE GRAPH smoke" 2>&1 | head -1
  zig-out/bin/geode query --server 127.0.0.1:3173 --insecure-tls-skip-verify \
      -U geode -P Geode1234Abc --no-saved-session --graph smoke \
      "CREATE (n:X {node_id: 'a'})" 2>&1 | head -1
  sleep 7
  echo "--- metrics lines mentioning coord_apply ---"
  grep 'coord_apply' /tmp/geode-coord-metrics-smoke-$$.log | head -3
  kill -9 $PID 2>/dev/null || true
  ```

  Expected: at least one `coord_apply_batches_total=N coord_apply_ops_total=M ...` line. If still absent, check the order in which `setGlobalRegistry`, `pool.submitDefault(metricsLoop)`, and the QUIC server start happen in `main.zig`.

- [ ] **Step 4.6: Commit.**

  ```bash
  git add src/storage/group_commit.zig
  git commit -m "fix(storage): coord_apply_* register from getOrStartCoordinator (Task 4)

  Previously the registration block ran inside ShardedCoordinator.start,
  which is called once per graph. If runtime_metrics.globalRegistry()
  was null at that exact moment (which the prior repro showed), the
  counters were silently never registered.

  Move registration into a public method on the coordinator and call
  it from every getOrStartCoordinator return path. Idempotent leak of
  a few Counter entries per re-call; bounded by graph count."
  ```

---

## Phase 3 — Apply per-call-site fairness fixes

### Task 5: Apply writer-preferred / tryLock-with-backoff at each starved EXCLUSIVE call site

**Files:**
- Modify: per `stacks-analysis.md` — typically `src/storage/graph_storage_adapter.zig` and/or `src/graph_store.zig`.

This task applies the same pattern to each call site identified by Task 3. The shape varies slightly per site (caller has a `graph_name` ↔ caller has a `*ManagedGraph`), but the principle is identical.

- [ ] **Step 5.1: Read `stacks-analysis.md` for the recommended fix order.**

  ```bash
  cat docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md
  ```

  Note each cluster's call site (file:line) and the recommended fix option (writer-preferred deadline OR tryLock-with-backoff).

- [ ] **Step 5.2: Apply Fix Option A — writer-preferred deadline (preferred where possible).**

  At call sites that have access to a `graph_name: []const u8` parameter, replace bare `mg.rwlock.lockUncancelable(io)` with a call through `acquireGraphWriteLockCancelable`, which already routes through writer-preferred slow path for ≥ 1 s deadlines:

  Before (bare lock):

  ```zig
      // ... inside some helper that has `mg: *ManagedGraph` and io ...
      mg.rwlock.lockUncancelable(io);
      defer mg.rwlock.unlock(io);
      // ... critical section ...
  ```

  After (writer-preferred):

  ```zig
      // ... inside the same helper, but with `graph_name: []const u8` available ...
      const deadline = monoNanosNow() + 120 * std.time.ns_per_s;
      const handle = graph_store.acquireGraphWriteLockCancelable(graph_name, deadline) catch |err| {
          log.warn("acquireGraphWriteLockCancelable timed out", &.{
              Attr.string("graph", graph_name),
              Attr.string("error", @errorName(err)),
              Attr.string("at", @src().file),
          });
          return err;
      };
      defer graph_store.releaseGraphLock(handle);
      // ... critical section ...
  ```

  Apply at every Cluster B/C/... call site whose `stacks-analysis.md` recommends Option A.

- [ ] **Step 5.3: Apply Fix Option B — tryLock-with-bounded-backoff (where Option A doesn't fit).**

  Some internal helpers (e.g., the persistence loop's `adapter.checkpointAll()`) don't have a clean `graph_name` parameter and don't want a hard deadline (they're background work that can wait until next interval). For those, replace bare `lockUncancelable` with a small inline tryLock-with-bounded-backoff loop:

  Before:

  ```zig
      mg.rwlock.lockUncancelable(io);
      defer mg.rwlock.unlock(io);
      // ... critical section ...
  ```

  After:

  ```zig
      var backoff_ns: u64 = 200 * std.time.ns_per_us;          // 200 µs initial
      const max_backoff_ns: u64 = 50 * std.time.ns_per_ms;     // 50 ms cap per attempt
      var attempts: u32 = 0;
      const max_attempts: u32 = 20;                            // ~total ≤ 1 s of backoff
      const lock_ok = while (attempts < max_attempts) : (attempts += 1) {
          if (mg.rwlock.tryLock(io)) break true;
          const ns: u64 = backoff_ns;
          const req = std.os.linux.timespec{
              .sec = @intCast(ns / std.time.ns_per_s),
              .nsec = @intCast(ns % std.time.ns_per_s),
          };
          var rem: std.os.linux.timespec = undefined;
          _ = std.os.linux.nanosleep(&req, &rem);
          backoff_ns = @min(backoff_ns * 2, max_backoff_ns);
      } else false;
      if (!lock_ok) {
          log.warn("rwlock EXCLUSIVE acquire surrendered after backoff — will retry next interval", &.{
              Attr.string("at", @src().file),
          });
          return; // caller (background loop) retries on next tick
      }
      defer mg.rwlock.unlock(io);
      // ... critical section ...
  ```

  Apply at every Cluster call site whose `stacks-analysis.md` recommends Option B.

- [ ] **Step 5.4: Verify build + sharded-coord tests.**

  ```bash
  zig build 2>&1 | tail -5
  zig build test-sharded-coordinator-routing test-sharded-coordinator test-sharded-coordinator-hub 2>&1 | tail -10
  ```

  Expected: clean + all PASS.

- [ ] **Step 5.5: Run the broader suite to verify no callers of the patched helpers regressed.**

  ```bash
  zig build test 2>&1 | grep -iE 'panic:|FAIL|new error:' | head -10
  ```

  Expected: no new panics or fails. Pre-existing environmental failures (FileNotFound, ConnectionRefused, ABRT on features_test) are not in scope.

- [ ] **Step 5.6: Commit (one commit per cluster).**

  Sample commit per cluster:

  ```bash
  git add src/storage/graph_storage_adapter.zig
  git commit -m "fix(storage): writer-preferred mg.rwlock acquire in <site>

  stacks-analysis.md identified <site> as a sustained-SHARED-starved
  EXCLUSIVE acquirer. Route through acquireGraphWriteLockCancelable
  with a 120s deadline (writer-preferred slow path).

  See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md
  cluster <X>."
  ```

  Repeat for each cluster.

---

## Phase 4 — Lock down with a regression test

### Task 6: Integration test — EXCLUSIVE acquire completes under sustained 16-way SHARED contention

**Files:**
- Create: `tests/test_rwlock_fairness_under_load.zig`
- Modify: `build.zig`

The test spawns 16 threads each holding `mg.rwlock` SHARED in a tight loop for ~5 s, while one thread tries to acquire `mg.rwlock` EXCLUSIVE via the writer-preferred path. The EXCLUSIVE acquirer MUST complete in < 30 s. Pre-fix this test would never complete (or take > 30 s); post-fix it completes in well under 30 s.

- [ ] **Step 6.1: Write the test.**

  Create `tests/test_rwlock_fairness_under_load.zig`:

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Regression test pinning fairness on `mg.rwlock` under sustained
  //! 16-way SHARED contention. Pre-fix, EXCLUSIVE acquirers were
  //! starved indefinitely; post-fix, they complete in well under 30 s
  //! via the writer-preferred slow path.

  // CANARY: REQ=REQ-PERF-RWLOCK-FAIRNESS-001; FEATURE="MgRwLockFairness"; ASPECT=ExclusiveAcquireUnderLoad; STATUS=TESTED; TEST=tests/test_rwlock_fairness_under_load.zig; OWNER=perf; UPDATED=2026-04-25

  const std = @import("std");
  const geode = @import("geode");
  const graph_store = geode.graph_store;
  const adapter_mod = geode.graph_storage_adapter;

  const SharedHolderCtx = struct {
      mg: *adapter_mod.ManagedGraph,
      stop: *std.atomic.Value(u32),
  };

  fn sharedHolder(ctx_ptr: *anyopaque) void {
      const ctx: *SharedHolderCtx = @ptrCast(@alignCast(ctx_ptr));
      const io = std.Io.Threaded.global_single_threaded.io();
      while (ctx.stop.load(.acquire) == 0) {
          ctx.mg.rwlock.lockSharedUncancelable(io);
          var rem: std.os.linux.timespec = undefined;
          const req = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
          _ = std.os.linux.nanosleep(&req, &rem);
          ctx.mg.rwlock.unlockShared(io);
      }
  }

  test "EXCLUSIVE acquire completes within 30s under 16-way SHARED contention" {
      const allocator = std.testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
      defer allocator.free(data_dir);

      var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
          .data_dir = data_dir,
          .encryption_key = null,
      });
      defer adapter.deinit();
      const mg = try adapter.getOrCreateGraph("g_fairness");

      var stop = std.atomic.Value(u32).init(0);
      var ctxs: [16]SharedHolderCtx = undefined;
      var threads: [16]std.Thread = undefined;
      for (&ctxs, &threads) |*c, *t| {
          c.* = .{ .mg = mg, .stop = &stop };
          t.* = try std.Thread.spawn(.{}, sharedHolder, .{@as(*anyopaque, @ptrCast(c))});
      }

      // Give the holders a chance to ramp up.
      var rem: std.os.linux.timespec = undefined;
      const ramp_req = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
      _ = std.os.linux.nanosleep(&ramp_req, &rem);

      // Now try to acquire EXCLUSIVE via the writer-preferred path.
      const start_ns = std.time.nanoTimestamp();
      const deadline = @as(u64, @intCast(start_ns)) + 120 * std.time.ns_per_s;
      const handle = try graph_store.acquireGraphWriteLockCancelable("g_fairness", deadline);
      const acquired_ns = std.time.nanoTimestamp();
      const wait_ns: u64 = @intCast(acquired_ns - start_ns);

      graph_store.releaseGraphLock(handle);
      stop.store(1, .release);
      for (threads) |t| t.join();

      const max_wait_ns: u64 = 30 * std.time.ns_per_s;
      if (wait_ns > max_wait_ns) {
          std.debug.print("EXCLUSIVE acquire took {d} ns (= {d:.1} s) — expected < 30 s\n", .{ wait_ns, @as(f64, @floatFromInt(wait_ns)) / 1e9 });
      }
      try std.testing.expect(wait_ns < max_wait_ns);
  }
  ```

- [ ] **Step 6.2: Register in `build.zig`.**

  Find the `test-runtime-metrics` block: `grep -n 'test-runtime-metrics' build.zig`. Immediately after, add:

  ```zig
      const rwlock_fairness_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rwlock_fairness_under_load.zig"), .target = target, .optimize = optimize });
      rwlock_fairness_mod.addImport("geode", root_mod);
      const rwlock_fairness_tests = b.addTest(.{ .root_module = rwlock_fairness_mod });
      const run_rwlock_fairness_tests = b.addRunArtifact(rwlock_fairness_tests);
      test_step.dependOn(&run_rwlock_fairness_tests.step);
      const rwlock_fairness_step = b.step("test-rwlock-fairness-under-load", "Run mg.rwlock fairness regression under sustained 16-way SHARED contention");
      rwlock_fairness_step.dependOn(&run_rwlock_fairness_tests.step);
  ```

- [ ] **Step 6.3: Run the test.**

  ```bash
  zig build test-rwlock-fairness-under-load 2>&1 | tail -10
  ```

  Expected: PASS within ~1–5 s typically; the test's tolerance is 30 s for headroom.

  If it fails (`wait_ns >= 30s`), the fairness fixes from Task 5 didn't reach the call site this test exercises (`acquireGraphWriteLockCancelable` ≥ 1 s deadline path). Re-read `stacks-analysis.md` and find the missing site.

- [ ] **Step 6.4: Commit.**

  ```bash
  git add tests/test_rwlock_fairness_under_load.zig build.zig
  git commit -m "test(perf): mg.rwlock fairness under sustained 16-way SHARED contention (Task 6)"
  ```

---

## Phase 5 — Validate end-to-end

### Task 7: Re-run msft-graph; commit closure

**Files:**
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log`
- Create (committed): `docs/performance/2026-04-25-enterprise-rwlock-fairness/CLOSURE.md`

- [ ] **Step 7.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 7.2: Run the same `/tmp/run-postfix-v2.sh` pattern but pointed at this plan's evidence dir.**

  ```bash
  cp /tmp/run-final-v2.sh /tmp/run-rwlock-fairness-postfix.sh
  sed -i 's|docs/performance/2026-04-24-sharding/phase2-final-run.log|docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log|g' /tmp/run-rwlock-fairness-postfix.sh
  bash /tmp/run-rwlock-fairness-postfix.sh
  ```

- [ ] **Step 7.3: Verify `edges_contains` completes in parallel mode.**

  ```bash
  grep 'seeded edges.*edges_contains' docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log
  # Expected: one matching line — edges_contains MUST complete

  grep -c 'retrying file in serial mode' docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log
  # Expected: 0 (or ≤ 1 if a different file cascades)

  grep -c '40001' docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log
  # Expected: 0

  grep wall_clock_s docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log
  # Expected: a number that reflects true completion, NOT 2700 (timeout cap).
  ```

  Hard-pass criteria:
  - `edges_contains` appears in `seeded edges` lines (it MUST complete in parallel mode).
  - `retrying file in serial mode` count ≤ 1.
  - Wall-clock ≤ 1500 s (25 min) — that's a 75 % improvement over the pre-fix ~6000 s.

  If `edges_contains` still cascades, return to Task 3 with the new stacks and identify which acquirer was missed.

- [ ] **Step 7.4: Write `CLOSURE.md`.**

  Create `docs/performance/2026-04-25-enterprise-rwlock-fairness/CLOSURE.md`:

  ```markdown
  # Enterprise rwlock fairness — closure (2026-04-25)

  ## Outcome

  - `edges_contains.jsonl` (4969 rows) completes in parallel pipeline mode: <YES/NO>.
  - Total wall-clock: <N> s (vs ~6000 s pre-fix).
  - 40001 errors: 0 ✅ (preserved from Phase 2-final).
  - `retrying file in serial mode` count: <N>.

  ## Fixes landed

  - `coord_apply_*` registration timing: commit `<SHA>` (Task 4).
  - rwlock fairness fixes per call site:
    - Cluster <X>: commit `<SHA>` — site `<file:line>`, fix Option A/B.
    - Cluster <Y>: commit `<SHA>` — site `<file:line>`, fix Option A/B.
  - Regression test: commit `<SHA>` (Task 6).

  ## Spec/plan

  Plan: `docs/superpowers/plans/2026-04-25-enterprise-rwlock-fairness.md`.
  Diagnosis: `stacks-analysis.md`.
  Evidence: `cascade-stacks.txt`, `post-fix-run.log`.

  ## Residual / follow-up

  <list anything still left, or "no residual">.
  ```

- [ ] **Step 7.5: Commit.**

  ```bash
  git add docs/performance/2026-04-25-enterprise-rwlock-fairness/post-fix-run.log \
          docs/performance/2026-04-25-enterprise-rwlock-fairness/CLOSURE.md
  git commit -m "docs(perf): rwlock fairness closure — edges_contains completes in parallel mode (Task 7)"
  ```

---

## Self-review results

- **Spec coverage:**
  - Follow-up 1 (capture gdb stacks at cascade time, identify each EXCLUSIVE-acquirer call site) → Tasks 1, 2, 3. ✓
  - Follow-up 2 (apply tryLock-with-backoff or writer-preferred at each identified site) → Task 5 (with explicit Option A vs Option B per stacks-analysis recommendation). ✓
  - Follow-up 3 (fix `coord_apply_*` registration timing) → Task 4. ✓
  - Lock-down regression test → Task 6. ✓
  - End-to-end validation → Task 7. ✓

- **Placeholder scan:** All steps have concrete code/commands. `stacks-analysis.md`'s template (Task 3.3) has placeholders for cluster names but those are the OUTPUT of the diagnosis — not a plan TODO.

- **Type consistency:**
  - `monoNanosNow` referenced in Task 5.2 — exists at file scope of `src/storage/graph_storage_adapter.zig`.
  - `acquireGraphWriteLockCancelable` reference — public, signature `(graph_name: []const u8, deadline_mono_ns: u64) !GraphLockHandle` per `src/graph_store.zig:5433`.
  - `releaseGraphLock(handle)` reference — public, takes `GraphLockHandle` per `src/graph_store.zig:5522`.
  - `runtime_metrics.globalRegistry()` reference — public, returns `?*Registry` per `src/server/runtime_metrics.zig`.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-enterprise-rwlock-fairness.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, spec + quality review between, fast iteration on the diagnosis-conditional fix work.
2. **Inline execution** — execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints.

**Which approach?**
