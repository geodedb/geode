# Bug: `__geode_security` fails to open under 0.8.4 with `error.NoManifest` against real 0.6.26-era data — graph_storage jumped v0.1.6 -> v0.3.2 underneath the version bump

**Status:** OPEN (mitigated by rollback) — observed in production, `mentats-prod`
namespace, StatefulSet `mentats-geode-0`, 2026-07-28. Caused a live outage:
`mentats-server` could not authenticate to geode at all for ~90 minutes until
rolled back to `0.6.26`.

## What happened

`apps/mentats`' geode was bumped `0.6.26` -> `0.8.4` in platform-gitops
(commit `8e4d018`). The pre-bump review compared geode's own release notes
between those tags and found no breaking changes. It did not check the
underlying `graph_storage` dependency pin, which turns out to have jumped
**v0.1.6 -> v0.3.2** — two major lines — in that same span:

```
# v0.6.26 build.zig.zon
.graph_storage = .{ .url = "...?ref=v0.1.6#...", .hash = "graph_storage-0.1.5-..." }

# v0.8.4 build.zig.zon
.graph_storage = .{ ..., .hash = "graph_storage-0.3.2-..." }
```

ArgoCD auto-synced the bump to `mentats-prod`. On restart, geode's
`AuthGraphManager` tried to open the real `__geode_security` graph —
containing this instance's actual, multi-day-old persisted admin/auth
state — under the new storage engine version, and failed:

```
2026-07-28T19:17:32.096731Z WARN geode.server AuthGraphManager initialization failed error=NoManifest
2026-07-28T19:17:32.096843Z WARN geode.security Generated random admin password — see password file in data directory
2026-07-28T19:17:32.097896Z ERROR geode.auth_graph_manager ADMIN BOOTSTRAP REFUSED (fail-closed): storage engine error
  while checking __geode_security for persisted admin records — cannot distinguish first boot from degraded
  security storage, so GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD seeding is BLOCKED. error=NoManifest
```

This is the `review-0016` fail-closed guard (`e2f6ed31`) working exactly as
designed — it correctly refuses to reseed an admin over an unreadable
persisted store rather than silently creating a new one — but the guard's
existence doesn't help an operator who just wants the service back: every
authentication attempt against geode failed (`AUTH: Authentication failed` /
rate-limited) until the image was rolled back to `0.6.26`, at which point
`__geode_security` opened cleanly with no errors and normal operation resumed
immediately.

Notably, non-security graphs (e.g. `default`) were **not** observed to have
this problem in the same incident — only `__geode_security` hit it. Whether
that's because the security graph's on-disk layout specifically changed
across the v0.1.6 -> v0.3.2 span, or because this instance's `default` graph
just didn't happen to exercise the failing path, is not yet determined.

## Impact

Total loss of geode authentication for `mentats-prod`'s `mentats-server` for
the duration the StatefulSet ran `0.8.4` (~90 minutes before diagnosis +
rollback). Every graph-backed endpoint (`strategy-core`, `analytics`,
`workflow`, etc.) degraded to errors for that window.

## Mitigation applied

Rolled `apps/mentats`' geode back to `0.6.26` in platform-gitops (all three
overlays + base), confirmed `__geode_security` opens cleanly and
`mentats-server` reconnects with no errors. This is a full recovery, not a
partial one — 0.8.4 never got far enough into its refused bootstrap to write
anything, so nothing needed repairing on rollback.

## What's still open

- Root cause **why** `__geode_security` specifically can't be opened by the
  v0.3.2 storage engine reading v0.1.6-era data is not identified — only that
  it happens. Needs a repro against a real (or realistically aged) v0.1.6
  `__geode_security` directory read by a v0.3.x build.
- No migration path exists today for taking a `__geode_security` graph across
  this specific version boundary. Before re-attempting any geode bump past
  `0.6.x` for a service with real persisted auth state, either: (a) find and
  fix the actual read-path incompatibility, (b) build and test an explicit
  migration tool, or (c) confirm empirically (against a copy of real
  production data, not a fresh volume) that the target version can open the
  existing `__geode_security` directory before touching a live deployment.
- The pre-bump review process itself needs a fix: comparing only the target
  project's release notes between two tags is insufficient when the project
  vendors a storage-format-defining dependency whose own version isn't
  mentioned in those notes. A real pre-bump check needs to diff the
  dependency pins (`build.zig.zon` here) and treat any major-line jump in a
  storage-format-owning dependency as a required manual compatibility check,
  not an assumed-safe patch bump.
