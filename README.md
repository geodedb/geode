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
- Runtime set-ops semantics (UNION/INTERSECT/EXCEPT) over binding tables with deterministic ordering:
  DISTINCT variants return sorted results; ALL variants preserve stable-left order.
- Planner policies: disallow OFFSET pushdown without explicit ORDER (US001), temporal-aware
  comparator for ORDER BY with session-local attachment.
- CLI: normalization/clamping for temporals; AST JSON with verbose temporals.

See USAGE.md for commands and flags.

## Diagnostics (policy and ISO anchors)

| Code            | Meaning                                                     | ISO anchor  | Example                                |
|-----------------|-------------------------------------------------------------|-------------|----------------------------------------|
| US001           | LIMIT/OFFSET on unordered table (requires stable ORDER BY)  | 16.18–16.19 | RETURN 1 LIMIT 10 OFFSET 5             |
| IllegalOrderKey | ORDER BY key must be identifier (policy: ident-only)        | 14.10       | RETURN a ORDER BY f(a)                 |
| GroupByIllegal  | Invalid GROUP BY legality (e.g., non-aggregated columns)    | 14.10       | RETURN a, SUM(b) GROUP BY a, b         |
| TypeMismatch    | Illegal cross-type comparison/ordering                      | 16.x        | RETURN 1 < "2"                         |

The CLI and server surface diagnostics with status_class/subclass. Tests assert codes/anchors via stderr.
