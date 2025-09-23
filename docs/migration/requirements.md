Below is a concrete, implementation‑level spec for a **Geode Migration Engine (GME)** modeled after `golang-migrate`. It covers file layout, metadata schema, locking, idempotency, CLI + library APIs, enforcement **inside the database**, CI/CD patterns, and example code. I’ve called out places where we should be stricter than `golang-migrate` and why.

---

## 0) Goals & Non‑Goals

**Goals**

- Deterministic, **idempotent** up/down migrations for graph **schema and data** per‑graph namespace.
- Single source of truth in DB: **migration ledger** + **lock** + **enforcement policy**.
- CLI and embeddable libraries (Go first, Zig native shim, Python wrapper).
- Safe in HA/K8s: **exactly one** runner at a time; fast failure if lock can’t be taken.
- Production‑grade UX parity with `golang-migrate`: `create`, `up`, `down`, `goto`, `force`, `version`, `drop`, `fix`, `status`, `validate`. ([Go Packages][1])

**Non‑Goals (v1)**

- Cross‑graph transactional migrations.
- Automatic diff/planner (can come later, akin to Atlas; not required for MVP). ([atlasgo.io][2])

---

## 1) Migration artifacts (disk)

**Directory layout**

```
migrations/
  <graph-name>/
    20250922010101_init.up.gql
    20250922010101_init.down.gql
    20250923121500_add_index.up.gql
    20250923121500_add_index.down.gql
    ...
```

- **Versioning**: timestamp (UTC `YYYYMMDDHHMMSS`) or zero‑padded sequence. Both must **sort lexicographically** and be **unique**. `golang-migrate` uses `VERSION_description.up/down.sql` naming; same pattern here with `.gql`. ([Go Packages][1])
- **File pairs** are mandatory: `.up.gql` and `.down.gql`. Duplicate versions must hard‑fail (detect duplicates up front; `golang-migrate` errors on duplicate). ([GitHub][3])
- **Optional sidecar**: `<version>_<name>.meta.yaml` for:

  - `preconditions`: GQL boolean checks that must hold before apply.
  - `postconditions`: assertions after apply.
  - `chunk` config for data migrations (batch size, resume token key).
  - `idempotent: true|false` (fail if script changed behavior vs expectations).

**Idempotency rules for scripts**

- Prefer **IF EXISTS / IF NOT EXISTS** guards in GQL where supported.
- Otherwise use `preconditions` queries (e.g., “label X exists”) and **no‑op** if already satisfied.
- Data migrations must be chunked + resumable (see §7).

---

## 2) On‑disk → In‑DB metadata

**System tables (per Geode database, keyed by `graph`)**

1. `geode_schema_migrations`

```
graph            STRING   not null
version          INT64    not null
name             STRING   not null
checksum_sha256  STRING   not null
applied_at       TIMESTAMP not null
execution_ms     INT64    not null
dirty            BOOL     not null default false
direction        ENUM('up','down') not null
runner_id        STRING   not null        -- instance/pod id
PRIMARY KEY (graph, version)
```

- **dirty** mirrors `golang-migrate` semantics: a failed migration leaves DB **dirty**; subsequent migrations are blocked until **fixed/forced**. ([Stack Overflow][4])

2. `geode_schema_lock`

```
graph            STRING   not null
lock_id          INT64    not null default 1
owner_session    STRING   not null
acquired_at      TIMESTAMP not null
expires_at       TIMESTAMP not null
heartbeat_ms     INT64 not null
PRIMARY KEY(graph, lock_id)
```

- Matches the spirit of migrate’s lock table; allow configurable lock strategy and table name (we’ll still default to `geode_schema_lock`). `migrate` exposes lock table + advisory lock options; we provide a robust TTL/heartbeat to break stale locks. ([Go Packages][5])

3. `geode_migration_policy`

```
graph              STRING   not null PRIMARY KEY
enforce            BOOL     not null default false
required_version   INT64    null        -- minimum version required to write
deny_mode          ENUM('writes','all') not null default 'writes'
min_client_semver  STRING   null
note               STRING   null
```

**Checksums**

- SHA‑256 over normalized file content (LF endings, strip trailing spaces). Any mismatch vs recorded checksum → **validate** fails; **force** required to override.

---

## 3) Execution model

**Atomicity**

- Each migration runs in a **transaction**. If any statement fails, rollback and mark row `dirty=true` for that `version`. Dirty blocks further actions until `fix/force`. (Same resilience model as `golang-migrate`). ([Stack Overflow][4])

**Locking**

- Runner must acquire `(graph, lock_id=1)` with TTL, then heartbeat every `heartbeat_ms`. If lock not acquired within `--lock-timeout`, exit non‑zero (parity with `migrate -lock-timeout`). ([Go Packages][1])
- On crash: lock expires; next runner can proceed (compare to stale lock issues in migrate; we solve via TTL + heartbeat). ([GitHub][6])

**Plan**

- Load FS migrations for `<graph>`, sort by version.
- Compare with ledger:

  - **Missing** in ledger → candidates for `up`.
  - **Extra in ledger** (i.e., down available) → candidates for `down`.
  - **Checksum drift** on applied migration → **validate** fails (requires manual remediation or `force`).

- Enforce **no gaps** and **no duplicates**; fail fast. (Duplicates are a known footgun in migrate; we detect early). ([GitHub][3])

**Signals**

- Respect SIGINT to stop at a safe point (current migration completes/rolls back, like migrate). ([Go Packages][1])

---

## 4) CLI

Binary: `geodemigrate`

**Global flags**

```
  --graph <name>                 # required
  --path  <dir|url>              # file:// s3:// gcs:// http(s):// git://
  --lock-timeout <sec>           # default 15
  --verbose
  --dry-run
```

**Commands** (parity with `golang-migrate` + a few extras)

- `create [-seq|-ts] NAME` → generate `<version>_<name>.up.gql/.down.gql`. `-seq` uses zero‑padded N digits; `-ts` uses timestamp. ([Go Packages][1])
- `up [N]` → apply all or next N ups. ([Go Packages][1])
- `down [N]` → revert last N. ([Go Packages][1])
- `goto V` → migrate to version V. ([Go Packages][1])
- `version` → print current DB version & dirty status. ([Go Packages][1])
- `force V` → set version to V without running scripts (clears dirty). **Dangerous;** prints big warning. ([Go Packages][1])
- `drop` → drop **graph namespace data** (if supported) or refuse unless `--i-know-what-im-doing`. ([Go Packages][1])
- `status` → show FS vs DB: pending, applied, drift, dirty.
- `validate` → checksum audit of applied migrations.
- `fix` → utility to rename/renumber files to match consistent scheme (optional, but users expect similar tooling). ([FreeCodeCamp][7])
- `policy --enforce [on|off] --required <V> --deny [writes|all]` → manage **in‑DB enforcement** (see §6).

**Exit codes**

- `0` success / no changes
- `1` generic failure
- `10` lock timeout
- `11` dirty state
- `12` validation drift

**Best‑practice guardrails**

- Refuse multi‑runner patterns in Kubernetes: fail fast if lock wait > timeout; **do not** run migrations from _every_ app pod on startup (common anti‑pattern). ([Reddit][8])

---

## 5) Library APIs

### Go (first‑class)

```go
package migrate

type Source interface { /* file/s3/http/git… */ }
type Logger interface  { Infof(string, ...any); Errorf(string, ...any) }

type Config struct {
    Graph         string
    Source        Source
    LockTimeout   time.Duration
    Heartbeat     time.Duration
    EnforcePolicy bool // also check graph policy gate on connect
    Logger        Logger
}

type Engine struct { /* holds conn, cfg, state */ }

func New(ctx context.Context, conn GeodeConn, cfg Config) (*Engine, error)

func (e *Engine) Up(ctx context.Context, n int) error
func (e *Engine) Down(ctx context.Context, n int) error
func (e *Engine) Goto(ctx context.Context, version int64) error
func (e *Engine) Force(ctx context.Context, version int64) error
func (e *Engine) Version(ctx context.Context) (ver int64, dirty bool, err error)
func (e *Engine) Status(ctx context.Context) (Status, error)
func (e *Engine) Validate(ctx context.Context) error
func (e *Engine) ApplyPolicy(ctx context.Context, p Policy) error
```

**Usage (Go)**

```go
package main

import (
  "context"
  "log"
  "time"
  gm "github.com/spyderorg/geode/migrate"
)

func main() {
  ctx := context.Background()
  conn := mustConnectGeode("quic://127.0.0.1:7567")

  eng, err := gm.New(ctx, conn, gm.Config{
    Graph: "social",
    Source: gm.FileSource("./migrations/social"),
    LockTimeout: 15 * time.Second,
    Heartbeat: 2 * time.Second,
  })
  if err != nil { log.Fatal(err) }

  if err := eng.Validate(ctx); err != nil { log.Fatal(err) }
  if err := eng.Up(ctx, 0); err != nil { log.Fatal(err) } // 0 = all pending
}
```

### Zig (thin shim)

```zig
pub fn migrateUp(allocator: *std.mem.Allocator, conn: *GeodeConn, graph: []const u8, path: []const u8) !void {
    var eng = try Engine.init(allocator, conn, .{ .graph = graph, .source = .{ .kind = .file, .path = path }});
    defer eng.deinit();
    try eng.validate();
    try eng.up(0); // all
}
```

### Python (wrapper around CLI)

```python
import subprocess, sys
subprocess.check_call([
  "geodemigrate",
  "--graph", "social",
  "--path", "./migrations/social",
  "up"
])
```

---

## 6) **Enforcement inside the database** (critical requirement)

Make migrations **enforceable by Geode**, not just “client convention”.

**Policy Gate (per graph)**

- `geode_migration_policy.enforce=true` and `required_version=V`.
- **Server‑side checks**:

  - At **transaction begin** and **commit**, if `current_graph_version < required_version`:

    - If `deny_mode='writes'`: reject any write (DML/DDL) with clear error **SQLSTATE‑like** code “schema_version_too_old”.
    - If `deny_mode='all'`: reject all statements except migration frames.

- **Session property** `session.graph_version_seen` set from ledger when session begins; if migration bumps version mid‑txn, commit must fail with retry hint (optimistic protection).
- **Audit**: log enforcement denials with user/session.

**Bumping current version**

- On successful `up` apply to version `V`, set **graph current version** atomically with ledger insert.
- Optionally support `policy.min_client_semver`: server may reject outdated CLI/library versions.

This closes the loop so prod **cannot drift**: no app writes until DB is at/above required version. (`golang-migrate` does not enforce in DB—this is our hardening). CLI exposes `policy` subcommand to set these flags.

---

## 7) Data migration model (idempotent & resumable)

- **Chunking**: engine provides `RUN_GQL` with `LIMIT`/cursor loop support. For each chunk:

  - write progress to `geode_schema_migrations_state`:

    ```
    graph, version, key TEXT, val JSONB
    ```

    to store a **resume token** (e.g., last processed node id).

- **Idempotency**: design transformations to be **set‑based** and **upsert‑style**; re‑running must not duplicate effects.
- **Retry**: on failure, migration marked **dirty=true**; operator can `force` to clear, then `up` re‑executes from resume token.
- **Timeouts**: support `--statement-timeout` per statement (migrate has similar option), default sane value. ([Go Packages][5])

---

## 8) Validation & Drift

- `validate` recomputes checksums for **applied** versions; if different → fail with actionable remediation text (checkout mismatch; don’t silently proceed).
- `status` shows:

  - **Applied** (ok)
  - **Pending**
  - **Dirty** (blocked until `force` or manual fix)
  - **Drift** (checksum mismatch)

- `fix` tool: assist with renumbering or renaming files (like community scripts). ([FreeCodeCamp][7])

---

## 9) Concurrency, HA, K8s

- One runner **per graph**; lock wait default 15s with backoff; then exit non‑zero so Jobs fail clearly (mirrors `-lock-timeout`). ([Go Packages][1])
- Provide a **Job** example manifest that runs `geodemigrate up` before app deploy.
- **Never** run from all app replicas at boot; known anti‑pattern that causes stalls/locks. ([Reddit][8])

---

## 10) Observability

- Structured logs: migration version, name, exec ms, rows touched (if reported), outcome.
- Emit counters: `geode_migrations_applied_total{graph}`, `geode_migration_errors_total{graph}`, `geode_migration_lock_wait_seconds`.
- CLI `--json` to print a machine‑readable outcome (for CI).

---

## 11) Security

- Lock & ledger updates are transactional and **permission‑gated** (role `geode_migrator`).
- CLI avoids echoing secrets; history files excluded (not storing DB URL).
- **Defense** against terminal escape sequences in CLI output (sanitize control chars).
- `force` prints a **“you can corrupt data”** banner and requires `--yes`.

---

## 12) Acceptance criteria

- End‑to‑end: create → up → validate → down → goto → force → version across a sample graph; results match plan; ledger reflects truth.
- Dirty handling: simulate a failure mid‑migration → DB is **dirty**; `up` blocked until `force`/fix; after force, resume works. (Parity with golang‑migrate dirty semantics.) ([Stack Overflow][4])
- Locking: two concurrent runners → one acquires, the other times out with code `10`. (Parity with migrate lock behavior). ([Go Packages][1])
- Enforcement: with `enforce=on` and `required_version=V`, regular writes from app at lower version are rejected by server: correct error code & audit entry.
- CI: running `geodemigrate up` in a Kubernetes Job succeeds and exits 0; app pods do not attempt migrations.

---

## 13) Example migration files

`20250922010101_init.up.gql`

```sql
-- Preconditions: graph 'social' exists (else \policy deny writes and require CREATE GRAPH earlier)
CREATE INDEX IF NOT EXISTS person_name_idx ON :Person(name);

-- Idempotent label seeding (no-ops if already present)
MATCH (n:SeedMarker {name: "init_20250922"}) RETURN 1
UNION
CREATE (:SeedMarker {name: "init_20250922"});
```

`20250922010101_init.down.gql`

```sql
DROP INDEX IF EXISTS person_name_idx;
MATCH (s:SeedMarker {name: "init_20250922"}) DETACH DELETE s;
```

`20250923121500_backfill_age.up.gql` (data migration, chunked)

```sql
// Process a chunk based on resume token `last_id`; engine injects WHERE id > $last_id ORDER BY id LIMIT 1000
MATCH (p:Person)
WHERE p.id > $last_id
SET p.age = 0
RETURN MAX(p.id) AS last_id   -- engine stores as resume token
```

---

## 14) Integration with `geodec` interactive shell (optional but easy)

Add meta‑commands:

- `\migrate status|up [N]|down [N]|goto V|version|force V|validate`
- `\migrate policy enforce on|off required V deny writes|all`
- Respect session graph; print nice tables.

---

## 15) Open questions / decisions

- **GQL features**: ensure “IF \[NOT] EXISTS” variants exist for core DDL; otherwise we must rely on preconditions.
- **Multi‑statement support** in a single file: supported; throttle with `x-multi-statement-max-size`‑like guard (migrate offers a similar toggle). ([Go Packages][5])
- **Sources**: start with `file://`, add `s3://`, `gcs://`, `git://`, `http(s)://` as parity later (migrate supports many). ([Go Packages][1])
- **Downs**: are we OK failing hard on missing downs (up‑only shops)? For v1, require downs for safety.

---

## 16) Quick commands parity table (for reviewers)

| migrate (ref) | GME equivalent                 | Notes                          |                    |
| ------------- | ------------------------------ | ------------------------------ | ------------------ |
| `create`      | `create`                       | seq or timestamp; `.gql` files | ([Go Packages][1]) |
| `up [N]`      | `up [N]`                       | lock + heartbeat               | ([Go Packages][1]) |
| `down [N]`    | `down [N]`                     | —                              | ([Go Packages][1]) |
| `goto V`      | `goto V`                       | —                              | ([Go Packages][1]) |
| `force V`     | `force V`                      | clears dirty; warns            | ([Go Packages][1]) |
| `version`     | `version`                      | prints dirty flag              | ([Go Packages][1]) |
| `drop`        | `drop`                         | dangerous, gated               | ([Go Packages][1]) |
| (—)           | `status`, `validate`, `policy` | extras we require              |                    |

---

## 17) What we’re stricter about than `golang-migrate`

- **Server‑side enforcement** (`geode_migration_policy`) so apps can’t write below required version (migrate doesn’t do this).
- **TTL‑based lock** to avoid stale lock deadlocks (users have hit this in migrate). ([GitHub][6])
- **Resume tokens** for data migrations (migrate leaves this to user code).
- Built‑in `status/validate` with checksum drift detection before `up`.

---

### References to align behavior & UX

- `migrate` CLI commands and options (create, up/down/goto/drop/force/version; lock-timeout; graceful SIGINT). ([Go Packages][1])
- Naming pattern `VERSION_description.up/down.sql`; adapt to `.gql`. ([DEV Community][9])
- Dirty state semantics and why it blocks further runs. ([Stack Overflow][4])
- Lock table/strategy options in pgx driver (we mirror conceptually). ([Go Packages][5])
- Anti‑pattern of running migrations from every app instance on startup in K8s. ([Reddit][8])

---

If you want, I can follow this with a minimal Go MVP plan (files, ledger DDL, lock + heartbeat implementation, and a basic `up`/`down`) and wire it into `geodec` as `\migrate …`.

[1]: https://pkg.go.dev/github.com/golang-migrate/migrate/cli 'cli command - github.com/golang-migrate/migrate/cli - Go Packages'
[2]: https://atlasgo.io/guides/migration-tools/golang-migrate?utm_source=chatgpt.com 'Automatic migration planning for golang-migrate'
[3]: https://github.com/golang-migrate/migrate/issues/574?utm_source=chatgpt.com 'The same sequence with different names should migrate'
[4]: https://stackoverflow.com/questions/59616263/dirty-database-version-error-when-using-golang-migrate?utm_source=chatgpt.com 'Dirty database version error when using golang-migrate'
[5]: https://pkg.go.dev/github.com/golang-migrate/migrate/v4/database/pgx?utm_source=chatgpt.com 'pgx package - github.com/golang-migrate ...'
[6]: https://github.com/golang-migrate/migrate/issues/712?utm_source=chatgpt.com 'Stale Lock ID causng tool to be inoperable · Issue #712'
[7]: https://www.freecodecamp.org/news/database-migration-golang-migrate/?utm_source=chatgpt.com 'How to Perform Database Migrations using Go Migrate'
[8]: https://www.reddit.com/r/golang/comments/12mypec/how_do_you_handle_migrations/?utm_source=chatgpt.com 'How do you handle migrations ? : r/golang'
[9]: https://dev.to/shrsv/level-up-your-database-schema-with-golang-migrate-5d26?utm_source=chatgpt.com 'Level Up Your Database Schema with Golang-Migrate'
