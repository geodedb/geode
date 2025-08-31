# Geode Graph Database

## Description

Geode is a Zig-based graph database project exploring an ISO/IEC 39075:2024 (GQL) front end with
structured temporals, ORDER BY policy checks, and developer-friendly printers and CLI tooling.

## Status & Conformance Summary

- Requirements Ledger and evidence: see docs/GAP_ANALYSIS.md
- GQL Conformance Profile (initial): see docs/GAP_ANALYSIS.md (bottom)
- Execution-ready backlog: see docs/NEXT.md

Highlights

- Parser/AST/printers for MATCH/OPTIONAL, ORDER BY, LIMIT/OFFSET, GROUP BY (parse-only),
  UNION/INTERSECT/EXCEPT (parse), pattern comprehensions, string predicates, CASE, and
  structured temporal literals (DATE/TIME/DATETIME/LOCAL DATETIME) with normalization.
- Planner policies: disallow OFFSET pushdown without explicit ORDER (US001), temporal-aware
  comparator for ORDER BY with session-local attachment.
- CLI: normalization/clamping for temporals; AST JSON with verbose temporals.

See USAGE.md for commands and flags.
