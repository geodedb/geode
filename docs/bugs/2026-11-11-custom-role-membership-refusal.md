# SONNY-6292: refuse ineffective custom-role assignments

Main was fetched again before this change and remained `122230c4`. The working
branch already contained the separate SONNY-6291 fix. Three new regression tests
then reproduced custom-role assignments returning success instead of refusal.

The procedure now returns `CustomRoleMembershipUnsupported` (`0A000`) for a
catalogued custom role, including `GRANT ROLE`, `ALTER USER ... SET ROLE` and
direct procedure calls. An unknown role remains `UnknownRole`; built-in
assignments still work. The entire unused, nonpersistent membership table and
its borrowed-slice accessor are removed. No assignment can remain in that table
after role deletion or return when a role name is reused. Enabling custom-role
membership still requires real persistence and authorization support.

The built-in assignment reply is allocated before mutation and owns its result
string. Failures propagate as errors rather than success-shaped error rows.
This does not claim to fix the separate persistence-callback failures tracked
by SONNY-3038/1333.

## Executed verification

```sh
zig build test-sonny6292-custom-role-refusal test-sonny6291-auth-procedures \
  test-gap0919 test-auth-ddl-parser test-user-management -j1 --summary all
```

Zig 0.16.0 on Linux/amd64: 47/47 build steps, 40/40 tests passed. The new tests
use the real authenticated executor, canonical permission decision and graph
storage callbacks. They prove refusal through all three assignment routes,
unchanged effective write denial, successful built-in assignment and writes,
drop/recreate safety, and durable restart behavior. The restart checkpoints the
real adapter, closes the manager/catalog/store, reopens the same data directory,
verifies the HMAC chain and rehydrates the custom-role catalog before checking
refusal and permissions again. This is a real storage reopen, not a fabricated
database response or a full server-process restart claim.

SONNY-6291's five tests and the neighboring suites remain green after extracting
their shared real-executor fixture. The new run step participates in the
aggregate via `shardDep`. CANARY lint/status are refreshed. Full required CI on
the combined MR head remains a prerequisite to merge and Done; no local
aggregate or platform result is claimed. No dependency, license or storage
format changes are introduced.
