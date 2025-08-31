# NEXT plan

This document lists the next implementation steps for the GQL front-end in priority order with brief acceptance criteria.

## P0 — Expand patterns and minimal aggregation

1. Multi-hop graph patterns

- Add parsing of chained patterns: (a)-[r1]->(b)-[r2]->(c)
- Support comma-separated multiple patterns in MATCH
- Acceptance: tests parse multi-hop and multiple patterns; AST captures arrays of hops; existing single-hop tests still pass

1. Variable-length relationships (quantifiers)

- Parse [r*], [r*3], [r*1..5] forms on relationship patterns
- Extend `RelPattern` with `min_len:?u32`, `max_len:?u32`
- Acceptance: tests for \*, \*k, \*k..m; error case when min>max

1. Minimal aggregation surface

- Parse COUNT(expr), SUM(expr), AVG(expr), MIN(expr), MAX(expr) as calls
- Introduce GROUP BY with a list of expressions
- Acceptance: RETURN COUNT(n) GROUP BY n parses; non-grouped non-aggregates with aggregates accepted by parser for now (semantics TBD)

## P1 — String predicates and CASE

1. String predicates

- Add operators: STARTS WITH, ENDS WITH, CONTAINS, =~ (regex)
- Acceptance: parsing tests for each operator; precedence consistent with comparisons

1. CASE expression

- Parse simple and searched CASE forms with ELSE
- Acceptance: parse trees for CASE WHEN cond THEN x ELSE y END; nested cases

## P1 — Functions and ORDER BY polish

1. Built-in registry expansion

- Add catalog with min/max arity and validators for: upper, lower, substring, replace, trim, size, keys, properties, exists, toBoolean, toFloat, round, floor, ceil
- Acceptance: unit tests assert valid/invalid arities and basic argument categories

1. ORDER BY NULLS FIRST/LAST

- Extend OrderKey with `nulls_first:?bool`
- Acceptance: ORDER BY a NULLS FIRST / NULLS LAST parses and decorates keys

## P2 — Set ops and diagnostics

1. INTERSECT/EXCEPT

- Extend Statement parsing to accept INTERSECT and EXCEPT/MINUS with ALL/DISTINCT
- Acceptance: chaining tests like q1 UNION ALL q2 EXCEPT q3

1. Diagnostics and CLI quality

- Add parser expected-set reporting in `last_error`
- Add CLI flags: `--dump-tokens`, `--ast=json`; pretty-printer for AST
- Acceptance: golden tests comparing printed AST for stable formatting
