# SONNY-6300 restore safety

Status: In Progress. This receipt records the live-target guard and staged
restore work; it does not claim the full restore follow-up is complete.

## Requirements and remaining work

1. Remove the data-loss path still reached by S3 restore. The storage API must
   never write over an open adapter, including canonical path aliases or a
   facade with an empty `data_dir`. Restore into a separate, verified staging
   directory and publish atomically. **Live target refusal and the common
   verified staging path are implemented. S3 uses that common path; a successful
   actual S3 transport round-trip still needs qualification.**
2. Decide the live engine contract. Retain the staged-output plus operator restart
   contract documented by SONNY-6288 (Jira comment 155274). No hot replacement is
   introduced: teardown checkpoints old memory and frees graph handles still
   reachable by concurrent queries. A future live reload would need admission
   control, draining, close without checkpoint, directory swap, reopen and cache
   reconstruction, respecting `CLAUDE.md`'s Mutex Lock Ordering table. Holding
   only the outer graph lock cannot establish all those lifetime guarantees.
3. Batch durable syncing, expose configurable client waits, and return progress
   or run restore as a job. **Linux filesystem batching is implemented; client
   wait/progress handling remains outstanding.** Linux uses one checked syncfs
   for staged contents and directory metadata before publication, then a parent
   directory fsync after rename. Other platforms retain file and directory
   syncing; directory fsync alone cannot make file contents durable.
4. Qualify all final changes in required CI and merge before closing Jira.
   **Outstanding.**

## Source and dependency

Pulled Geode main `122230c4` before editing. Work is isolated on
`fix/sonny-6300-restore-safety`. SONNY-6288's server staging change `ea8cddcc` is
reported as committed elsewhere but unpublished; it is absent from fetched main,
remote refs and this checkout's object store. Its server integration must be
reconciled before claiming the complete follow-up delivered.

## Live-target guard

`BackupManager.restoreToPointInTime` now validates the destination before reading
or writing restore data. It resolves canonical paths and refuses targets that
are the live directory, contain it, or lie beneath it. Both the passed facade and
the current global adapter identify protected directories. The old global
data-directory override and checkpointing adapter reopen are removed. S3 calls
the same preflight before downloading metadata or allocating temporary files.
The named error is `LiveRestoreRequiresRestart`.

The guard does not claim to coordinate other processes or supply a hot reload.
Offline targets now use the verified staging path below.

## Evidence

The named, sharded aggregate-registered step
`zig build test-sonny6300-restore-safety` uses the real graph engine and backup
manager with strict allocator checking. A backup has one node and the live store
subsequently has two. Direct, canonical-alias, pathless-facade and S3-target
refusals preserve both resident state and real durable state after adapter
reopen. A positive fixture-only reopen checks the persistence assertion itself.

- Baseline `geode-6300-live-red2`: four behavioral failures. The direct and alias
  restores returned success; S3 reached its request path instead of refusing.
- Guard `geode-6300-live-green2`: 35/35 build steps, 5/5 tests passed.
- Initial neighboring checks exposed three existing assertions that treated lazy
  store registration as eager hydration. Unchanged main reproduces all three:
  `geode-6300-neighbor-baseline`, 5/8 tests passed. The tests now first-touch the
  `default` graph before asserting unchanged node, edge and property values.
  Final `geode-6300-live-neighbors`: 44/44 build steps and 29/29 tests passed
  (live safety, GAP-0862 integrity, GAP-0880 upload/compression and S3 signing).

Raw logs are retained under the task's `sonny-critical-tmp` evidence directory.
No full aggregate, cross-platform, server-wire or S3-success qualification is
claimed by these focused checks.

## Verified staging

The common restore path refuses nonempty targets and target symlinks. It fully
parses the archive before writing, with checked lengths, version and exact end
position, rejects absolute/traversing/empty components and duplicate paths, then
creates a private mode-0700 sibling stage. Extraction uses exclusive file creation
and propagates parent-directory errors. Every extracted file is compared byte
for byte with the decoded archive using bounded read buffers.

The graph registry must decode successfully; normal adapter startup's tolerant
registry fallback cannot bless an empty restore. Every registry graph directory
must already exist, and a separate adapter opens the real engine and counts nodes
and edges before publication. The adapter's restore-verification constructor
avoids importing the snapshot's merge-key sidecars into the running process's
global registries or backfilling its live store. It never replaces the global
adapter or data-directory override.

Linux syncfs batches all staged file contents and metadata, including files
created during verification. The stage is then renamed on the same filesystem;
missing targets use no-replace rename, and an existing empty target can only be
replaced while it remains empty. The parent directory is synced before success
is returned. A failure before publication cleans up the private stage and leaves
the old target intact. If the final parent sync fails after the rename, the
validated directory can remain visible but success is not returned; operators
must not use a new target before a successful restore response.

Additional evidence:

- `geode-6300-staging-red`: the three new behavioral regressions reproduced a
  partial output after a malformed later entry, a traversal write, and merging
  into a nonempty target (6/9 tests passed, 3 failed).
- The first staging run caught an unsyncable O_PATH parent descriptor. Parent
  syncing now opens an iterable/readable directory; its failed log is retained.
- `geode-6300-staging-green2`: 41/41 build steps and 18/18 tests passed, including
  corrupt registry rejection and existing integrity/upload tests.
- `geode-6300-metadata-red`: a further regression proved normal verification
  imported an archived merge key into the live process (10/11 tests passed,
  one failed). The new verification constructor avoids those global imports.
- `geode-6300-staging-final`: 44/44 build steps and 35/35 tests passed,
  including all eleven restore-safety regressions, GAP-0862 integrity,
  GAP-0880 upload/compression and S3 SigV4. No aggregate/platform or server-wire
  pass is claimed here. A final outer-length race guard then passed all eleven
  named restore tests again (`geode-6300-staging-length-guard`, 35/35 steps).

Client timeouts and progress/job behavior, real S3 transport qualification,
unpublished SONNY-6288 integration, and final required CI/merge remain open.
