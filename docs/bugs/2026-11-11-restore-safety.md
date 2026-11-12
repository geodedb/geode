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

## Restore jobs and client waits

The job manager permits one active restore and retains the most recent eight
job records in memory. It owns copied request strings, uses a private random
job id and a sibling output directory, and reports queued/running/completed/
failed states. Status snapshots own their strings. Completed history is bounded;
synchronous waiters pin their result until returned. Unknown/evicted job ids
return `RestoreJobNotFound`; job records do not survive server restart.

Progress reports reading, decoding, extraction, file verification, store
verification, syncing and publication. Completion is recorded only after the
parent sync. Failed checksums remain failed jobs and do not publish output.
Shutdown first refuses new jobs and then joins workers without holding the
status mutex. The server drains this manager before freeing the global store;
its outer cleanup follows the existing gRPC-straggler preservation policy.

QUIC and gRPC share the service. Both keep current-session Admin authorization
before each start or status poll. New restores are cluster-gated and audited as
`SERVER_RESTORE` with the job id and state. The service chooses a sibling of the
adapter's actual data directory, never a client-controlled target or a fresh
environment lookup. This implements the necessary server-target/staging behavior
independently of SONNY-6288's unpublished branch. A later integration must retain
the new job and lifetime behavior; its unavailable source is not represented as
reviewed or qualified here.

Wire additions are optional protobuf fields: `RestoreRequest.async_restore`
opts into immediate job acceptance; `job_id` polls an existing job. Responses
include job id/state, phase and completed/total file counts. `success` is true
only for completed restoration, never acceptance. Legacy synchronous requests
continue to wait for terminal state, and completion timestamps are stable across
polls. The restored copy is offline; the response instructs the operator to
restart with its reported data directory. Starting a job does not switch the
live engine or make that server serve the restored copy.

The remote CLI requests jobs and polls progress. `--timeout-ms` configures the
total wait (default 1800000 ms / 30 minutes, range 1..86400000); each request has
a bounded wait and each poll releases its decode arena. A timeout/disconnect
after the job id has been received reports how to resume with `--job <id>` and
the same server/authentication/TLS options. Timing out does not cancel the server
job. `--job` is read-only polling and needs no confirmation; it cannot be combined
with a source or new target time. gRPC clients opt into `async_restore`, poll with
their authenticated session id and choose their normal per-request RPC deadline;
a poll does not wait for the long filesystem operation.

Executed evidence for this phase:

- `geode-6300-progress`: 35/35 steps and 12/12 actual-storage tests passed.
- `geode-6300-jobs2` and `geode-6300-jobs-service-base2`: 38/38 steps and 15/15
  actual job/storage tests passed (request expiry, phase polling, active-job
  exclusion, checksum failure, bounded history and shutdown drain).
- `geode-6300-jobs-final`: 38/38 steps and 17/17 tests passed, adding synchronous
  completion/stable timestamps and actual protobuf request/response round trips.
- `geode-6300-server-build`: 58/58 native Debug build steps passed, including the
  real geode and gql executables. The resulting binary's help exposes both new
  flags, and it rejects zero, malformed and excessive timeouts and conflicting
  job/source options. This build preceded the final timestamp/audit/CLI cleanup
  additions; a fresh native build on the final source remains required.

Shared transport and CLI polling markers remain IMPL until their real runtime
qualification. Actual QUIC/gRPC progress/resume/auth/cluster behavior, an actual
S3 transport round-trip, final source CI and merge remain outstanding. This
receipt does not substitute job-manager tests or a successful build for those
runtime checks.
