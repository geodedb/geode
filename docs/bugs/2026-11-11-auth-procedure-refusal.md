# SONNY-6291: truthful API-key refusal and protected user profiles

Geode main was pulled to `122230c4` before this patch. The first four new
authenticated-executor regressions all failed on that source: fabricated API
keys and scope results, user enumeration, cross-user profile disclosure, and
invented records for absent users.

The GQL `geode.auth.apikey_*` family now returns `ApiKeysUnsupported`, mapped to
SQLSTATE `0A000`. This includes known and catch-all procedure names, with no
user/key lookup. Authentication remains enforced before this refusal. The
disconnected success handlers are removed; this does not change the separate
offline API-key manager or authentication library.

`user_show` authorizes the caller before lookup: self or Admin, otherwise
`42501` with the existing access-denied audit event. An authorized absent-user
lookup returns `UserNotFound` (`42704`). `user_permissions` also rejects absent
users and requires Admin, consistent with the intended SONNY-6269 guard. Both
procedures reject missing/malformed targets. `SHOW PERMISSIONS` therefore
requires Admin in both forms; without `FOR`, it selects the current user. The
reference documents these behavior changes.

## Initial executed local checks

On this patch, using Zig 0.16.0 on Linux/amd64:

```sh
zig build test-sonny6291-auth-procedures test-gap0919 \
  test-auth-ddl-parser test-user-management -j1 --summary all
```

All 44 build steps and 37 tests passed: five new regression tests, one denied
DDL audit test, 18 parser tests and 13 user-management tests. The new tests use
the real executor with authentication enabled, production user/catalog modules
and a real audit file. They cover every exposed API-key procedure plus unknown
names, existing and missing users, Admin/non-Admin/unauthenticated callers,
successful self/Admin profile reads, denied reads and their audit events,
missing users, argument validation and wire error mappings. The testing
allocator checks fixture cleanup; no response is mocked.

CANARY lint passes and `docs/status.csv` is regenerated. The generator still
reports four existing invalid/example status markers; this patch adds no new
invalid marker. No dependency pin, license, storage format or migration changes.

Full aggregate and platform checks remain required in CI before merge. They
are not represented as local passes: the local pre-push hook documents about
29 GiB for its four shard caches, while this shared host currently has about
3 GiB free. The named regression's run step is registered with `shardDep`, so
it participates in the required aggregate CI shards. No CI check or severity is
relaxed.

The Markdown hook bootstrap tried an unreleased Node 27 version and failed
inside nodeenv before any checks ran. Hook Node is now pinned to the installed
stable version 24.22.1; the Markdown hook version and rules are unchanged.

SONNY-1333/6269/6273 work was still unpublished when this patch was prepared.
Integration must preserve those fixes; this patch does not claim their broader
auth mutation, storage-deletion or policy-sealing work complete. SONNY-6291
remains In Progress until the required review/CI gates and merge complete.

## Profile-list bypass review

The final review found `user_list` exposed the same fields protected by
`user_show` on current main, before the unpublished SONNY-6269 change. An added
real-executor regression reproduced that bypass. `user_list` and `SHOW USERS`
now require Admin too. Sensitive reads retain their read-only classification
for replication, separately from authorization: a real follower-coordinator
test proves Admin listing/profile/permission reads succeed while mutations
remain refused. That regression failed before separating these decisions.

The positive Admin list test also exposed a leaked cache-allocated snapshot.
The handler now requests a caller-allocated snapshot array and frees it; its
borrowed user strings retain the existing cache ownership. The old public
`listUsers()` signature is preserved, and lookup failures propagate rather than
becoming an empty success result.

The final adjacent run passed all 66 build steps: 476 tests passed, with two
existing graph-store tests skipped. All fifteen new auth regressions ran and
passed, including the additional cluster case and user-management coverage.
The exact command is the combined command in the checked-delete receipt with
`test-user-management` added. Full required CI, including the standalone
compile sweep, still gates merge and Done.
