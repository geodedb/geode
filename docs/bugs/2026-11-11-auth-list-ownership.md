# SONNY-6312: request-owned auth lists

Status: In Progress. Required final-head CI and merge remain outstanding.
Geode main and the auth working branch were pulled before changes. This fix
joins MR !81 because its caller-allocated user array still borrowed cache strings.

## Ownership contract

`UserCache.snapshot` deep-copies username, email and password hash while its
caller holds `user_store_mutex`. User scalar fields are copied as well. The
returned array and every string belong to the requested allocator and survive
concurrent deletion, eviction and updates. `freeUsersSnapshot` releases the
complete snapshot. A partial clone or partially built array unwinds every
successful allocation on error.

`listUsersAlloc` uses the caller's request allocator. The legacy zero-argument
`listUsers` retains its signature and uses the store allocator, but now has the
same deep ownership contract. Its sole repository caller was updated to release
the complete snapshot. Other `listUsers` methods in CLI/user-manager modules
are separate implementations and are not changed by this API.

The user-list handler releases the deep snapshot after creating a fully owned
result. Both `SHOW USERS` and `CALL geode.auth.user_list()` therefore have
request-owned username, email and role values. Result deinitialization releases
all values; no row borrows a cache string after unlocking. Allocation failures
clean up incomplete columns and rows. Fallible allocations complete before a
`Value` union tag becomes `Str`, so cleanup never sees an uninitialized payload.

## Sibling list audit

| Surface | Finding and final behavior |
| --- | --- |
| `role_list` / `SHOW ROLES` | Custom role names were borrowed map keys after unlocking. All names are now copied under `g_custom_roles_mu` and owned by the result, including built-in names. Listing no longer initializes a global map with a request allocator. |
| `policy_list` | Already duplicates name and scope strings and marks result memory owned. A real list/drop test retains and checks the returned values. This does not claim a new concurrent-policy-catalog locking audit; its documented caller synchronization contract remains. |
| `grant_list` | No handler exists; the real dispatch returns `UnknownProcedure`. There is no list snapshot to borrow. |
| `apikey_list` | Refused as `ApiKeysUnsupported` by SONNY-6291 before producing any snapshot. |

Global custom-role storage/persistence and other profile getters are not
replaced by this list-snapshot change. Wider unpublished auth mutation fixes
remain separate.

## Executed checks

`test-sonny6312-user-list-ownership` is a named RUN step registered with
`shardDep`, so the mandatory CI shards run it. Its six real-module tests cover:

- independent snapshot string allocations, retained after actual user deletion;
- 64 repeated actual `SHOW USERS` / procedure calls using the testing allocator
  directly for results, and a retained result after `DROP USER`;
- 512 user-list reads concurrently with 256 real `DROP USER` operations and
  production user-cache creation; each writer request has its own arena backed
  by the strict testing allocator, and the reader owns and frees each result;
- custom-role listing retained after real `DROP ROLE`;
- every allocation failure in snapshot construction, user-list results and
  role-list results, with strict cleanup checking;
- policy-list ownership after real deletion and truthful grant/API-key refusal.

Baseline `geode-6312-red` reproduced four ownership failures on `f37510c1`.
The first implementation run caught a cleanup crash during allocation-failure
injection: a union tag could change before the fallible string allocation had
completed. The final implementation separates allocation from tag assignment.
That failed log is retained; it is not represented as a passing check.

The corrected preliminary `geode-6312-green2` run passed 50/50 build steps and
37/37 tests across the new ownership step, all three prior critical auth
regression steps, reserved-username paths and user-management inline tests.
Final `geode-6312-final` also passed 50/50 build steps and 37/37 tests,
including the added role-list allocation-failure coverage. All six new
ownership tests passed with strict allocator cleanup.

These are focused Linux/amd64 checks with Zig 0.16.0. Full aggregate, standalone
compile and platform checks remain required CI venues; no local broad pass is
claimed. Historical 476-test evidence in the earlier receipts belongs to the
prior head and is not substituted for final-head CI. Raw run logs are retained
in the task's `sonny-critical-tmp` directory.
