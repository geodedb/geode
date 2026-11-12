# SONNY-6300 restore safety

Status: In Progress. This receipt records the first verified change; it does not
claim that the full restore follow-up is complete.

## Requirements and remaining work

1. Remove the data-loss path still reached by S3 restore. The storage API must
   never write over an open adapter, including canonical path aliases or a
   facade with an empty `data_dir`. Restore into a separate, verified staging
   directory and publish atomically. **Live target refusal implemented; atomic
   staging and verified S3 round-trip still outstanding.**
2. Decide the live engine contract. Retain the staged-output plus operator restart
   contract documented by SONNY-6288 (Jira comment 155274). No hot replacement is
   introduced: teardown checkpoints old memory and frees graph handles still
   reachable by concurrent queries. A future live reload would need admission
   control, draining, close without checkpoint, directory swap, reopen and cache
   reconstruction, respecting `CLAUDE.md`'s Mutex Lock Ordering table. Holding
   only the outer graph lock cannot establish all those lifetime guarantees.
3. Batch durable syncing, expose configurable client waits, and return progress
   or run restore as a job. **Outstanding.** Directory fsync alone does not flush
   file contents; a batched implementation must preserve data durability.
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
Offline targets still use the existing extraction path until staging lands.

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
