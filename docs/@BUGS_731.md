# Confirmed product bugs found during blog-post validation (v0.8.4)

This document collects eight real, independently-confirmed bugs in
`geodedb/geode` found while validating four upcoming CodePros blog posts
(`introducing-geode`, `why-quic-matters`, `building-social-network`,
`query-optimization-tips`) against a live `geodedb/geode:latest`
container. At the time of testing, `docker pull geodedb/geode:latest`
resolved to **v0.8.4** — every finding below was reproduced against that
running server/CLI build, not inferred from documentation or reported
secondhand. The full repro evidence, exact commands, and exact output
live in the companion `devnw/codepros/geode/geode-examples` repository
(see "Source Material" at the end of this document); this write-up
transcribes that evidence for the geode product team to triage.

Four blog posts reference this product and are pending publication —
these bugs should be triaged before they go out, since several directly
affect example code the posts show as working.

## Summary

| # | Bug | Severity (assessed) | Affected area | Status |
|---|-----|----------------------|----------------|--------|
| 1 | Docker `HEALTHCHECK` runs unauthenticated, trips the server's own auth rate limiter, never self-recovers; the "obvious" env-var fix doesn't work either (unquoted `$AUTH_ARGS` word-splits multi-word passphrases) | High | Docker image (`docker/health-check.sh`), auth rate limiter | Confirmed, twice-reproduced (independently and via building-social-network task) |
| 2 | CLI leaks memory (DebugAllocator report) on every authenticated request | Low/Cosmetic (confirmed no functional block; not confirmed leak-free over long-running processes) | CLI (`src/cli/main.zig`, protobuf decode path) | Confirmed, reproduced across multiple independent tasks |
| 3 | `--insecure-tls-skip-verify` / `--insecure` is refused unless `GEODE_ALLOW_INSECURE_TLS=1` is also set | Informational / footgun (may be intentional defense-in-depth) | CLI TLS handling | Confirmed behavior; exact error text not captured in evidence |
| 4 | `ALTER USER ... SET PASSWORD` — the server's own documented recovery path — changes the password but never clears `password_reset_required`, permanently locking the account | Critical | Server auth / password-reset flow | Confirmed, twice-reproduced from a clean container each time |
| 5 | Chained `MATCH` clauses silently lose scope, matching globally instead of restricting to the anchor's actual relationships | Critical | GQL query engine (`MATCH` clause chaining) | Confirmed, minimized repro with concrete row counts |
| 6 | `count(DISTINCT ...)` always returns `null`; plain `count(...)` works | High | GQL query engine (aggregates) | **Fixed 2026-07-31** (`zig build test-bug731-aggvec`) |
| 7 | `length(path)` via a `WITH`-bound path variable always returns `0` | High | GQL query engine (`WITH` projection of path-derived expressions) | Confirmed, minimized repro; bare `RETURN length(path)` is correct |
| 8 | `distance()`/`similarity()`/`euclidean()`/`knn()` always return `null`; `cosine()` works correctly with the same call shape | High | GQL query engine (vector-similarity functions) | **Fixed 2026-07-31** (`zig build test-bug731-aggvec`) |

---

## 1. Docker `HEALTHCHECK` is broken by default and cannot self-recover

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** High. This makes the shipped image
unhealthy-by-default out of the box, and — critically — once the
server's auth rate limiter trips (from any source, not just the
healthcheck itself), the healthcheck's own perpetual unauthenticated
retries keep re-tripping the limiter forever, with no self-recovery
observed no matter how long the container is left running. Any consumer
relying on Docker/Kubernetes health status for readiness or restart
decisions is directly affected.

**Root cause / mechanism:**

The image's baked-in `HEALTHCHECK` (`docker/health-check.sh` inside
`geodedb/geode:latest`) runs `geode query ... --insecure` on a short
default interval. Per `blog-posts/_shared/FINDINGS.md`:

> `docker/health-check.sh` (baked into `geodedb/geode:latest`) runs
> `geode query ... --insecure`. This CLI build hard-refuses
> `--insecure-tls-skip-verify` (and its `--insecure` alias) under what it
> calls "production conditions" unless `GEODE_ALLOW_INSECURE_TLS=1` is set
> in the environment — which the image does not set by default. Result:
> `docker run geodedb/geode:latest` with no extra flags never reports
> `healthy`. Workaround: set `GEODE_ALLOW_INSECURE_TLS=1` on the container
> (see docker-compose.yml). Confirmed: even with that var set, the
> container's `docker inspect` health status never reliably transitions to
> `healthy` in our testing — `bootstrap.sh` does not rely on Docker's
> health status at all; it polls for the QUIC "listening" log line instead
> (see section 3).

Beyond simply never reporting healthy, the healthcheck's unauthenticated
query attempts count against the server's shared auth rate limiter. Once
anything trips that limiter, the healthcheck compounds the problem
because it keeps retrying forever. From
`blog-posts/building-social-network/FINDINGS.md` section 11:

> The shared `geode-blog-posts` container's own Docker `HEALTHCHECK`
> (from `../_shared/docker-compose.yml`, image-baked script at
> `/usr/local/bin/health-check.sh`) runs `geode query "RETURN 1 AS
> health" --insecure` **every 5 seconds**, with `GEODE_USERNAME`/
> `GEODE_PASSWORD` never set in the compose file — so every single
> healthcheck invocation connects with **no credentials at all**. This
> was already known-broken (`../_shared/FINDINGS.md` documents the
> healthcheck failing outright), but this task found a worse consequence:
> once *anything* (this task's own testing burst, in this case) pushes
> the server's auth rate limiter into its tripped state, the
> healthcheck's own continuous no-credential attempts every 5 seconds
> keep re-tripping it, forever — it does not recover on its own no
> matter how long you wait. Confirmed via `docker inspect`'s health-log:
> `FailingStreak` in the high hundreds, with `Error: Too many failed
> authentication attempts` recorded on essentially every 5-second
> healthcheck tick once tripped, and the container's own top-level status
> stuck at `unhealthy` throughout.

The runtime-only fix applied to unblock that task's own validation (not
persisted, not a committed-file change) was to replace the healthcheck
script inside the running container with a no-op:

```text
docker exec -u root geode-blog-posts sh -c '...'   # replaced /usr/local/bin/health-check.sh with `exit 0`
```

**The "obvious" fix (setting the healthcheck's own supported
`GEODE_USERNAME`/`GEODE_PASSWORD` env vars) does NOT work either.** Per
the inline comment in `blog-posts/_shared/docker-compose.yml`:

> 1. GEODE_ALLOW_INSECURE_TLS=1 unblocks the --insecure flag but the
>    query still needs real credentials — connecting with none
>    fails auth every single tick (_shared/FINDINGS.md section 1).
> 2. Authenticating it properly (GEODE_USERNAME/GEODE_PASSWORD env
>    vars the script itself supports) doesn't work either: this
>    server's password policy requires a multi-word passphrase
>    (see _shared/FINDINGS.md section 2), but health-check.sh
>    builds its args as `AUTH_ARGS="$AUTH_ARGS -P $GEODE_PASSWORD"`
>    and expands `$AUTH_ARGS` UNQUOTED — a passphrase containing
>    spaces gets word-split into several bogus arguments, so the
>    password never actually authenticates correctly either way.
>
> Worse than a merely-broken healthcheck: every one of those failed
> attempts (auth or not) counts against the server's shared auth
> rate limiter. Once anything trips that limiter, the healthcheck's
> own perpetual every-5-second failures keep re-tripping it forever
> — confirmed it does not clear on its own no matter how long you
> wait (blog-posts/building-social-network/FINDINGS.md section 11:
> FailingStreak in the high hundreds, unhealthy indefinitely).

In other words: the exact mechanism is that `health-check.sh` builds its
authentication arguments as an unquoted shell variable
(`AUTH_ARGS="$AUTH_ARGS -P $GEODE_PASSWORD"`, then expands `$AUTH_ARGS`
without quotes), so any passphrase containing spaces — which the
server's own password policy requires (see bug 4 below for the full
policy) — gets word-split into multiple bogus CLI arguments instead of
being passed as a single password value. The healthcheck therefore can
never authenticate correctly even when a user attempts to configure it
properly via its own supported env vars.

**Workaround found:** Override the compose-level `healthcheck.test` to
something that doesn't touch the network/auth path at all. The example
projects use:

```yaml
healthcheck:
  test: [CMD, /usr/local/bin/geode, --version]
  interval: 5s
  timeout: 5s
  start_period: 15s
  retries: 6
```

with actual readiness confirmed independently by polling container logs
for the QUIC `"status":"listening"` line rather than trusting Docker's
health status at all (see `blog-posts/_shared/bootstrap.sh`).

**Surfaced by:** `blog-posts/_shared/FINDINGS.md` (section 1, primary
description of the default-broken healthcheck) and
`blog-posts/building-social-network/FINDINGS.md` (section 11, the
permanent-lockout variant and the `FailingStreak`/no-self-recovery
evidence), corroborated by `blog-posts/_shared/docker-compose.yml`'s
inline comments (mechanism of the unquoted `$AUTH_ARGS` failure) and
`blog-posts/_shared/bootstrap.sh`.

**Corrections (verified 2026-07-31):**

- The auth rate limiter is **per source IP**, not global
  (`src/transport/quic.zig`: 10 attempts, 60s lockout), and it **does**
  decay — `zig build test-auth-rate-limiter` and the
  `authn_rate_limiter_expiry.yml` harness spec both prove expiry. The
  observed "shared" lockout is real but comes from
  `docker run --network container:<name>`, which shares the network
  namespace and therefore the same `127.0.0.1` limiter key. The limiter is
  correct; the probe was the defect. A probe that can never authenticate
  simply refills 0→10 in ~50s and re-locks forever.
- A third, previously unrecorded defect made the recommended replacement
  probe unreliable: the `/health` liveness endpoint parsed METHOD/PATH out
  of a buffer slice that the header-drain loop had already invalidated, so
  a request whose bytes arrived in more than one TCP segment (what a
  dependency-free `bash` `/dev/tcp` probe produces) got a bogus 404/400.

**Fixed 2026-07-31.** `docker/health-check.sh` now probes the
unauthenticated out-of-band liveness endpoint
(`GET http://127.0.0.1:$GEODE_METRICS_PORT/health`) and only falls back to
an authenticated query when BOTH `GEODE_USERNAME` and `GEODE_PASSWORD` are
set — passed as real positional parameters, so a multi-word passphrase
survives intact; the `# shellcheck disable=SC2086` suppression is gone.
The 16 server Dockerfiles bake in `ENV GEODE_METRICS_PORT` so the listener
actually starts, and `src/monitoring/metrics_server.zig` no longer
misparses a segment-split request. Regressions:
`make docker-healthcheck-test` (9/9) and `zig build test-metrics-server`
(5/5).

---

## 2. CLI leaks memory on every authenticated request

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** Low/cosmetic based on available evidence
— every command still completes and returns a correct result after the
leak-report noise is printed, and no functional failure was observed.
Confirmed only as stderr noise across short-lived CLI invocations in
this evidence set; **not confirmed** one way or the other for
long-running processes or heavy sustained query volume, so a
higher-severity resource-exhaustion risk cannot be ruled out from this
evidence alone.

**Root cause / mechanism:** Reproduced repeatedly and independently
across multiple tasks. Zig's `DebugAllocator` reports a leaked
allocation on stderr after every successful authenticated `auth login`
or authenticated `query` invocation. Per `blog-posts/_shared/FINDINGS.md`
section 3:

> Every successful `auth login` or authenticated `query` prints Zig
> `DebugAllocator` leak reports to stderr, e.g.:
>
> ```text
> error(DebugAllocator): memory address 0x7f7a82d20000 leaked:
> /builds/devnw/codepros/geode/geode/zig-pkg/protobuf-0.1.4-0e82aqOEKgCEvqL9LJPtDWc4nzQ3LKAHmUzdiEWqo1-K/src/wire.zig:955:51: 0x1592775 in decodeMessage__anon_535851 (geode)
> /builds/devnw/codepros/geode/geode/zig-pkg/protobuf-0.1.4-0e82aqOEKgCEvqL9LJPtDWc4nzQ3LKAHmUzdiEWqo1-K/src/wire.zig:1260:77: 0x1576101 in decodeMessage__anon_533383 (geode)
> /builds/devnw/codepros/geode/geode/src/cli/main.zig:2542:39: 0x15ecdbd in readProtoMessageViaZigClient (geode)
> /builds/devnw/codepros/geode/geode/src/cli/main.zig:3576:50: 0x15f3f81 in connectToServer (geode)
> /builds/devnw/codepros/geode/geode/src/cli/cli_dispatcher.zig:312:30: 0x1247e73 in dispatch (geode)
> /builds/devnw/codepros/geode/geode/src/cli/main.zig:3377:32: 0x124dc69 in main (geode)
> /root/.zvm/0.16.0/lib/libc/musl/src/env/__libc_start_main.c:95:7: 0x1c24e07 in libc_start_main_stage2 (/root/.zvm/0.16.0/lib/libc/musl/src/env/__libc_start_main.c)
> ```
>
> The command still succeeds and prints a correct result after the leak
> dump — this does not block usage, but it is a real bug worth filing
> against `devnw/codepros/geode/geode`.

The stack trace points at the CLI's own request/response path: protobuf
message decode (`zig-pkg/protobuf-0.1.4/.../wire.zig`) called from
`readProtoMessageViaZigClient` / `connectToServer` in
`src/cli/main.zig`, dispatched from `src/cli/cli_dispatcher.zig`.

**Workaround found:** No fix; example scripts filter the noise from
captured output rather than working around the leak itself. Per the
same section: "All example scripts in this repo should filter it with
`grep -v 'DebugAllocator\|\.zig:\|libc_start\|additional stack'` when
capturing CLI output programmatically, so it isn't mistaken for a real
failure." `blog-posts/_shared/bootstrap.sh` applies exactly this filter
to its own sanity-check query output, noting: "Leak-report noise on
stderr from the CLI's DebugAllocator is expected and harmless here."

**Surfaced by:** `blog-posts/_shared/FINDINGS.md` (section 3, primary
description and stack trace), corroborated by
`blog-posts/_shared/bootstrap.sh` (filtering it as expected/harmless
noise). Described as reproduced "across multiple independent tasks" in
the source material, though only one concrete stack trace instance is
quoted in the evidence read for this document.

**Correction (verified 2026-07-31, live server):** the title's "every
authenticated request" is WRONG. Only `geode auth login` leaked (5
reports); `geode query`, `CREATE`, `MATCH` and `SHOW USERS` leaked
nothing. The leak fired once per `connectToServer`, whose only caller is
`cmdAuthLogin`.

**Fixed 2026-07-31.** The decoded `schema.ServerPacket` is now released on
every path (success, `success=false`, and the `orelse error.InvalidMessage`
path) in `src/client/hello_decode.zig`. Regression:
`zig build test-bug731-cli-leak` (6/6, 0 leaks; 5/6 with 30 leaks before).
The same change also stopped discarding
`HelloResponse.password_reset_required`, which had hardcoded
`.requires_password_reset = false` and made the CLI's post-login "password
reset required" warning dead code — directly relevant to bug 4.

---

## 3. `--insecure-tls-skip-verify` is refused unless `GEODE_ALLOW_INSECURE_TLS=1` is also set

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** Informational / footgun rather than a
clear-cut defect. This may well be intentional defense-in-depth — a
deliberate two-key gate against accidentally disabling TLS verification
in a real deployment — rather than a bug. It is documented here because
it is a real, confirmed behavior that surprises a first-time user (and
is directly responsible for bug 1's default-unhealthy image, since the
baked-in healthcheck hits exactly this refusal). The evidence sources
themselves frame it as something to *document* rather than assert as a
defect; this write-up preserves that framing.

**Root cause / mechanism:** Per `blog-posts/_shared/FINDINGS.md` section
1:

> This CLI build hard-refuses `--insecure-tls-skip-verify` (and its
> `--insecure` alias) under what it calls "production conditions" unless
> `GEODE_ALLOW_INSECURE_TLS=1` is set in the environment — which the
> image does not set by default.

**Note on evidence completeness:** The exact refusal error message text
(e.g. the literal string the CLI prints when it hard-refuses the flag)
is **not quoted verbatim** in any of the evidence sources read for this
document — only the described behavior ("hard-refuses ... unless
`GEODE_ALLOW_INSECURE_TLS=1` is set") is available. This is flagged
explicitly rather than fabricating an exact error string.

**Workaround/unblock:** Set `GEODE_ALLOW_INSECURE_TLS=1` in the
container environment. All four example projects' Docker Compose
configs and ad hoc `docker run` invocations set this explicitly, e.g.
`blog-posts/_shared/docker-compose.yml`:

```yaml
environment:
  # The image's own baked-in HEALTHCHECK runs `geode query ... --insecure`,
  # which this release build hard-refuses without this var set. Without
  # it the container never reports healthy. See _shared/FINDINGS.md.
  GEODE_ALLOW_INSECURE_TLS: '1'
```

and `blog-posts/_shared/bootstrap.sh`'s own sanity-check invocation:

```bash
health_output="$(docker run --rm --network container:"$CONTAINER_NAME" \
  -e GEODE_ALLOW_INSECURE_TLS=1 geodedb/geode:latest \
  query -U "$GEODE_USER" --password "$GEODE_PASSWORD" --server "127.0.0.1:${GEODE_PORT}" \
  --insecure-tls-skip-verify --format json "RETURN 1 AS health" 2>&1 \
  | grep -v 'DebugAllocator\|\.zig:\|libc_start\|additional stack')"
```

**Surfaced by:** `blog-posts/_shared/FINDINGS.md` (section 1, primary
description), `blog-posts/_shared/docker-compose.yml` and
`blog-posts/_shared/bootstrap.sh` (both consume the workaround
directly), and corroborated indirectly by
`blog-posts/building-social-network/validate.sh` and
`blog-posts/query-optimization-tips/validate.sh`, which both also pass
`-e GEODE_ALLOW_INSECURE_TLS=1`.

**Resolution (2026-07-31): NOT A DEFECT — documentation only.** This is
deliberate defense-in-depth (SEC-CLI-01, GAP-0885d,
`src/cli/insecure_tls_gate.zig`, unit-tested via
`tests/test_s3_sigv4.zig`). The gate predicate is
`insecure_requested AND NOT GEODE_ALLOW_INSECURE_TLS AND (is_release OR
GEODE_ENV=production)`, where `is_release` is `builtin.mode != .Debug`.
The refusal string the evidence never captured is, verbatim:

```text
SECURITY: refusing --insecure-tls-skip-verify — TLS certificate verification cannot be disabled under production conditions (release build or GEODE_ENV=production). Connections without verification are exposed to man-in-the-middle attacks. Use --ca-cert <path> to trust a private CA, or set GEODE_ALLOW_INSECURE_TLS=1 to explicitly acknowledge the risk.
```

The supported answer is `--ca-cert <path>`, not the acknowledgement
variable. This is now documented in
[DOCKER_OVERVIEW.md](DOCKER_OVERVIEW.md) ("Health Checks" →
"`--insecure-tls-skip-verify` is refused in release builds"), together
with the note that `.gitlab-ci.yml` deliberately builds Debug for the GQL
compliance job for exactly this reason — which is why the release-image
healthcheck path was never exercised in CI.

---

## 4. `ALTER USER ... SET PASSWORD` changes the password but never clears `password_reset_required`, permanently locking the account

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** Critical. This is the server's own
documented, error-message-instructed self-service recovery path for the
auto-generated first-boot admin password, and following those
instructions exactly as given **permanently locks the account out of
running any query at all**. There is no self-service way out of this
state once entered; the only confirmed avoidance is to never enter the
forced-reset flow in the first place (seed the password before first
boot instead — see below). This directly affects any operator following
the server's own guidance on a fresh container.

**Root cause / mechanism, exact repro (twice-reproduced from a clean
container each time):** Per `blog-posts/_shared/FINDINGS.md` section 2:

> - The server generates a random password on first boot and writes it to
>   `/data/.geode_admin_password` inside the container.
> - The username to authenticate as is **`geode`** — not `admin`,
>   despite the startup log calling it "admin password."
> - That first login succeeds but every *query* is rejected with
>   `Password reset required. Change password with: ALTER USER <username>
>   SET PASSWORD '<new_password>'` — the server names its own recovery
>   command in the error message.
>
> **Following that instruction does not work.** We reproduced this
> precisely, twice, from a clean container each time:
>
> 1. Read the auto-generated password from `/data/.geode_admin_password`.
> 2. Authenticate and run `ALTER USER geode SET PASSWORD '<new-pw>'`
>    exactly as instructed. The CLI reports `Error: query execution
>    failed` (not a policy-validation error — see below for what those
>    look like).
> 3. Despite the client-visible error, the password *did* change: the old
>    password now gets `Authentication failed`, and the new password gets
>    accepted as a valid credential rather than rejected.
> 4. But running any subsequent query — including a trivial `RETURN 1`
>    — with the *new*, now-valid password still returns `Password reset
>    required`, identical to step 2. The `password_reset_required` flag is
>    never cleared. The account is permanently locked out of running any
>    normal query through this flow. Running `ALTER USER` again from this
>    state repeats the same cycle indefinitely.

The evidence source further isolates this as specific to the
forced-first-login-reset state, not a general `ALTER USER` defect:

> We also confirmed this is **specific to the forced-first-login-reset
> state**, not a general `ALTER USER` bug: once an account is *not* in
> `password_reset_required` state (e.g. because it was seeded via
> `GEODE_ADMIN_PASSWORD`, see below), `ALTER USER <user> SET PASSWORD
> '<new>'` works completely normally — the password changes and the very
> next query with the new password succeeds immediately.

An on-disk-only alternative was also tried and found unsafe against a
live server (does not update the running server's in-memory state):

> We also tried `geode user reset-password <user> --new-password <new>
> --data-dir /data`, run via `docker exec` directly inside the *live*
> server container (bypassing the network entirely). This subcommand
> operates on-disk against the auth store independently of the running
> server process and reports `Password reset for user 'geode'` — but the
> running server's in-memory state does not see this write: a subsequent
> network query with the "reset" password gets `Authentication failed`.
> This path is unsafe to use against a live server and was abandoned.

**Confirmed password policy** (relevant to reproducing this bug, since
`ALTER USER` policy validation only runs on an already-active,
non-reset-required account — see above):

> - Minimum 20 characters (`"Password too short (minimum 20 characters)"`).
> - At least one uppercase letter
>   (`"Password must contain at least one uppercase letter"`).
> - At least one lowercase letter
>   (`"Password must contain at least one lowercase letter"`).
> - Must be a passphrase of at least 3 space-separated words
>   (`"Password must be a passphrase with at least 3 words"`).
> - No digit or special-character requirement was found — two different
>   passphrases containing only letters and spaces (`Correct horse battery
>   staple`, `Correct horse battery`) were both accepted.

Notably, this policy is **not** enforced on `GEODE_ADMIN_PASSWORD`
first-boot seeding — "this seed path does **not** enforce the password
policy described below (a one-word, 5-character password was accepted
by the seed step)."

**Workaround found (avoids the flow entirely — the only known escape):**
Seed `GEODE_ADMIN_PASSWORD` before the container's first boot, which
skips the auto-generated-password/forced-reset flow entirely. Per
`blog-posts/_shared/bootstrap.sh`'s own header comment:

> Instead, this script generates a fresh admin password and seeds it via
> the GEODE_ADMIN_PASSWORD environment variable *before* the container's
> first boot. That bypasses the auto-generated-password/forced-reset flow
> entirely -- confirmed working end-to-end against a live container.

Implemented concretely in `bootstrap.sh` as:

```bash
NEW_PW="Correct Horse Battery Staple ${RANDOM}${RANDOM}"
echo -n "$NEW_PW" > "$PW_FILE"
chmod 600 "$PW_FILE"

GEODE_ADMIN_PASSWORD="$NEW_PW" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
```

and `blog-posts/_shared/docker-compose.yml`:

```yaml
GEODE_ADMIN_PASSWORD: ${GEODE_ADMIN_PASSWORD:?GEODE_ADMIN_PASSWORD must be set by bootstrap.sh before calling docker compose up}
```

**Surfaced by:** `blog-posts/_shared/FINDINGS.md` (section 2, primary
and most detailed writeup, including the twice-reproduced repro steps
and confirmed password policy), corroborated by
`blog-posts/_shared/bootstrap.sh` and
`blog-posts/_shared/docker-compose.yml` (both implement the
seed-before-boot workaround and document why in inline comments).

---

## 5. Chained `MATCH` clauses silently lose scope

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** Critical. This is a silent correctness
bug in the GQL query engine itself — no error is raised, the query
returns a plausible-looking result set, but that result set is wrong
(scoped globally instead of to the intended anchor). Evidence source
calls this "the most significant *server*-side bug found in this task"
and warns it "likely affects every multi-`MATCH` query across all four
posts in this plan, not just this one."

**Root cause / mechanism, exact repro:** Per
`blog-posts/building-social-network/FINDINGS.md` section 7, the affected
query shape (from the post's `get_recommendations`):

```gql
MATCH (me:User {username: $my_username})-[:FRIENDS_WITH]-(friend)
MATCH (friend)-[:FRIENDS_WITH]-(suggestion)
WHERE NOT (me)-[:FRIENDS_WITH]-(suggestion) AND me <> suggestion
...
```

> Two separate top-level `MATCH` clauses, the second re-referencing
> `friend` (bound by the first). **Confirmed live: this silently loses
> the scoping to the first clause's anchor node and matches globally
> across the ENTIRE graph.** Minimized repro, run against a graph with
> exactly one real friendship for `alice` (`alice`-`bob`, from
> `sample_data.gql`) plus many *unrelated* users/friendships from other
> tasks'/this task's own test data:
>
> ```text
> > MATCH (me:User {username: "alice"})
>   MATCH (me)-[:FRIENDS_WITH]-(friend)
>   RETURN friend.username
> +--------------------+
> | username           |
> +--------------------+
> | bob                |
> | bob                |
> | alice              |
> | charlie            |
> | ... (68 rows total, every user in the graph with ANY FRIENDS_WITH edge)
> ```
>
> The **semantically identical single-clause** form is correctly scoped:
>
> ```text
> > MATCH (me:User {username: "alice"})-[:FRIENDS_WITH]-(friend)
>   RETURN friend.username
> +----------+
> | username |
> +----------+
> | bob      |
> | bob      |
> +----------+
> (2 rows)
> ```

So the exact confirmed numbers are **68 rows instead of the correct 2
rows** for a graph where `alice` has exactly one real friendship
(`alice`-`bob`).

Two additional, related findings from the same section:

> **Narrower related bug**: even a *single* `MATCH` clause combining a
> variable-length hop with a further fixed hop
> (`(me)-[:FRIENDS_WITH*0..1]-(friend)-[:POSTED]->(post)`) exhibits the
> same leak -- apparently decomposed internally the same broken way, even
> though it's syntactically one clause. The `*0..1` segment alone (no
> further hop chained onto it in the same clause) is scoped correctly.
>
> **Also confirmed, separate but related bug**: node-identity comparison
> (`WHERE ... AND me <> suggestion`, exactly as the post writes it) does
> **not** filter correctly -- rows where `suggestion` is literally the
> same node as `me` are NOT excluded. Comparing a property instead
> (`me.username <> suggestion.username`) works correctly.

And a confirmed-safe counter-example (same file), showing the bug is
specifically about re-referencing a variable as a *traversal anchor*
across clauses, not chained `MATCH` clauses in general:

> **`add_friend`'s two separate `MATCH` clauses are NOT affected**:
> `MATCH (u1:User {username: $user1}) MATCH (u2:User {username: $user2})`
> does an independent property lookup in each clause with no variable
> re-referenced as a *traversal anchor* from a prior clause -- a
> different shape than the buggy pattern above.

`OPTIONAL MATCH` referencing a variable from a single *preceding*
`MATCH` clause was also confirmed **not** affected.

**Workaround found (confirmed working):** Collapse every traversal into
a single connected `MATCH` pattern per path, rather than chaining
separate `MATCH` clauses that re-reference a prior variable as a
traversal anchor:

> **Fix applied throughout `python/social_network.py`**: express every
> traversal as one single `MATCH` clause per connected path (e.g.
> `MATCH (me:User {...})-[:FRIENDS_WITH]-(friend)-[:FRIENDS_WITH]-(suggestion)`
> in one clause, never two chained ones).

**Surfaced by:**
`blog-posts/building-social-network/FINDINGS.md` (section 7, the sole
and primary source for this finding).

---

## 6. `count(DISTINCT ...)` always returns `null`

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** High. This is a silent-wrong-answer bug
(the query succeeds and returns a row, just with `null` where a real
count belongs) affecting any aggregate query that needs
distinct-counting semantics — common for engagement/social-graph metrics
and de-duplicating counts across joined/cross-product traversals.

**Root cause / mechanism, exact repro:** Per
`blog-posts/building-social-network/FINDINGS.md` section 8:

> Minimized repro:
>
> ```text
> > MATCH (me:User {username:"dbgtest_alice"})-[:FRIENDS_WITH]-(f)
>   RETURN count(DISTINCT f) AS cnt
> {"cnt": null}
>
> > MATCH (me:User {username:"dbgtest_alice"})-[:FRIENDS_WITH]-(f)
>   RETURN count(f) AS cnt          -- no DISTINCT
> {"cnt": 2}
> ```
>
> Also confirmed with a property expression instead of a node
> (`count(DISTINCT f.username)` -> also `null`), ruling out "only broken
> for node types." `collect(DISTINCT expr)` doesn't even parse
> (`Error: expected token 'r_paren', got 'identifier'`) -- `DISTINCT`
> inside an aggregate is only syntactically accepted by `count()`, and
> semantically broken there.

**Workaround found — partial only, confirmed no full substitute
exists:** For the one case the post's own tests actually assert on
(mutual-friend counting via a bidirectionally-created edge), a
workaround was found by changing traversal direction so `DISTINCT`
becomes unnecessary:

> **Fix applied in `python/social_network.py`**: `get_recommendations`
> traverses `-[:FRIENDS_WITH]->` in ONE direction only (not the post's
> undirected `-[:FRIENDS_WITH]-`). Since `add_friend` always creates
> *both* directed edges for a friendship, one-directional traversal
> naturally visits each real friendship exactly once, so plain
> non-`DISTINCT` `count(friend)` is correct without needing `DISTINCT` to
> dedupe the bidirectional storage. This is sufficient for
> `mutual_friends`, the one field the post's own pytest assertions
> actually check.

But for cases that genuinely need distinct-counting semantics (not just
avoidable via directional traversal), **no working single-query
substitute was found**:

> The post's additional `like_count`/`comment_count`
> (`get_feed`) and `common_groups`/`score` (`get_recommendations`) fields
> are dropped from this project's implementation entirely: they need
> `DISTINCT` to dedupe the `OPTIONAL MATCH` cross-joins those computations
> require, and no working substitute for that specific combination
> (directed one-hop dedup doesn't apply the same way across an
> `OPTIONAL MATCH` join) was found during this task.

This is documented as a real functional gap, not merely cosmetic: "the
feature is simply non-functional."

**Surfaced by:**
`blog-posts/building-social-network/FINDINGS.md` (section 8, sole and
primary source).

**Fixed 2026-07-31.** Three layers:

- **6a (the live-path defect).** `computeGroupAggregation`
  (`src/execution.zig`) — the function EVERY `RETURN` projection funnels
  through, because `planned_read_runtime` wraps `RETURN` in a synthetic
  `WithClause` — dispatched only on count/sum/avg/min/max/collect and fell
  through to `return Value{ .Null = {} }`. It now normalises the parser's
  synthetic `countDistinct` callee and honours the DISTINCT quantifier for
  every aggregate.
- **6b (divergence).** Five sibling aggregate implementations each rolled
  their own `countDistinct` and disagreed about node handling, boolean
  handling and the empty-group result. All five
  (`aggregation_evaluation.zig` x2, `pattern_helpers.zig`,
  `match_operations.zig`, `query_execution.zig`) now share ONE accumulator,
  `src/execution/distinct_set.zig`: node/edge identity by id, integral
  numerics unified (`10` == `10.0`), strings by bytes, booleans, NULLs
  skipped per ISO, empty group -> 0 (never NULL).
- **6c (ISO conformance).** ISO/IEC 39075:2024 `<general set function>`
  permits a `<set quantifier>` (DISTINCT | ALL) on EVERY
  `<computational operation>`, but the parser accepted it only for `count`
  — which is why `collect(DISTINCT x)` raised
  `expected token 'r_paren', got 'identifier'`. The quantifier is now a
  flag on the AST `Call` node (`ast.Expr.Call.distinct`) accepted for
  count/sum/avg/min/max/collect/collect_list/stddev_*/percentile_*. The
  `count` -> `countDistinct` callee rewrite is retained for backwards
  compatibility with the executor paths and `tests/test_count_distinct_parser.zig`.

Regressions: `zig build test-bug731-aggvec` (20/20),
`test-count-edges-fastpath` (9/9, its `count(DISTINCT r)` case now asserts
a real value), `test-iso-conformance` (96/96, the COUNT DISTINCT case now
also covers `collect`/`sum`/`avg`/`min`/`max` with DISTINCT and ALL).

---

## 7. `length(path)` via a `WITH`-bound path variable always returns 0

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** High. Silent-wrong-answer bug: the query
runs without error and appears to succeed, but with a constant-zero
value substituted for a real path length, which then silently filters
out all rows in any query that also applies a `WHERE` threshold on that
computed value (as the source blog post's own recommended pattern does).

**Root cause / mechanism, exact repro:** Per
`blog-posts/query-optimization-tips/FINDINGS.md` section 5:

> **Confirmed live**, isolated to exactly this: `length(path)` evaluated
> directly in a top-level `RETURN` (no `WITH` involved) returns correct
> values --
>
> ```text
> > MATCH path = (p:Person)-[:KNOWS*1..3]-(friend)
>   RETURN length(path) AS L LIMIT 10;
> +---+
> | L |
> +---+
> | 1 |
> | 1 |
> | 2 |
> | 2 |
> | 3 |
> | 3 |
> ...
> ```
>
> -- but the *same* `length(path)` expression, carried through a `WITH`
> projection, always evaluates to `0`:
>
> ```text
> > MATCH path = (p:Person)-[:KNOWS*1..3]-(friend)
>   WITH p, friend, length(path) AS L
>   RETURN p.name, L LIMIT 5;
> +-----------+---+
> | name      | L |
> +-----------+---+
> | Person394 | 0 |
> | Person394 | 0 |
> | Person394 | 0 |
> | Person394 | 0 |
> | Person394 | 0 |
> +-----------+---+
> (5 rows)
> ```
>
> Because `L` is always `0`, Tip 6's `WHERE path_length > 2` filters out
> every row -- the query "succeeds" (no error) but silently returns 0
> rows, even though real length-3 paths exist in the underlying data (as
> the un-WITH'd version above proves).

The affected blog-post pattern this was found validating (Tip 6's
"Solution", intended to demonstrate computing an expensive expression
once via `WITH`):

```gql
WITH p, friend, length(path) AS path_length WHERE path_length > 2
RETURN p.name, path_length
```

**Workaround found:** None. The example project deliberately keeps the
broken query as-is rather than routing around it:

> **Fix applied**: none -- `tips/06_with_pipeline.gql` keeps the post's
> exact Solution GQL verbatim. Unlike the parse-error cases above (#1),
> this query runs without error and just as the post specifies, so
> "fixing" it (e.g. by not routing `length(path)` through `WITH`) would
> misrepresent what the post's own recommended code actually does when
> run for real -- readers deserve to see the real (silently wrong)
> behavior.

**Surfaced by:**
`blog-posts/query-optimization-tips/FINDINGS.md` (section 5, sole and
primary source).

---

## 8. Vector functions `distance()`/`similarity()`/`knn()` always return `null`; `cosine()` works correctly

**Affected version:** v0.8.4 (the only version tested)

**Severity/impact (assessed):** High — evidence source itself calls this
"the most severe functional gap found in this project": an entire
documented feature area (vector similarity search) is silently
non-functional for three of its four documented functions, with no
error raised.

**Root cause / mechanism, exact repro:** Per
`blog-posts/query-optimization-tips/FINDINGS.md` section 9:

> **Confirmed live**, with clean, unambiguous literal-only inputs (no
> property access, no index involved -- ruling out data/index issues):
>
> ```text
> > RETURN distance([0.0,0.0], [3.0,4.0], "l2");        -> null
> > RETURN distance([0.0,0.0], [3.0,4.0], "euclidean");  -> null
> > RETURN distance([0.0,0.0], [3.0,4.0]);               -> null  (2-arg form)
> > RETURN euclidean([0.0,0.0], [3.0,4.0]);              -> null
> > RETURN similarity([1.0,0.0], [1.0,0.0], "cosine");   -> null
> > RETURN similarity([1.0,0.0], [1.0,0.0]);             -> null  (2-arg form)
> > RETURN cosine([1.0,0.0], [1.0,0.0]);                 -> 1.000000  (correct!)
> ```
>
> `cosine()` is the *only* one of the four vector functions mentioned in
> this post (`distance`, `similarity`, `knn`, plus `cosine`/`euclidean`
> from the CLI's own `geode:syntax` reference) that actually computes a
> value. `distance()`, `similarity()`, `euclidean()`, and `knn()` all
> return `null` unconditionally, regardless of arguments -- confirmed with
> both literal-only calls and calls against real seeded `Document.embedding`
> properties (also `null`), and regardless of whether a `vector` index
> exists over the property (`CREATE INDEX doc_embedding_idx ON
> Document(embedding) USING vector` itself succeeds).

So the exact set confirmed broken (always `null`, all forms tested) is:
`distance()` (2-arg and 3-arg forms, both `"l2"` and `"euclidean"`
metric arguments), `similarity()` (2-arg and 3-arg forms), `euclidean()`,
and `knn()` (referenced via the affected blog-post snippet below, not
independently re-tested with a bare literal call in the quoted evidence
— see note). The exact one confirmed **working** is `cosine()`, which
returned the mathematically correct `1.000000` for two identical unit
vectors.

**Note on evidence completeness:** `knn()` is named as broken in the
evidence source's summary prose ("`distance()`, `similarity()`,
`euclidean()`, and `knn()` all return `null` unconditionally") and in
the "Where it matters" framing (the bonus tip's `knn(d.embedding,
$query_vector, 10)` call), but the quoted literal-input repro block
itself does not show a standalone `RETURN knn(...)` line the way it does
for `distance`/`euclidean`/`similarity`/`cosine`. The finding treats
`knn()` as confirmed broken based on the bonus tip's real query against
seeded data returning `null` (see below), not a separate isolated
literal-only call.

The affected blog-post pattern (bonus tip "Use Vector Indexes for
Similarity Search"):

```gql
WHERE distance(d.embedding, $query_vector, 'l2') < 0.5
```

```gql
knn(d.embedding, $query_vector, 10)
```

**Workaround found:** None. As with bug 7, the example project
deliberately keeps the broken query verbatim rather than substituting
`cosine()`:

> **Fix applied**: none -- `bonus/vector_index.gql` keeps the post's exact
> Solution GQL verbatim (both the `distance(...)` `WHERE` clause and the
> `knn(...)` call). Both statements run without error and return `null`
> results, which is itself the finding: this is not a parse-error case
> ..., it is a silent wrong-answer case... "Fixing" the file to use
> `cosine()` instead would misrepresent what the post's own recommended
> code actually does when run for real.

**Surfaced by:**
`blog-posts/query-optimization-tips/FINDINGS.md` (section 9, sole and
primary source).

**Fixed 2026-07-31.** The math core was always correct; naming, argument
coercion and error reporting were not:

- **8b (the mechanism behind every null).** `src/eval.zig` ended its
  function dispatch with `// Function not found, return null`, so ANY
  unresolved name silently evaluated to NULL (`RETURN totally_bogus_fn(1,2)`
  -> `null`). It now raises `EvalError.UnknownFunction`, mapped to
  SQLSTATE `42883` "Unknown function" by `src/server/proto_util.zig` —
  the same undefined_function class the `UnknownProcedure` path already
  used.
- **8a (missing registrations).** `distance`, `similarity`, `euclidean`
  and `manhattan` were registered NOWHERE (`cosine` worked only via a
  one-off alias). They are now real scalar functions sharing the vector
  metric core with `vector_knn`. Results are `DECIMAL(scale 6)`, matching
  `cosine`.
- **8c (list-literal coercion).** The registered `vector_*` functions
  gated on the `VectorF32` tag and returned NULL for anything else, while
  a GQL list literal evaluates to a `List`. Both `src/eval.zig` and
  `src/eval_extended.zig` now coerce numeric lists (and `VectorI32`) to
  `VectorF32`, so `vector_l2([0,0],[3,4])` computes 5 exactly as
  `vector_l2(vectorf32([0,0]), vectorf32([3,4]))` always did.
- **8d (knn).** `knn` is now a plain alias of the implemented
  `vector_knn(property_name, query_vector, k, metric)`. The documented
  3-argument form `knn(d.embedding, $q, 10)` cannot resolve (arg 0 is a
  vector value, not a property NAME, and there is no metric) and now
  raises `InvalidArgs` instead of silently returning NULL. The dead MVP
  stub in `eval_extended.zig` that always returned an empty list is
  deleted.
- **8e (metric vocabulary).** `parseVectorMetric` rejected `"euclidean"`
  even though `CREATE INDEX ... USING vector` accepts it; it is now a
  synonym of `l2` everywhere.
- **8f (catalog reconciliation).** Four catalogs disagreed.
  `src/gql/language_metadata.zig` advertised distance/similarity/cosine/
  euclidean/manhattan — all now real — plus the optional metric parameter,
  and gained the previously-unadvertised `vector_knn`/`knn`.
  `src/execution/statement_handlers.zig` listed `distance(point1, point2)`
  as a GEOSPATIAL function (a fourth, incompatible scheme); that row is now
  the vector signature and the rest of the vector surface was added.
  `docs/API_REFERENCE.md` documents the real `knn` arity, and
  `docs/TYPES_AND_FUNCTIONS.md` no longer advertises the never-implemented
  `cosineSimilarity`/`dotProduct`/`manhattanDistance`/`hammingDistance`/
  `norm`/`normalize`/`add`/`scale` scheme.

Regression: `zig build test-bug731-aggvec` (20/20).

---

## Source Material

All evidence quoted above was drawn from the following files in
`devnw/codepros/geode/geode-examples` (paths relative to that repo's
root):

- `blog-posts/_shared/docker-compose.yml` — bugs 1, 3, 4 (inline comments
  on the HEALTHCHECK/rate-limiter interaction, `GEODE_ALLOW_INSECURE_TLS`
  requirement, and `GEODE_ADMIN_PASSWORD` seeding requirement)
- `blog-posts/_shared/bootstrap.sh` — bugs 1, 2, 3, 4 (inline comments on
  the password-reset dead end, the `GEODE_ALLOW_INSECURE_TLS` /
  `--insecure-tls-skip-verify` requirement, the DebugAllocator leak-noise
  filtering, and the confirmed password policy)
- `blog-posts/_shared/FINDINGS.md` — bugs 1, 2, 3, 4 (primary writeup for
  all four shared-infrastructure bugs: sections 1 (HEALTHCHECK), 2
  (password-reset dead end and password policy), and 3 (memory leak))
- `blog-posts/building-social-network/FINDINGS.md` — bugs 1, 5, 6
  (section 11 for the permanent-lockout HEALTHCHECK variant; section 7
  for chained-`MATCH` scoping; section 8 for `count(DISTINCT ...)`)
- `blog-posts/query-optimization-tips/FINDINGS.md` — bugs 7, 8 (section 5
  for `length(path)` via `WITH`; section 9 for the vector-function
  bugs)
- `blog-posts/introducing-geode/FINDINGS.md` — checked for corroborating
  detail on auth/TLS requirements (section intro, "Auth is required on
  every connection" / TLS-verification note); contained no additional
  detail on the HEALTHCHECK, memory-leak, or password-reset bugs
  specifically beyond confirming auth/TLS are required on every
  connection
- `blog-posts/why-quic-matters/FINDINGS.md` — checked for corroborating
  detail; contained DSN-level `insecure_tls_skip_verify` usage examples
  but no additional detail on the HEALTHCHECK, memory-leak, or
  password-reset bugs specifically
