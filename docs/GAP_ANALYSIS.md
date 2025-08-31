# GQL Implementation GAP Analysis

This document compares the current implementation to the ISO/IEC 39075:2024 GQL specification and identifies what is implemented vs. what remains. It also highlights adjacent non-grammar work (CLI, APIs, tests) relevant to developer UX.

Note: This is intentionally focused on the front-end (lexing/parsing/AST/options/errors) now in this repository. Storage/engine topics are tracked separately.

## Scope and Artifacts in this repo

- Language front-end
  - `src/gql/token.zig` — tokens and keywords
  - `src/gql/lexer.zig` — case-insensitive lexer with multi-char operators
  - `src/gql/ast.zig` — AST types for queries, patterns, expressions
  - `src/gql/parser.zig` — recursive-descent parser with options and validation
  - `src/gql/main.zig` — CLI for parsing and error reporting
  - `src/lib.zig` — library API (ParseOptions, ParseResult, ParseOutcome)
  - `src/gql.zig` — tests covering the implemented grammar
- Build: Zig 0.14 with module wiring in `build.zig`
- Docs: this GAP, prompt docs, and research notes

## Summary: What’s implemented (today)

- Entry points
  - Program with one-or-more statements; semicolon optional
  - Statements: Query, UNION chains; session/transaction ops: START TRANSACTION, COMMIT, ROLLBACK, SESSION SET/RESET/CLOSE
- Query structure (single-part)
  - OPTIONAL MATCH | MATCH graph-pattern
  - optional WHERE predicate (also post-WITH filtering merged via AND)
  - optional WITH projection (forwarding bindings)
  - RETURN [DISTINCT] projection list with aliases
  - ORDER BY expression keys, per-key ASC/DESC
  - LIMIT and OFFSET (integers)
- UNION
  - UNION with per-tail modifiers: ALL or DISTINCT (mutually exclusive per segment)
  - Chaining supported: first + tails array
- Patterns (Annex B subset, expanded)
  - NodePattern: optional name, multiple labels (:Label), optional property map {k: expr, ...}
  - RelPattern: optional name, multiple types (:TYPE | TYPE2), optional property map, direction <-, ->, or undirected
  - GraphPattern: supports multi-hop chains and comma-separated multiple chains
  - Relationship length quantifiers: \*, \*k, \*k..m, \*..m, \*k..
  - Path aliasing: allow chain alias via `p = (a)-[r]->(b)` and use alias in RETURN
  - Pattern comprehensions: `[ pattern (WHERE expr)? | expr ]` with optional alias form `p = [ ... ]`
- Expressions
  - Literals: integer, string, TRUE/FALSE/NULL, map literals, list literals (in IN set)
  - Variables and member access: a, a.b, a.b.c
  - Calls: ident(args...), with basic built-in validation (exists, length, id, labels, type, coalesce, toInteger, toString, abs)
  - Unary: NOT, numeric negation
  - Binary arithmetic: +, -, \*, /
  - Comparisons: =, <>, !=, <, <=, >, >=
  - Logical: AND, OR
  - Predicates: IN [list], IS [NOT] NULL
  - Grouping with parentheses
- Parser options (semantics/guardrails)
  - strict_order_keys: ORDER BY keys must be identifier or member-chain
  - ident_order_only: ORDER BY keys must be bare identifiers
  - forbid_orderby_calls: disallow function calls in ORDER BY expressions
  - forbid_orderby_paths: disallow ORDER BY referring to known path aliases (precise, not all idents)
- Error reporting
  - `Parser.last_error` populated by `expect()` / `unexpected()` for contextual messages
  - Library `parseGqlOutcome`: returns Ok(ParseResult) or Err{msg,line,column,token} without throwing
  - CLI prints contextual parse errors and uses exit codes (2: IO, 3: parse)
- Tests
  - Sanity queries, labels/props/member access, IN/IS NULL, arithmetic
  - RETURN DISTINCT and aliasing; WITH projection; OPTIONAL MATCH
  - ORDER BY expressions and per-key ASC/DESC; option toggles (ident-only, simple, forbid-orderby-paths)
  - UNION ALL/DISTINCT chaining with tail assertions
  - Patterns: multi-hop chains; multiple comma-separated patterns
  - Relationship quantifiers: \*, \*k, \*k..m, \*..m with validation (min<=max)
  - Alternation in relationship types via `:T1|T2`
  - Pattern comprehensions parse; alias binding `p = [ ... ]`
  - GROUP BY keys (parse-only acceptance)

## Coverage matrix (high level)

- Statements
  - [x] MATCH / OPTIONAL MATCH
  - [x] WITH (projection + optional WHERE filter after WITH)
  - [x] RETURN (DISTINCT supported)
  - [x] ORDER BY (per-key ASC/DESC) | LIMIT | OFFSET
  - [x] UNION with chaining (ALL or DISTINCT per segment)
  - [~] Session/transaction control (parsed as statements, minimal)
  - [ ] Other schema/graph DDL (CREATE GRAPH, DROP, etc.)
  - [ ] Data updates (CREATE/MERGE/DELETE/SET/REMOVE)
- Patterns
  - [x] Node/Relationship with labels/types and property maps
  - [x] Multi-hop chains (n)-[r1]-(m)-[r2]-(p)
  - [x] Variable-length paths (quantifiers: \*, \*k, \*k..m, \*..m, \*k..)
  - [x] Alternation in relationship types (e.g., :T1|T2)
  - [~] Path variables/aliases and path-return (aliases parsed and can be RETURNed; semantics TBD)
  - [x] Pattern comprehension `[ pattern (WHERE expr)? | expr ]` and alias form `p = [ ... ]`
- Expressions and predicates
  - [x] Literals (int, string, bool, null), map, list
  - [x] Arithmetic, comparisons, AND/OR/NOT
  - [x] IN [], IS [NOT] NULL
  - [x] Function calls (basic, with small builtin table)
  - [ ] CASE/WHEN, NULLIF (COALESCE available as call; semantics still minimal)
  - [ ] String predicates: STARTS WITH, ENDS WITH, CONTAINS, LIKE/GLOB, regex =~
  - [ ] BETWEEN, RANGE, any/all/none list predicates
  - [ ] Parameter markers ($param) / typed parameters
  - [ ] Date/time/duration literals and operators
- Projection and grouping
  - [x] RETURN items with aliasing, DISTINCT
  - [ ] Aggregation functions: COUNT, SUM, AVG, MIN, MAX, COLLECT, etc.
  - [~] GROUP BY (syntax parsed; semantics and scoping rules not enforced yet)
  - [ ] HAVING
  - [ ] WITH DISTINCT, WITH aggregation semantics
- Set operations (beyond UNION)
  - [x] UNION ALL
  - [x] UNION DISTINCT
  - [ ] INTERSECT [ALL|DISTINCT]
  - [ ] EXCEPT/MINUS [ALL|DISTINCT]
- Ordering and pagination
  - [x] ORDER BY expression keys, per-key direction
  - [~] ORDER BY restrictions via options (ident-only, simple, forbid calls, forbid path aliases)
  - [ ] Stable collation, NULLS FIRST/LAST modifiers
  - [x] LIMIT, OFFSET (integers)
- Functions and built-ins
  - [~] Minimal registry/validation for a handful of built-ins
  - [ ] Comprehensive function catalog with arity/type checks
  - [ ] Aggregates and window functions (if applicable)
- Errors and diagnostics
  - [x] Context message via `last_error`
  - [x] Outcome API for non-throwing parse results
  - [ ] Richer diagnostics (expected-set, caret ranges, source snippets)
  - [ ] Error recovery for multiple diagnostics per parse
- Tooling
  - [x] CLI flags: --strict-order-keys, --ident-order-only, --forbid-orderby-calls, --forbid-orderby-paths
  - [x] CLI: AST pretty-printer and JSON output
  - [ ] Token stream dump option
  - [ ] Fuzzing hooks beyond existing script stub

Legend: [x] implemented, [~] partial/minimal, [ ] not yet.

## Known gaps (prioritized)

Priority P0 (next up)

1. Aggregation semantics and grouping

- Aggregates: COUNT, SUM, AVG, MIN, MAX (parse present as calls; add catalog + basic validation)
- GROUP BY scoping rules and validation (non-aggregates must appear in GROUP BY)
- HAVING clause parsing
- WITH DISTINCT and aggregation forwarding semantics (parse ok; enforce later)

1. String predicates and CASE

- CASE [WHEN] ... ELSE ... END (simple and searched forms)
- STARTS WITH, ENDS WITH, CONTAINS, LIKE/GLOB, and regex =~ (syntax + minimal handling)

1. Parameters and literals

- $param markers; optional type hints; AST threading
- Date/time/duration literal tokens and basic parse forms

1. ORDER BY polish

- NULLS FIRST/LAST parsing; wire into OrderKey
- Collation and stability policy notes (doc + options stub)

Priority P1

5. Functions registry

- Expand builtins with min/max arity and argument category/type checks
- Aggregates catalog and validations

6. CLI and diagnostics

- Token stream dump for debugging
- Richer error messages: expected vs. found set; underline ranges; caret source snippets

Priority P2

9. Other statements

   - Schema/graph DDL: CREATE GRAPH, DROP, etc.
   - Data updates (CREATE/MERGE/DELETE/SET/REMOVE) — parse surface only

10. Advanced expressions

- ANY/ALL/NONE list predicates
- List/map comprehensions and slicing

## Implementation notes (current)

- Parser architecture: recursive descent with explicit precedence levels
- Memory: arena allocator threaded through, AST owns allocations
- UNION representation: non-recursive union of `first` + `tails` to avoid self-referential types
- ORDER BY controls: optional constraints to match deployment policies
- Error policy: capture last expected/what; return Err outcome for clean API

## Test coverage snapshot

- Happy paths for: MATCH/OPTIONAL MATCH, WHERE, WITH projection, RETURN w/ DISTINCT and aliases, ORDER BY expressions and directions, LIMIT/OFFSET
- UNION: ALL/DISTINCT and chaining structure tested
- Patterns: multi-hop and multiple chains; quantifiers; alternation; path aliasing; pattern comprehensions
- GROUP BY: parse-only keys list
- ORDER BY policies: ident-only/simple/call-ban/path-ban
- Expressions: arithmetic, comparisons, IN, IS [NOT] NULL, function calls, map/list literals

## Risks and unknowns

- Exact ISO grammar points (e.g., full CASE semantics, string predicate operators, set operations) need tight reading to settle edge cases and precedence
- Scoping rules across WITH/aggregation and name resolution need dedicated design + tests
- Path pattern semantics (quantifiers, binds, alternations) have many corner cases

---

Last updated: 2025-08-30

## NEXT plan (prioritized and testable)

P0 — Aggregation, grouping, and predicates

1. Aggregation semantics and grouping

- Aggregates: COUNT, SUM, AVG, MIN, MAX (catalog + validation)
- GROUP BY scoping rules and validation
- HAVING clause parsing
- WITH DISTINCT and aggregation forwarding (semantics later)

2. String predicates and CASE

- Operators: STARTS WITH, ENDS WITH, CONTAINS, LIKE/GLOB, =~ (regex)
- CASE expression (simple and searched)

3. Parameters and literals

- $param markers and optional typing
- Date/time/duration literal tokens and basic parse

4. ORDER BY polish

- NULLS FIRST/LAST in OrderKey
- Collation/stability policy notes (options stub)

P1 — Functions and diagnostics

1. Functions registry expansion

- Broader builtin catalog with arity/type checks
- Aggregates catalog validations

1. CLI and diagnostics improvements

- Token dump flag
- Richer diagnostics: expected-set, caret snippets

P2 — Set ops and advanced expressions

1. Set operations

- INTERSECT and EXCEPT/MINUS with ALL/DISTINCT

1. Advanced expressions

- ANY/ALL/NONE list predicates; list/map comprehensions and slicing
