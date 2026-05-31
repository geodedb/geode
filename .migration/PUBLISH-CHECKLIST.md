# Dependency-Publish Checklist — fts-storage migration

This branch (`feat/storage-lib-migration`) makes the external **`fts-storage`**
LSM library the primary backing store for full-text search. **Local builds work
offline** via the Zig package cache, so the items below are a **CI / remote
concern only** — CI cannot resolve geode's `.fts_storage` `.url` until the
fts-storage branch is pushed/merged.

Do these **in order**:

## 1. Push/merge the fts-storage library branch (REQUIRED for CI)

The fts-storage 0.1.1 change is **committed locally but NOT pushed**. CI will
fail to resolve geode's `.fts_storage` dependency until this lands on the remote.

- **Repo:** `gitlab.com/devnw/zig/fts-storage`
- **Branch:** `feat/optional-single-writer-thread-check`
- **Commit:** `908c1f54` (`908c1f54d8597b60ac84e6f44ad8748a2b72f95f`)
- **Version:** `v0.1.1`
- **What it adds:** `EngineConfig.single_writer_thread_check` — geode sets it
  `false` in `fts_storage_adapter` so the engine can be driven from the QUIC
  server's worker-thread pool (geode serializes via the adapter `write_mu` +
  the engine `rw_lock`). This makes a cross-worker-thread `DROP INDEX` safe and
  keeps the server alive during the drop.

```sh
# In the fts-storage checkout:
git push origin feat/optional-single-writer-thread-check
# then merge to the default branch (or tag v0.1.1) so the pinned commit is reachable
```

The pinned commit hash in geode's `build.zig.zon` (`908c1f54…`) **must be
reachable on the remote** for CI's package fetch to succeed.

## 2. Push the geode branch

- **Repo:** `gitlab.com/devnw/codepros/geode/geode`
- **Branch:** `feat/storage-lib-migration`

```sh
git push origin feat/storage-lib-migration
```

CI on this branch fetches `.fts_storage` from the URL in `build.zig.zon`, so
step 1 **must** complete first.

## Reference: `build.zig.zon` `.fts_storage` stanza

```zig
.fts_storage = .{
    .url = "git+https://gitlab.com/devnw/zig/fts-storage.git#908c1f54d8597b60ac84e6f44ad8748a2b72f95f",
    .hash = "fts_storage-0.1.1-daM0d4TNCgBuDB3Lbb1fn-5yy15Na-l8dADLQpMB6Zos",
},
```

## Notes

- **Local builds are unaffected** — the dependency is already in the local Zig
  package cache (resolved by the `.hash` above), so `zig build` works offline
  today. This checklist is purely about making CI (and other machines without a
  warm cache) able to fetch the dependency from its remote URL.
- **No client / proto / transport publish needed.** FTS results ride the generic
  GQL Execute+rows protocol; no `geode-client-zig`, client, or proto changes
  were made on this branch. Nothing else to publish.
