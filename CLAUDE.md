# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🏆 Project Status (November 2026)

**DEVELOPMENT READY (single-tenant).** Geode is a **single-tenant** graph database with strong ISO GQL alignment and active development (canonical status: [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) + [docs/KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)). Multi-tenant hardening landed substantially on the `gap-closure-2026-06-09` branch (strict-tenancy auto-default, tenant-hierarchy enforcement in read paths, FLE request-context, tenant-drop cascade, insecure-allow-all production guard, FLE audit-chain fix, durable `ALTER POLICY`), but multi-tenant deployments, distributed clusters, and the full RLS expression compilation path still carry documented residuals and require operator review before production use — see Known Limitations below.

- **Local test baseline: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)** (canonical; failures named with file:line evidence). Its last full per-step sweep (2026-06-11) scored 236 PASS, 0 FAIL, 1 TIMEOUT, 3 SKIP of the 240 named `zig build test-*` steps then registered; `build.zig` now registers about 1,000 named steps and no full re-sweep has been recorded since, so there is no current pass count. Every named step either runs in the sharded aggregate `zig build test` or is listed with its reason in `build.zig`'s `not_in_aggregate_steps`. The intentionally red TDD reproductions on that list are `test-sonny2848-tenant-subquery-aggregation`, `test-sonny2979-txn-crash-atomicity`, `test-sonny6571-schema-names` and `test-sonny6595-wal-drain`. A fresh geodetestlab integration-suite (`../geode-test-harness`) run is owed (prior ~97% / 1644-1688 kept as a dated historical snapshot).
- **ISO/IEC 39075:2024 conformance suite: 120/120** in the named `tests/gql_iso_conformance.zig` suite (`zig build test-iso-conformance`; **parse-only scope** — it asserts parser accept/reject, not executed results). The executed-query `gql_conformance` harness suite is 21/21 after GAP-0892 (T1–T20 plus the `ZZ_cleanup` teardown) (`zig build test-gql-conformance`). This scopes "compliance" to those named suites — not a blanket "100% standards-compliant" claim. See [GQL_COMPLIANCE.md](docs/GQL_COMPLIANCE.md) for the verified-forms list and residual limits (e.g. recursive-CTE working-set model, no `SEARCH`/`CYCLE`).
- **5,792 CANARY Markers** tracking requirements (4,600 TESTED = 79.4%, 871 IMPL = 15.0%, 234 EXEMPT, 69 BENCHED, 18 STUB per `docs/status.csv`, regenerated 2026-11-15; run `make status-generate` for current counts). GAP-0514 (CANARY IMPL governance debt) closed 2026-06-11 at 223 IMPL and was **reopened 2026-11-12 (Partial)**: IMPL is now far above both its ≤250 and ≤5% targets, because the SONNY-738 sweep downgraded TESTED markers whose cited tests never compiled, never ran or only parsed a query. See Known Limitations.
- **✅ Enterprise Features** implemented (TDE, audit, vector search, backup/restore CLI, row-level security) — see limitations below for multi-tenant and backup caveats
- **TODO.md phases 2-7: not all delivered as claimed** — Phase 4 (transaction isolation) is not implemented in the server, Phase 6 (materialized views) is not reachable from any query, and Phase 7's measured gains came from code no build compiled; see Implementation Status below

### Known Limitations

- **Single-tenant recommended for production.** Multi-tenant deployments require operator review of the open gaps in `docs/GAP_ANALYSIS.md` before enabling. The storage-level tenant isolation primitives (`getAllNodesForTenant`, `getNodesByLabels(..., tenant)`, `getEdgesByType(..., tenant, graph)`) are correct and regression-tested, but the full cross-cutting concern has not been end-to-end audited against a multi-tenant benchmark suite.
- **Multi-tenancy query isolation (GAP-0509, Closed 2026-04-11)**: all 17 full-scan sites and 7 label-indexed sites in `match_operations.zig` apply `passesTenantFilter`/`getNodesByLabels(..., tenant)`. `listNodeLabels`/`SHOW TABLES` now takes a `filter_tenant` parameter pulled from `ExecutionContext`. Regression cover in `tests/test_gap0509_tenant_isolation.zig`. Residual: the unsafe `evaluateAggregation`/`evaluateAggregationWithLabels` functions in `aggregation_evaluation.zig` were removed entirely via GAP-0739 (2026-04-16, commit `4be895a9`); only a tombstone comment remains. The surviving aggregation entry points (`evaluateGroupAggregation`, `computeBindingGroupAggregation`) operate on already-tenant-filtered bindings and never iterate `store.nodes` directly.
- **RLS expression engine (closed 2026-04-11; see `docs/GAP_ANALYSIS_RESOLVED.md`)**: wired at server startup (`setGlobalExprRLSEngine` in `src/server/main.zig`) and read from the match loop (`rowPoliciesAllow` in `src/execution/match_operations.zig`). Compiled bytecode policies enforce property-based row-level filtering via `checkRowAccessByUsernameSeeded` (`src/security/rls_core.zig`). Regression cover in `tests/test_rls_expr_engine_wiring.zig`. Residual: the GQL → bytecode pipeline for policy compilation is still manual — policies must be pinned with a pre-compiled `CompiledExpression` until the parser path lands. Temporal policies (`TemporalConstraint`) evaluate but have no end-to-end tests.
- **Distributed module (GAP-0513, Closed 2026-04-10)**: per `docs/DISTRIBUTED_GAP_ANALYSIS.md`, all distributed gaps closed via commit `68ff42c4`. The live cluster path is Raft consensus + `ClusterCoordinator` (`src/distributed/cluster.zig`) with Raft-replicated writes within the documented slice and fail-closed unreplicated surfaces (see Cluster-mode fail-closed surfaces below). Membership is the static `--peers` / `GEODE_PEERS` list (JOIN_CLUSTER is answered with ERR, SONNY-6459); nothing in production fills `cluster_state.shards`, so shard forwarding, replica promotion and replication-factor repair never run outside tests — a failed node's Raft role is taken over by leader election. Modules the server never reached (`node_registry.zig`, `twophase.zig`, `raft_persistent.zig` and others) were deleted (SONNY-6563); `src/distributed/` now holds 13 `.zig` files plus `README.md`, the canonical description of what the cluster does. **Federated / scatter-gather query coordination is NOT implemented** (story SONNY-6573): queries run on the receiving node; the federation and query-coordinator code was never compiled into any build artifact and was removed 2026-11-11 (SONNY-6279). **Raft storage:** an entry is durable before it is applied or acknowledged; if a Raft storage write fails the node pauses (no Raft input, nothing sent or applied, proposals refused with `RaftStoragePersistFailed`) and each tick retries with backoff until it succeeds, so a paused leader loses leadership (SONNY-6617). **Raft snapshots:** a follower restores a durable snapshot (`GRS3`: the engine files of every graph except `__geode_security`, lossless) into the durable store on a restore thread while its Raft node stays paused, never under `inner_mutex`. Graphs are swapped crash-safely, resident state is reset, and the store records the Raft index it reflects (`raft_store.index`) so covered entries are never applied again. The lossy JSON-lines `GRS2` snapshot path was deleted. Every node (leader and followers) snapshots its own durable store past `GEODE_RAFT_SNAPSHOT_ENTRIES` (default 10000) or `GEODE_RAFT_SNAPSHOT_BYTES` (default 64 MiB) and compacts its Raft log there, so the log is bounded: it holds its applies (committed entries queue) while a snapshot thread copies the store off `inner_mutex`, so heartbeats go on, but a snapshotting node's reads lag its commits for the length of the copy. Residual: the raft library writes the snapshot (and a leader re-reads it to send it) under `inner_mutex`, a pause that grows with the store (141-167 ms for 4.4 MB measured). Tests: `test-sonny6636-server-snapshot` (timing), `test-sonny6636-replay-idempotency`, `test-sonny6636-cluster-snapshot` (three `geode serve` processes, SIGKILL and restart) (SONNY-6636; `src/distributed/README.md`). A label or relationship type new to a graph is given its id (a durable label-dictionary write, two fsyncs per shard set) when the entry enters the log, under the graph's `replicated_apply_mutex`, not under the Raft `inner_mutex`, for a graph already open; for a graph the entry first creates, the apply still writes it under `inner_mutex` (SONNY-6633 item 4, SONNY-6636; `src/distributed/README.md`). With `GEODE_TDE_KEY` set the Raft log entries and snapshot data are sealed (`src/distributed/raft_tde_storage.zig`, SONNY-6571). Activates only when `GEODE_CLUSTER_TOKEN` is set; `--no-cluster` (default) bypasses this path entirely.
- **Auth defaults**: Authentication is enabled by default (fail-closed) and must be configured with credentials before deployment; `geode serve --no-auth` is refused at startup in every build mode (SONNY-6329). A user with no stored role resolves to `none` (no global access; only its per-graph grants), not `readwrite` (breaking, 2026-10; see [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md#users-with-no-stored-role-fail-closed-default)). `DROP USER` of a user that does not exist answers 42704 to an Admin (42501 to anyone else; `DROP USER IF EXISTS` is a no-op, SONNY-6609). MFA is not enforced at login (see User Authentication below, SONNY-6604).
- **mTLS**: `GEODE_MTLS_REQUIRED` needs `GEODE_MTLS_CLIENT_CA` (a PEM bundle of CA certificates, the only trust anchors for client certificates); without a usable one, or with `--listen-grpc` (the gRPC transport does not verify client certificates), the server refuses to start (SONNY-6453). A release build of the CLI, or `GEODE_ENV=production`, refuses to connect without `--ca-cert` unless `GEODE_ALLOW_INSECURE_TLS=1` is combined with `--insecure-tls-skip-verify` (SONNY-6453). Every `geode mtls` subcommand is refused as unsupported: nothing maps certificates to users yet (SONNY-6457, story SONNY-6458).
- **LSP authentication**: the TCP listener `geode serve` co-hosts logs `initialize` in with a user name and password, like HELLO, behind the same rate limiter, and a session reads only its own graph's schema (SONNY-6589); tokens are refused (the server issues none, SONNY-6554). The standalone `geode lsp` (stdio, and `--listen`) authenticates nobody and refuses every `initialize`; only stdio `--no-auth` runs, as a synthesized local admin ([docs/LSP_FEATURES.md](docs/LSP_FEATURES.md)).
- **TDE** ([docs/TDE_FILE_LEVEL_ENCRYPTION.md](docs/TDE_FILE_LEVEL_ENCRYPTION.md)): `GEODE_TDE_KEY` (64 hex characters) encrypts the storage engine's pages and WAL and the schema catalogs; a set but malformed key refuses startup before the data directory is created (SONNY-6386), and a non-empty `GEODE_WAL_KEY` refuses startup (there is no separate WAL key, SONNY-6422). In cluster mode the Raft log entry data and snapshot data are sealed (SONNY-6571); the Raft `hard_state` (term and vote) is not. Backups are encrypted under `GEODE_TDE_KEY` when it is set (SONNY-6355). NOT encrypted: label and relationship type names (`labels.dict`) and property key names (`props.idx`, `prop_exact.idx` / `prop_rev.idx`) — red reproduction `test-sonny6571-schema-names`; time-series data unless `GEODE_TS_TDE=1` is also set. Overhead is not "<1%" (see Storage Engine below). A store written by graph_storage ≤ 0.4.11 lost the last 16 bytes of encrypted pages: `geode storage verify --check tde-page-tail` finds them and `geode storage repair --tde-page-tail --i-have-a-backup` restores what is derivable (SONNY-6441, SONNY-6452). The page-format upgrade is one-way: a build on graph_storage ≤ 0.4.11 cannot read the new format; to go back, restore the pre-upgrade backup. A wrong key surfaces as `DecryptionFailed` (Raft directory: `RaftStorageTdeKeyMismatch`). Per-tenant keys are deferred (GAP-0873).
- **Multi-tenant hardening (GAP-0842 + 2026-06-09/10 branch)**: never set `--insecure-allow-all` in production — it bypasses tenant isolation, RLS, and FLE authz for every request. This branch hardened the path substantially: strict-tenancy is now the **auto-default** in multi-tenant mode (GAP-0848; `--strict-tenancy` / `GEODE_STRICT_TENANCY=1`, GAP-0840), `--insecure-allow-all` is refused in production posture by a startup guard (GAP-0850), tenant-hierarchy is enforced in the read paths with two real isolation-leak fixes (GAP-0846), FLE carries a per-request role/tenant context (GAP-0852), tenant DROP cascades to owned graphs (GAP-0847), and the FLE audit-chain corruption that broke restart was fixed (GAP-0854). Documented residuals: the LSP tenant is still client-asserted (GAP-0818, Partial), and per-tenant at-rest encryption keys are deferred (see `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`). See [docs/security/MULTI_TENANT_HARDENING.md](docs/security/MULTI_TENANT_HARDENING.md).
- **CANARY coverage (GAP-0514, Partial — reopened 2026-11-12, SONNY-6321)**: repo-wide CANARY IMPL is 871/5,792 (15.0%; TESTED 4,600 = 79.4%) per `docs/status.csv` (regenerated 2026-11-15 with `make status-csv`; the committed file matches) — above both the gap's ≤250 count and ≤5% targets. It closed 2026-06-11 at 223/5,094. The SONNY-738 sweep then downgraded TESTED markers whose cited tests never compiled or do not exercise the code: SONNY-6298/6321 (`tests/test_tde_kms_integration.zig`, in no build step), SONNY-6374 (TEST= tokens naming missing files), SONNY-6378 (the GAP-0193 batch 2 suites, whose cases only parse a query), and SONNY-6542/6548 (564 `tests/*.zig` files no build step compiled; their markers say IMPL until the files run — see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) "tests/ files no build step compiles"). Removing never-compiled files shrank the marker total. The gap closes again when IMPL ≤ 250 (register row in [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md)).
- **MCP server (GAP-0516, Closed 2026-06-10)**: resource subscriptions stay intentionally unimplemented — Geode does not produce streaming resource-change notifications, so `subscribeResourceHandler`/`unsubscribeResourceHandler` (`src/mcp/server.zig`) return `error.MethodNotFound` → JSON-RPC `-32601` (spec §4.5, the canonical "method not implemented" signal); clients poll via `resources/read`. Regression `tests/test_gap0516_mcp_capabilities.zig` (`zig build test-gap0516`) drives the real `mcp.Server.processMessage` dispatch and asserts the implemented subset (`tools/list`, `resources/list`, `resources/templates/list`, `prompts/list`, `completion/complete`, `logging/setLevel`) succeeds while subscribe/unsubscribe return `-32601`. **Caveat pinned by the test:** the pinned `mcp` v0.1.22 library hardcodes `resources.subscribe:true` in its `initialize` response with no override, so the advertised capability string cannot be made truthful without forking the dependency — the runtime-truthful contract is the handler's `-32601`. `completeHandler` answers an empty CompleteResult (`{"completion":{"values":[],"total":0,"hasMore":false}}`, SONNY-6544); `setLogLevelHandler` is a safe no-op. See [docs/MCP_SERVER.md](docs/MCP_SERVER.md). **Handler result ownership (SONNY-6531, 2026-11-14):** `mcp` v0.1.22 frees the result of EVERY handler callback that returns `[]const u8` (all dispatch arms, also for notifications and when building the response fails) with the allocator passed to `mcp.Server.init`; v0.1.12–v0.1.21 freed only `tools/call` results, so every `resources/read` response (and the stringified `prompts/get` arguments / `completion/complete` params) leaked for the life of `geode mcp`. Geode's handlers return bytes from that same allocator (`GeodeMcpServer.allocator`; fixed text via `ownedCopy`) — a handler returning a string literal is an invalid free. Regression: `zig build test-sonny6531-mcp-ownership` (every method through `processMessage` under `std.testing.allocator`, plus a real `geode mcp --stdio` session), with `test-gap0516`, `test-mcp-read-only`, `test-sonny6494-mcp-dsn-errors` and `test-sonny6544-mcp-completion` all leak-checked.
- **Auth DDL persistence**: Auth DDL writes persist to the HMAC-chained `__geode_security` graph and survive restart (users, roles, password/role/active changes, and per-graph `GRANT … ON GRAPH …`). Hydrated at startup via `PersistentUserResolver`, `hydrateCustomRolesFromGraph`, and `GraphRBACPolicy.loadGraphGrants`. Residuals: no model for a `GRANT <privilege>` without `ON GRAPH` (global privilege is governed by the user's role); custom roles carry no privileges and cannot be granted to a user (`GRANT ROLE <custom>` / `ALTER USER ... SET ROLE <custom>` answer 0A000, SONNY-6292; a user holds one built-in role); GPS policy DDL (`CREATE`/`ALTER`/`DROP POLICY`, incl. `RENAME TO`) now persists durably with the same write-through pattern (GAP-0858, `zig build test-gap0858`) — the remaining RLS residual is the manual GQL→bytecode expression-compilation path; the BIND-time per-graph grant check is additive/permissive in default single-tenant config. See [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md) for the full persistence spec and known limitations.
- **Cluster-mode fail-closed surfaces (2026-06-10)**: in cluster mode (`GEODE_CLUSTER_TOKEN` set), write surfaces with no Raft replication slice are refused instead of silently applying node-locally (`cluster.gateUnreplicatedWrite()`: follower → `ClusterNotLeader`, leader → `ClusterWriteNotReplicable`). Gated surfaces: `geode.ts.insert`/`insert_many`, auth DDL + mutating `geode.auth.*`, policy DDL, tenant create/drop/set_quota, CREATE/DROP INDEX, CREATE/DROP GRAPH, constraints, mutating TDE/CDC/FLE procedures, and a user's own `ALTER USER <self> SET PASSWORD` and the forced reset after a `password_reset_required` login on QUIC and gRPC (SONNY-1332; offline `geode user` / `geode auth init` still write only the member they run against). Standalone mode is unaffected. `MATCH…CREATE` now replicates within its documented slice (head-only named MATCH chains, each var resolving to exactly one node, CREATE endpoints pure var refs, scalar edge props, ≤32 edges); residual shapes (Cartesian matches, new node minted inside the CREATE pattern) fail closed. DECIMAL values, `INSERT`, multi-chain `CREATE`, list/date properties and a MERGE that matches and SETs replicate (SONNY-6718); the replicated and the deliberately refused shapes are in `docs/CLUSTER_WRITES.md`. e2e: `tests/test_cluster_replicable_mutations.zig` (9/9 on 2026-11-12, named step only, incl. "unreplicated write surfaces fail closed"); netns coverage: M8 in `tests/cluster/netns_cluster_membership_churn_test.sh`. Closure log: `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`.
- **Fast-path index maintenance (FTS: Task 4 2026-08-28 and SONNY-6591; vector: SONNY-6595)**: FTS is backed end-to-end by the external `fts-storage` LSM library (see Full-Text Search below). Node create / `SET` / delete on the general path keep fulltext indexes current. The three QUIC node fast paths in `quic_connection_handler.zig` — simple CREATE (`executeBulkSimpleCreate`, fulltext since SONNY-6591), bulk MERGE (`executeBulkSimpleMerge`) and its `/*+BATCH*/` sibling (`executeBatchSimpleMerge`) — run `fts_index_ops.maintainFulltextOnWrite` and, since SONNY-6595, pin vector dimensions (`adoptBulkVectorDims`) and maintain the vector (advanced) indexes on the node's labels (`maintainBulkAdvancedIndexes`), on the connection thread after the commit with no graph lock held. The two edge fast paths (`executeBulkMatchCreateEdge`, `executeBulkMatchMergeEdge`) call neither. The label → fulltext index registry is refilled from the catalog by the first write hook on a graph after a restart, so maintenance keeps working after a clean restart or a crash (SONNY-6591; before, no write after a restart reached an index until `CALL geode.fts.rebuild`). `CALL geode.fts.rebuild('<index>')` (Task 3) remains the recovery/backfill path — e.g. after a restore, or for nodes written by an older binary. Regressions: `zig build test-sonny6591-fts-write-paths` (every path over QUIC and gRPC, with and without TDE, after SIGKILL and SIGTERM restarts), `zig build test-sonny6595-vector-write-paths`, `zig build test-fts-bulk-merge-maintenance`, plus `../geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml`. Ingestion invariant: after any bulk-ingestion run, verify FTS visibility with a canary query (`CALL geode.fts.search(...)` for a known term) before marking ingestion ready — cheap insurance, and the only signal on an older binary or a restore that predates an index. `CALL geode.fts.*` and fulltext `CREATE INDEX` run on the default graph whatever the session's graph (SONNY-2790), so a node fast-path-written into another graph is maintained in that graph's index, which the procedures cannot query.
- **Graph quarantine**: a graph whose hydration fails transiently (out of memory, descriptor/thread quota, `NoSpaceLeft`, `DiskQuota`, `WouldBlock`, `DeviceBusy`) fails only that statement (53200 for OOM) and is built again on the next access (SONNY-6605). Corruption (checksum or encrypted-page authentication failure, `DataCorruption`, `InvalidData`, side-file errors, EIO) quarantines the graph (58000) until a restart reopens the store, and so does an engine transaction that could not be ended cleanly (`AbortNotUndone`, `CommitFailed`, SONNY-6529): reads and writes are refused until the restart reopens the graph at its committed state (`src/graph_store.zig` `GraphQuarantineError` / `TransientHydrationError`).
- **`LabelDictionaryDiverged`**: graph-storage (since 0.4.15) refuses to open a graph whose 16 shard `labels.dict` files disagree on an id its records use; that graph's reads and writes fail with 58000 `LabelDictionaryDiverged` (a restart does not clear it) while other graphs keep serving. `GEODE_LABEL_DICT_ADOPT_SHARD0=<graph>[,<graph>...]` opens a named graph in the "shift" shape by rewriting shards 1-15 from shard 0; the lost-name shapes stay refused and need a manual repair (`src/storage/label_dict_divergence.zig`, SONNY-6524, [docs/SERVER_FEATURES.md](docs/SERVER_FEATURES.md)).
- **CDC captures nothing** (SONNY-6570; capture is story SONNY-6572): no write path feeds the CDC engine. 18 `cdc.*` procedures (`cdc.get_events`, `cdc.pause`, `cdc.set_guardrail`, ...) are refused with 0A000 `CdcNotImplemented`; `enable`, `disable`, `status`, `export_diagnostics`, `get_guardrail_status`, `reset_guardrails`, `start` and `stop` answer only the engine's own state. Every `cdc.*` procedure, and the QUIC/gRPC CDC_CONTROL / CDC_DIAGNOSTICS frames, require Admin (42501 otherwise; SONNY-6561).
- **Schema introspection is session-graph scoped**: `db.labels`, `db.relationshipTypes`, `db.propertyKeys` and SHOW TABLES list only the session graph (its HELLO graph or the last `USE GRAPH`), after the tenant scope and RLS label filtering; an internal graph such as `__geode_security` lists nothing (SONNY-6606, `src/execution/meta_dispatch.zig`).
- **Unregistered tenants**: once the tenant registry holds a tenant other than the default, a session scoped to a tenant the registry does not know is refused with 42501 `TenantNotRegistered`, and a tenant being dropped with `TenantDropping`; with no registry, or an empty one, nothing is refused (SONNY-6612, SONNY-6607, `src/execution/tenancy.zig` `refuseDroppingTenant`).
- **Reserved words as names**: PATH, VALUE, COUNT, AVG and TIMESTAMP stay usable as binding names (a documented non-conformance with ISO/IEC 39075 21.3) because Geode procedures yield columns so named (no procedure yields `timestamp` any more; it is kept for existing queries). Renaming the columns is a breaking change for every client and is a pending decision ([docs/GQL_COMPLIANCE.md](docs/GQL_COMPLIANCE.md), SONNY-6564).
- **MCP endpoint timeout** (geode-client-zig v0.3.19, SONNY-6589/6617): the endpoint DSN timeout bounds the QUIC handshake or gRPC connect, the HELLO answer, the first answer to query / begin / commit / rollback / ping, and a write held up by flow control; a query's later pages wait at most 5 s each, or the timeout if shorter ([docs/MCP_SERVER.md](docs/MCP_SERVER.md)).
- **Full audit report**: See [docs/FULL_AUDIT_2026_04_06.md](docs/FULL_AUDIT_2026_04_06.md) (with 2026-04-11 closure-notes footer) for the comprehensive audit and per-gap resolution details.

## 📚 Documentation Structure

**Complete documentation is available in the [`./docs/`](docs/) directory:**

### Essential References

- **[Implementation Status](docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md)** - Complete feature status with evidence
- **[Features Overview](docs/FEATURES_OVERVIEW.md)** - Comprehensive feature catalog
- **[Development TODO](docs/TODO.md)** - Phase list with status notes (several phases are not implemented as originally claimed; see Implementation Status)
- **[Completion Reports](docs/completion_reports/)** - Detailed phase completion documentation
- **[Quick Reference](docs/QUICK_REFERENCE.md)** - Essential commands and syntax

### Technical Documentation

- **[API Reference](docs/API_REFERENCE.md)** - Complete API documentation
- **[Types & Functions](docs/TYPES_AND_FUNCTIONS.md)** - 50+ specialized data types
- **[GQL Compliance](docs/GQL_COMPLIANCE.md)** - ISO/IEC 39075:2024 conformance
- **[LSP Features](docs/LSP_FEATURES.md)** - Schema-aware completion, hover, and diagnostics with per-user permission filtering. The TCP listener `geode serve` co-hosts authenticates by password and scopes a session to its graph; the standalone stdio / `--listen` LSP authenticates nobody (only stdio `--no-auth` runs) — see LSP authentication in Known Limitations

### Enterprise & Security

- **[Advanced Security Features](docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md)** - RLS, TDE, auth and audit overview (dated; see its status note)
- **[KMS Provider System](docs/KMS_PROVIDER_SYSTEM.md)** - KMS provider clients as library code that the server does not use: `KMSProvider` (`src/security/kms.zig`) wraps and unwraps only with the `external_kms` provider, whose seeded stand-in compiles into test builds only (SONNY-6442); `vault_transit` / `aws_kms` / `azure_kv` configurations are refused with `UnsupportedProvider`; `local_dev` and `remote_kms` were removed (SONNY-6448). The remote KMS client (`src/security/kms_remote.zig`, `zig build test-remote-kms`) verifies the server certificate against a CA bundle and binds attestations to the TLS channel (`test-sonny6442-kms-channel`), but only test steps reach it; the Vault Transit / AWS clients in `external_kms_client.zig` are constructed by nothing (wiring is SONNY-6380). The TDE master key comes from `GEODE_TDE_KEY`, not from a KMS: TDE-KMS integration is NOT implemented (its only code, `tde_kms_integration.zig`, was never compiled and was removed 2026-11-11, SONNY-6298); `GEODE_KMS_URL` only gates startup on the endpoint accepting a TCP connection (a symbolic provider name is refused, SONNY-6348); `tde.configure_kms` is refused with 0A000 (SONNY-6342)
- **[User Authentication](docs/USER_AUTH.md)** - RBAC/ABAC. **MFA is NOT enforced at login** (SONNY-6602; wiring it into HELLO is story SONNY-6604): QUIC and gRPC HELLO take a user name and password only, and `SecurityManager.authenticateWithMFA` has no production caller. The `geode.auth.mfa_*` procedures enroll a TOTP secret and check a code on request (rate limited: five failures, five-minute lockout). Enrollments persist to `__geode_security` (SONNY-6608) and the lockout survives a restart (SONNY-6619); the TOTP secret is sealed at rest with AES-256-GCM under a key derived from the security graph's HMAC key (SONNY-6609). SMS/email/U2F are planned, NOT implemented; step-up uses scoped `OperationClass` classification, fail-closed — GAP-0884, `zig build test-gap0884`
- **[GQL Auth DDL](docs/GQL_AUTH_DDL.md)** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW statements (Geode extension)

### Advanced Features

- **[ML Graph Embeddings](docs/ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk (EXPERIMENTAL library code, `src/ml/graph_embeddings.zig`; see GAP-0879). NOT wired: only `src/lib.zig` exports it, and no procedure or statement reaches it (story SONNY-6588)
- **[Real-time Analytics](docs/REAL_TIME_ANALYTICS.md)** - Streaming analytics library code (`src/analytics/real_time.zig`). NOT wired: only `src/lib.zig` exports it, no procedure or statement reaches it (story SONNY-6588), and the server captures no CDC to feed it
- **[Materialized Views](docs/MATERIALIZED_VIEWS.md)** - NOT available through the server: `src/query/enhanced_materialized_views.zig` (lifecycle, refresh, exact-match rewrite at API level, GAP-0876) is exported from `src/lib.zig` only; no GQL statement, procedure or executor path reaches it (story SONNY-6565). The older `src/query/materialized_views.zig` was removed as unreachable (SONNY-6548)
- **[Enhanced Transaction Isolation](docs/ENHANCED_TRANSACTION_ISOLATION.md)** - Status note: NOT implemented (removed 2026-11-11, SONNY-6298); describes the per-graph write lock, per-query read snapshot and undo-log rollback the server does provide
- **[Distributed Query Coordination](docs/DISTRIBUTED_QUERY_COORDINATION.md)** - Status note: NOT implemented (removed 2026-11-11, SONNY-6279; story SONNY-6573); describes what the live cluster path provides

## 🎯 Implementation Status

### TODO.md Phases (reported complete October 16, 2025; status corrected 2026-11)

**Total**: ~13,554+ lines of production code across all phases

**Phases**:

1. **Phase 2: Parser Extensions** - Map literals, deep nesting (8+ levels)
2. **Phase 3: Set Operations** - UNION/INTERSECT/EXCEPT. The "22/22" came from a harness spec (`gql_set_operations_comprehensive.yml`, not in this repo); no named step counts set operations, and `tests/e2e_setops_*.zig` do not compile under Zig 0.16 (listed in `scripts/ci/unreachable_test_sources.zig`, SONNY-6542). UNION regressions run as `test-gap0814-union-parallelism` and `test-sonny3243-union-write-atomicity`
3. **Phase 4: Transaction Isolation** - NOT implemented in the server: no isolation levels, SSI, phantom-read prevention or deadlock detection. `src/server/txn/enhanced_isolation.zig` and `isolation_integration.zig` were never compiled and were removed 2026-11-11 (SONNY-6298). Writes are serialized per graph, each read sees one snapshot, and explicit transactions roll back through an undo log; see [docs/ENHANCED_TRANSACTION_ISOLATION.md](docs/ENHANCED_TRANSACTION_ISOLATION.md)
4. **Phase 5: Distributed Coordination** - Raft consensus and cluster management, replicating the documented write slice (see Cluster-mode fail-closed surfaces). No two-phase commit and no replicated DDL: nothing proposes a `txn_prepare`/`txn_decide` or `schema_change` entry, so their apply arms run only in tests (SONNY-6547), and `src/distributed/twophase.zig` and the other modules the server never reached were deleted (SONNY-6563); `src/distributed/` now holds 14,052 lines in 13 `.zig` files. Membership is static and shard failover never runs outside tests (see Distributed module in Known Limitations). The phase's federation / scatter-gather query coordination code was never compiled and was removed 2026-11-11 (SONNY-6279)
5. **Phase 6: Materialized Views** - NOT available through the server (see Materialized Views above; story SONNY-6565)
6. **Phase 7: Graph Algorithms** - the `CALL algo.*` procedures (`src/execution/algo_dispatch.zig`, `centrality_algorithms.zig`). The "20-90% performance improvements" came from `src/graph/centrality_optimized.zig` and its sibling modules, which no build ever compiled; they were removed 2026-11-13 (SONNY-6511) and no gain was measured on the server path

**Details**: See [docs/completion_reports/](docs/completion_reports/) for comprehensive phase reports

### Major Features (October 2025 list, status corrected 2026-11)

1. **Backup/Restore** - Engine-backed `geode backup create` / `geode restore` CLI with full graph-data round-trip. Backups are local files: the binary has NO S3 / Digital Ocean Spaces path for backup or restore (`src/storage/s3_backup.zig` is reached by no command; an `s3://`/`http(s)://` `--output` or restore source is refused; copy files with your own tool — SONNY-6290, `zig build test-sonny6290-backup-doc-commands`). `geode restore <file> --data-dir <dir>` restores offline into a new or empty directory, verified before it reports success; from 2026-03-28 until SONNY-6280 the local CLI restore wrote nothing while reporting success (`zig build test-sonny6280-cli-restore-writes-data`). A server restore (QUIC/gRPC `restore`, `geode restore --server`) never writes into the live data directory: it restores into a new, verified `<data dir>.restored-<id>-<ms>` directory beside it and reports it; the server keeps serving its current data until restarted on that directory (Admin-only, audited, refused in cluster mode; until SONNY-6288 it wrote into `GEODE_DATA_DIR` or `./data` in place and reported "Restore completed" while serving old data — `zig build test-sonny6288-server-restore-target`). Backups hold graph data only — never `.geode_hmac_key`, `server.key`/`server.crt`, `.geode_admin_password` or `.geode.lock` — and server backups live in `<data dir>/backups/` (0700, files 0600) or an absolute `GEODE_BACKUP_DIR`, with the legacy `./server_backups` still read for one release; restoring auth records offline needs the source's HMAC key (`--hmac-key-file`, `GEODE_AUTH_HMAC_KEY`/`GEODE_TDE_KEY`) and verifies the chain with it (SONNY-6299, `zig build test-sonny6299-backup-excludes-secrets`). Restoring straight from an `s3://`/`http(s)://` URI is NOT supported (download the file first). A live in-place restore into a running server is NOT implemented (restart on the restored directory). The checks a restore runs by opening the store (graph counts, the auth-chain verifier) run on a throwaway copy, so the committed directory is exactly the backup plus the HMAC key file (SONNY-6348); the staged copy's files and directories are synced after they are all written, in parallel, not one fsync after another and not by a filesystem-wide `syncfs` that waited for every other writer (SONNY-6956), and the CLI waits up to 300 s (`--timeout <s>`) for a server's backup/restore answer (SONNY-6300, `zig build test-sonny6300-staged-restore-paths`). GQL `BACKUP`/`RESTORE` statements are NOT implemented (CLI only). Payload compression: `.gzip` has a real encoder (stdlib DEFLATE, GAP-0880); zstd/lz4/snappy are NOT wired — protocol upload-ingestion residuals remain tracked in GAP-0880. See Known Limitations.
2. **REPL QUIC Integration** - Real-time interactive shell with comprehensive features
3. **Vector Operations** - HNSW vector indexes with 3 metrics (l2/euclidean, cosine, dot/inner product; `src/execution.zig` CREATE INDEX, `src/index/advanced_types_index.zig`); scalar distance functions in `src/types/vector.zig` also cover hamming, jaccard and manhattan
4. **Performance Optimization** - the "13.18x I/O improvement" was never measured on the server path: `src/performance/memory_mapped_io.zig` is used by no server path (it reads the file into a heap buffer; only a benchmark runs it). What is memory-mapped is `src/storage/id_map.zig` and the hydration snapshots (SONNY-6511)
5. **IndexOptimizer** - NOT implemented: `src/server/index_optimizer.zig` and the planner optimizers beside it were never compiled and were removed 2026-11-11 (SONNY-6298). Index use is rule-based: a pattern with a UNIQUE-indexed literal-equality property is seeked through the merge index (`zig build test-multi-pattern-index-seek`), otherwise the label is scanned; EXPLAIN shows fixed per-operator costs. `cbo.StatsRegistry` statistics collection and the predicate-aware `index_catalog.chooseIndexForPredicate` are tested by `zig build test-gap0867`, but no query path calls them. `GEODE_ENABLE_QUERY_OPTIMIZER` turns on a plan cache (`query_plan_cache.SharedQueryOptimizer`) whose hints are passed in `ExecutionContext.optimizer_hints` and read by no executor
6. **ML Graph Embeddings** - EXPERIMENTAL library code: Node2Vec (real p/q-biased walks, seeded, real loss reporting), simplified GraphSAGE aggregation, DeepWalk (see docs/ML_GRAPH_EMBEDDINGS.md, GAP-0879). Not reachable from any query or procedure (SONNY-6588)
7. **Real-time Analytics** - library code (pattern and anomaly detection) not reachable from any query or procedure (SONNY-6588)
8. **Enhanced Transaction Isolation** - NOT implemented (see Phase 4 above)
9. **Distributed Query Coordination** - NOT implemented (story SONNY-6573): the federation / scatter-gather coordinator code was never wired into a build artifact and was removed 2026-11-11 (SONNY-6279). Cluster mode replicates writes through Raft within the documented slice; queries run on the receiving node
10. **Materialized View Refresh** - library-only, not reachable from the server (see Phase 6; SONNY-6565)
11. **CLI Subprocess Elimination** - Unified binary architecture eliminating subprocess spawning
12. **Advanced Security Features** - Row-level security in `src/security/rls_core.zig` (the `rls` module): policy CRUD, bytecode-compiled expression policies enforced in the MATCH loop (`rowPoliciesAllow`), `current_user()` / `has_role()`, temporal and IPv4 CIDR conditions and a policy cache; plus the label-level post-result filter in `src/server/rls_filter.zig`. There is no RLS policy optimizer and no per-policy evaluation statistics (the never-compiled `rls_enhanced.zig` was removed, SONNY-6298)
13. **GQL Auth DDL** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW USERS/ROLES/PERMISSIONS/VERSION/CAPABILITIES (Geode extension; see [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md)). Routes to existing geode.auth.* handlers — same authorization, audit, and __geode_security persistence. user_assign_role now mutates the user's built-in role. All auth DDL writes persist to the `__geode_security` graph (HMAC-chained, hydrated at startup) and survive restart.

### 🏗️ Architecture Overview

**Core Components**:

- **Parser/Lexer** (`src/gql/`): passes the 120/120 ISO conformance suite (`tests/gql_iso_conformance.zig`, `zig build test-iso-conformance`; parse-only scope, scoped to that suite — see [docs/GQL_COMPLIANCE.md](docs/GQL_COMPLIANCE.md))
- **Query Planner** (`src/planner/`): rule-based index use; EXPLAIN reports per-operator seed costs (`cost_explain.zig`, `cost_seed.zig`). No cost-based plan choice reaches execution (see item 5 above)
- **Storage Engine** (`src/storage/`): the external `graph_storage` engine (WAL, pages, checkpoints) behind `graph_storage_adapter.zig`; writes are serialized per graph and each read sees one snapshot (see [docs/ENHANCED_TRANSACTION_ISOLATION.md](docs/ENHANCED_TRANSACTION_ISOLATION.md)). TDE does NOT cost "<1%": `zig build test-sonny6435-tde-overhead` measured +1.0% with an fsync per commit (the default), +29% on the commit path with deferred WAL sync, and +57% to +62% on reads that miss the buffer pool ([docs/TDE_FILE_LEVEL_ENCRYPTION.md](docs/TDE_FILE_LEVEL_ENCRYPTION.md), "Measured overhead"; see TDE in Known Limitations)
- **Index System** (`src/index/`): 6 index types including HNSW and R-tree. Full-text search is backed by the external **`fts-storage`** LSM library (see Full-Text Search below) via `src/storage/fts_storage_adapter.zig`; the `FullTextIndex` facade (`src/index/fulltext.zig`) delegates to it.
- **Security** (`src/security/`): Enterprise authentication, audit, encryption, row-level security (`rls_core.zig`)
- **Transport** (`src/transport/`): QUIC+TLS (`--listen`, always available) plus gRPC over HTTP/2 (`--listen-grpc`, requires OpenSSL 3.x at build and run time; fails closed with `error.TlsRequired` where it is absent). `--listen-grpc` takes `<ipv4>:<port>`, `localhost:<port>` or a port alone and binds exactly that address (IPv4 only: an IPv6 address, a host name or a bad port exits 2; a port alone takes the QUIC `--listen` host, or `0.0.0.0`; `GRPC_ZIG_BIND_ADDR` no longer affects the bind; SONNY-1336). mTLS is not enforced on gRPC, so `GEODE_MTLS_REQUIRED` with `--listen-grpc` refuses to start. Per-target availability and the `libssl.so.3` runtime requirement are documented in [docs/GRPC_TRANSPORT.md](docs/GRPC_TRANSPORT.md) and enforced from `release/target_manifest.json`.

### 🔎 Full-Text Search (fts-storage-backed)

Full-text search uses the external **`fts-storage`** LSM library as the **primary backing store**, surfaced as a native Geode GQL extension. The legacy in-memory inverted index + bespoke `fulltext_persist.zig` were removed; durability now comes from the library's WAL + segments + manifest.

- **Layout / adapter**: `src/storage/fts_storage_adapter.zig` is a per-graph registry of `fts_storage.Engine`s, one per index, under `{graph_dir}/fts/<index_name>/`. The `FullTextIndex` facade (`src/index/fulltext.zig`) delegates to the adapter; tokenization lives in `src/index/fts_tokenizer.zig`.
- **GQL surface** (native Geode extension, ISO-GQL-compliant in form):
  - `CREATE INDEX <name> FOR (n:Label) ON (n.prop[, n.prop2]) USING fulltext` — creates a fulltext index and backfills existing matching nodes.
  - `CALL geode.fts.search('<index>', '<query>'[, <max>])` — returns rows of `node` (id) + `score` (BM25), reachable over the QUIC wire. (This is ISO GQL's `CALL` procedure form — not a scalar function, and not Cypher `UNWIND`.)
  - `CALL geode.fts.phrase('<index>', '<phrase>'[, <max>])` and `CALL geode.fts.proximity('<index>', '<terms>', <distance>[, <max>])` — REAL position-based phrase/proximity search against the engine's persisted per-(term, doc) token positions (GAP-0869; the former hard-coded stubs in `src/fts/advanced.zig` were deleted). Byte-accurate highlighting via `FullTextIndex.highlight` (caller supplies post-RLS/FLE authorized content).
  - `DROP INDEX <name>` — drops the fulltext index on the session's graph (server stays alive; since fts-storage 0.1.1 geode turns the engine's `single_writer_thread_check` off, so a DROP from another worker thread is safe; the adapter waits for in-flight users before tearing an engine down).
  - `CALL geode.fts.rebuild('<index>')` (Task 3) — drops+recreates+re-backfills a fulltext index from current store contents; YIELDs `index`/`nodes_indexed`. Recovery/backfill path (e.g. re-arming an index after a restore, or backfilling nodes written before the Task 4 live-maintenance fix below). The drop→create→backfill window is closed against concurrent writers (2026-08-29): `fts_storage_adapter.zig` tracks a per-index rebuilding flag + pending node-id set (`beginRebuild`/`noteWriteDuringRebuild`/`endRebuild`); a live write landing mid-window is queued instead of erroring on the momentarily-absent engine or double-appending past the backfill snapshot, and drained (plain re-index, never delete-then-reindex) after backfill completes. A second concurrent rebuild of the same index is refused (`RebuildInProgress`). Regression: `tests/test_fts_rebuild.zig`.
- **Live maintenance**: node create / `SET` / delete, and the three QUIC node fast paths (simple CREATE since SONNY-6591; bulk MERGE and `/*+BATCH*/` MERGE since Task 4, 2026-08-28) keep the index current; the fast-path hook runs on the connection thread after the commit, with no graph lock held. Writes to one engine are serialized by the adapter's per-index `write_mu` (geode turns the library's `single_writer_thread_check` off so worker threads may write). The edge fast paths do not maintain indexes (see Known Limitations).
- **Durability**: indexes survive a server restart (lazy re-open of on-disk fts indexes on first query), and the label → index registry the write hooks use is rebuilt from the catalog after a restart (SONNY-6591).
- **Dependency**: pinned in `build.zig.zon` as `.fts_storage` v0.1.6 (commit `e4724290`). See [.migration/PUBLISH-CHECKLIST.md](.migration/PUBLISH-CHECKLIST.md) for the publish requirement.
- **Verification**: unit tests (`tests/test_fts_storage_adapter.zig`, `test_fts_tokenizer.zig`, `test_fts_e2e.zig`, `tests/test_fts_bulk_merge_maintenance.zig` for the bulk-MERGE maintenance contract, plus `tests/test_fts_apply_symmetry.zig` for raft-apply/snapshot maintenance), a native VarianceEnvelope benchmark (`benchmarks/benchmark_fts_storage.zig`), a CI-aware latency gate (`tests/test_fts_latency.zig`), and harness specs (`geodetestlab-cli/specs/fts_storage_basic.yml`, `fulltext_search_basic.yml`, `fts_bulk_merge_visibility.yml`). Plus `zig build test-sonny6591-fts-write-paths` for every write path after restarts. `tests/test_fts_maintenance.zig` and `tests/test_fts_coverage.zig` do not compile under Zig 0.16 and are listed in `scripts/ci/unreachable_test_sources.zig` (SONNY-6542); do not cite them as live coverage.
- **Ingestion invariant**: after any bulk-ingestion run, verify FTS visibility with a canary query (`CALL geode.fts.search(...)` for a known term) before marking ingestion ready — cheap insurance even now that every node fast path is live-maintained and the registry survives restarts, and the only recovery signal on an older binary or a restore that predates an index.

See [docs/FULLTEXT_SEARCH.md](docs/FULLTEXT_SEARCH.md) for the full reference.

### ⏱️ Time-Series (timeseries-storage-backed)

Time-series uses the external **`timeseries-storage`** LSM library as its backing store (geode wraps it in `src/timeseries/timeseries.zig`, pinned in `build.zig.zon`). It was already the store layer; what's NEW is the native GQL surface to write + query it over the wire — surfaced exactly the way FTS is (`CALL geode.ts.*`, the analog of `CALL geode.fts.search`). Dispatch lives in `src/execution/ts_dispatch.zig`.

- **GQL surface** (native Geode extension, ISO/IEC 39075 `CALL`-procedure form — NOT Cypher; `YIELD` is optional, a bare `CALL` auto-projects its columns as rows):
  - WRITE (**mutating** — a read-only user cannot ingest): `CALL geode.ts.insert(device_id, metric, ts, value)` → YIELD `inserted` (count); `CALL geode.ts.insert_many(device_id, metric, [[ts, value], ...])` → YIELD `inserted`.
  - READ (**read-only** — queryable by a read-only user): `CALL geode.ts.range(device_id, metric, start_ts, end_ts)` → YIELD `ts, value` (one row per point, inclusive of both bounds); `CALL geode.ts.last(device_id, metric)` → YIELD `ts, value`; `CALL geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)` → YIELD `bucket_ts, avg`; `CALL geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)` → YIELD `bucket_ts, value` (agg ∈ avg/sum/min/max/count/first/last).
  - A series is identified by the `(device_id, metric)` pair (`device_id` an integer, `metric` a string).
- **Value type: integer (`i64`) only in this release.** `ts` and `value` are integers; a float/decimal value (e.g. `100.0`) is **rejected** with a clear error. Document `100`, not `100.0`. A float value lane is a deferred follow-up.
- **Wire protocol**: values ride the generic GQL rows wire protocol — **no client or proto change** (same posture as `CALL geode.fts.search`).
- **Concurrency / durability**: the timeseries Store is mutex-guarded for concurrent ingest from the QUIC worker pool (a new leaf-tier lock, see the lock-ordering table below); points persist (durable engine) and survive restart; `range` is inclusive `[start_ts, end_ts]` in both the in-memory and durable paths.
- **Verification**: unit tests (`tests/ts_ingest_roundtrip.zig` — ingest/read/restart/exactness/multi-series/bounds/concurrency/rejection), a native VarianceEnvelope benchmark + a CI-aware latency gate (added in a parallel commit), and a geode-test-harness spec (`timeseries_basic.yml`, forthcoming).

See [docs/TIMESERIES.md](docs/TIMESERIES.md) for the full reference.

## 🧮 Key Data Types

### **Vector Types** (Fully Implemented)

- **VectorF32**: Single-precision floating-point vectors with SIMD acceleration
- **VectorI32**: Integer vectors for discrete data and categorical embeddings
- **HNSW Index Support**: vector indexes with 3 metrics (l2/euclidean, cosine, dot/inner product)
- **Index use**: `knn` / `vector_knn` read the registered vector index for the property when there is one, otherwise they scan; there is no cost-based selection
- **Dimensions**: up to 65,535 (`dim: u16`; larger is `VectorTooLarge`). No benchmark in this repository measures the per-distance latency

### **Advanced Types** (Complete)

- **Network Types**: IPv4/IPv6, CIDR, MAC (`src/types/network.zig`, over the `advanced_types` library; stored and returned through GQL in `zig build test-advanced-property-ga`). No benchmark in this repository measures their parse time
- **Geographic**: Point, LineString, Polygon with R-tree spatial indexing
- **Cryptographic**: Hash types, digital signatures, encryption key management
- **Temporal**: DateTime with timezone support, intervals, duration arithmetic

## 🧪 Testing & Quality

### Evidence-Based Development

- **CANARY System**: 5,792 governance markers tracking requirements
- **Local test baseline**: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (canonical; its last full per-step sweep, 2026-06-11, passed 236 of 240 steps with 0 FAIL; no full sweep of the ~1,000 steps registered now has been recorded); a fresh geodetestlab harness run is owed (prior ~97% / 1644-1688 is a dated historical snapshot)
- **ISO conformance suite**: 120/120 in the named `tests/gql_iso_conformance.zig` suite (`zig build test-iso-conformance`; parse-only scope, not a blanket "100% compliant" claim); executed-query `gql_conformance` 21/21 (`zig build test-gql-conformance`)
- **Performance Benchmarks**: Automated regression testing
- **Status Breakdown**: 79.4% TESTED, 15.0% IMPL (871), plus EXEMPT/BENCHED/STUB (2026-11-15; run `make status-generate` for current counts; GAP-0514 reopened 2026-11-12, Partial — see Known Limitations)

### Test Execution

```bash
# Run all tests
python3 scripts/test/extended_test_runner.py

# Or use make targets
make geodetestlab-comprehensive

# Generate governance status
make status-generate

# Build and verify
make build && make verify-fast
```

### Zig Test Conventions

- **Every regression test is a named step.** Write it as `tests/test_<ticket>_<topic>.zig` and register it in `build.zig` as `zig build test-<name>`, with the RUN step passed to `shardDep` as the neighbouring tests do (`const run_x = b.addRunArtifact(x_tests); shardDep(test_step, &run_x.step, 1, test_shard_loads, test_shard_index);`). That is what puts it in the sharded aggregate `zig build test`, which the pre-push hook and the CI shard jobs run. `shardDep` rejects a compile step at configure time, because a compile step is built but never run (SONNY-2394). The one exception is an intentionally red TDD reproduction listed in [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md): it may stay out of `shardDep`, so the aggregate stays green, until the commit that fixes it registers it there, and until then its test artifact is added to `test-compile` directly (`if (g_test_compile_step) |c| c.dependOn(&x_tests.step);`). Any named `test-*` step that stays out of the aggregate (that reproduction, TSan, subprocess cluster, GPU, e2e, benchmark) must be listed with its reason in `build.zig`'s `not_in_aggregate_steps`; configuration (even `zig build -l`) fails for a named step that is in neither, and for a listed name that matches no step or one in the aggregate (SONNY-2772).
- **Every `tests/*.zig` file is compiled by some step or listed.** A file must be the root of a test module, or reached from one through an `@import` the compiler analyzes (an unreferenced container-level `const _x = @import(...)` does not count), or be listed with its reason in `scripts/ci/unreachable_test_sources.zig`; `checkTestSourcesReachable` fails configuration otherwise (SONNY-6542). A listed file's CANARY markers say `IMPL` until it runs; reviving one means porting it, registering a named step through `shardDep` and deleting its entry ([KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)).
- **A test that spawns geode spawns this build's executable.** Register its artifact with `spawnsBuiltGeode(x_tests)` and spawn `@import("geode_test_bin").geode_exe` (SONNY-2697). Never spawn `./zig-out/bin/geode`: it holds whatever the last install left (another commit, or nothing, and the test skips), and depending on the install step does not fix a `-p <prefix>` install or a concurrent build. Configuration fails, listing file:line, when a test artifact any step runs names that path in code (`checkSpawningTestsUseBuiltGeode`, SONNY-6535); a line that only parses the path string carries the trailing comment `// not spawned (SONNY-6535)`.
- **Run `zig build test-compile` before claiming the aggregate is green.** It compiles every artifact the aggregate `test` step runs, in all shards, and every executable target, without running any of them. A sweep of named steps cannot see aggregate artifacts that have no named step, so a sweep can pass while the aggregate does not even compile (SONNY-2394). Executables join on their own, so a new one needs no registration; the exceptions are cross-target and Vulkan builds. `build.zig`'s `rotted_executables` (SONNY-2746) is the list of executables excused because they do not compile; it is empty since SONNY-2771 and should stay empty — migrate or delete an executable rather than add it. It builds several hundred artifacts and its build cache grows past 60 GB: run it on its own, not alongside other builds, with that much free disk.

### Load Test Baseline Tracking

Load test results are tracked against baselines in `benchmarks/loadtest/` to detect performance regressions between releases. The system compares QPS and p50 latency at each concurrency level.

**Baseline file**: `benchmarks/loadtest/baseline.jsonl` (JSONL, one record per concurrency level)

```bash
# Run load tests (requires ../geode-test-harness with Go loadtest built)
cd ../geode-test-harness
GEODE_ADMIN_PASSWORD=<password> LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" make loadtest-go

# Compare results against baseline (from geode repo root)
make loadtest-compare

# Save current results as new baseline (after verified improvement)
make loadtest-save-baseline
```

**Regression thresholds** (configurable via `--threshold`):

- QPS: regression if current < baseline * 0.8 (20% drop)
- p50 latency: regression if current > baseline * 1.2 (20% increase)
- Error rate: regression if current > 10% and baseline was < 5%

**CI**: The `loadtest-regression` job runs the comparison on MRs and main branch pushes. Verification jobs (build, test, scan) run on GitHub Actions (`.github/workflows/ci.yml`, on the github.com/geodedb/geode mirror) while `GEODE_VERIFY_ON` in `.gitlab-ci.yml` is `github`; GitLab keeps the release/publish jobs and gates them on the `github-actions/geode` commit status (`github-verify-gate`). Set `GEODE_VERIFY_ON` to `gitlab` to run verification on GitLab again.

**Updating baselines**: After performance improvements, run `make loadtest-save-baseline` to update the baseline. Commit the updated `baseline.jsonl` with the performance change.

### Geodetestlab Integration Test Suite

The full integration test suite lives in `../geode-test-harness/`. We highly recommend using the unified test target which runs the `geodetestlab` unit tests, integration tests, shell tests, and load tests all together:

```bash
# Run the complete test suite (unit, integration, shell, load tests)
cd ../geode-test-harness
make test-everything GEODE_BINARY=/path/to/geode

# Run just the integration suite (198 specs, ~25 min with 2 workers)
GEODE_BINARY=/path/to/geode make test

# Run single spec
make test-spec SPEC=geodetestlab-cli/specs/my_spec.yml
```

### OTel Monitoring During Tests / Benchmarks (debugging)

When a bug report involves "hung for N minutes", "connection died", "chunk failed",
slow queries, or any cross-layer behavior, **run the suite with OTel monitoring
enabled** to capture every span and metric geode emits during the run. This is
how you triage cascading failures across QUIC ↔ executor ↔ WAL ↔ storage without
having to instrument by hand.

The harness ships a docker `otel/opentelemetry-collector-contrib` lifecycle and
a one-shot Make target:

```bash
cd ../geode-test-harness
# One-shot: start collector → run full suite → verify spans landed → stop collector
make test-everything-otel GEODE_BINARY=/path/to/geode

# Manual control (debugging a specific spec or load profile)
make otel-start                      # docker collector on :44318 / :44317
make otel-tail                       # docker logs -f (live span/metric stream)
GEODE_OTEL=1 make test-spec SPEC=specs/foo.yml
make otel-verify                     # assert spans with service.name=geode arrived
make otel-stop                       # tear down
```

**Generated artefacts** (all under `../geode-test-harness/reports/`, gitignored):

- `reports/spans.jsonl` — every span/metric in OTLP/JSON, one record per line.
  Filter with `jq '.resourceSpans[].scopeSpans[] | select(.scope.name=="wal")'`.
- `reports/otel-collector.log` — drained collector stdout.
- `reports/.otel-env` — exact `OTEL_*` env vars sourced into the test run.

**InstrumentationScopes that fire** (updated 2026-05-29 — see [docs/OBSERVABILITY_ARCHITECTURE.md](docs/OBSERVABILITY_ARCHITECTURE.md)):

> **IMPORTANT:** dependent-library otel seams (wal, gql, dns, vulkan, thread_pool, repl, slog,
> protobuf) are **OFF** — every lib hardcodes `observability.enabled = false` and geode passes no
> `-Dwith_otel`. So those lib scopes do **NOT** fire (zero overhead). geode emits its OWN telemetry
> under `com.geodedb.geode`, and bridges lib-internal QUIC stats into `geode.runtime.*`.

| Scope | What geode emits |
|---|---|
| `com.geodedb.geode` (metrics) | `geode.query.*` (count/active/execution.duration/parse.duration/rows.returned), `geode.transport.*` (connection/request.duration/inflight/bytes), `geode.storage.*`, `geode.wal.*`, `geode.index.*`, `geode.transaction.*`, `geode.security.authorization.check.*`, `geode.security.rls.evaluation.*` (when an RLS policy is active), `geode.audit.*`, `geode.server.*` |
| `com.geodedb.geode` (`geode.runtime.*`) | 76 observable gauges bridging the runtime registry: QUIC RTT/cwnd/bytes-in-flight (`geode.runtime.quic_*`), 20 poll-phase timings, 13 stream-write counters, 24 first-stream phase metrics, `geode.runtime.proto_reader_*`, leaked-conn reaper |
| `com.geodedb.geode` (traces) | `geode.query.execute` SERVER span per statement (bounded attrs only). geode-side periodic flush drains the BSP (no-pool BSP has no timer) |

**Common debugging recipes**:

- *"chunk failed: driver: bad connection"* — look for `geode.transport.request`
  spans whose status is error and check `quic_active_connections` over the
  surrounding window. If `quic_min_smoothed_rtt_ns=12297829382473034410`
  (`0xAAAA…`) shows up, that's an uninit-stat sentinel — focus on whether
  the connection ever completed handshake.
- *Slow query investigation* — diff `gql.execute.PARSE` and
  `geode.query.execute` durations to see whether time is in parse, plan, or
  execute.
- *Pipeline cascade* — the `wal.*` span that errors first names the
  operation type (e.g. `wal.create_edge`); pair with `geode.graph_store.*`
  to localize.

The harness `CLAUDE.md` (`../geode-test-harness/CLAUDE.md`) has the deep dive
on collector defaults, port overrides, and `scripts/otel-collector.sh`
internals.

### Recent Test Improvements (October 2025)

- **stdin handling** in test runner fixed (critical issue)
- **Multi-statement execution** in CLI (session management workflows)
- **Reserved keywords** as parameter names ($count, $name, etc.)
- **IF NOT EXISTS** support in parameter clauses

## 🔧 Development Setup

### Quick Start (Recommended for New Developers)

```bash
# Clone and setup everything automatically
git clone https://gitlab.com/devnw/codepros/geode/geode.git
cd geode
make setup-dev
```

This installs pre-commit hooks, builds the project, and runs tests.

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for code quality enforcement:

```bash
# Install hooks (done automatically by setup-dev)
make pre-commit-install

# Run all checks manually
make pre-commit

# Update hooks to latest versions
make pre-commit-update
```

**Hooks run on commit:** formatting, linting, compilation checks
**Hooks run on push:** cross-compilation, full tests, CANARY verification

### Build & Server

```bash
# Build debug version
make build

# Build release version
make release

# Start server (QUIC+TLS only)
./zig-out/bin/geode serve --listen 0.0.0.0:3141

# Interactive shell
./zig-out/bin/geode shell

# Execute queries
./zig-out/bin/geode query "RETURN 1 AS x"
```

### Common Make Targets

```bash
make help              # Show all available targets
make setup-dev         # Full development setup (recommended)
make build             # Debug build
make release           # Release build
make test              # Run unit tests
make fmt               # Format Zig code
make pre-commit        # Run pre-commit checks
make cross-compile     # Cross-compile for all platforms
make geodetestlab-comprehensive  # Full integration test suite
make loadtest-compare  # Compare load test results against baseline
make loadtest-save-baseline  # Save current results as new baseline
```

## 📋 Code Conventions

### Language & Style

- **Language**: Zig 0.16.0+
- **Comments**: Minimal unless required for clarity
- **CANARY Markers**: Required for all implementations
- **Memory Safety**: Proper allocation/deallocation patterns

### Mutex Lock Ordering (GAP-0278)

When acquiring multiple mutexes, always acquire in this order (lower tier first):

| Tier | Mutex | Module | Notes |
|------|-------|--------|-------|
| 0 | `StorageAdapter.mutex` | `storage/graph_storage_adapter.zig` | Graph handle map (`engines`, `dropped_graph_names`, open failures) — brief lookups and engine open/create; must never be taken while a tier-1 store lock is held (`graph_store.zig` `materializeGraphForWriteLock`). `dropped_graphs.dat` is written and fsynced under it (`saveDroppedGraphNamesLocked`, SONNY-6523). (Listed before 2026-11-15 as `graph_handles_mutex`, a name no code uses.) |
| 0.5 | `merge_tuple_locks[..]` | `storage/graph_storage_adapter.zig` | Striped per-`(label, merge props)` MERGE tuple locks (GAP-0894). Acquired ONLY by the two bulk-MERGE fast paths (`bulkMergeNodeWithReservedIdForTenant`, `bulkMergeNodeWithReservedIdMultiPropForTenant`) and ONLY as the OUTERMOST graph lock: strict order is `merge_tuple_locks[i]` → per-graph `rwlock` (SHARED) → `shard_locks[..]`. **ENG-3914 (RC-2):** the `rwlock` SHARED hold must span the ENTIRE probe→insert, never be dropped and re-taken — the general MERGE path (`execution/crud_operations.zig` `executeMerge`, run under the connection handler's whole-graph `rwlock` EXCLUSIVE) takes NO tuple lock, so any zero-reader gap lets it complete a full probe→CREATE for the same key and duplicate the node. A caller holding `rwlock` (SHARED or EXCLUSIVE) must NEVER then acquire a tuple lock — that reversal is the ABBA deadlock. |
| 1 | `g_store_rwlock` / per-graph `ManagedGraph.rwlock` | `graph_store.zig` / `storage/graph_storage_adapter.zig` | Graph data. The store lock is taken only through `acquireStoreLock` (shared) / `acquireStoreWriteLock` (exclusive); per-graph locks through `acquireGraphReadLock` / `acquireGraphWriteLock`, several at once in alphabetical order (`acquireMultiGraphReadLocks`). |
| 1.03 | Raft `inner_mutex` | `distributed/raft_consensus.zig` | Raft node state. Order: graph `rwlock` → `inner_mutex` → `replicated_apply_mutex` (a leader request holds its graph's `rwlock` while it proposes). A replicated `drop_graph` apply waits for a graph's `rwlock` under `inner_mutex`; a snapshot restore takes the store write lock (`beginReplicatedRestore`, SONNY-6622) on the node's restore thread, NOT under `inner_mutex` (the node stays paused meanwhile, SONNY-6636); so a request that holds a graph or store lock never blocks on `inner_mutex` (`lockInnerForRequest` polls and gives up when `threadMustYieldToReplicatedApply()`). An apply's graph is hydrated before the entry enters the log or before a restarted node replays it, not under `inner_mutex` (`prehydrateForApply`, `ensureGraphHydratedForReplicatedApply`; SONNY-6547, SONNY-6631). |
| 1.05 | `ManagedGraph.replicated_apply_mutex` | `storage/graph_storage_adapter.zig` | Held by a Raft apply for each replicated write to the graph (`beginReplicatedApply`, under `inner_mutex`) and by a checkpoint right after it takes the graph's `rwlock` EXCLUSIVE (SONNY-6528). Order: `rwlock` → this; the apply never takes `rwlock` while it holds this. |
| 1 | `shard_locks[..]` | `storage/graph_storage_adapter.zig` | Per-shard rwlocks over a graph's node/edge/adjacency partitions: a writer takes the graph's `rwlock` SHARED, then its shard EXCLUSIVE (`acquireShardWriteLock`); several shards in ascending index order; `acquireWholeGraphExclusive` takes `rwlock` EXCLUSIVE instead. `string_indexes_mutex` is taken strictly inside a shard lock. |
| 1 | `MergePropertyIndexShard.mutex` | `graph_store.zig` | MERGE property index shards — leaves (no path holding one takes `labels_rwlock`); taken under `labels_rwlock`. Replaced the former `merge_prop_index_mutex` / `merge_prop_index_lock` (GAP-0894). |
| 1 | `perf_c_refcount_mutex` | `graph_store.zig` | PERF-C tenant-keyed refcount maps (issue #814) — leaf-level; serializes `bumpRefcount` / `decRefcount` and the `listNodeLabels` / `listEdgeTypes` / `listPropertiesForLabel` readers. MAY be acquired while `labels_rwlock` is held EXCLUSIVE (writers reach `bumpLabelCount` / `decLabelCount` inside their labels critical section), so the strict ordering is `labels_rwlock` → `perf_c_refcount_mutex`. (`labels_rwlock` is not a leaf, whatever its declaration comment says: `addNodeLabel` also takes `label_index_mutex` and the merge-index shard mutexes under it.) |
| 1 | `g_unique_fence_mutex` | `graph_store.zig` | UNIQUE-constraint fences (`addUniqueFence` / `removeUniqueFence` / `uniqueFenced`, SONNY-6270). Leaf: nothing else is acquired while it is held. Taken under the graph lock (the adapter's `refuseIfUniqueFenced`, CREATE CONSTRAINT under the transport's graph write lock); DROP CONSTRAINT releases the catalog lock before it takes this. |
| 1.5 | `rebuild_mutex` | `index/index_manager.zig` | Advanced-index REGISTRY + rebuild mutex. Guards `advanced_vector_indexes` AND every `VectorIndexWrapper.refs`/`dropped` in-flight reference (`requireVectorIndex` / `releaseVectorIndex`). Every vector-wrapper teardown runs under it, so "held ⇒ no wrapper can be destroyed"; DROP INDEX and the rebuild SWAP wait on `vector_drained` (the wait RELEASES this mutex). **INVARIANT: NEVER acquire a graph lock while holding `rebuild_mutex`** — `rebuildAdvancedVectorIndexNonBlocking` releases it before taking the SHARED lock for its snapshot and again for its drain. A caller MAY hold a graph lock and then take this one (DROP INDEX DDL, the `#875` drain); never the reverse. |
| 1.6 | `rebuild_window_mutex` | `index/index_manager.zig` | Guards `rebuild_windows` only. Leaf, strictly BELOW `rebuild_mutex` — `tryIncrementalInsertForProperty` takes `rebuild_mutex` then this one; nothing ever takes `rebuild_mutex` while holding this. |
| 1.7 | `auth_ddl_lock` | `security/auth_ddl_lock.zig` | One auth / policy change at a time (SONNY-6329). Re-entrant per thread. Taken at the start of every security change (`auth_dispatch.execute` for mutating `geode.auth.*`, `policy_ddl` create/drop/alter, the `user_management` user changes incl. the QUIC/gRPC `ALTER USER ... SET PASSWORD` intercepts) and by the periodic chain verification and `canUserAccessGraph` (SONNY-6352), BEFORE any `__geode_security` graph lock, `user_store_mutex`, the custom-role mutexes, `PolicyCatalog.rwlock`, `seal_mutex` or `user_cache_lock`; never taken while holding any lock but the session graph's. |
| 1.8 | `index_ddl_mutex` | `fle_integration.zig` | Index DDL over FLE-configured fields (SONNY-6468). After any graph lock (index DDL runs under the graph's write lock), before the schema catalog lock and the FLE catalog and key-state mutexes, which are taken while it is held. No graph lock is ever taken while it is held. |
| 2 | `Catalog.rwlock` | `schema/catalog.zig` | Schema catalog. Never held while a graph lock (tier 1) or the node cache is taken: copy under it, release, then read the store (SONNY-2795 pattern). `execution.zig`'s `catalog_instance_mutex` only guards the singleton's init. |
| 3 | `connections_mutex` | `transport/quic.zig` | QUIC connection list |
| 3 | `pending_destroy_mutex` | `transport/quic.zig` | Deferred cleanup |
| 4 | `global_catalog_mutex` / `SchemaCatalog.mutex` | `schema/fle_catalog.zig` | FLE field metadata |
| 4 | `global_mutex` (FLE) | `fle_integration.zig` | FLE key-manager and blind-index singletons. FLE role grants are `map_mutex` (leaf) and `change_mutex` in `security/fle_role_grants.zig`; nothing that holds a graph or catalog lock takes `change_mutex`. |
| 5 | `user_store_mutex` | `security/user_management.zig` | Auth user store (in-memory user cache). Never held across the persistent writer callbacks that write `__geode_security`: the six user changes (create, import, delete, password, role, active) hold `auth_ddl_lock` for the whole change and take this mutex only to read the cache before the write-through and to apply the saved change after it (SONNY-6352). |
| 5 | `SessionRegistry.mutex` | `cli/security/session_storage.zig` | Session state |
| 5 | `g_mfa_store_mu` | `execution/auth_dispatch.zig` | In-memory MFA enrollments and attempt counts. Released before the `__geode_security` write-through, which takes graph locks (`storeMfaAttempts`, SONNY-6619). |
| 6 | `global_cdc_mutex` | `execution/storage_dispatch.zig` | The process CDC engine (enable/disable/diagnostics/control). Replaced `cdc_mutex` in `procedure_registry.zig`, which holds no lock any more; the code states no order for it. |
| 6.5 | `PolicyCatalog.rwlock` | `security/policy_catalog.zig` | GPS policy catalog (SONNY-2756). Taken while a caller holds a graph lock or any lower tier; only leaves are taken under it (the decision cache mutex, `GraphRBACPolicy.grants_mutex`, the user attribute store mutex). Never taken shared twice on one thread. |
| 7 | `IdempotencyDedup.mutex` | `distributed/cluster_replication.zig` | Raft idempotency-key table (SONNY-6667) — leaf: held only inside `record` / `lookup` / `serialize` / `replaceFrom`'s swap, from apply (under `inner_mutex`), the restore thread and the snapshot thread; never held while acquiring another lock. |
| 7 | `g_mutex` (gRPC cancel watch) | `transport/grpc_cancel_watch.zig` | SONNY-6759 registry of in-flight gRPC RPCs and their per-RPC cancel flags. Taken before the vendored transport's `Transport.flow_mutex` (inside `isStreamReset`); nothing holds a transport lock while registering or unregistering an RPC, and no geode lock is acquired while holding it. |
| 7 | `store_mutex` (timeseries) | `timeseries/timeseries.zig` | Timeseries Store (`std.Io.Mutex`) — guards concurrent ingest/read from the QUIC worker pool. Leaf lock: touches no other geode lock and is NEVER held while acquiring another lock. |
| 7 | `Log.mutex` (txn undo log) | `txn_durable_undo.zig` | SONNY-2979 durable transaction undo log (`txn_undo.wal`). Leaf lock: taken with graph locks held (around one append + fsync, or the file's truncation); NEVER held while acquiring another lock (`markThreadRolledBack` commits the session engine transaction with it released). SONNY-6658: an auto-commit statement's flush takes it while holding its statement record's `Record.mutex` (`statement_undo.zig`), so the order is `Record.mutex` → `Log.mutex`; nothing takes `Record.mutex` while holding `Log.mutex`. |
| last | `__geode_security` graph `rwlock` via `holdSecurityGraphForWrite` | `storage/graph_storage_adapter.zig` | Taken EXCLUSIVE last: the caller may hold any auth lock and its session graph's lock, and nothing is acquired while it is held but the store's leaf mutexes. No-op for other graphs or when already held. `seal_mutex` (`security/auth_graph_manager.zig`) is held across the chain seal and its persist. |
| leaf | `user_cache_lock` | `storage/user_storage.zig` | `UserStorageBackend` user cache (SONNY-6329). May be taken under any lock (a graph lock, `user_store_mutex`, `PolicyCatalog.rwlock` shared); nothing is acquired while it is held. |
| leaf | `cluster_state_mutex`, `inbound_conns_mutex` | `distributed/cluster.zig` | `cluster_state.nodes` / `.shards` (SONNY-6456) and the inbound peer connection list. Leaves: no other geode lock is acquired while either is held (read Raft state such as `role()` before taking `cluster_state_mutex`). |
| leaf | `checkpoint_failure_log_mutex` | `storage/graph_storage_adapter.zig` | `CheckpointFailureLog` (SONNY-6523); each hold covers only the log call. |

Tier numbers between the integers (1.03, 1.05, 1.8, 6.5) encode the relative orders the code comments state; the code itself names only `auth_ddl_lock` (1.7) and `PolicyCatalog.rwlock` (6.5) by tier.

Never hold a higher-tier mutex while acquiring a lower-tier one. Thread-local atomics (`std.atomic.Value`) don't require ordering.

### Testing Requirements

- **Unit Tests**: All components must have test coverage
- **Integration Tests**: End-to-end scenario verification  
- **Regression Tests**: Automated prevention of known issues
- **Performance Tests**: Benchmark validation for optimizations

## 🎯 Implementation Methodology

### Evidence-Based Development

1. **CANARY Markers**: All features tracked with governance compliance
2. **Test-Driven**: Implementation verified through automated testing
3. **Performance Validation**: Benchmarks required for optimization claims
4. **Documentation**: All features documented with implementation proof

### Quality Gates

- **Test Coverage**: Keep the local `zig build test-*` baseline green (no named step outside the intentionally red reproductions in `not_in_aggregate_steps` may fail; track the canonical baseline and regressions in [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)), and pass `zig build test-compile` before calling the aggregate `zig build test` green (see Zig Test Conventions above)
- **Memory Safety**: Zero memory leaks in test runs
- **Standards Compliance**: Keep the ISO conformance suite green (120/120 in `tests/gql_iso_conformance.zig`, `zig build test-iso-conformance`) and the executed-query `gql_conformance` suite green (21/21, `zig build test-gql-conformance`)
- **Performance**: No regressions in core operations

## 📍 Current Status

**Open gaps remain; several TODO.md phases are not implemented as originally claimed (see Implementation Status).**

The project is **DEVELOPMENT READY (single-tenant)**. [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md), the canonical register, counts 8 open/partial gaps: GAP-0256 (release signing, Blocked on org signing infra), GAP-0838 (cross-pod cluster, Blocked — repo-side fixes landed, real-cluster k8s validation owed), GAP-0885 (security sibling backlog residuals), GAP-0893 (gRPC transport), GAP-0900 (write throughput: single-threaded commit path; opt-in `GEODE_WAL_SYNC=deferred` shipped), GAP-0514 (CANARY IMPL), GAP-0873 (per-tenant at-rest encryption, deferred to GAP-0290) and GAP-0897 (per-graph metrics registered under fixed names). GAP-0893 was re-diagnosed 2026-08-25 — the "vendor `grpc_zig` blocker" was stale (fixed upstream in v0.1.8; `build.zig.zon` now pins grpc-zig by commit `fe88ba8d`, package 0.1.15) and the real cause was two geode-side defects in `src/transport/grpc_tls.zig` / `grpc_server.zig`, fixed with `zig build test-grpc-raw-io` + `test-transport-parity` (twelve smokes, an e2e lane outside the aggregate) as gates. GAP-0514 (CANARY IMPL coverage) closed 2026-06-11 and was reopened 2026-11-12 (Partial): IMPL is 871 (15.0%), above its ≤250 / ≤5% targets. Operators MUST review the Known Limitations section above before deploying.

**Multi-tenancy caveat:** Multi-tenancy isolation is materially stronger after the 2026-06-09/10 hardening branch — graph-level isolation, query-layer tenant filtering (GAP-0509), wired expression RLS (GAP-0511), strict-tenancy auto-default (GAP-0848), tenant-hierarchy read-path enforcement (GAP-0846), FLE request-context (GAP-0852), and tenant-drop cascade (GAP-0847) are all in place. Documented residuals: per-tenant at-rest encryption keys are deferred (`docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`), the LSP tenant is client-asserted (GAP-0818, Partial), per-tenant quotas are not implemented, and the cross-cutting concern has not been end-to-end audited against a multi-tenant benchmark suite. See [FEATURES_OVERVIEW.md](docs/FEATURES_OVERVIEW.md) for details.

## 🔧 Unified CLI Architecture

**Complete Migration Achieved**:

- ✅ **Single Binary**: `./zig-out/bin/geode` (unified architecture)
- ✅ **Zero Subprocess Calls**: Eliminated geodec/geoded spawning
- **Server and offline modes**: queries go to a server over QUIC (or gRPC); `geode restore --data-dir`, the `geode user` commands and `geode storage verify` / `repair` work offline on a data directory
- ✅ **Local Test Baseline**: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (canonical; no current full-sweep pass count — see Project Status)

---

## 📚 For Comprehensive Information

**See the complete documentation in [`./docs/`](docs/)** for detailed technical specifications, API references, performance analysis, and implementation guides.

*Last Updated: 2026-11-15*
*Status: DEVELOPMENT READY (single-tenant) - ISO conformance suite 120/120 (parse-only scope), local test baseline per [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (see Known Limitations for multi-tenant, distributed, and backup gaps)*
*License: Apache License, Version 2.0 - Copyright 2024-2025 CodePros*

## Important Development Guidelines

- You have completely botched the geodetestlab fixes by mocking and simulating the responses from `geode` in the test harness itself. NEVER EVER DO THIS! Always add the complex missing logic and fixes to the code to make the tests work unless the tests are actually wrong
- NO MOCK DATA, NO SIMULATION, IMPLEMENT THE COMPLEX FEATURES
- Always verify against the authoritative GQL specification before making architectural changes. The official ISO/IEC 39075:2024 standard is the source of truth, not assumptions or secondary sources.
