# TODO

## Identity of Vertices / Edges / User Accounts / Roles / Permissions / etc...

- [ ] Move everything to using UUIDv7 by default for ids not integers

## REPL 

- [ ] Complete the Client REPL
    - Add command history
    - Add auto-completion
    - Add multi-line input support
    - Add better error handling and reporting

## Storage & Backup

* [ ] **`src/storage/s3_backup.zig`**

  * [ ] `createArchive` / `createWALArchive` – no archiving logic, just return temp paths.
  * [ ] `initiateMultipartUpload`, `uploadPart`, `completeMultipartUpload` – stubbed, return dummy strings.
  * [ ] `putObject`, `getObject`, `downloadFile` – all empty implementations.
  * [ ] No error handling, concurrency, or file cleanup.
  * [ ] No actual integration with AWS SDK or HTTP client.

## Query Optimization

* [ ] **`src/planner/query_optimizer.zig`**

  * [ ] `planJoinOrder` – placeholder; no dynamic programming or heuristic plan search.
  * [ ] `estimateCardinality` – hard-coded constants (`1000`, `100`); no statistics used.
  * [ ] `pushDownPredicates`, `eliminateRedundantSorts`, `mergeConsecutiveFilters` – recursive no-ops.
  * [ ] `considerParallelization` – dummy logic with fixed thresholds.
  * [ ] `indexAppliesToTable` – unsafe substring heuristic; could mis-match unrelated indices.

## Recursive Queries

* [ ] **`src/planner/recursive.zig`**

  * [ ] `buildPathFindingCTE`, `buildTransitiveClosureCTE` – return `error.NotImplemented`.
  * [ ] Disk spill handling (`spillToDisk`) – counter only; no I/O implemented.
  * [ ] Cycle detection (`detectCyclesDFS`, `UnionFind`, `Topological`) – empty stubs.
  * [ ] Path building (`buildPaths`, `extractPaths`) – unimplemented.
  * [ ] `processDistinctUnion` – does nothing.
  * [ ] Many functions ignore parameters with `_ = self`.

## Streaming / CDC

* [ ] **`src/streaming/cdc.zig`**

  * [ ] `captureEvent` – always uses transaction_id = 0 (TODO comment).
  * [ ] `sendToKafka`, `writeToFile`, `sendToWebhook` – no logic.
  * [ ] `WindowState.addEvent` / `shouldTrigger` – empty; windows never trigger.
  * [ ] Missing batching, acking, and error handling.
  * [ ] Effectively no CDC output is produced.

## Distributed Transactions

* [ ] **`src/distributed/twophase.zig`**

  * [ ] `prepare` – sets participant states; no network messages.
  * [ ] `commit` – marks committed; no persistence or quorum checks.
  * [ ] `abort` – skips undo log application.
  * [ ] Participant `handleCommit` / `handleAbort` – ignore ops; do not touch storage.
  * [ ] Missing recovery, coordinator election, and timeout handling.
  * [ ] Uses `_ = op` / `_ = undo_entry`; possible inconsistent state after failures.

## Multi-Graph Management

* [ ] **`src/storage/multi_graph.zig`**

  * [ ] `GraphDescriptor.owner` fixed to `"system"`.
  * [ ] `persistGraphMetadata` / `removeGraphMetadata` – stubs.
  * [ ] No catalog or durable metadata.
  * [ ] No user ownership or ACL enforcement.

## Sharding / Distribution

* [ ] **`src/distributed/sharding.zig`**

  * [ ] `executeMigration`, `migrateData`, `migrateAllData` – all TODOs.
  * [ ] `getRangeShardId`, `getGraphAwareShardId`, `getGeoShardId` – always return first shard.
  * [ ] `rangeOverlaps` – always `true`; range scans broadcast to all shards.
  * [ ] `splitShard` / `mergeShards` – call unimplemented migration; data loss risk.
  * [ ] `handleShardFailure` – selects **oldest** replica (`max(last_heartbeat)`) as new primary (inverted logic).
  * [ ] No consistency or resync protocol.

## Distributed Query Coordination

* [ ] **`src/distributed/query_coordinator.zig`**

  * [ ] `planDistributedQuery` – returns all shards; no predicate pruning.
  * [ ] `executeLocalFragment` – returns empty results.
  * [ ] Sequential `for` loop; no true parallelism.
  * [ ] `compareRows` – always `false`; ORDER BY results undefined.
  * [ ] `mergeOrderedResults` – sorts full dataset then truncates; O(n log n) inefficiency.

## Parser

* [ ] **`src/gql.zig`**

  * [ ] Skipped test marked `error.SkipZigTest` for string literal parsing in `STARTS WITH`.
  * [ ] Parser misclassifies some quoted strings as identifiers.
  * [ ] Certain GQL syntaxes currently unparsable.

## Materialized Views

* [ ] **`src/storage/materialized_views.zig`**

  * [ ] `CostEstimator.estimateCost` – returns 0.0.
  * [ ] `extractColumns`, `createDefaultIndexes`, `extractDependencies` – return empty lists.
  * [ ] `scheduleRefresh`, `waitForRefresh` – no implementation.
  * [ ] `performCompleteRefresh` – ignores differential refresh logic.
  * [ ] `findApplicableViews` – returns empty; `rewriteQuery` – returns unmodified query.
  * [ ] Materialized views never actually used by planner.
  * [ ] `parsed_query` pointer freed but still stored → **dangling pointer / use-after-free**.
  * [ ] Missing deinit/destructor; potential memory leaks for plans & names.

---

### Summary

* 80–90 % of advanced subsystems (distributed, optimizer, materialized views, CDC, 2PC, sharding) are **stub or placeholder code**.
* Numerous `TODO` and `_ =` placeholders indicate unexecuted logic.
* Several unsafe memory and logic bugs: dangling AST pointer, inverted failover comparator, empty undo logs, and broadcast range scans.
* Overall: the `.zig` sources compile but many critical database features are **non-functional scaffolding** rather than implemented behavior.

# 🧩 Geode Unified CLI & REPL Issues — Zig Source Audit (Markdown Checklist)

This checklist captures **all issues** in Zig code preventing Geode from being a single-binary CLI (`geode`) and all formatting/logic issues in the REPL implementation.

---

## 🧱 Unified CLI Integration Issues

### `src/cli/main.zig`

* [ ] **`serve` subcommand spawns external process**

  * Found around **L659–L667** and **L736–L744**
  * Uses `std.process.Child.spawnAndWait` to launch `geoded` instead of calling an internal function.
  * ❌ Breaks the one-binary design — server should be started via a local function, e.g. `server.start()`.
* [ ] **`query` subcommand spawns external client (`geodec`)**

  * Around **L805–L813**, **L974–L983**
  * Executes `geodec` binary with query args.
  * Should instead invoke the in-process query runner or RPC client.
* [ ] **Fallback logic when binaries not found**

  * **L741–L750** prints “`geoded not found`” / suggests building it — should be removed once unified.
  * Replace with internal dispatch through a function table or `switch(subcommand)`.
* [ ] **Global flag propagation incomplete**

  * `--json`, `--verbose`, `--audit*` parsed but not applied to subcommands when internally dispatched.
  * Unify config propagation through a shared `Context` struct.

* [ ] `geoded` and `geodec` binaries still exist in `src/bin/` and are built by default.
  * Remove these binaries and their build targets once unified.
  * update integration tests to call `geode serve` and `geode query` instead.
  * update geodetestlab scripts to use unified CLI.

---

## 🧮 REPL Implementation Issues

### General (`src/repl_loop.zig`, `src/repl_dispatch.zig`, `src/repl_parse.zig`)

* [ ] **Duplicate welcome message**

  * `main.zig` prints “`Geode Shell v0.16.0`”; REPL prints `v0.18.0` banner.
  * Only keep the `repl_loop.zig` banner (`printWelcomeMessage`) for version accuracy.
* [ ] **Disconnected REPL session**

  * `ClientSession.connect()` (**L13–L21**, `repl_dispatch.zig`) is a stub; does not open QUIC/TLS connection.
  * `ClientSession.runGql()` (**L30–L38**) fabricates JSON output; not wired to backend.
  * Implement real QUIC client integration using the internal networking layer (`spyderorg/quic`).
* [ ] **Output format ignored**

  * `--format` flag and `\format` command parsed but never affect output.
  * `executeGql` (**L327–L335**, `repl_dispatch.zig`) always prints JSON.
  * Add a formatter layer to handle `table`, `csv`, and `json`.
* [ ] **Timing flag inert**

  * `\timing` toggles print only (`repl_loop.zig` **L254–L263**) but no timing logic.
  * Wrap query execution with `std.time.Timer` and display elapsed time when enabled.
* [ ] **Incomplete multi-line input support**

  * `isComplete()` (**L2–L10**, `repl_parse.zig`) only checks for semicolon/bracket balance.
  * `needsContinuation()` defined but never used.
  * Show continuation prompt (`...>`) and buffer until query completes.
  * Don’t re-echo previous input lines on continuation.
* [ ] **Prompt formatting**

  * After `\clear`, screen clears but no prompt is re-drawn immediately.
  * Ensure prompt is re-rendered after clear to avoid user confusion.
  * Add visual distinction for multi-line mode (e.g., change prompt color or symbol).
* [ ] **ANSI color output not consistently gated**

  * Some messages print color regardless of `NO_COLOR` or `--json`.
  * Ensure all colorized output checks `platform.isStdoutTty()` or global `context.json_mode`.
* [ ] **Global `--json` flag ignored**

  * Running `geode --json shell` doesn’t affect REPL output.
  * Should disable banners and emit machine-readable output for automation.
* [ ] **Error message formatting inconsistent**

  * Error prints mix raw JSON strings and colored text.
  * Standardize via `printError(msg: []const u8, json_mode: bool)` utility.
* [ ] **History and state not persisted**

  * Command history resets each session; no `~/.geode_history`.
  * Add `std.fs` file-based persistent history (respecting config path).

---

## 🧭 Structural & Code Quality Improvements

* [ ] **Refactor CLI dispatch table**

  * Create a single `const commands = std.AutoHashMap([]const u8, fn (ctx: *Context) !void)` in `main.zig`.
  * Remove subprocess handling; map subcommands directly to internal functions.
* [ ] **Integrate `geoded` and `geodec` logic**

  * Move entrypoints from old binaries into reusable modules (`server.zig`, `client.zig`).
  * Ensure both can run as tasks in the same process via async/await.
* [ ] **Unify config and audit context**

  * Current duplication across CLI, server, and client.
  * Consolidate flags into a global `Config` struct passed to all subcommands.
* [ ] **Add integration tests for subcommands**

  * Verify `geode serve`, `geode query`, `geode shell`, etc., all operate without external binaries.
  * Simulate full CLI lifecycle using `std.testing.execCmd`.

---

## ✅ Summary

| Area       | Issue                              | Fix                              |
| ---------- | ---------------------------------- | -------------------------------- |
| CLI        | `serve`/`query` spawn subprocesses | Replace with in-process calls    |
| CLI        | Missing flag propagation           | Use shared context struct        |
| REPL       | Duplicate banners                  | Remove old shell message         |
| REPL       | Fake connection                    | Wire QUIC/TLS client             |
| REPL       | Output format ignored              | Add formatter                    |
| REPL       | `\timing` inert                    | Use `std.time.Timer`             |
| REPL       | Multi-line UX                      | Use continuation prompt          |
| REPL       | Color/JSON inconsistency           | Centralize formatting            |
| REPL       | History ephemeral                  | Add persistent file              |
| Structural | Commands scattered                 | Implement unified dispatch table |

