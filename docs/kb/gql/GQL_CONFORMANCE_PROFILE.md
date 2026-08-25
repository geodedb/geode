# GQL Conformance Profile (ISO/IEC 39075:2024)

## A. Product

- Implementation: Geode v0.1.0
- Scope: Working toward GQL front‑end + planner/executor for distributed ACID graph DB.
- **Current Status**: SQL-like query engine with GQL syntax parsing; graph features not yet implemented.

## B. Minimum conformance

- This implementation **will** correctly translate/execute all GQL programs conforming to the language when complete.
- Currently **rejects** programs with proper ISO diagnostics but **cannot execute** graph patterns.

## C. Optional features claimed (Annex D)

Currently implemented:

- **GQ03 UNION** - DISTINCT and ALL variants working
- **GQ04/5 EXCEPT** - DISTINCT and ALL variants working
- **GQ06/7 INTERSECT** - DISTINCT and ALL variants working
- **GQ12 OFFSET** - With US001 policy enforcement
- **GQ13 LIMIT** - Working with ORDER BY requirements

Planned but not implemented:

- **G060 bounded quantifiers** - Path patterns not yet supported
- Graph pattern features pending implementation

## D. Implementation‑defined / dependent behaviors

Implemented:

- **US001**: NOT enforced — OFFSET/LIMIT on unordered tables is accepted. ISO/IEC 39075 leaves the ordering of an unordered result set implementation-defined; Geode declares `UnorderedPaginationAllowed` in its implementation-defined flagger report rather than raising a diagnostic.
- **UA002**: Multiple diagnostic conditions use precedence rules (ISO 23.2)
- **UA005/UA006**: Deterministic path tie‑break (Length then stable internal id) for variable length expansions
- **I:ORDER**: ORDER BY keys restricted to identifiers by default (configurable via --order-keys expr)
- **I:NULLS** / `NullOrderPolicyDefault`: NULLS FIRST default, NULLS LAST via `GEODE_NULLS_LAST` env var (flag surfaced as `NullOrderPolicyDefault` in protocol findings)
- **I:COLLATION** / `CollationBinaryDefault`: Binary collation for string comparison (flag surfaced as `CollationBinaryDefault`)
- **I:DECIMAL**: Decimal values normalized to canonical form
- **I:NUMERIC**: Int→Decimal promotion in mixed arithmetic

Recent additions reflected in protocol Flagger (see tests): `CollationBinaryDefault`, `NullOrderPolicyDefault`.

Deferred / pending clarification:

- None in this category presently (path tie‑break now implemented)

## E. Extensions / Options

- Custom functions MATCH_1HOP, EXPAND_FROM as temporary workarounds (not standard GQL)
- PROFILE/EXPLAIN prefixes for query analysis
- Memory governance with spill thresholds
- QUIC transport with TLS 1.3

## F. Flagger

- Provided in protocol frames
- Flags non-standard modes and extensions
- Reports when implementation-defined choices affect results

## G. Current Limitations

The following core GQL features are **not yet implemented**:

1. **MATCH patterns** - Parser recognizes but cannot execute graph traversal
2. **Property access** - Cannot access node/edge properties (n.name syntax)
3. **Node/edge labels** - No label-based filtering
4. **OPTIONAL MATCH** - Parsed but not executed
5. **Path patterns** - No variable-length traversal
6. **Graph mutations** - CREATE/DELETE/MERGE not supported
7. **WITH clause** - Query chaining not implemented

See [GAP_ANALYSIS.md](GAP_ANALYSIS.md) for detailed implementation status and [NEXT.md](NEXT.md) for roadmap.
