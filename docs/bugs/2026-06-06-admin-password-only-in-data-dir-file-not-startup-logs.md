# Bug: first-boot admin password is written **only** to `<data-dir>/.geode_admin_password`, never to stdout/stderr — log-scraping credential retrieval silently breaks

**Status:** **OPEN** (documentation / integration contract) — reported 2026-06-06 against geode `v0.6.13` (local `/usr/bin/geode`).

**Severity:** Medium. Not a crash and not a data-correctness bug, but it silently
breaks every consumer/harness that obtains the auto-generated admin password by
scraping the server's startup output. Concretely it disables the entire
`//go:build integration` geode-backed test suite in downstream `divelife-api`
(every integration test `t.Fatal`s with `timed out waiting for geode admin
password`), and it makes first-boot credential discovery non-obvious for an
operator who is watching `kubectl logs` / `docker logs`.

This is the operational counterpart to the GAP-0104 / "S3" security fix that
(correctly) stopped logging the secret. The fix changed where the password
lives without leaving a discoverable breadcrumb in the startup output, so
downstream tooling that relied on the old log line keeps waiting for a line that
will never come.

---

## 1. Symptom

On a **fresh data dir**, `geode serve` starts fully and reports `server ready`,
but emits **no** admin-password line at any log level. A consumer that waits for
the historical `Generated admin password:` (or any password text) on
stdout/stderr blocks until it times out.

Downstream failure (divelife-api integration tests, `geode v0.6.13`):

```
--- FAIL: TestIntegration_Incident_MediaIDsRoundTrip
    geode.go:143: timed out waiting for geode admin password
--- FAIL: TestIntegration_Incident_CreateEncryptsAtRest   (identical cause)
```

The harness (`divelife-api/internal/testutil/geode.go`) starts the server and
scans combined stdout+stderr for the string `Generated admin password:`
(`geode.go:68`), then `t.Fatal`s after a 10 s timeout (`geode.go:136-143`)
because that string is never printed.

---

## 2. Reproduction

```sh
TMPD=$(mktemp -d); PORT=47895
timeout 6 geode serve --data-dir "$TMPD" --listen 127.0.0.1:$PORT --log-level error \
  > /tmp/geode.log 2>&1

# (a) No password / no "admin password generated" notice anywhere in the output:
grep -in "password" /tmp/geode.log        # -> (no matches)

# (b) The password is sitting in a 0600 dotfile in the data dir instead:
ls -la "$TMPD" | grep admin
#   .rw-------  32  .geode_admin_password
cat "$TMPD/.geode_admin_password"
#   d762b6f72e2f583661af3fd1b86c36b2
```

Observed across `--log-level error`, the default (`info`), and `--log-level
debug` — all three produce the same 13 startup lines, none containing the
password or the "generated" notice. The only on-disk artifacts are
`.geode_admin_password` (0600) and `.geode_hmac_key` (0600).

The full startup output a consumer actually sees (no password, no notice):

```
[startup] user store initialized (0ms)
Generated self-signed certificates at .../server.crt and .../server.key
[startup] certificates ready (9ms)
warning: Audit signing keys stored as files. Set GEODE_AUDIT_PUB and GEODE_AUDIT_SEC env vars for production.
info(graph_storage_adapter): created graph '__geode_security'
[startup] server initialized (162ms)
[startup] auth cache configured (0ms)
{"component":"transport","transport":"quic", ... "status":"listening"}
[startup] QUIC transport listening (2ms)
[startup] thread pool initialized (104ms, 64 workers)
[startup] server ready (303ms total)
info: metrics: ...
```

---

## 3. Root cause (source-cited)

First-boot user bootstrap is `ensureDefaultUser` in
`src/security/user_management.zig:915`. When no users exist it takes the
password from `GEODE_ADMIN_PASSWORD` or, absent that, generates a random one
(`:936-942`), then — per the GAP-0104 fix — deliberately logs the secret-free
notice only:

```zig
// src/security/user_management.zig:948-957
// Log that a password was generated (without the password itself — S3 security fix).
// The actual password is printed to stderr via std.debug.print in server_init.zig
// for one-time retrieval; it must NEVER appear in structured logs ...
if (generated_password) {
    log.err("Initial admin password generated - change on first login", &.{
        Attr.string("admin_username", admin_user),
        Attr.string("action_required", "Password was printed to stderr — change on first login"),
    });
}
```

The actual secret is persisted to a 0600 file under the data dir, per
`src/server/data_dir_permissions.zig:5` ("… the auto-generated admin password to
`<data_dir>/.geode_admin_password`").

Two gaps between the comment/intent and observed behavior:

1. **The password is not on stderr in practice.** The code comment claims the
   password is "printed to stderr via `std.debug.print` in server_init.zig for
   one-time retrieval," but no password text appears on stdout **or** stderr in
   the reproduction above. The only retrieval path that actually works is reading
   `<data_dir>/.geode_admin_password`.
2. **The "Initial admin password generated" notice is also invisible** in the
   combined stdout/stderr at `--log-level error` (and info/debug). So an operator
   watching container logs gets *no* on-screen signal that (a) a password was
   generated or (b) where to find it. The `log.err` notice appears to be routed
   to a sink that is not the process's stdout/stderr in the default serve path.

Net effect: the **only** reliable source of the first-boot password is the
`.geode_admin_password` file, but nothing in the startup output points a human or
a tool to it.

---

## 4. Impact

- **Downstream test harnesses that scrape the log break.** `divelife-api`'s
  `StartGeode` helper waits for `Generated admin password:` and times out, so the
  entire geode-backed integration suite (`//go:build integration`) cannot run.
  Those tests now silently provide no coverage in CI/local runs (they `t.Fatal`
  or are skipped), masking real geode-persistence regressions.
- **Operator first-boot friction.** Bringing up a fresh node and logging in
  requires knowing to `cat <data-dir>/.geode_admin_password`; the logs give no
  hint. In a container, that file is inside the pod's data volume and not surfaced
  anywhere obvious.

---

## 5. Suggested resolution

Pick the security-preserving option(s); do **not** revert to logging the secret.

1. **Emit a discoverable, secret-free breadcrumb to stdout/stderr** at all log
   levels on first boot, e.g.
   `[startup] generated initial admin password written to <data-dir>/.geode_admin_password (mode 0600) — change on first login`.
   This restores operator discoverability and gives tooling a stable, secret-free
   line to wait on. (Ensure this actually reaches the process stdout/stderr — the
   current `log.err` notice does not in the default serve path.)
2. **Document the `.geode_admin_password` file and the `GEODE_ADMIN_PASSWORD`
   env var** as the supported first-boot credential mechanisms (see
   `geode-limitations.md` / `USER_AUTH.md`). For deterministic automation/tests,
   `GEODE_ADMIN_PASSWORD` is the right knob — it skips generation entirely
   (`user_management.zig:936`) and lets the harness use a known credential.

### Consumer-side workaround (already actionable today)

Downstream harnesses should stop scraping logs and instead either:

- set `GEODE_ADMIN_PASSWORD` (and optionally `GEODE_ADMIN_USERNAME`) in the
  server's environment and connect with that known password; **or**
- after `server ready`, read the password from `<data-dir>/.geode_admin_password`.

Specifically `divelife-api/internal/testutil/geode.go` should be updated to set
`GEODE_ADMIN_PASSWORD` on the `geode serve` child process (the cleanest fix:
deterministic, no file race) rather than waiting for the removed log line.

---

## 6. Environment

- geode `v0.6.13`, local binary `/usr/bin/geode`, single-node `geode serve`.
- Reproduced 2026-06-06 on Linux (kernel 6.19.x). Independent of `--log-level`.
- Discovered while running `divelife-api` geode-backed integration tests during
  the UX-cohesion backend follow-up work (sighting/incident/listing media
  round-trips); see `divelife-ui/docs/UX_COHESION_FINDINGS.md`.
