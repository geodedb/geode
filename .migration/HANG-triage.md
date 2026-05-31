# HANG / CRASH triage: `fulltext_search()` over the QUIC server

> **Branch** `feat/storage-lib-migration`, **HEAD** `2ef54aad`
> ("fix(fts): lazily reopen on-disk fulltext index after store restart").
> **Binary** `./zig-out/bin/geode`, mtime 2026-05-31 09:36 — NOT rebuilt (per
> instructions; this binary contains the full A4/A5 FTS work and already
> reproduced the bug in the captured A7 run).

## TL;DR — the "hang" is a *downstream symptom of a server crash*, not a deadlock or a spin

The decisive evidence is the prior A7 run (`/tmp/a7_probe.out`, `/tmp/a7_run3.log`),
which captured a **complete, symbolized Zig panic stack trace**. It overturns the
original framing:

1. `UNWIND fulltext_search('doc_body_idx','fox') AS r RETURN …` does **NOT hang on
   its own** — it returns **`42000 "parse error"` immediately** (§2). The FTS
   function never even executes on the server path; the GQL parser rejects the
   statement shape first.
2. The server **crashes (SIGABRT, "reached unreachable code")** on
   `DROP INDEX doc_body_idx`. The crash is an **owning-thread assertion** inside
   the vendored `fts_storage` library's `Engine.flush()`.
3. The "30s timeout / hang" the brief describes is the **next client query
   (`SHOW INDEXES`) trying to reach the now-dead server** — the connection never
   establishes, so it times out at 30s. That is a **dead-server timeout**, not a
   lock deadlock and not an infinite loop.

So there are two real defects (a crash and a parse-error), and the apparent
"hangs" are purely a consequence of the crash.

## 1. Environment / tooling

- `nproc` = 56, but the tool-result channel **repeatedly went fully dark under
  load** (many consecutive `Bash`/`Read`/`ToolSearch` calls returned empty
  payloads, including a bare `echo`), exactly as CLAUDE.md warns ("Tool output
  garbles under load — redirect to files, Read back, retry"). I did not need a
  fresh live repro: A7 already captured the crash with a full symbolized trace,
  which is strictly better than a `gdb -p` snapshot of a hung process. `gdb` and
  `top` are present (`/usr/bin/gdb`, `/usr/bin/top`) for future confirmation.
- Source verified directly this session:
  `src/storage/fts_storage_adapter.zig` (full, 331 lines) and the panic frames in
  `/tmp/a7_run3.log`.

## 2. Observed behavior (from `/tmp/a7_probe.out`, verbatim)

```
CREATE (:Doc {body:'the quick brown fox jumps'})                      -> 00000 ok
CREATE (:Doc {body:'a lazy sleeping dog'})                            -> 00000 ok
CREATE (:Doc {body:'a gigantic blue whale swims'})                    -> 00000 ok
CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext      -> 00000 ok
UNWIND fulltext_search('doc_body_idx','fox') AS r RETURN r.node_id…   -> 42000 "parse error"  (Defect X)
UNWIND fulltext_search(...) AS r MATCH (n) WHERE id(n)=r.node_id …    -> 42000 "parse error"  (Defect X)
SHOW INDEXES   -> ok: lists doc_body_idx (fulltext, Doc, body) + auto_idx_Doc_id
DROP INDEX doc_body_idx   -> "Error: query execution failed";  SERVER PROCESS Aborted (SIGABRT)  (Defect Y)
SHOW INDEXES   -> "Error: query timed out after 30 seconds"   (server is dead — the "hang")
```

Note: the harness specs `fts_storage_basic.yml` (9/9) and
`fulltext_search_basic.yml` PASS in the same run — they exercise CREATE/SHOW and
the storage-adapter layer, but **not** the `UNWIND fulltext_search(...)` query
shape and **not** `DROP INDEX`, which is why they stay green while the probe
hits both defects.

## 3. The crash stack trace (load-bearing evidence, from `/tmp/a7_run3.log`)

```
thread 240791 panic: reached unreachable code
  std/debug.zig:420  assert            -> if (!ok) unreachable;
  fts_storage .../src/engine.zig:419   assertOwnedByCurrentThread
        std.debug.assert(self.owning_thread == std.Thread.getCurrentId());
  fts_storage .../src/engine.zig:984   flush
        self.assertOwnedByCurrentThread();
  src/storage/fts_storage_adapter.zig:112   deinit            ie.engine.flush() catch {};
  src/storage/graph_storage_adapter.zig:1006 deinit           fa.deinit();
  src/storage/graph_storage_adapter.zig:1424 deinit           entry.value_ptr.*.deinit(self.allocator);
  src/graph_store.zig:7043   deinitAdapter                    castAdapter(ctx).deinit();
  src/graph_store.zig:7092   deinitGlobalAdapter              vt.deinitFn(vt.ctx);
  src/graph_store.zig:7850   deinitGlobalStore
  src/server/main.zig:1703   main                             graph_store.deinitGlobalStore();
  src/cli/main.zig:849       cmdServe                         server_main.main();
```

(The probe's `DROP INDEX` aborts via the *same* assert reached through
`dropIndex` → `ie.engine.flush()` at `fts_storage_adapter.zig:222`; the trace
above is the shutdown path through `deinit` at line 112, which re-trips it. Both
call `Engine.flush()` from a thread that does not own the engine.)

## 4. Root cause (precise, source-verified)

`fts_storage.Engine` is a **thread-pinned single-writer engine**: at
`Engine.init` it records `owning_thread = std.Thread.getCurrentId()` and every
mutating op asserts the caller is that exact OS thread —
`engine.zig:419 assertOwnedByCurrentThread`, invoked from `engine.zig:984 flush`
(and the other mutators).

geode's adapter (`src/storage/fts_storage_adapter.zig`) guards each engine with a
per-index `write_mu` (`IndexEngine.write_mu`, line 75) and its doc comment
(lines 29–30) claims this "honors the fts-storage single-writer contract."
**That is the bug's core misconception:** `write_mu` only enforces *mutual
exclusion* (no two threads at once); it does **not** enforce *thread affinity*
(always the *same* thread). The library requires the latter. So:

- `Engine.init` runs on whichever **QUIC worker thread** served the
  `CREATE INDEX` (or, at HEAD `2ef54aad`, whichever worker first lazily reopens
  the index after restart) → `owning_thread` = that worker's id.
- `Engine.flush()` then runs from a **different thread**:
  - on `DROP INDEX`, the worker thread handling that statement
    (`dropIndex` → `ie.engine.flush()`, `fts_storage_adapter.zig:222`), and/or
  - on shutdown, the **main thread** running `deinitGlobalStore`
    (`deinit` → `ie.engine.flush()`, `fts_storage_adapter.zig:112`, reached from
    `server/main.zig:1703`).
- `owning_thread != getCurrentId()` → `assert` → `unreachable` → **SIGABRT**.

This is a **thread-affinity violation introduced/exposed by the storage-lib
migration**: geode's server is multi-threaded ("thread pool initialized,
64 workers" in the run log) and routes successive statements to *different* pool
threads, but the engine is pinned to its creator thread. The lazy-reopen change
at HEAD widens the window further: the engine can now be (re)created on an
arbitrary worker that happens to miss the in-memory registry, making the
creator-thread ≠ teardown/drop-thread mismatch the common case rather than the
exception.

**Exact crash site:** `src/storage/fts_storage_adapter.zig:112`
(`ie.engine.flush()` in `deinit`) — and the identical pattern at line 222
(`ie.engine.flush()` in `dropIndex`) — asserting at
`fts_storage/src/engine.zig:419` via `engine.zig:984`.

**Why the in-process test (`tests/test_fts_e2e.zig`) does not crash:** it runs
create / search / teardown all on the **same single test thread**, so
`owning_thread == getCurrentId()` always holds and the assert never fires; it
also calls `execution.executeStatementWithContext` directly, with no wire GQL
parser, so it never hits Defect X either.

## 5. Recommended fixes (DIAGNOSE-ONLY — do NOT implement yet)

Two independent issues; both need fixing.

### Fix Y — the crash (HIGH priority; this is what produces the "hang")

Honor the engine's single-thread contract for **every** mutating/lifecycle call
(`init`, `indexDocument`, `indexDocumentBatch`, `deleteDocument`, `flush`,
`deinit`), not just mutual exclusion. Options, smallest first:

1. **Re-bind ownership to the current thread under `write_mu`, immediately before
   each exclusive op.** The cleanest minimal change. Add a tiny setter to the
   vendored library, e.g. `Engine.adoptCurrentThread()` that does
   `self.owning_thread = std.Thread.getCurrentId();`, and call it inside the
   adapter while holding the relevant lock — specifically before
   `ie.engine.flush()` at `fts_storage_adapter.zig:112` (deinit), line 222
   (dropIndex), and at the top of `flush`/`indexNode`/`indexNodeBatch`/
   `deleteNode` (they already hold `write_mu`). Since `write_mu` guarantees no
   other thread is inside the engine at that moment, rebinding the owner to the
   caller is safe and satisfies the assert. **NOTE:** `deinit` (line 104–121) and
   `dropIndex` (213–232) currently call `flush()` WITHOUT taking `write_mu` —
   that must be fixed too (take `ie.write_mu` around the flush+deinit so the
   rebind is race-free).

2. **Pin all ops for an engine to one dedicated executor thread** (a per-engine
   single-thread queue). Most faithful to the library's intent, but heavier.

3. **At shutdown, post each engine's flush+deinit to its owning thread and join**
   instead of flushing from the main thread.

Recommended: **(1)** — add `adoptCurrentThread()` to the library and call it
under `write_mu` before each exclusive engine op; also wrap the `deinit`/`dropIndex`
flush in `write_mu`. Minimal, local, and matches the adapter's existing
serialization model.

Do **NOT** "fix" this by deleting the assert in the vendored library — it is
correctly catching real cross-thread misuse of a single-writer engine; silencing
it risks data corruption.

### Fix X — the `UNWIND fulltext_search(...)` parse error (separate, MEDIUM)

The server GQL parser rejects a Geode-extension function call as the *source*
expression of `UNWIND`, returning `42000` immediately. Locate where `UNWIND
<expr>` is parsed in `src/gql/` and where function-call expressions /
`fulltext_search` are recognized, and make an extension function call a valid
`UNWIND` source on the **server parse path** (parity with the in-process path the
e2e test uses). The eval-side dispatch already exists (`eval.evalFulltextFunction`,
`eval.zig:~3841`); the gap is purely in the wire/server parse acceptance, not in
execution.

## 6. Does the DROP-INDEX crash share a root with the "hang"? — YES (same root)

They are the **same root cause**, not independent. The DROP-INDEX crash *is* the
owning-thread assert (§3/§4). The "hang" is purely downstream: once `DROP INDEX`
aborts the server, the next client query cannot connect and times out at 30s.
There is **no lock deadlock and no infinite loop** on the FTS path. Fixing the
thread-affinity violation (Fix Y) removes both the crash and the cascading 30s
timeouts. Defect X (the `UNWIND` parse error) is the one genuinely separate issue
— and notably, even after Fix X lands, the FTS *query* would still ultimately
crash the server on teardown/drop until Fix Y is in, so Fix Y is the priority.

## 7. Live-confirmation plan (run when the tool channel is healthy)

The crash is already proven by the captured trace; this validates the mechanism
and any fix:

```bash
DATADIR=$(mktemp -d /tmp/geode-fts-XXXXXX); PORT=3199; PW='GeodeTestPassword123!'; BIN=./zig-out/bin/geode
GEODE_ALLOW_TEST_AUDIT_KEYS=1 "$BIN" serve --listen 127.0.0.1:$PORT --data-dir "$DATADIR" -U geode -P "$PW" > /tmp/srv.log 2>&1 &
q(){ timeout 35 "$BIN" query --server 127.0.0.1:$PORT -U geode -P "$PW" --insecure-tls-skip-verify - <<<"$1"; echo "exit=$?"; }
q "CREATE (:Doc {body:'the quick brown fox'})"
q "CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext"
q "UNWIND fulltext_search('doc_body_idx','fox') AS r RETURN r.node_id"   # expect 42000 parse error (Defect X)
q "DROP INDEX doc_body_idx"                                              # expect server SIGABRT (Defect Y)
grep -nE "assertOwnedByCurrentThread|owning_thread|reached unreachable" /tmp/srv.log   # confirm the assert
```

If `srv.log` shows the same `engine.zig:419 assertOwnedByCurrentThread` panic as
`/tmp/a7_run3.log`, the diagnosis is confirmed. To make the creator-vs-flusher
thread mismatch explicit, temporarily log `std.Thread.getCurrentId()` at
`Engine.init` and at `flush()` and compare against the `thread NNNN` in the
panic header.
