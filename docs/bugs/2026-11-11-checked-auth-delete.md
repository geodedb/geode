# SONNY-6293: preserve security records when node deletion fails

The branch was pulled and main fetched before changes; main remained
`122230c4`. This patch follows the separate SONNY-6291/6292 commits. All six
new behavioral regressions failed before the fix: role/policy removal swallowed
delete failures, and a failed real `DROP POLICY` had already discarded its
cached record.

`UserStorageBackend.removeRole` and `removePolicy` now use
`GraphStore.deleteNodeChecked` before removing cache or node-index entries.
The checked primitive propagates the existing statement write fence, undo
recording, graph-name allocation, adapter slot lookup and adapter delete errors.
The legacy void method remains available and retains the statement resource
error relay. A failure before deletion therefore leaves the record/cache/index
available, and the policy DDL caller preserves its catalog entry.

## Executed regression proof

```sh
zig build test-sonny6293-checked-auth-delete -j1 --summary all
```

Zig 0.16.0, Linux/amd64: 35/35 build steps and 6/6 tests passed. Both role and
policy deletion are tested against a real statement write fence and a failing
allocator. Tests check the retained node, cache and index, verify the HMAC chain,
and retry successfully after clearing the fault.

The other two tests run authenticated `DROP POLICY` through the real executor
and production persistence callbacks for allow and deny policies. A refused
delete returns an error, retains the policy and preserves its effective access
decision. The tests checkpoint storage, close and reopen the actual
adapter/catalog, verify the HMAC chain, rehydrate policy state and check its
enforcement again. A subsequent successful drop removes it. No database response
is mocked; this is durable engine reopen coverage, not a full process restart.

The checked primitive was not yet on main: SONNY-1333's related implementation
and SONNY-6273's manager-level sealing fix remained unpublished elsewhere.
Integration must preserve those changes when available. This patch does not
claim general atomicity for the separate partly applied engine-mutation defect
SONNY-6268, or fix other auth mutation callbacks. It covers refused deletion,
error propagation and cache ordering for these two record types.

The combined adjacent run also passed all 63 build steps: 462 tests passed and
two tests in the graph-store inline root were skipped. It includes all fourteen
new SONNY-6291/6292/6293 tests (none skipped), both auth-manager suites, GPS
policy persistence, policy hygiene, statement limit atomicity/undo and the
graph-store inline suite. Exact command:

```sh
zig build test-sonny6291-auth-procedures test-sonny6292-custom-role-refusal \
  test-sonny6293-checked-auth-delete test-auth-graph-manager-src \
  test-auth-graph-manager test-gps-policy-persistence \
  test-sonny2757-policy-hygiene test-sonny3348-limit-atomicity \
  test-sonny3348-statement-undo test-graph-store -j1 --summary all
```

CANARY lint passes and the generated status inventory is current. The generator
continues to disclose four existing invalid/example markers; this patch adds no
invalid marker. Full required CI remains a prerequisite to merge and Done. No
aggregate/platform local pass is claimed. No dependency, license, storage format
or migration changes are introduced.

The final qualification review found that CI ran aggregate shards without the
separate `zig build test-compile` sweep required by AGENTS.md. A required
`test-zig-compile` job now runs that command alone on the existing dedicated
Linux pool for source/build changes and tags, with one compiler step at a time
and a retained result log. Its large disposable outputs are not uploaded as a
cache. Passing this job is an additional merge prerequisite; the local host
does not have space for the full sweep.
