// GAP-0514 Phase 6 P3: test root that places src/distributed/query_planner.zig
// in a module rooted at src/ so its INLINE tests are discovered by the zig
// test runner. query_planner.zig cannot be its own test root (its relative
// imports `../gql/ast.zig` / `../planner/cbo.zig` escape src/distributed/),
// and tests living in the geode root module (a different module from the
// tests/*.zig roots) are never collected across the module boundary.
// Wired as `zig build test-dist-query-planner` (second half).
comptime {
    _ = @import("distributed/query_planner.zig");
}
