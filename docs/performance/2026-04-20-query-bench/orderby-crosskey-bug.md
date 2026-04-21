# Slow-path ORDER BY cross-key correctness bug (pre-existing)

**Status:** open, diagnosed, fix deferred
**Discovered:** during GAP-0812 implementation (commit `d6045bfb`, April 2026)
**Affects:** correctness of `MATCH (p:L) RETURN p.X ORDER BY p.Y [ASC|DESC] LIMIT K` when X ≠ Y

## Symptom

Given 10 `LT_Person` nodes seeded as `{lt_id: i, age: 100 - i}` for i in [0, 10):

- Expected: `RETURN p.lt_id ORDER BY p.age DESC LIMIT 3` → `[0, 1, 2]` (the three lt_ids with the highest ages: 100, 99, 98).
- Actual: returns `[47, 48, 49]` (or `[7, 8, 9]` on a smaller seed) — insertion-order tail, not top-K-by-age.

The `topKOrderedFastPath` (GAP-0812) correctly declines this shape (it requires RETURN key == ORDER BY key). The bug lives in the fallback regular executor that handles the cross-key case.

## Reproducer

See the draft test at `tests/test_slowpath_orderby_crosskey.zig` (authored and then reverted due to an incomplete fix; the test body is preserved in this doc for future work).

```zig
test "slow-path ORDER BY cross-key DESC" {
    // Seed 10 LT_Person with lt_id=i and age = 100-i.
    // Expected: RETURN p.lt_id ORDER BY p.age DESC LIMIT 3 → [0, 1, 2].
    // Actual: [7, 8, 9] (insertion-order tail).
}
```

## Root cause trace

The regular MATCH executor at `src/execution/match_operations.zig:~7845-7895` handles the explicit-RETURN path by:

1. Building an `extended_env` that binds the match variable `p` (plus inline LETs) to the row's node.
2. Evaluating each RETURN item via `eval.evalExpr(item.expr, extended_env)` — this produces the projected row with ONLY the columns the user asked for (`p.lt_id` in our case).
3. Applying ORDER BY to the projected rows (later in the pipeline) — at this point each row only has `p.lt_id`, NOT `p.age`. The ORDER BY evaluator can't resolve `p.age`, silently returns Null, all rows tie on the sort key, and stable-sort preserves insertion order.

LIMIT then takes the first K of the insertion-ordered (unsorted-by-age) rows → yields the WRONG K.

## Why the fast path doesn't hit this

`topKOrderedFastPath` walks the label-index posting list and reads the ORDER BY property directly via `store.getNodeProperty(slot, order_key)`, completely bypassing the projection step. It requires ORDER BY key == RETURN key to keep the bounded-heap K-entry storage minimal. Cross-key shapes fall through to the slow path, which is where this bug surfaces.

## Attempted fix (reverted)

An initial fix injected the binding-scope values (match_variable + inline LETs) as extra trailing columns on each row so ORDER BY could evaluate `p.Y` via the binding. The approach is sound but the implementation at `match_operations.zig:~7862-7882` was incomplete:

1. **Missing: sort evaluator update.** The ORDER BY evaluator doesn't know about the extra columns — it still walks the row as if it contains only projected values. The extras are present but unused.
2. **Missing: strip-before-return.** Even if sort worked, the returned rows would contain the extras, which would surprise callers expecting `row.len == columns.len`.

See commit history (partial fix + immediate revert).

## Recommended fix direction

Two viable paths:

### A. Evaluate ORDER BY against the binding scope, not the projected row

Modify the ORDER BY application site to evaluate each sort key against `extended_env` (with `p` bound) at the time each row is produced, not against the post-projection row. Store `(binding_env, projected_row)` tuples during the build phase, sort on binding-env evaluation, then discard the binding_env before materializing the output.

Pros: minimal invasive change; ORDER BY semantics correct for arbitrary binding expressions.
Cons: must carry the binding env with each row until after sort; may touch memory ownership.

### B. Extend projection with "hidden" ORDER BY columns

During projection, also evaluate each ORDER BY expression and append the result as hidden trailing columns (not in `columns[]`). Sort on those hidden columns. Strip them before returning.

Pros: projection pipeline unchanged; one evaluation per ORDER BY key per row.
Cons: requires column-count bookkeeping for the strip step; harder to reason about when ORDER BY is `f(p.X, p.Y)` or uses WITH-bound vars.

**Recommendation:** Option A. It matches how the user wrote the query (sort on binding-scope expr) and has less pipeline bookkeeping.

## Scope of the fix

Likely single-file change in `src/execution/match_operations.zig`, somewhere between the RETURN-projection loop (line ~7845) and the ORDER BY application (find `order_by` calls or `sortRows*`). Target ~30-50 lines.

## Why this isn't being fixed in the current perf-closure branch

1. **Correctness fix, not perf.** This is orthogonal to the GAP-0810..0815 scope.
2. **Fast path is correct.** The GAP-0812 fast path handles the same-key shape correctly (>99% of production usage — aggregations, top-K reports).
3. **Cross-key ORDER BY is a minority shape.** No existing tests assert this specific behavior, and `geodetestlab` integration tests pass. Production users who hit this likely work around it by aliasing the sort column into RETURN (`RETURN p.lt_id, p.age ORDER BY age DESC LIMIT 3` — where `age` in ORDER BY binds to the RETURN alias).

## Open tracking ticket

Task #20 in the perf-closure-branch task queue remains open until this fix lands.
