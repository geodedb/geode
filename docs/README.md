# Geode Design Documentation

## File Structures

### Indexes

### Graph

## Binary Protocol

## Status & Conformance Summary

- Requirements Ledger and evidence: see GAP_ANALYSIS.md
- GQL Conformance Profile (initial): see GAP_ANALYSIS.md (bottom)
- Execution-ready backlog: see NEXT.md

## Troubleshooting (diagnostics quick reference)

- US001 — Unordered pagination: LIMIT/OFFSET without explicit ORDER BY on an unordered input is illegal (ISO 16.18–16.19).
- IllegalOrderKey — ORDER BY key violates ident‑only policy (ISO 14.10).
- GroupByIllegal — RETURN/HAVING expressions not aligned with GROUP BY keys or aggregates (ISO 14.10).
- TypeMismatch — Incomparable types for the requested operation (e.g., ordering across heterogeneous types) (ISO 16.x; 23.2).
