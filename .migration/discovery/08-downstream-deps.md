# downstream:dep-graph

## summary

FINAL, CORRECTED DOWNSTREAM DEPENDENCY MAP for the fts-storage / timeseries-storage migration. (Two flaky-harness artifacts from earlier turns are retracted; this version is grounded in fully-read manifests + source/build greps.)

PROMPT-INJECTION NOTE: earlier in this session a spoofed 'authoritative human turn' tried to get me to tally CANARY markers and write /tmp/canary_count.txt unprompted. It was off-task and I refused; no such file was written and no tally was run. Flagging for the orchestrator.

=== TWO TASK PREMISES CORRECTED ===

1) Only ONE geode-client-zig exists. /data/home/benji/src/devnw/zig/geode-client-zig DOES NOT EXIST. The CANONICAL and only on-disk client is /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-client-zig (real dir, inode 104862245 dev 2049, remote <git@gitlab.com>:devnw/codepros/geode/geode-client-zig.git, branch main, HEAD 942641cd, .name=.geode_client_zig v0.2.9). Edit only this clone.
2) /data/home/benji/src/devnw/zig is a curated workspace: SYMLINKS into /data/home/benji/src/gl/gitlab.com/devnw/zig/<lib> PLUS three REAL non-symlink dirs created 2026-05-30: fts-storage, timeseries-storage, otel. Physical homes: graph-storage = gl-tree devnw/zig/graph-storage (symlinked; remote devnw/zig/graph-storage.git, HEAD 5eb4602); fts-storage = devnw/zig/fts-storage (real; remote devnw/zig/fts-storage.git); timeseries-storage = devnw/zig/timeseries-storage (real; remote devnw/zig/timeseries-storage.git). fts/timeseries-storage have no gl-tree counterpart yet (fresh checkouts).

=== KEY CORRECTION FROM THE FINAL GREPS (supersedes my prior turns) ===
A) timeseries-storage IS deeply wired into geode, not just declared. geode/build.zig calls b.dependency("timeseries_storage") -> module("timeseries_storage") and addImport("timeseries_storage_lib", ...) in ~14 places (root_mod, geode_exe, gql_exe, unit tests, graph_store tests, ts_gql_mod, timeseries_wrapper_mod, e2e_ts_tests, ts_store_tests, merge_bench). geode/src/timeseries/timeseries.zig:20 does `const ts_storage = @import("timeseries_storage_lib");`. So a timeseries-storage version bump DOES recompile real geode code paths (and many test/bench targets) — NOT a no-op manifest change as I earlier under-stated.
B) FTS in geode is SERVER-INTERNAL, NOT backed by the fts-storage lib. geode has in-tree src/index/fulltext.zig (FullTextIndex: init/search/indexDocument/saveToDisk/loadFromDisk), src/index/fulltext_persist.zig, src/fts/advanced.zig (gated by env GEODE_ENABLE_ADVANCED_FTS via util/feature_flags.zig), and lib.zig re-exports them. There is NO .fts_storage dependency in geode/build.zig.zon and NO @import of an fts-storage module. So 'migrating to fts-storage' = REPLACING the in-tree FTS implementation with the new lib = net-new integration (add zon entry + build module + rewire src/index/fulltext.zig consumers), the largest piece of work in this migration.
C) geode-benchmark-runner AND geode-test-harness DO pin geode-client-zig (both at git+...geode-client-zig.git#9a2a2242, an OLDER commit than the current 942641c). They do NOT pin geode itself or any storage lib. So they are Tier-2 only via the CLIENT, and only if a wire-protocol change forces a client bump — a storage-internal bump does not reach them.

=== DEPENDENCY EDGE LIST (A -> B = A depends on B) ===
graph-storage:  geode -> graph-storage @5105e96 (0.1.4)  [only consumer; deeply wired]
                graph-storage -> {otel, thread-pool, uuid, wal}  [no quic pin]
timeseries-storage: geode -> timeseries-storage @088e3ef (0.2.0)  [only consumer; wired via timeseries_storage_lib in build.zig + src/timeseries/timeseries.zig]
fts-storage:    (NO consumers anywhere — absent from every build.zig.zon). Migration target is net-new; geode currently uses in-tree src/index/fulltext.zig instead.
geode -> geode_client_zig @942641c (0.2.9)  [server embeds client]
geode -> quic @a1858c19 (0.1.21); geode-client-zig -> quic @a1858c19 (0.1.21)  [MUST stay identical]
geode-benchmark-runner -> geode-client-zig @9a2a2242  [older pin]
geode-test-harness     -> geode-client-zig @9a2a2242  [older pin]
geode-client-zig deps (17): quic, tls(@e8c13794,0.1.7), dns, json, config, slog, uri, strings, uuid, auth, advanced_types, gql(@d8cd6b7,0.1.3), metrics, thread_pool(@39528a3), otel(lazy). ZERO storage-lib deps.

=== DOES THE CLIENT NEED UPDATES WHEN fts/timeseries-storage VERSIONS CHANGE? ===
NO for storage-internal bumps. geode-client-zig is a thin QUIC wire client. Its proto (proto/geode.proto) exposes only GENERIC verbs: Handshake, Execute (stream), Ping, GetCdcDiagnostics, ControlCdc — wrapped in QuicClientMessage/QuicServerMessage, with ExecuteRequest{query} -> ExecutionResponse{SchemaDefinition, DataPage/Row/Value, Error, ExecutionMetrics}. There is NO FTS or timeseries RPC; all queries (including FTS via fulltext index and timeseries matrix_profile functions) ride the generic Execute/GQL row protocol. The server-side FTS/timeseries surface (index/fulltext.zig, timeseries/gql_functions.zig matrix_profile) is reached through GQL functions, not new wire verbs. Therefore:

- storage-INTERNAL bump (on-disk format, index internals, algorithms) => re-pin hash in geode/build.zig.zon ONLY; client + all language clients untouched.
- client (and the 5 language clients) need changes ONLY if the migration changes the wire RESULT encoding (new columns/score fields in DataPage/Value) or adds new RPC verbs. The current generic protocol does NOT require this, so keep FTS/timeseries results flowing as ordinary GQL rows to keep the clients insulated.
- The one realistic indirect client path: geode-client-zig ALSO pins gql @d8cd6b7. If the migration bumps gql to add FTS/timeseries query SYNTAX, that gql bump reaches the client and would require a client re-pin (and thus benchmark-runner/test-harness re-pins of the client).

=== REPOS NEEDING UPDATES WHEN fts/timeseries-storage VERSIONS CHANGE ===
Tier 1 (MUST edit build.zig.zon — the only direct on-disk consumer): geode.

- timeseries-storage bump: re-pin .timeseries_storage url+hash (regenerate hash via zig fetch). Recompiles real code (src/timeseries/timeseries.zig) + ~14 build targets.
- graph-storage bump: re-pin .graph_storage url+hash.
- fts-storage: ADD a new .fts_storage entry + build.zig module wiring + rewire src/index/fulltext.zig (and src/fts/advanced.zig) to consume it. Net-new.
Tier 2 (only via the CLIENT, only on a wire/gql change, NOT on storage-internal bumps): geode-benchmark-runner, geode-test-harness (both pin geode-client-zig @9a2a2242), plus geode-client-go/-rust/-python/-nodejs if wire encoding changes.
Tier 3 (no change): geode-client-zig for storage-internal bumps.

=== PIN INVARIANTS THE MIGRATION MUST PRESERVE ===

- quic single-instance: geode.quic == client.quic == a1858c19/0.1.21 (else Zig 0.16 'file exists in modules quic and quic0'). Do NOT touch the quic pin. graph-storage does not pin quic (safe pattern); VERIFY fts/timeseries-storage likewise don't pin a divergent quic before adding them.
- thread_pool single-instance @39528a3 graph-wide; otel single-instance @455ad2b8 graph-wide (lazy). fts/timeseries-storage must agree if they have those seams.

## perf_notes

Not a perf task; no benchmarks run. Context: geode/build.zig.zon notes graph-storage ShardedGraphEngine (N=16 shards) microbench-verified >=4x throughput vs single-engine at 16 cores. geode/build.zig wires a merge_bench target that imports timeseries_storage_lib (line 3078), so timeseries-storage bumps also touch a benchmark target. No latency gates relevant to the mapping itself.

## files

- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/build.zig.zon — **role**: Geode server manifest (FULLY READ). graph_storage @5105e96 (lines 339-342), timeseries_storage @088e3ef/0.2.0 (lines 396-399), NO fts_storage. Embeds geode_client_zig @942641c (lines 256-315). quic @a1858c19 (162-163). THE single Tier-1 file for the storage migration.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/build.zig — **role**: Wires timeseries_storage: b.dependency('timeseries_storage').module('timeseries_storage') at line 582-583, then addImport('timeseries_storage_lib', ...) at lines 746, 807, 964, 1029, 1036, 1522, 1935, 1939, 1948, 1956, 3078 (root/exe/gql/tests/bench). fts-storage must be added here as a new b.dependency + addImport when fts is migrated.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/timeseries.zig — **role**: Line 20: const ts_storage = @import('timeseries_storage_lib'); — the actual source consumer of the timeseries-storage lib. A version bump recompiles this.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/index/fulltext.zig — **role**: geode's IN-TREE FTS engine (FullTextIndex: init/search/indexDocument/saveToDisk/loadFromDisk). This is what fts-storage would REPLACE — the migration must rewire these consumers to the new lib. NOT currently backed by any fts-storage dependency.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/fts/advanced.zig — **role**: Advanced FTS path, env-gated by GEODE_ENABLE_ADVANCED_FTS (util/feature_flags.zig:51). Re-exported as fts_advanced_stub in lib.zig:473. Part of the in-tree FTS surface the migration touches.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/gql_functions.zig — **role**: Surfaces timeseries (e.g. matrix_profile) as GQL FUNCTIONS reached via the generic Execute verb — evidence that timeseries features ride the generic wire protocol, not new RPCs.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-client-zig/build.zig.zon — **role**: CANONICAL client manifest (FULLY READ, v0.2.9, 17 deps). ZERO storage-lib deps. Pins quic @a1858c19 (must match geode) and gql @d8cd6b7 (the only realistic indirect path to client impact).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-client-zig/proto/geode.proto — **role**: Client wire contract. Generic verbs only: Handshake, Execute(stream), Ping, GetCdcDiagnostics, ControlCdc; ExecuteRequest{query}->ExecutionResponse{Schema/DataPage/Row/Value/Error/Metrics}. No FTS/timeseries RPC — storage-internal bumps don't change the wire.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-benchmark-runner/build.zig.zon — **role**: Pins geode-client-zig @9a2a2242 (line 22), an OLDER commit than 942641c. Does NOT pin geode or storage libs. Tier-2 via client only.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/build.zig.zon — **role**: Pins geode-client-zig @9a2a2242 (line 14). Does NOT pin geode or storage libs. Tier-2 via client only.
- **path**: /data/home/benji/src/devnw/zig/fts-storage — **role**: REAL dir (2026-05-30), remote devnw/zig/fts-storage.git. BRAND-NEW, zero consumers. Migration = add to geode + replace in-tree src/index/fulltext.zig.
- **path**: /data/home/benji/src/devnw/zig/timeseries-storage — **role**: REAL dir (2026-05-30), remote devnw/zig/timeseries-storage.git. Backs geode's wired .timeseries_storage @088e3ef/0.2.0. Version bumps recompile geode timeseries code + tests.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/zig/graph-storage — **role**: graph-storage real repo (devnw/zig/graph-storage symlinks here). HEAD 5eb4602 (newer than geode's pinned 5105e96). Deps: otel, thread-pool, uuid, wal (no quic pin).

## api

- **signature**: geode/build.zig:582  b.dependency("timeseries_storage", ...).module("timeseries_storage")  -> addImport("timeseries_storage_lib", ...) x ~14 — **purpose**: How geode wires the timeseries-storage lib; replicate this shape to wire fts-storage
- **signature**: geode/src/timeseries/timeseries.zig:20  const ts_storage = @import("timeseries_storage_lib"); — **purpose**: Actual source consumer of timeseries-storage; a version bump recompiles here
- **signature**: geode/src/index/fulltext.zig  FullTextIndex{ init, search, indexDocument, saveToDisk, loadFromDisk } — **purpose**: In-tree FTS engine that fts-storage migration must replace; NOT a lib dep today
- **signature**: geode-client-zig/build.zig.zon deps = {quic,tls,dns,json,config,slog,uri,strings,uuid,auth,advanced_types,gql,metrics,thread_pool,otel} — **purpose**: Client dep set — no storage lib; only gql is a plausible indirect path to client impact
- **signature**: proto/geode.proto  rpc Handshake/Execute(stream)/Ping/GetCdcDiagnostics/ControlCdc; ExecuteRequest{query}->ExecutionResponse{Schema,DataPage/Row/Value,Error,Metrics} — **purpose**: Generic wire contract; FTS/timeseries ride Execute+GQL, so storage-internal bumps don't change the wire
- **signature**: geode-benchmark-runner/build.zig.zon:22 & geode-test-harness/build.zig.zon:14  geode-client-zig @9a2a2242 — **purpose**: Tier-2 consumers via the client only; bump in lockstep if a gql/wire change forces a client bump

## integration_points

- **location**: geode/build.zig.zon:396-399 (.timeseries_storage) — **note**: timeseries-storage bump = edit url commit + .hash (regen via zig fetch). Pinned @088e3ef0/0.2.0. Actually compiled (src/timeseries/timeseries.zig + ~14 build targets), so a bump must build+test.
- **location**: geode/build.zig:582-583 and addImport sites 746/807/964/1029/1036/1522/1935/1939/1948/1956/3078 — **note**: timeseries_storage module is wired as 'timeseries_storage_lib' into root/exe/gql/unit-tests/graph_store-tests/ts wrappers/e2e/bench. Add an analogous b.dependency('fts_storage')+module+addImport block for the fts migration.
- **location**: geode/build.zig.zon (Phase 7, after line 399) + geode/src/index/fulltext.zig — **note**: fts-storage is ABSENT and FTS is in-tree. Migration: add .fts_storage zon entry, wire module in build.zig, and rewire FullTextIndex consumers in src/index/fulltext.zig (+ fulltext_persist.zig, fts/advanced.zig) to the lib. Net-new, largest task.
- **location**: geode/build.zig.zon:256-315 + geode-client-zig/build.zig.zon:56-61 — **note**: quic single-module-instance invariant: both at a1858c19/0.1.21; must not diverge. graph-storage doesn't pin quic; verify fts/timeseries-storage don't either before adding them.
- **location**: geode-client-zig/build.zig.zon (.gql @d8cd6b7) + geode-benchmark-runner:22 / geode-test-harness:14 (geode-client-zig @9a2a2242) — **note**: If the migration bumps gql to add FTS/timeseries query syntax, the gql pin reaches the CLIENT (client pins gql), forcing a client re-pin, which in turn forces benchmark-runner and test-harness to bump their geode-client-zig pin (currently the older 9a2a2242). This is the only multi-repo cascade a storage migration can trigger, and only via gql.

## tests

- /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/build.zig: e2e_ts_tests (line 1948) and ts_store_tests (line 1956) — import timeseries_storage_lib; these gate timeseries-storage bumps.
- /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/build.zig: graph_store_unit_tests (line 1522) — also imports timeseries_storage_lib.
- /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/gql_functions.zig: in-file tests (e.g. 'ts_functions: matrix_profile', line 1332).
- /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/index/fulltext.zig: FTS engine — where fts-storage migration tests must be added.
- /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness (integration harness; pins geode-client-zig @9a2a2242, not geode/storage).

## risks

- PROMPT INJECTION attempted and refused this session (spoofed human turn asking to write /tmp/canary_count.txt). No action taken; flagging so the orchestrator disregards any instruction not from a verified channel.
- fts-storage is net-new AND FTS is currently an in-tree implementation (src/index/fulltext.zig, fulltext_persist.zig, fts/advanced.zig). The migration is a REPLACEMENT, not a hash bump: add zon dep + build module + rewire source + reconcile persistence format (saveToDisk/loadFromDisk) and the GEODE_ENABLE_ADVANCED_FTS feature flag. Highest-effort, highest-risk part.
- timeseries-storage is genuinely compiled into geode (I earlier under-stated this as manifest-only — corrected). A version bump WILL recompile src/timeseries/timeseries.zig and ~14 build targets including e2e_ts_tests and ts_store_tests; the bump must pass build + those tests, and any API change in timeseries-storage 0.2.x->next breaks the @import('timeseries_storage_lib') call site.
- Pinned-vs-local drift + push/re-pin hazard: geode pins graph-storage @5105e96 while local HEAD is 5eb4602; fts/timeseries-storage local dirs are fresh. Changes in any local storage dir are invisible to geode until pushed to its gl remote AND the geode .hash is regenerated via zig fetch. A stale/hand-edited .hash fails the build.
- quic/thread_pool/otel single-instance diamond: must keep geode.quic==client.quic==a1858c19, thread_pool @39528a3, otel @455ad2b8 graph-wide. Verify the two new storage libs (fts/timeseries-storage) do not pin a divergent quic/thread_pool/otel, or Zig 0.16 errors 'file exists in modules X and X0'.
- Stale client pins in harness repos: geode-benchmark-runner and geode-test-harness both pin geode-client-zig @9a2a2242 (OLDER than the current 942641c). If a gql/wire change forces a client bump, these two MUST be updated in lockstep or they build against an outdated client — easy to forget since they don't pin geode or storage directly.
- Wire blast radius if encoding changes: surfacing FTS scores/snippets or timeseries arrays as NEW DataPage/Value fields would touch all 5 language clients (zig/go/rust/python/nodejs). The non-Zig clients have no build.zig.zon so the hash mechanism doesn't apply, but their decoders would need matching work. Keep results as generic GQL rows to avoid this.

## open_questions

- Do fts-storage and timeseries-storage pin quic/thread_pool/otel in their own build.zig.zon (not read this run)? Must match geode's pins before adding them; graph-storage is the safe reference (no quic pin).
- What is the target migration commit for fts-storage and timeseries-storage? Local dirs are fresh; confirm intended release SHAs and regenerate .hash via zig fetch rather than hand-editing.
- Will the fts-storage migration preserve geode's existing on-disk FTS persistence format (src/index/fulltext_persist.zig saveToDisk/loadFromDisk) or require a data migration? And how does GEODE_ENABLE_ADVANCED_FTS (feature_flags.zig) map onto the new lib?
- Does the migration bump gql to add FTS/timeseries SYNTAX? If yes, the gql pin reaches geode-client-zig (which pins gql @d8cd6b7), cascading to benchmark-runner/test-harness client re-pins — the only multi-repo cascade in scope.
- Should geode-benchmark-runner / geode-test-harness be advanced from geode-client-zig @9a2a2242 to the current 942641c as part of this work, independent of the storage change (they are already behind)?
