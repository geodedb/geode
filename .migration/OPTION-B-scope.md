# Option B scope: `CALL ns.proc(args) YIELD col, … [RETURN …]` as a top-level statement

Read-only assessment for the controller's decision. Option B is NOT implemented
here — Option A (bare `CALL geode.fts.search(...)`, no YIELD, auto-projected
rows) is the shipped FTS-over-the-wire surface and is fully spec-valid (ISO/IEC
39075:2024 clause 16.3: YIELD is optional). This note records exactly what the
*fuller* YIELD form does today and what closing it would take.

## What PARSES today (verified)

`src/gql/parser.zig` — the "Traditional procedure call" branch (the `else` arm
around lines 1369–1446) already parses the full shape:

```
CALL <member.path>(<args>)
     [ YIELD <projection items> ]
     [ RETURN [DISTINCT] <projection items> ]
     [ ORDER BY … ] [ LIMIT … ] [ OFFSET/SKIP … ]
```

- YIELD is consumed only `if (self.cur.kind == .YIELD)` → optional. Result stored
  in `ast.CallProcedure.yield_items: ?[]ast.ReturnItem`.
- RETURN, ORDER BY, LIMIT, OFFSET are likewise optional and captured on the same
  `Procedure` AST node.

So the **grammar already accepts** `CALL ns.proc(a) YIELD x, y RETURN x`. The
premise that "CALL … YIELD … RETURN does NOT parse" is stale for this branch.

## What EXECUTES today (verified)

- `execution.zig` `.Call → .Procedure` (≈ lines 1639–1681): runs the procedure
  via `executeCallStatement`, then applies the procedure node's ORDER BY /
  OFFSET / LIMIT to the result table. Returns the (possibly trimmed) table.
- `src/execution/fts_dispatch.zig` applies `filterYieldColumns` when
  `call_stmt.yield_items` is non-null — i.e. `YIELD score` projects the result
  table down to just the `score` column. Column-level YIELD projection WORKS.
- With no YIELD, the full `(node, score)` table is the statement result
  (Option A auto-projection).

## What is MISSING for full Option B

1. **YIELD-bound variables are not added to a query-wide binding scope.**
   `filterYieldColumns` is a *column filter on the procedure's own result table*.
   It does not register `node`/`score` as variables visible to a subsequent
   top-level clause. So `CALL geode.fts.search(...) YIELD node MATCH (n) WHERE
   id(n) = node RETURN n` cannot compose — there is no linear-pipeline plumbing
   that threads the YIELD record into the next reading clause.

2. **RETURN-after-CALL is evaluated narrowly.** The captured `return_clause` on
   the Procedure node is only meaningfully exercised for the
   subquery (`CallSubquery`) path; for the procedure path the result table is
   returned essentially as-is (after ORDER BY/LIMIT). A `RETURN node, score AS s`
   that *renames/derives* over YIELD vars is not generally evaluated against a
   binding environment.

3. **No table-valued composition / lateral join.** The ISO model lets a CALL …
   YIELD feed a driving table into following clauses (a lateral/dependent join).
   geode has no executor stage that iterates an outer binding table and re-invokes
   / correlates the CALL output per row.

## Rough effort & risk

- **Small (a few lines):** nothing useful in isolation. Wiring only
  `filterYieldColumns` (already done) does not yield composition.
- **Medium (≈1–2 days):** make `CALL … YIELD a, b RETURN <exprs over a,b>` work as
  a *self-contained* statement — evaluate the RETURN projection against each row
  of the procedure's result table treating YIELD names as that row's column
  bindings. This is a localized evaluator over the existing result table; no
  planner change. Covers the common "rename / pick / compute over yielded
  columns" case. Risk: LOW (no cross-clause scope, no planner).
- **Large (real project, ≈1–2 weeks):** general linear composition — `CALL …
  YIELD …` as a pipeline source feeding arbitrary downstream MATCH/WHERE/WITH,
  i.e. lateral correlation. Requires a binding-scope abstraction that spans
  clauses and an executor stage that drives downstream clauses per outer row.
  Risk: MEDIUM-HIGH — touches the core planner/executor pipeline and binding
  model; broad regression surface.

## Recommendation

Ship Option A (done). If a richer surface is wanted, the **medium** slice
(RETURN over YIELD columns within a single statement) is the high-value,
low-risk next step. The **large** slice (full lateral composition) should be its
own planned project, not folded into FTS.
