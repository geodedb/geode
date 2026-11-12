# Sonny Geode capability profile

This document defines version 1 of the `sonny-graphrag` compatibility profile.
It has two deliberately separate surfaces:

- `SHOW CAPABILITIES` is runtime discovery. It returns exactly two owned string
  columns, `feature` and `supported`. Fifty-eight rows use only `true` or
  `false`; `sonny_profile_version` is typed metadata whose string value is `1`.
- `release/sonny_capability_profile.json` is an immutable requirements
  document. Its `required` field says what Sonny requires; it is not a snapshot
  of current support and therefore has no `supported` field.

Publication is not readiness. The repository currently identifies the engine
as 0.8.13, while this profile requires at least 0.8.14. All newly published
boolean discovery rows start false and can change only with their owning
behavior and verification.

## Pinned versions and artifact qualification

| Component | Profile identity | Qualification |
|---|---:|---|
| Geode engine source | actual 0.8.13; minimum 0.8.14 | `build.zig.zon:4`; the current source does not satisfy the profile floor |
| `geodedb.com/geode` Go client | minimum v0.1.28 | requirement only; the installed or released client artifact is not qualified here |
| `devnw.dev/geode` adapter | minimum v0.0.3 | requirement only; the installed or released adapter artifact is not qualified here |
| Container image | `docker.io/geodedb/geode:0.8.14` is the intended release coordinate | no 0.8.14 release artifact is asserted by this source publication |
| Container digest | unknown pending the Sonny release/compose qualification | no digest is guessed or certified by this profile |

Client, adapter, image, native-platform, and external-harness qualification
remain separate release evidence. The engine cannot certify those installed
artifact identities through `SHOW CAPABILITIES`.

## Discovery surfaces

- `SHOW VERSION` reports the build-injected engine version
  (`src/execution/admin_ddl.zig:160`).
- `SHOW CAPABILITIES` reports the typed two-string-column discovery snapshot
  (`src/execution/admin_ddl.zig:168`).
- `SHOW INDEXES` reports catalog entries, and `SHOW PROCEDURES` reports the
  registered procedure surface (`src/execution/statement_handlers.zig:62`).
  Index presence is not proof that an index is populated: a catalog row can be
  visible before backfill completes
  (`docs/INDEX_MAINTENANCE_AND_BULK_INGEST.md:149`).
- HELLO has a separate repeated-string `capabilities` field
  (`src/proto/geode.proto:92`). It is not a substitute for the profile version
  row or the requirement manifest.

### Complete discovery inventory

The order below is the wire order. Existing rows retain their prior values;
the 36 profile additions are appended.

| # | Row | Value | Owner |
|---:|---|---|---|
| 1 | `auth_ddl` | `true` | security/auth |
| 2 | `admin_writable` | `true` | execution/admin |
| 3 | `role_ddl` | `true` | security/auth |
| 4 | `grant_ddl` | `true` | security/auth |
| 5 | `show_permissions` | `true` | security/auth |
| 6 | `show_version` | `true` | execution/admin |
| 7 | `policy_ddl` | `true` | security/policy |
| 8 | `fle_ddl` | `false` | security/FLE |
| 9 | `tenant_ddl` | `false` | security/tenancy |
| 10 | `vector_knn` | `true` | vector/index |
| 11 | `vector_index_metrics` | `true` | vector/index |
| 12 | `knn_metric_validation` | `true` | vector/index |
| 13 | `fts_search` | `true` | retrieval/FTS |
| 14 | `fts_phrase_proximity` | `true` | retrieval/FTS |
| 15 | `fts_rebuild` | `true` | retrieval/FTS |
| 16 | `fts_bulk_merge_live_maintenance` | `true` | retrieval/FTS |
| 17 | `fts_row_visibility` | `true` | retrieval/FTS |
| 18 | `ts_procedures` | `true` | timeseries |
| 19 | `read_only_execute` | `true` | execution |
| 20 | `mcp_read_only` | `true` | MCP |
| 21 | `explain` | `true` | planner/execution |
| 22 | `profile` | `true` | planner/execution |
| 23 | `explain_policy` | `true` | security/policy |
| 24 | `sonny_profile_version` | `1` | execution/profile |
| 25 | `read_only_covers_admin_ddl` | `true` | execution/security |
| 26 | `strict_tenancy_production_default` | `false` | security/tenancy |
| 27 | `tenant_scope_fail_closed` | `false` | security/tenancy |
| 28 | `tenant_binding_server_verified` | `false` | transport/security |
| 29 | `fts_strict_tenancy` | `false` | retrieval/FTS |
| 30 | `fts_multi_graph` | `false` | retrieval/FTS |
| 31 | `knn_row_visibility` | `false` | vector/security |
| 32 | `knn_delete_liveness` | `false` | vector/index |
| 33 | `knn_filtered_ann_pushdown` | `false` | vector/security |
| 34 | `graph_procedure_tenancy` | `true` | graph/security |
| 35 | `embedding_space_pinning` | `false` | vector/index |
| 36 | `vector_index_generations` | `false` | vector/index |
| 37 | `vector_generation_rollback` | `false` | vector/index |
| 38 | `vector_build_bounded` | `false` | vector/index |
| 39 | `vector_index_restart_rebuild` | `false` | vector/index |
| 40 | `bulk_vector_index_maintenance` | `false` | vector/index |
| 41 | `bulk_create_fts_maintenance` | `false` | retrieval/FTS |
| 42 | `bulk_delete_batch` | `false` | execution/storage |
| 43 | `index_build_telemetry` | `false` | monitoring/index |
| 44 | `retrieval_ready` | `false` | retrieval |
| 45 | `traversal_multi_edge_type` | `false` | graph/traversal |
| 46 | `traversal_bounded_nodes_cost_time` | `false` | graph/traversal |
| 47 | `traversal_cycle_hub_control` | `false` | graph/traversal |
| 48 | `traversal_cancellation` | `false` | graph/traversal |
| 49 | `traversal_deterministic_ties` | `false` | graph/traversal |
| 50 | `traversal_path_provenance` | `false` | graph/traversal |
| 51 | `weighted_path_raw_property` | `false` | graph/traversal |
| 52 | `temporal_traversal_predicates` | `false` | graph/traversal |
| 53 | `cdc_ordered_resumable` | `false` | streaming/CDC |
| 54 | `cdc_tenant_bound` | `false` | streaming/CDC |
| 55 | `cdc_backpressure_dlq_observable` | `false` | streaming/CDC |
| 56 | `federation_authorization_preserved` | `false` | distributed/federation |
| 57 | `federation_deterministic_topk` | `false` | distributed/federation |
| 58 | `federation_partial_shard_errors` | `false` | distributed/federation |
| 59 | `graph_community_summary_layer` | `false` | Sonny application |

## Required behaviors

### Parameterized GQL surface

Sonny must issue parameterized GQL rather than construct query text from user
values. The current limitations document records parameterized LIMIT/OFFSET as
fixed, so `LIMIT $n` is supported in current source
(`docs/geode-limitations.md:308`); older examples saying otherwise are stale.
The profile's query-planning requirements are represented by `explain`,
`profile`, and `explain_policy`.

### BM25 and full-text retrieval

`fts_search`, `fts_row_visibility`, `fts_rebuild`, `fts_strict_tenancy`,
`fts_multi_graph`, and `bulk_create_fts_maintenance` jointly own the BM25
surface, row authorization, graph isolation, rebuild, and ingest-maintenance
contract. A true search row alone does not satisfy the profile while the new
isolation and maintenance rows remain false.

### HNSW and KNN

`vector_knn`, `knn_metric_validation`, `knn_row_visibility`,
`knn_delete_liveness`, `vector_index_generations`,
`vector_generation_rollback`, `vector_build_bounded`,
`vector_index_restart_rebuild`, and `bulk_vector_index_maintenance` cover
selection, authorization, deletion, lifecycle, bounded construction, restart,
and ingest maintenance. `knn_filtered_ann_pushdown` is optional and gated, but
its false value still requires a security-safe, recall-budgeted alternative;
an arbitrary scan fallback is not automatically acceptable.

### Graph procedures and traversal

`graph_procedure_tenancy`, `traversal_multi_edge_type`,
`traversal_bounded_nodes_cost_time`, `traversal_cycle_hub_control`,
`traversal_cancellation`, `traversal_deterministic_ties`,
`traversal_path_provenance`, `weighted_path_raw_property`, and
`temporal_traversal_predicates` cover tenant-bound algorithms and bounded,
deterministic, attributable path traversal.

### Strict tenancy and verified identity binding

`strict_tenancy_production_default`, `tenant_scope_fail_closed`,
`tenant_binding_server_verified`, `fts_strict_tenancy`,
`knn_row_visibility`, and `graph_procedure_tenancy` collectively prevent a
missing or client-invented tenant scope from widening retrieval.

### Read-only execution

`read_only_execute` records the existing read-only execution surface.
`read_only_covers_admin_ddl` is true since SONNY-2751: a read-only request
(and the MCP read-only mode) refuses the security DDL (CREATE / ALTER / DROP
USER, a password change, CREATE / DROP ROLE, GRANT, REVOKE, CREATE / ALTER /
DROP POLICY) and every procedure that is not on the read-only list (the
tenant, FLE, TDE and CDC mutators among them), as it refuses data and schema
changes.

### CDC

`cdc_ordered_resumable`, `cdc_tenant_bound`, and
`cdc_backpressure_dlq_observable` require an ordered tenant/graph-bound stream,
resumable checkpoints, and observable bounded backpressure/dead-letter
behavior. All three remain false.

### Federation

`federation_authorization_preserved`, `federation_deterministic_topk`, and
`federation_partial_shard_errors` cover authorization propagation,
deterministic result merging, and explicit partial failure. Federation
retrieval remains disabled while any of these gates is false.

### EXPLAIN, PROFILE, and policy explanation

`explain`, `profile`, and `explain_policy` are required and currently true.
They are node-local surfaces; distributed execution does not imply distributed
EXPLAIN/PROFILE support (`docs/DISTRIBUTED_QUERY_COORDINATION.md:7`).

### Metric and dimension pinning

`knn_metric_validation` is currently true. `embedding_space_pinning` remains
false until dimension and metric identity are persisted and enforced for each
embedding space across index generations and restart.

## Immutable requirement inventory

The shipped JSON contains exactly 45 ordered requirements: 40 required and
five optional. `gate` appears only on the five optional entries and is always
`sonny_feature_gate`.

| # | Requirement row | Required | Jira | Gate | Owner |
|---:|---|:---:|---|---|---|
| 1 | `sonny_profile_version` | yes | ENG-4653 | — | execution/profile |
| 2 | `explain` | yes | ENG-4653 | — | planner/execution |
| 3 | `profile` | yes | ENG-4653 | — | planner/execution |
| 4 | `explain_policy` | yes | ENG-4653 | — | security/policy |
| 5 | `read_only_execute` | yes | ENG-4651 | — | execution |
| 6 | `read_only_covers_admin_ddl` | yes | ENG-4651 | — | execution/security |
| 7 | `strict_tenancy_production_default` | yes | ENG-4651 | — | security/tenancy |
| 8 | `tenant_scope_fail_closed` | yes | ENG-4651 | — | security/tenancy |
| 9 | `tenant_binding_server_verified` | yes | ENG-4651 | — | transport/security |
| 10 | `fts_search` | yes | ENG-4651 | — | retrieval/FTS |
| 11 | `fts_row_visibility` | yes | ENG-4651 | — | retrieval/FTS |
| 12 | `fts_strict_tenancy` | yes | ENG-4651 | — | retrieval/FTS |
| 13 | `fts_multi_graph` | yes | ENG-4652 | — | retrieval/FTS |
| 14 | `fts_rebuild` | yes | ENG-4652 | — | retrieval/FTS |
| 15 | `vector_knn` | yes | ENG-4651 | — | vector/index |
| 16 | `knn_row_visibility` | yes | ENG-4651 | — | vector/security |
| 17 | `knn_metric_validation` | yes | ENG-4649 | — | vector/index |
| 18 | `knn_delete_liveness` | yes | ENG-4649 | — | vector/index |
| 19 | `graph_procedure_tenancy` | yes | ENG-4651 | — | graph/security |
| 20 | `embedding_space_pinning` | yes | ENG-4649 | — | vector/index |
| 21 | `vector_index_generations` | yes | ENG-4649 | — | vector/index |
| 22 | `vector_generation_rollback` | yes | ENG-4649 | — | vector/index |
| 23 | `vector_build_bounded` | yes | ENG-4649 | — | vector/index |
| 24 | `vector_index_restart_rebuild` | yes | ENG-4649 | — | vector/index |
| 25 | `bulk_vector_index_maintenance` | yes | ENG-4649 | — | vector/index |
| 26 | `bulk_create_fts_maintenance` | yes | ENG-4652 | — | retrieval/FTS |
| 27 | `bulk_delete_batch` | yes | ENG-4652 | — | execution/storage |
| 28 | `index_build_telemetry` | yes | ENG-4652 | — | monitoring/index |
| 29 | `retrieval_ready` | yes | ENG-4652 | — | retrieval |
| 30 | `traversal_multi_edge_type` | yes | ENG-4655 | — | graph/traversal |
| 31 | `traversal_bounded_nodes_cost_time` | yes | ENG-4655 | — | graph/traversal |
| 32 | `traversal_cycle_hub_control` | yes | ENG-4655 | — | graph/traversal |
| 33 | `traversal_cancellation` | yes | ENG-4655 | — | graph/traversal |
| 34 | `traversal_deterministic_ties` | yes | ENG-4655 | — | graph/traversal |
| 35 | `traversal_path_provenance` | yes | ENG-4655 | — | graph/traversal |
| 36 | `weighted_path_raw_property` | yes | ENG-4655 | — | graph/traversal |
| 37 | `temporal_traversal_predicates` | yes | ENG-4655 | — | graph/traversal |
| 38 | `cdc_ordered_resumable` | yes | ENG-4654 | — | streaming/CDC |
| 39 | `cdc_tenant_bound` | yes | ENG-4654 | — | streaming/CDC |
| 40 | `cdc_backpressure_dlq_observable` | yes | ENG-4654 | — | streaming/CDC |
| 41 | `knn_filtered_ann_pushdown` | no | ENG-4651 | `sonny_feature_gate` | vector/security |
| 42 | `federation_authorization_preserved` | no | ENG-4654 | `sonny_feature_gate` | distributed/federation |
| 43 | `federation_deterministic_topk` | no | ENG-4654 | `sonny_feature_gate` | distributed/federation |
| 44 | `federation_partial_shard_errors` | no | ENG-4654 | `sonny_feature_gate` | distributed/federation |
| 45 | `graph_community_summary_layer` | no | ENG-4654 | `sonny_feature_gate` | Sonny application |

## Fail-closed feature gates

There are five, not four, optional gates:

- `knn_filtered_ann_pushdown` (ENG-4651): when false, do not treat HNSW as
  applying tenant/property filters. Use only an independently safe path and
  budget the scan cost and recall behavior.
- `federation_authorization_preserved` (ENG-4654): when false, never route
  Sonny retrieval through federation.
- `federation_deterministic_topk` (ENG-4654): when false, disable federated
  top-k retrieval rather than accepting unstable ranking.
- `federation_partial_shard_errors` (ENG-4654): when false, disable federated
  retrieval rather than silently accepting partial results.
- `graph_community_summary_layer` (ENG-4654): when false, build Sonny's complete
  community/topic summary layer application-side. This does not claim that
  Geode has no community algorithms at all.

## Startup contract

Select the startup gate with
`--require-capability-profile release/sonny_capability_profile.json`,
`GEODE_REQUIRE_CAPABILITY_PROFILE`, or the configuration-file string key
`require_capability_profile`. Precedence is CLI > environment > selected file
> unset. Every relative path resolves from the process working directory.
Unset preserves ordinary startup. Explicit empty, malformed, duplicate CLI,
or missing-value selections fail; an invalid lower-precedence source cannot be
overridden to hide its error. Existing unreadable or malformed configuration
files also refuse startup; discovery skips only files that do not exist.

The gate validates the complete immutable v1 inventory, strict JSON schema,
profile identity, semantic versions, and every discovery row before checking
required support. Missing or false required booleans refuse startup. Optional
entries remain strictly parsed; missing/false optional support does not satisfy
the dependent application feature. Unknown well-formed boolean discovery rows
are allowed. Manifest input is bounded to 1 MiB, nesting to eight levels, and
discovery to 256 rows. Duplicate keys and duplicate row names are rejected.

Validation runs immediately after effective tenancy resolution, before OTel
export, cluster bootstrap, metrics, gRPC, QUIC, or embedded LSP startup. The
profile is opened once read-only with NONBLOCK/CLOEXEC, then statted and read
through that same descriptor. Only regular files are accepted (including normal
symlinks to regular files); writerless FIFOs cannot block open. Oversize and
growing input is refused without truncation. Unverified non-POSIX file-reading
paths refuse an explicitly requested gate.

The real display version comes from `git describe`. The production adapter
removes only one leading ASCII `v`; the strict validator preserves the remaining
SemVer suffix and precedence. For example, `v0.8.13-2-g080f1737` becomes
`0.8.13-2-g080f1737` and refuses the unchanged `0.8.14` floor. Bare hashes,
unknown versions, doubled prefixes, and malformed versions remain invalid.
Neither support values nor build identity are changed to pass this gate.

Refusal returns an error with a bounded diagnostic so registered cleanup runs.
Storage, authentication, tenant, certificate, audit, and lock initialization may
already have created protected files; refusal is before serving, not rollback
of those files. The gate does not certify broader registry fallback or startup
allocation ownership. Positive live canonical-profile startup still requires
the owning capability behaviors and a compatible release identity. On a
release at or above the floor the live refusal reason is
`MandatoryCapabilityUnsupported` until every required row reports `true`.

`zig build test-capability-gate` runs pure/schema/bounds/config tests, including
allocation-failure checks. `zig build test-capability-gate-startup` runs the
installed real binary, paired ordinary listener controls, native Linux syscall
observation, file refusal cases, and lock-release checks. Native prerequisites
(Python 3, strace, OpenSSL, ptrace, non-root permission checks, and x86_64 for
the deterministic file-growth observer) are required; missing prerequisites
are test failures. Tests retain fresh isolated fixture/evidence directories
under `.superpowers/sdd/` and never use existing deployment data.

## Change policy

Discovery names and order are append-only: existing names are never renamed or
removed (`src/execution/admin_ddl.zig:168`). Boolean rows change to true only
after their owning behavior and real verification land. Requirement inventory,
required bits, identity, type, or minimum-version changes require a profile
version bump and a matching Sonny consumer update. Documentation or Jira-note
wording alone does not change requirement semantics.
