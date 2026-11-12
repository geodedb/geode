// Test root for rls_core.zig's inline tests (`zig build test-rls-injection`).
//
// SONNY-3038: the GAP-0496 injection-guard tests that lived here tested
// `rls_core.QueryRewriter`, which built a GQL predicate from policy text and
// combined the policies the old way (each permissive OR, each restrictive
// AND, in list order). Nothing called it: the engine enforces policies by
// evaluating compiled expressions per row (`checkRowAccess`,
// `rls_core.PolicyVerdict`), and builds no query text. It was deleted with
// its tests. The file stays the root that compiles rls_core.zig with its
// inline tests.
const rls_core = @import("rls_core.zig");

test {
    _ = rls_core;
}
