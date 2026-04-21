# GAP-0810 follow-up: enhanced materialized-view manager cache wiring

**Date:** 2026-04-20
**Related task:** task #18 (follow-up to Task 1.3 / commit `c1b660fd`)
**Status:** hook present, not invoked in production

## Context

Task 1.3 (GAP-0810) threaded `SharedAstCache` through the *classic*
materialized-view manager in `src/query/materialized_views.zig` and the
*classic* distributed query coordinator in
`src/distributed/query_coordinator.zig`. A spec review then flagged that
the actual production-used manager is the *enhanced* one at
`src/query/enhanced_materialized_views.zig`, and that the "enhanced"
coordinator at `src/distributed/enhanced_query_coordinator.zig` may also
parse GQL.

This follow-up audits both and wires the cache into the enhanced manager
using the same "optional field + `setAstCache` + cache-or-fallback at
parse site" pattern.

## Findings

### `src/distributed/enhanced_query_coordinator.zig`

- `grep -n "parseGql\|parseQuery\|parse"` returns **zero** matches.
  The enhanced coordinator does not parse GQL at all -- its
  `analyzeQuery` / `extractLabelsAndProperties` work off the raw query
  string via string-scanning heuristics. No cache wiring needed.

- Matches Task 1.3 spec-review prediction. No modifications applied.

### `src/query/enhanced_materialized_views.zig`

- Two parse callsites:

  1. `MaterializedViewManager.parseAndValidateQuery` (called by
     `createMaterializedView`) -- parses into an arena and then clones
     the parsed `ast.Query` into `self.allocator`. **Critically, the
     arena is intentionally NOT deinited** (see the comment at
     `parseAndValidateQuery:296-299`: "In a production system, we would
     deep-copy all string data"). String slices referenced by the
     cloned `ast.Query` live in the leaked arena until process exit.
     Routing this site through `parseGqlCached` would be **unsafe**
     without first doing the deep-copy the TODO comment describes: if
     the cache evicts the handle, string slices in the stored
     `MaterializedView.parsed_query` would dangle. Not wired.

  2. `QueryRewriter.findApplicableViews` -- parses into an arena with
     `defer arena.deinit()`, inspects `incoming_query.match.chains` to
     compute label/relationship overlap with each catalog view, then
     returns a `QueryRewrite` whose string fields are all
     `allocator.dupe(u8, ...)` / `allocPrint` copies. Scope-bounded,
     **safe to cache**. Wired via the cache-or-fallback branch.

- Added:
  - `ast_cache: ?*lib.SharedAstCache = null` field on
    `MaterializedViewManager` and on the private `QueryRewriter`.
  - `pub fn setAstCache(self, cache) void` on `MaterializedViewManager`,
    which propagates into `query_rewriter.ast_cache`.
  - Cache-or-fallback branch in `findApplicableViews` that unwraps a
    cached handle with `defer handle.release()`.
  - Shared body `buildRewriteForQuery(self, query, incoming_query,
    catalog) !?QueryRewrite` so the cached and uncached branches walk
    the same program -- avoids drift.

- `parseAndValidateQuery` is annotated with an explicit comment
  explaining why it is NOT cached. If the "deep-copy string data"
  pre-condition is addressed in a later branch, this site becomes a
  mechanical cache-or-fallback swap too.

## Production caller status

The enhanced `MaterializedViewManager` is **not constructed anywhere in
`src/server/*` or `src/query/*`**. The only references in-tree are:

- Two test files (`tests/test_materialized_views_enhanced.zig`,
  `tests/test_materialized_views_enhanced_integration.zig`), neither
  registered in `build.zig`.
- Documentation files (docs/, GAP_ANALYSIS_RESOLVED).
- CANARY status CSVs.

The server does not call `EnhancedMaterializedViewManager.init`, so no
`setAstCache(state.shared_ast_cache)` call is inserted in
`src/server/main.zig` or `src/server/server_init.zig`. This matches the
disposition Task 1.3 landed on for the classic manager: the wiring hook
is in place for future callers, but no production code path invokes it
yet.

## Test disposition

The existing GAP-0810 cross-subsystem test
(`tests/test_gap0810_cross_subsystem_cache.zig`) asserts that
`geode.parseGqlCached` registers one miss plus at least one hit for
identical input -- the property both view managers and the coordinator
now depend on. A full end-to-end "instantiate enhanced manager, set
cache, parse twice" test would require either (a) registering the
enhanced manager in `src/lib.zig`'s public surface or (b) adding a new
build-graph test artifact with a relative `@import` to the enhanced
file. Both expand the task scope beyond the minimal-change bar Task 1.3
set. Deferred -- the cross-subsystem test already proves cache
reachability from any caller, and the wiring in
`findApplicableViews` is a straightforward mirror of the Task 1.3
pattern with the same handle-release invariant.

## Related commits

- `c1b660fd` -- Task 1.3, classic-manager wiring
- `b6e8c341` -- GAP-0810 A/B ledger close-out
