# SONNY-6300 restore safety

Status: In Progress. This receipt records the live-target guard and staged
restore work; it does not claim the full restore follow-up is complete.

## Requirements and remaining work

1. Remove the data-loss path still reached by S3 restore. The storage API must
   never write over an open adapter, including canonical path aliases or a
   facade with an empty `data_dir`. Restore into a separate, verified staging
   directory and publish atomically. **Live target refusal and the common
   verified staging path are implemented. S3 uses that common path; a successful
   actual MinIO SigV4 upload/download/restore passed locally; required CI is pending.**
2. Decide the live engine contract. Retain the staged-output plus operator restart
   contract documented by SONNY-6288 (Jira comment 155274). No hot replacement is
   introduced: teardown checkpoints old memory and frees graph handles still
   reachable by concurrent queries. A future live reload would need admission
   control, draining, close without checkpoint, directory swap, reopen and cache
   reconstruction, respecting `CLAUDE.md`'s Mutex Lock Ordering table. Holding
   only the outer graph lock cannot establish all those lifetime guarantees.
3. Batch durable syncing, expose configurable client waits, and return progress
   or run restore as a job. **Linux filesystem batching, owned jobs, progress and configurable client
   waits are implemented and locally qualified.** Linux uses one checked syncfs
   for staged contents and directory metadata before publication, then a parent
   directory fsync after rename. Other platforms retain file and directory
   syncing; directory fsync alone cannot make file contents durable.
4. Qualify all final changes in required CI and merge before closing Jira.
   **Outstanding.**

## Source and dependency

Pulled Geode main `122230c4` before editing. Work is isolated on
`fix/sonny-6300-restore-safety`. SONNY-6288's server staging change `ea8cddcc` is
reported as committed elsewhere but unpublished; it is absent from fetched main,
remote refs and this checkout's object store. The necessary server-target/staging behavior is implemented independently here.
Any later integration must preserve these jobs and shutdown guarantees; the
unavailable branch is not treated as reviewed or as a blocker to this fix.

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

The later job and transport sections record client waits/progress and actual S3
qualification. Final required CI and merge remain open.

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

## Actual transport qualification

`geode-6300-server-build-final` passed 58/58 native steps on signed source
`a934d5f0`. The permanent `test-sonny6300-restore-transport` RUN step is registered
in the sharded aggregate and installs the real geode binary first. Its Python
helper uses only the standard library and openssl, verifies a private CA, sends
real protobuf gRPC over TLS HTTP/2, and uses the actual QUIC CLI. It never mocks
database responses. `geode-6300-wire-formal2` passed all fourteen initial runtime
checks; `geode-6300-transport-registered` then passed 38/38 steps and its actual
runtime regression on the updated native binary. Evidence covers:

- Admin, readonly and unauthenticated start/poll gates; required confirmation
  and invalid target-time refusal.
- Pending acceptance (success false), progress over 579 archived files,
  completion, and stable completion timestamps across real gRPC polls.
- Synchronous clients receiving completion; CLI start/timeout/resume with a
  paused owned daemon, and completed-job polling with restart instructions.
- Target selection beside the actual server data directory, live node count 2,
  and shutdown/restart on the staged copy retaining the backed-up node count 1.

The expanded `geode-6300-transport-cluster` run passed 47/47 steps and 34/34
tests (12 storage, 5 jobs, 16 signing and 1 actual runtime test), including a real
cluster-coordinator refusal. `geode-6300-transport-final` then passed 38/38
steps and its full actual runtime test with an elected leader explicitly
refusing `ClusterWriteNotReplicable` too. Owned daemons are resumed and joined
in cleanup; retained private logs are mode 0600. Jobs borrow the live primary
store, never a thread's temporary query snapshot.

## Actual S3 qualification

`geode-6300-s3-real2` passed 35/35 build steps and the strict-allocator real S3
regression. The fixture starts its own loopback MinIO release
`RELEASE.2025-09-07T16-13-09Z`, verifies executable SHA-256
`7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f`, creates a private
bucket with SigV4, and runs the actual Geode S3 manager. This covers signed backup
and metadata uploads, signed metadata/archive downloads, common verified staging,
live-target refusal, restored count 1 versus live count 2 after reopening, refusal
to overwrite the published nonempty target, and cleanup of private staging.
The initial run failed compilation on the new directory-permission call; the
corrected run above executed the actual round trip. Both raw logs are retained.

`S3Config.addressing_style` defaults to the existing virtual-host mode. Explicit
path mode supports custom endpoints without wildcard DNS and signs the actual
bucket-prefixed URI. Downloads now use an exclusive mode-0700 random sibling
directory rather than the shared predictable `/tmp` path.

The aggregate explicitly skips the external-S3 test when no owned fixture is
configured. A new required `test-restore-s3` CI job supplies the pinned real
fixture and runs it. A separate required `test-zig-compile` job compiles every
aggregate artifact and executable alone. These jobs, all existing mandatory
checks, and merge remain outstanding; focused local passes are not a full
aggregate or cross-platform qualification.
