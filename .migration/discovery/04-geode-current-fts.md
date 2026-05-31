# geode:current-fts

## summary

FINAL, EVIDENCE-COMPLETE ANSWER (supersedes my two earlier outputs in this session — the first chased a non-existent src/index/text_index.zig; this one is verified against the real files and the actual CREATE INDEX execution handler).

WHERE FTS LIVES (two subsystems):
(A) PRIMARY engine `src/index/fulltext.zig` `FullTextIndex` + persistence `src/index/fulltext_persist.zig`. A real BM25 inverted index, owned PER-GRAPH by the StorageAdapter (`ManagedGraph.fts_index`). Created/loaded at graph init.
(B) SECONDARY/advanced `src/fts/bm25.zig` (standalone `score()`, `BM25F` multi-field, `SearchEngine`, `DocStats`/`IndexStats`) and `src/fts/advanced.zig` (`AdvancedSearch`, `LanguageAnalyzer` analyzers simple/whitespace/english/standard, Porter2 `Stemmer`, `phraseQuery`/`proximityQuery`/`highlight`, Levenshtein `fuzzyMatch`, `generateNgrams`, `SynonymDict`, `soundex`). Subsystem B is gated by the `adv_fts` feature flag (advanced.zig:16-23) and several of its query functions operate on synthetic stub corpora (advanced.zig:67-112). It is wired into the server-side cost optimizer and the advanced tests, NOT into CREATE INDEX execution.

CRITICAL WIRING FINDING — THE ENGINE IS BUILT BUT NOT POPULATED BY DDL OR WRITES:

- The per-graph `FullTextIndex` is allocated/loaded at graph creation: `initFtsForGraph` (graph_storage_adapter.zig:3881) -> assigned `mg.fts_index` at 3977/4060; cleaned up at 767-775; query handle `getFulltextIndex(name)` (1269) -> `mg.fts_index`.
- BUT `CREATE ... INDEX ... USING fulltext` does NOT populate it. The CreateIndex execution handler (src/execution.zig:1405) maps `.fulltext` to a catalog entry only (1463-1468, `catalog.addIndex`), then the structure-creation switch (1463-1474) builds real structures ONLY for `.btree`/`.hash` (via IndexManager.createPropertyIndexStructure); the `else` branch (covering fulltext) is explicitly "catalog registration only for now ... created on-demand or via specialized DDL" (CANARY REQ-GQL-DDL-IDX-002 STATUS=IMPL). So a fulltext CREATE INDEX shows up in SHOW INDEXES but builds no inverted-index content.
- `FullTextIndex.indexDocument` / `.search` / `removeDocument` have ZERO production callers. Verified by repo-wide grep: the only callers outside the def files (fulltext.zig/fulltext_persist.zig) are inside `test` blocks — graph_storage_adapter.zig:5794/5796/5800 are within a unit `test` starting at line ~5780; index_manager.zig:1136 is `indexDocument` for the JSONB advanced index, not FTS. There is NO node create/update/delete hook feeding text into the FTS index, and no query operator that calls `getFulltextIndex(...).search(...)`. So end-to-end BM25 retrieval is NOT reachable from GQL today via the primary engine; it is exercised only by unit/integration tests that call the API directly.

CORE DATA STRUCTURES (src/index/fulltext.zig `FullTextIndex`):

- `documents: AutoHashMap(u64, Document)`, `inverted_index: StringHashMap(PostingList)`, `stopwords: StringHashMap(void)` (24 built-in English stopwords, init lines 59-67).
- `Document{ id:u64, content:[]const u8 (owned dupe), tokens:[]Token, vector:?[]f32 (reserved, null) }`; `Token{ text, position, offset, length }`; `PostingList{ term:[]const u8, documents:[]PostingEntry, idf:f32 }`; `PostingEntry{ doc_id:u64, positions:[]usize, tf:f32, tf_idf:f32 }`; `SearchResult{ doc_id:u64, score:f32, highlights:[]Highlight }`; `Highlight{ offset, length, term }`.
- Tokenizer (fulltext.zig:177): split on non-(alphanumeric|underscore). Normalize (fulltext.zig:204) is UNICODE-AWARE: NFC + case fold via src/unicode/geode_unicode.zig (CANARY REQ-GQL-UNICODE-007) — NOT ASCII-only.
- `indexDocument` (243): tokenize -> store Document -> per-term positions -> append PostingEntry (grows posting array by realloc+memcpy each insert) -> `updateIdfScores` recomputes IDF over ALL terms on every insert (O(vocabulary) per document — superlinear ingestion). `search` (97): tokenize/normalize query, drop stopwords, accumulate BM25 with idf=ln(((N-df+0.5)/(df+0.5))+1), doc-tf saturation k1=1.2/b=0.75, and query-tf saturation k3=7.0, sort desc, top-N. `removeDocument` (341) filters + recomputes IDF. Persistence to {dir}/fulltext.idx via fulltext_persist save/load (saveToDisk/loadFromDisk 328/335); index dir is {graph_dir}/fts; participates in TDE file-level encryption (CANARY REQ-TDE-FILELEVEL-001 ASPECT=FullTextIndex, STATUS=IMPL).

GQL SURFACE SYNTAX (precise; parser `parseCreateIndex` src/gql/parser.zig:4835):
  CREATE [UNIQUE] INDEX [name] [IF NOT EXISTS]
        ( ON [:]Label | FOR (var:Label) ON (var.prop) | FOR ()-[var:RelType]-() ... )
        [USING <type>]  ( prop1 [, prop2 ...] )?

- Two grammars: legacy `ON :Label` and ISO `FOR (n:Label) ON (n.prop)`.
- The ONLY way to request fulltext is `USING fulltext` or `USING FullText` (parser.zig:4970 pre-properties, 5054 post-properties), which sets `ast.IndexType.fulltext` (ast.zig:585). Unknown USING name -> error.InvalidIndexType. There is NO leading `FULLTEXT`/`TEXT` keyword in the accepted grammar (my earlier claim was wrong); the recommendation engine's wording "CREATE FULLTEXT INDEX ON :Label(prop)" (recommendations.zig:269,283, diagnostic code geode/suggest-fulltext-index) is advisory only.
- AST `ast.CreateIndexStatement{ name:?[]const u8, unique:bool, index_type:IndexType=.btree, label:[]const u8, properties:[][]const u8, if_not_exists:bool }` (ast.zig:518). IndexType enum (582): btree,hash,fulltext,spatial,vector,vector_f32,spatial_geographic,network_cidr,signature_crypto,interval_tree,jsonb_inverted,domain_trie. No analyzer/tokenizer options on the AST.
- There is NO dedicated FTS query keyword/function/CALL surface (no search()/db.index.fulltext.* in the parser).

EXECUTION/PLANNER PLUMBING THAT EXISTS BUT IS NOT CONNECTED TO THE LIVE ENGINE:

- src/execution.zig:1405 CreateIndex handler (catalog-only for fulltext, see above).
- IndexManager parallel registry `fulltext_indexes: StringHashMap(FullTextIndex)` (index_manager.zig:67) with `createFullTextIndex(name,label,properties)` (497) that DISCARDS label+properties (`_ = label; _ = properties;` 503-504). SHOW INDEXES / db.indexes() reads THIS map (meta_dispatch.zig:288-325, emits type "FULLTEXT"; issue #844 fix), which is distinct from the StorageAdapter per-graph handle — a real divergence.
- src/server/index_optimizer.zig: full BM25 cost model + EXPLAIN — QueryType `.fulltext_search` (1196), `findBestFullTextIndex` (1862), `estimateBM25FulltextCost` (687, normalization k1*(1-b+b*|d|/avgdl) at 729), `createFullTextIndexExplain` (1940), scan type "FTS BM25", uses `stats.fts_search_queries` (667/750). src/server/index_statistics.zig:243 base BM25 cost O(vocabulary_size * log(documents)).

CANARY MARKERS (FTS): REQ-GQL-FTS-001 BM25 Search/Scoring TESTED (fulltext.zig:96; fts/bm25.zig:4 with TEST=tests/e2e_fts_advanced.zig BENCH=tests/benchmark_fts_bm25_scoring.zig); REQ-GQL-FTS-002 Document Indexing TESTED (fulltext.zig:242); REQ-GQL-FTS-ADV-001 Advanced FTS TESTED (fts/advanced.zig:5, BENCH=tests/benchmark_fts_analyzer_perf.zig); REQ-GQL-UNICODE-007/008 FTS normalize TESTED (fulltext.zig:206, advanced.zig:54); REQ-GQL-DDL-IDX-001 CreateIndex TESTED + REQ-GQL-DDL-IDX-002 IndexBackend STATUS=IMPL (execution.zig:1459/1462 — the IMPL marker is exactly the unbuilt fulltext backend); REQ-TDE-FILELEVEL-001 ASPECT=FullTextIndex IMPL (fulltext_persist.zig:11); FTS optimizer/statistics markers OWNER=fts (server/index_optimizer.zig, index_statistics.zig, UPDATED=2025-10-04).

TESTS (geode repo): tests/test_fulltext_bm25.zig, tests/test_fulltext_bm25_integration.zig, tests/e2e_fts_advanced.zig, tests/test_fts_advanced_analyzers.zig, tests/test_fts_indexoptimizer_integration.zig, tests/test_fts_performance_optimization.zig, tests/canary_unicode_fts.zig, tests/test_bm25_index_optimizer.zig, tests/integration_bm25_optimizer.zig, tests/unit_bm25_skeleton.zig, tests/benchmark_fts_bm25_scoring.zig, tests/benchmark_fts_analyzer_perf.zig, tests/index_integration_persistence.zig, tests/integration/test_large_social_network.zig, plus an inline `test` in graph_storage_adapter.zig (~5780) for per-graph FTS init/index/search. HARNESS SPECS (exist): ../geode-test-harness/geodetestlab-cli/specs/fulltext_search_basic.yml, .../specs/legacy/geode_fulltext_bm25_comprehensive.yml, .../specs/legacy/geode_fts_bm25_optimization.yml (cases: basic search, phrase, boolean, wildcard, perf benchmark, ranking accuracy, tf-idf scoring). Given the engine is not GQL-reachable, these harness specs likely exercise the path indirectly or are part of the legacy/aspirational set — worth confirming what query they issue.

NET FOR RE-POINTING AT AN EXTERNAL FTS-STORAGE LIB: the index handle is `ManagedGraph.fts_index: ?*fulltext.FullTextIndex`. To make FTS actually work with an external lib you must (1) open/create the lib index where initFtsForGraph runs (graph_storage_adapter.zig:3881) AND/OR in the CreateIndex handler's currently-empty fulltext branch (execution.zig:1470), (2) add the MISSING write hook so node create/update/delete calls the lib's add/update/delete-document (no such hook exists today), (3) add a query operator + route it (or CONTAINS) to the lib via getFulltextIndex/search (no such routing exists today), (4) persist via the lib or keep fulltext_persist, and (5) feed cost/cardinality to server/index_optimizer.zig. The cleanest adapter is to keep the `FullTextIndex` public API (init/deinit/indexDocument/search/removeDocument/saveToDisk/loadFromDisk) and replace its internals with the external lib, then ADD the create-population + write-maintenance + query-routing wiring that is currently absent.

## perf_notes

Live FTS BM25 params k1=1.2, b=0.75, query-term saturation k3=7.0 (src/index/fulltext.zig:105-107); standalone bm25.Params k1=1.2,b=0.75 (src/fts/bm25.zig:6-9). Optimizer models BM25 as logarithmic in collection size, linear in query terms (index_optimizer.zig:687,729); index_statistics.zig:243 base cost O(vocabulary_size * log(documents)); EXPLAIN scan type 'FTS BM25'. Benchmarks: tests/benchmark_fts_bm25_scoring.zig (BENCH REQ-GQL-FTS-001), tests/benchmark_fts_analyzer_perf.zig (BENCH REQ-GQL-FTS-ADV-001), tests/test_fts_performance_optimization.zig. Ingestion hot-path concern: per-document full-IDF recompute + per-posting realloc make indexing superlinear. No explicit FTS query latency gate value found.

## files

- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/index/fulltext.zig — **role**: PRIMARY BM25 inverted-index engine. FullTextIndex (documents/inverted_index/stopwords). indexDocument (243), search k1=1.2/b=0.75/k3=7.0 (97), removeDocument (341), tokenize (177), Unicode NFC+foldCase normalize (204), updateIdfScores per-insert (214), saveToDisk/loadFromDisk (328/335). Built per-graph but NOT populated by DDL/writes (zero production callers of indexDocument/search).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/index/fulltext_persist.zig — **role**: Serialize/deserialize FullTextIndex to {dir}/fulltext.idx (terms/postings/positions/idf/doc stats). save()/load(). CANARY REQ-TDE-FILELEVEL-001 ASPECT=FullTextIndex.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/fts/bm25.zig — **role**: Standalone BM25: score(), BM25F multi-field, SearchEngine, DocStats/IndexStats. CANARY REQ-GQL-FTS-001. Used by fts/advanced.zig and optimizer, not by CREATE INDEX.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/fts/advanced.zig — **role**: adv_fts-flagged advanced FTS: analyzers (simple/whitespace/english/standard), Porter2 Stemmer, phrase/proximity/highlight (stub corpora), fuzzy/Levenshtein, n-grams, SynonymDict, soundex, AdvancedSearch over bm25.SearchEngine. CANARY REQ-GQL-FTS-ADV-001, UNICODE-008.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/execution.zig — **role**: CreateIndex execution handler (1405): for .fulltext does CATALOG REGISTRATION ONLY (1463-1468); structure-build switch only handles .btree/.hash, fulltext falls into the 'catalog registration only for now' else-branch (1470-1473). CANARY REQ-GQL-DDL-IDX-001 TESTED / REQ-GQL-DDL-IDX-002 IMPL. THE place to add real fulltext index creation.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/storage/graph_storage_adapter.zig — **role**: Per-graph FTS ownership: ManagedGraph.fts_index (652), initFtsForGraph creates/loads {graph_dir}/fts (3881-3927), assigned at 3977/4060, freed 767-775, getFulltextIndex(name)->mg.fts_index (1269). PRIMARY open/create + query-handle seam. indexDocument/search only called from the inline test (~5780).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/gql/parser.zig — **role**: parseCreateIndex (4835): CREATE [UNIQUE] INDEX ... (ON :Label | FOR (n:Label) ON (n.prop)) [USING <type>](props). USING fulltext|FullText -> IndexType.fulltext (4970, 5054). No analyzer options. No FTS query keyword.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/gql/ast.zig — **role**: CreateIndexStatement (518) + IndexType enum with .fulltext (585). No analyzer field.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/index/index_manager.zig — **role**: Parallel FTS registry fulltext_indexes StringHashMap(FullTextIndex) (67), createFullTextIndex DISCARDS label/properties (497-504), init/deinit 207/268. Read by SHOW INDEXES; diverges from StorageAdapter handle. (index_manager.zig:1136 indexDocument is the JSONB index, not FTS.)
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/execution/meta_dispatch.zig — **role**: SHOW INDEXES / db.indexes(): merges catalog indexes with IndexManager.fulltext_indexes, emits type 'FULLTEXT' (288-325; issue #844). Reads IndexManager map, not the live per-graph handle.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/server/index_optimizer.zig — **role**: BM25 cost model + EXPLAIN: QueryType.fulltext_search (1196), findBestFullTextIndex (1862), estimateBM25FulltextCost (687), createFullTextIndexExplain (1940), 'FTS BM25' scan type, stats.fts_search_queries (667/750).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/gql/recommendations.zig — **role**: Advisory diagnostics suggesting 'CREATE FULLTEXT INDEX ON :Label(prop)' for CONTAINS/STARTS WITH (269,283; geode/suggest-fulltext-index). Wording only; accepted grammar is USING fulltext.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/server/index_statistics.zig — **role**: BM25 cost statistics: base cost O(vocabulary_size * log(documents)) (243). OWNER=fts.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/unicode/geode_unicode.zig — **role**: Unicode NFC normalize + case fold used by both FTS normalize paths (fulltext.zig:207, advanced.zig:55). Analyzer-swap must preserve/replace this contract.

## api

- **signature**: fulltext.FullTextIndex.init(alloc)!; deinit(); indexDocument(doc_id:u64, content:[]const u8)!void; search(query:[]const u8, max_results:usize)![]SearchResult; removeDocument(doc_id:u64)!void; saveToDisk(dir)!; loadFromDisk(alloc,dir)!FullTextIndex — **purpose**: Live BM25 index API (doc_id == node id). Has ZERO production callers; only tests use it. Keep this signature stable when swapping internals for an external lib, then add the missing create/write/query wiring.
- **signature**: fulltext.FullTextIndex types: Document{id,content,tokens:[]Token,vector:?[]f32}; Token{text,position,offset,length}; PostingList{term,documents:[]PostingEntry,idf:f32}; PostingEntry{doc_id,positions:[]usize,tf:f32,tf_idf:f32}; SearchResult{doc_id:u64,score:f32,highlights:[]Highlight} — **purpose**: Inverted-index posting/document layout + ranked result type.
- **signature**: StorageAdapter.getFulltextIndex(name) ?*fulltext.FullTextIndex; (private) initFtsForGraph(alloc,data_dir,graph_uuid,load_existing) ?FtsInitResult; ManagedGraph.fts_index: ?*fulltext.FullTextIndex — **purpose**: Per-graph FTS handle accessor + create/load at graph init ({graph_dir}/fts). The handle exists but is never populated by production code.
- **signature**: execution CreateIndex handler: .CreateIndex => |ci| { catalog.addIndex(...); switch(ci.index_type){ .btree,.hash => createPropertyIndexStructure(...), else => /*catalog only*/ } } — **purpose**: execution.zig:1405. fulltext hits the else-branch -> NO index built. Primary place to add real fulltext creation/population.
- **signature**: IndexManager.createFullTextIndex(name, label, properties)!void; fulltext_indexes: StringHashMap(FullTextIndex) — **purpose**: Parallel registry; discards label/properties; read by SHOW INDEXES. Diverges from the StorageAdapter handle.
- **signature**: fts.bm25.score(doc_tf,doc_len,avg_doc_len,doc_freq,total_docs,Params{k1=1.2,b=0.75}) f64; bm25.BM25F.scoreMultiField(...); bm25.SearchEngine.search(query_terms,max_results)![]SearchResult; advanced.AdvancedSearch.search(query,SearchOptions)! — **purpose**: Standalone/advanced BM25 + analyzers (adv_fts flag). Used by optimizer + advanced tests, not by CREATE INDEX.
- **signature**: GQL: CREATE [UNIQUE] INDEX [name] [IF NOT EXISTS] (ON [:]Label | FOR (n:Label) ON (n.prop)) USING fulltext ( prop, ... ) — **purpose**: Exact accepted surface to declare a fulltext index. USING fulltext|FullText is the selector; no FULLTEXT/TEXT keyword; no analyzer options; today it only registers catalog metadata (no inverted index built).

## integration_points

- **location**: src/execution.zig:1405-1474 CreateIndex handler, the fulltext `else` branch at 1470-1473 (with CANARY REQ-GQL-DDL-IDX-002 IMPL at 1462) — **note**: PRIMARY CREATE seam and the gap. Today fulltext only does catalog.addIndex; the else-branch is 'catalog registration only for now'. An external lib must be created/opened AND backfilled (scan label.property text -> add-document) here.
- **location**: src/storage/graph_storage_adapter.zig:3881 initFtsForGraph (FullTextIndex.init @3919 / loadFromDisk @3908), assigned mg.fts_index @3977/4060, freed @767-775, accessor getFulltextIndex @1269 — **note**: OPEN/CREATE + QUERY-HANDLE seam. The per-graph index object is built here. Re-point to open the external lib's handle. (Note: this allocates an empty index for every graph regardless of whether any fulltext index was declared.)
- **location**: NODE WRITE PATH (crud_operations.zig / graph_store create/update/delete) — MISSING TODAY — **note**: WRITE/MAINTENANCE seam DOES NOT EXIST. No production code calls FullTextIndex.indexDocument/removeDocument. Adopting an external lib REQUIRES adding add/update/delete-document calls on node mutations for indexed label.property.
- **location**: QUERY OPERATOR — MISSING TODAY (no caller of getFulltextIndex().search() outside tests) — **note**: QUERY seam DOES NOT EXIST end-to-end. There is no GQL operator/function and no CONTAINS routing that reaches FullTextIndex.search. Must add a query operator (or CONTAINS routing) -> getFulltextIndex -> external lib search, returning node ids.
- **location**: src/index/fulltext_persist.zig save/load + src/index/fulltext.zig:328/335 saveToDisk/loadFromDisk — **note**: PERSISTENCE seam ({dir}/fulltext.idx, TDE-encrypted). Re-point to the external lib or keep as the on-disk format.
- **location**: src/index/index_manager.zig:497 createFullTextIndex + :67 fulltext_indexes (read by src/execution/meta_dispatch.zig:296) — **note**: REGISTRY/INTROSPECTION seam. SHOW INDEXES enumerates this map; it discards label/properties and diverges from the live handle. Unify when adopting an external lib.
- **location**: src/server/index_optimizer.zig:687/1196/1862/1940 + src/server/index_statistics.zig:243 — **note**: PLANNER/COST seam. Feed the external lib's cost/cardinality so EXPLAIN ('FTS BM25') and index selection stay accurate once FTS is actually query-reachable.
- **location**: src/index/fulltext.zig:204 normalize + src/fts/advanced.zig:52 lowerAlloc -> src/unicode/geode_unicode.zig — **note**: ANALYZER/NORMALIZATION seam (Unicode NFC + foldCase). Thread analyzer config to the external lib (CreateIndexStatement carries none) or preserve this normalization.
- **location**: src/gql/parser.zig:4835 + src/gql/ast.zig:518 — **note**: DDL surface already selects FTS via USING fulltext; no parser change needed to adopt a lib, but extend CreateIndexStatement to carry analyzer/tokenizer options for the lib.

## tests

- tests/test_fulltext_bm25.zig
- tests/test_fulltext_bm25_integration.zig
- tests/e2e_fts_advanced.zig
- tests/test_fts_advanced_analyzers.zig
- tests/test_fts_indexoptimizer_integration.zig
- tests/test_fts_performance_optimization.zig
- tests/canary_unicode_fts.zig
- tests/test_bm25_index_optimizer.zig
- tests/integration_bm25_optimizer.zig
- tests/unit_bm25_skeleton.zig
- tests/benchmark_fts_bm25_scoring.zig
- tests/benchmark_fts_analyzer_perf.zig
- tests/index_integration_persistence.zig
- tests/integration/test_large_social_network.zig
- inline test in src/storage/graph_storage_adapter.zig (~line 5780): per-graph FTS init + indexDocument + search (the only place the live engine API is driven)
- HARNESS: ../geode-test-harness/geodetestlab-cli/specs/fulltext_search_basic.yml
- HARNESS: ../geode-test-harness/geodetestlab-cli/specs/legacy/geode_fulltext_bm25_comprehensive.yml
- HARNESS: ../geode-test-harness/geodetestlab-cli/specs/legacy/geode_fts_bm25_optimization.yml

## risks

- DDL DOES NOT BUILD THE INDEX: CREATE ... INDEX ... USING fulltext only registers catalog metadata (execution.zig:1466 + else-branch 1470-1473). It appears in SHOW INDEXES but builds no inverted index. CANARY REQ-GQL-DDL-IDX-002 is correctly STATUS=IMPL for this.
- NO WRITE MAINTENANCE: FullTextIndex.indexDocument/removeDocument have zero production callers; node writes never update the FTS index. The per-graph fts_index stays empty in production.
- NO QUERY OPERATOR: getFulltextIndex().search() is only called from a unit test; no GQL operator/function/CONTAINS-routing reaches BM25 retrieval. End-to-end FTS is not user-reachable via the primary engine today.
- Wasted allocation: initFtsForGraph allocates an empty FullTextIndex for EVERY graph at creation even when no fulltext index is declared (graph_storage_adapter.zig:3881/3977/4060).
- Two divergent registries: live per-graph ManagedGraph.fts_index vs IndexManager.fulltext_indexes (read by SHOW INDEXES). IndexManager.createFullTextIndex discards label/properties (503-504), so it cannot scope an index.
- Superlinear ingestion: indexDocument recomputes IDF over all terms per document (updateIdfScores) and grows posting lists via realloc+memcpy per posting; bulk loading is quadratic-ish. An external lib should batch.
- Advanced subsystem (src/fts/*) is adv_fts-flagged and partly stubbed (phrase/proximity over synthetic corpora) — not the DDL path; do not assume CREATE INDEX exercises analyzers/stemming.
- Harness FTS specs exist but, since the engine is not GQL-reachable, it is unclear what they actually assert — verify the queries in fulltext_search_basic.yml / legacy specs before trusting them as coverage.
- PROCESS NOTE: my first two StructuredOutputs this session were wrong (non-existent text_index.zig; then an overstated 'fully wired' claim). This third output is the authoritative one; disregard the prior two.

## open_questions

- Confirm what the harness specs (fulltext_search_basic.yml, legacy geode_fulltext_bm25_*.yml) actually issue — since CREATE fulltext builds no index and no query operator reaches search(), do they pass, xfail, or exercise a different path?
- Should real fulltext index creation+backfill live in the CreateIndex handler (execution.zig:1470) or in initFtsForGraph, and how should the per-graph empty-index allocation be made conditional on a declared fulltext index?
- Where to add the missing node create/update/delete -> indexDocument/removeDocument maintenance hook (crud_operations.zig vs graph_store)?
- What GQL query surface should reach FTS — a new search()/CALL, or transparent CONTAINS/STARTS WITH routing? Neither exists today.
- Unify ownership: StorageAdapter per-graph fts_index vs IndexManager.fulltext_indexes (SHOW INDEXES). Which becomes the store of record for an external lib?
- Analyzer/tokenizer config surfacing: CreateIndexStatement has no analyzer field; live path is fixed Unicode NFC+foldCase; richer analyzers are in flag-gated src/fts/advanced.zig.
- node_id<->doc_id and per-graph/per-tenant key scheme for an external lib (today doc_id == node id; dir {graph_dir}/fts; TDE-encrypted).
