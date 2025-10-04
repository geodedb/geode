# ISO/IEC 39075:2024 GQL Conformance Patch

This patch implements critical GQL conformance features for Geode v0.16.0.

## Implemented Features

### A. Core Conformance Fixes

1. **Unordered LIMIT/OFFSET (US001)**
   - LIMIT/OFFSET allowed without ORDER BY
   - Applies deterministic implementation order when no ORDER BY specified
   - US001 diagnostic gated behind strict_mode (disabled by default)
   - Flags: `U:OrderTiebreak=LexJSON` when implicit ordering applied

2. **SKIP Synonym (GQ13)**
   - `SKIP <n>` accepted as synonym for `OFFSET <n>`
   - Full parser and lexer support

3. **Double-quoted Identifiers**
   - Quoted identifiers like `"order"` supported
   - Escaping via `""` within quotes
   - Case-preserving semantics

4. **ORDER BY Expressions**
   - Removed restriction on ORDER BY expressions
   - Function calls and complex expressions allowed
   - Ordinal sort keys (ORDER BY 1, 2) supported with flag

5. **Per-key NULLS FIRST|LAST**
   - Per-key NULL ordering policy
   - Overrides global default when specified
   - Mixed policies supported in multi-key ORDER BY

6. **UNKNOWN Keyword & IS [NOT] UNKNOWN**
   - Three-valued logic support
   - NULL IS UNKNOWN returns true
   - Non-NULL IS NOT UNKNOWN returns true

7. **Comment Conformance**
   - `/*...*/` multi-line comments supported
   - `//` single-line comments supported and flagged (GB03)
   - `--` double-hyphen comments disabled with clear diagnostic (GB02)

### B. Multi-graph Session Semantics

8. **Graph Catalog & Per-session Active Graph**
   - In-memory graph catalog
   - SESSION SET PROPERTY GRAPH <name> switches graphs
   - Auto-creates empty graphs when referenced
   - Flag: `I:GraphCatalog=memory`

### C. Aggregation Semantics

9. **GROUP BY / HAVING Execution**
   - Basic aggregation support
   - COUNT(*), COUNT(expr), COUNT(DISTINCT expr)
   - SUM, AVG, MIN, MAX aggregates
   - NULL handling per SQL standards
   - HAVING clause filtering
   - Proper grouping validation

## Flagger Findings

The implementation tracks and reports the following flags:

- `U:OrderTiebreak=LexJSON` - Implicit ordering applied
- `GB03:DoubleSolidusComment` - // comments used
- `E:OrdinalSortKey` - Ordinal sort keys used
- `I:GraphCatalog=memory` - In-memory graph catalog active
- `I:IllegalOrderKeyPolicy=expr` - Expression ORDER BY keys allowed

## Build & Test

```bash
# Build
zig build -Drelease-safe=false

# Run all tests
zig build test

# Run conformance tests
zig test tests/gql_conformance.zig

# Format check
zig fmt --check src/ tests/
```

## Test Coverage

19 acceptance tests covering:
- T1-T10: Core language features
- T11-T13: Multi-graph session management
- T14-T19: Aggregation and GROUP BY

## Conformance Notes

- Minimum ISO/IEC 39075:2024 conformance level met
- Optional features: GQ03 (UNION), GQ13 (SKIP)
- Implementation-defined: US001 behavior, tie-break ordering
- Diagnostics map to ISO codes with clause anchors

## Security

- Graph names validated (ASCII + quoted identifiers)
- Maximum name length enforced
- No filesystem or network access in catalog
- Session isolation maintained

## License

MIT

## Rationale

1. **US001 gating** - Allows LIMIT/OFFSET without ORDER for developer convenience while maintaining determinism
2. **LexJSON tie-break** - Provides stable, predictable ordering when implicit
3. **Auto-create graphs** - Simplifies testing and development workflows
4. **In-memory catalog** - Fast, simple implementation suitable for v0.16.0
5. **Expression ORDER BY** - Aligns with modern SQL expectations
6. **Per-key NULLS policy** - Fine-grained control over result ordering
7. **Comment flexibility** - Supports multiple comment styles with appropriate flagging