# BM25 IndexOptimizer Integration — Status: Not Implemented

**Status (2026-11-11, SONNY-6298):** there is no IndexOptimizer and no
cost-based choice between a full-text index and a scan. This document used to
describe BM25-aware cost estimation in `src/server/index_optimizer.zig` and
corpus statistics in `src/server/index_statistics.zig`. Neither file was
reachable from any executable or test in `build.zig`; they were never compiled
and were removed, with the uncompiled tests that exercised them.

What is implemented: full-text search runs only when a query calls it
explicitly (`CALL geode.fts.search`, `geode.fts.phrase`, `geode.fts.proximity`)
against an index created with `CREATE INDEX ... USING fulltext`, and results
are ranked by BM25 in the `fts-storage` engine. See
[FULLTEXT_SEARCH.md](FULLTEXT_SEARCH.md).
