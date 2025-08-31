# GQL implementation gap analysis (current state)

This file records what the front end implements today, how it maps to ISO/IEC 39075:2024 (GQL) clauses, and what’s next. It also embeds a conformance profile at the end.

References to clauses are pointers only, not reproductions of the spec. See `docs/query_engine.md` for planner-focused background and citations.

## Snapshot: implemented highlights

- MATCH/OPTIONAL patterns, RETURN, ORDER BY, LIMIT, OFFSET parsing with AST and CLI controls.
- Path patterns: multi-hop, relationship type alternation (a:τ1|τ2), and variable-length quantifiers (\*, k, k..m, ..m, k..).
- UNION with per-part ALL/DISTINCT modifiers.
- Pattern comprehension `[ pattern (WHERE expr)? | expr ]` and prefixed alias form `p = [ ... ]`.
- ORDER BY policy flags: strict key shape, identifiers-only, forbid calls, and forbid path-alias keys (precise set).
- Pretty-printer (human/JSON) traverses queries, graph patterns, keys, and quantifiers.

Evidence (code anchors):

- Parser options and checks: `src/gql/parser.zig` (fields `strict_order_keys`, `ident_order_only`, `forbid_orderby_calls`, `forbid_orderby_paths` and checks in `parseQuery`).
- Precise path-alias set and enforcement: `parser.zig:isPathAlias`, alias collection in `parseGraphPattern` guarded by `collect_chain_aliases`, enabled around MATCH in `parseQuery`.
- Pattern comprehension + alias: `parser.zig:parsePrimaryExpr` handling for `ident '=' '[' ... ']'` and `'[' pattern '|' expr ']'` into `ast.Expr.PatternComp`.
- AST shape: `src/gql/ast.zig` defines `RelPattern{min_len,max_len}`, union `Expr.PatternComp{pattern,where,map,alias?}`.
- CLI flags exposed: `src/gql/main.zig` (`--strict-order-keys`, `--ident-order-only`, `--forbid-orderby-calls`, `--forbid-orderby-paths`, `--ast`, `--ast-json`).
- Printer: `src/gql/print.zig` prints Match/Where/With/Group/Return/Order/Limit/Offset, graph pattern chains/hops, labels/types, quantifiers, and pattern comprehensions.

## Requirements ledger (by clause/area)

Legend for Status: Done = implemented and tested at parse/AST level; Parse-only = parsed/printed but semantics not enforced; Planned = on NEXT.md; Policy = implementation-defined policy documented.

### 1. Linear/primitive result statements and ORDER BY & page

- ISO clauses: 14.10 (primitive result + ORDER BY & page), 16.18–16.19 (LIMIT/OFFSET)
- Requirement: RETURN with optional DISTINCT; ORDER BY keys and ASC/DESC; LIMIT then OFFSET semantics. Respect implementation-defined ordering when paginating unordered tables (US001).
- Status: Done (parse/AST, printer); Policy for US001 documented in `docs/query_engine.md`.
- Evidence: `parser.zig:parseQuery` builds `ret`, `order_by`, `limit`, `offset`; `print.zig:printQuery` shows all components; `main.zig` supports printing AST.

### 2. ORDER BY key legality and safety

- ISO clauses: 14.10; feature interactions with expressions (16.16–16.17)
- Requirement: Validate sort-key shapes (identifier or member chain when configured), forbid function calls if configured; reject path-alias variables when policy forbids them.
- Status: Done (configurable via CLI and Parser fields).
- Evidence: `parser.zig` checks in ORDER BY loop; flags in `main.zig`; precise alias set via `isPathAlias` backed by aliases collected in `parseGraphPattern`.

### 3. MATCH and OPTIONAL MATCH patterns

- ISO clauses: 14.4
- Requirement: Node/relationship patterns, alternation on relationship types, variable-length quantifiers.
- Status: Done (parse/AST, print).
- Evidence: `ast.zig:RelPattern{types,min_len,max_len}`, `parser.zig:parseRelPattern` (colon types with `|`, `*` quantifier forms), `print.zig:printRel` formats quantifiers.

### 4. Pattern comprehensions and aliasing

- ISO clauses: list/pattern comprehensions (clause numbering varies; see also 20.x subqueries for related constructs)
- Requirement: `[ pattern (WHERE expr)? | expr ]` yielding a list; optional alias binding `p = [ ... ]`.
- Status: Done (parse/AST, print). Alias recorded on `Expr.PatternComp.alias`.
- Evidence: `ast.zig:Expr.PatternComp{alias:?[]const u8}`, `parser.zig:parsePrimaryExpr` comprehension branches; `print.zig:printExpr` shows alias and body.

### 5. UNION with ALL/DISTINCT

- ISO clauses: 14.12 (SELECT desugaring and set ops family); Annex for set operators
- Requirement: Support `UNION` chaining with per-part ALL or DISTINCT.
- Status: Done (parse/AST); semantics (duplicate elimination) are engine-level and not executed here.
- Evidence: `parser.zig:parseStatement` builds `Statement.Union{first,tails[]}` and records `all`/`distinct` per tail.

### 6. GROUP BY and aggregates

- ISO clauses: 14.10 (grouping), 16.14 (YIELD scope), 16.13 (WHERE scope)
- Requirement: Parse GROUP BY keys; later enforce scoping of non-aggregates and HAVING.
- Status: Parse-only; no scoping/aggregate legality yet.
- Evidence: `parser.zig:parseQuery` captures `group_by: ?GroupBy` and prints keys in `print.zig`.

### 7. Expressions and predicates

- ISO clauses: 16.x (expressions), 20.x (subqueries)
- Requirement: Arithmetic, boolean, NULL tests, IN list, function calls with basic validation.
- Status: Done (core); Planned: CASE, string predicates (STARTS WITH, ENDS WITH, CONTAINS, =~), temporal literals.
- Evidence: `parser.zig:parse*Expr` family; built-in call validator `validateBuiltinCall`.

### 8. ORDER BY path-alias policy (precise)

- ISO clauses: interacts with 14.10 key legality; also paths in 22.4
- Requirement: Forbid sorting by path variables when policy set; identify only actual path aliases from the current MATCH.
- Status: Done (configurable); default off unless `--forbid-orderby-paths`.
- Evidence: `parser.zig:isPathAlias`, `parseQuery` enables `collect_chain_aliases` for MATCH, `parseGraphPattern` records `chain_name` when `ident '=' ...` appears.

### 9. Pretty-printer and JSON AST

- ISO linkage: developer tooling, not normative
- Requirement: Human and JSON rendering for debugging and tests.
- Status: Done.
- Evidence: `src/gql/print.zig` (`printProgramHuman`, `printProgramJson`).

### 10. CLI and Library surface

- ISO linkage: none
- Requirement: Expose parser policy flags and AST printers.
- Status: Done.
- Evidence: `src/gql/main.zig` flag parsing; `src/lib.zig` re-exports printer and options (not shown here; see code).

## Known gaps and priorities

- Aggregation semantics: GROUP BY scoping, HAVING, aggregate catalog and typing. Status: Planned.
- String predicates and CASE expression. Status: Planned.
- Temporal literals and basic temporal types. Status: Planned.
- Parameters (`$param`) and ORDER BY NULLS FIRST/LAST. Status: Planned.
- Set operations beyond UNION (INTERSECT/EXCEPT with ALL/DISTINCT). Status: Planned.
- Diagnostics mapping and conformance flagger. Status: Planned.
- Path selection tie-breaking policy for selective searches (UA005/UA006). Status: Planned (document and implement in planner/runtime stage).

See `docs/NEXT.md` for an execution-ready plan.

## Conformance profile (front-end scope)

Feature tags are summarized for the front end (parser/AST/printer). This is not a runtime/engine conformance statement.

- GQ12 OFFSET, GQ13 LIMIT: Parse-level support — Done. Evidence: `parser.zig:parseQuery`.
- ORDER BY keys and expressions: Parse-level support with policy flags — Done. Evidence: `parser.zig` checks.
- MATCH/OPTIONAL: Parse-level support — Done.
- Path patterns with quantifiers/alternation: Parse-level support — Done.
- Pattern comprehensions with alias: Parse-level support — Done.
- UNION (ALL/DISTINCT per part): Parse-level support — Done.
- GROUP BY: Parse-only (no scoping validation) — Parse-only.
- INTERSECT/EXCEPT: Not yet — Planned.
- CASE, string predicates, temporal literals: Not yet — Planned.
- Implementation-defined ordering (US001) with pagination: Documented in `query_engine.md`; enforcement is planner/runtime — Policy.

Notes

- Clause anchors used here follow those cited in `docs/query_engine.md` (e.g., 14.4, 14.10, 14.12, 16.18–16.19, 22.4). This file does not quote the standard.

See also: `docs/CONFORMANCE_MATRIX.md` for a compact, quick-scan table.
