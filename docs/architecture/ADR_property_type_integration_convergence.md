# ADR: Staged Convergence for Property Type and Advanced Type Integration

**Status**: PROPOSED
**Date**: 2026-04-01
**Decision Makers**: Codex architecture analysis
**Related Documents**: [property_type_optimization_analysis.md](./property_type_optimization_analysis.md)

## Context

Geode currently represents property and advanced types through multiple overlapping models:

- `src/value_types.zig`
- `src/eval_extended.zig`
- `src/graph_store.zig`
- `src/storage/heap.zig`
- `src/types/extended.zig`

This has produced concrete integration failures:

1. `ExtValue` is lossy in `src/storage/graph_storage_adapter.zig`
2. `ExtValue` is lossy in `src/txn_undo_log.zig`
3. inbound protocol params reject `ext_val`
4. typed literals degrade to strings in `src/eval.zig`
5. specialized index DDL is partially downgraded to `.btree`
6. advanced optimizer/index surfaces exist without active production wiring

The product requirement is now clarified:

- all advanced property families documented in `docs/TYPES_AND_FUNCTIONS.md` and `specs/advanced-types/*` are **GA**
- extended types are expected to have **full end-to-end support**
- the client/server contract must preserve the documented annotation/constructor and protocol JSON shapes

The system therefore has useful specialized implementations, but no single trustworthy end-to-end integration boundary.

## Decision

Adopt a **staged convergence strategy**:

1. **Keep** the specialized advanced type implementations and specialized index/storage backends.
2. **Replace** lossy property-type boundaries with an explicit canonical integration layer.
3. **Require full protocol/storage/runtime support for documented GA families**, with explicit validation errors only for invalid payloads, not “unsupported” responses for GA types.
4. **Wire or remove** advanced optimizer and index subsystems based on actual planner/executor usage.
5. **Converge long-term** toward one canonical semantic property model for query/runtime behavior, with explicit codecs for persistence/protocol/index boundaries.

## Decision Drivers

- Data integrity is currently at risk for advanced property values.
- Build/test green does not prove end-to-end integration.
- The documented GA contract removes the option of leaving advanced families partially integrated.
- Big-bang replacement would be high risk.
- Specialized index backends are worth preserving.
- Architectural duplication is too high to leave unaddressed.

## Options Considered

### 1. Keep current system

Rejected.

Reason:

- Does not solve persistence, rollback, or integration correctness.

### 2. Improve current system in place only

Accepted as part of Stage 1, but not sufficient as the final architecture.

Reason:

- Fixes correctness faster, but leaves too much long-term duplication.

### 3. Full replacement now

Not selected as the immediate path.

Reason:

- Long-term architecture is attractive, but near-term migration risk is too high.

### 4. Staged convergence

Selected.

Reason:

- Fixes correctness first, preserves specialized performance paths, and creates a controlled path to simplification.

## Consequences

### Positive

- Advanced property values can become safe across persistence and rollback first.
- Specialized vector/spatial/network/jsonb/domain implementations are preserved.
- Dead or misleading optimizer paths can be retired or explicitly quarantined.
- The codebase moves toward one coherent property-type boundary.
- The staged plan still converges on full GA parity for all documented advanced families.

### Negative

- Temporary coexistence of old and new boundaries will continue during migration.
- Requires disciplined milestone ownership to avoid perpetual partial migration.

## Implementation Direction

### Stage 1: Boundary correctness

- storage adapter codec for advanced values
- undo-log codec for advanced values
- protocol input support for the documented annotation/constructor contract
- typed literal materialization
- remove silent lossy fallbacks for documented GA families

### Stage 2: Real index/runtime wiring

- parser DDL maps to actual specialized index types
- mutation-to-index sync path
- production query callsites for advanced indexes

### Stage 3: Consolidation

- establish canonical semantic property model
- retire or quarantine duplicate type stacks only after canonical-path parity is reached
- wire or remove dead advanced optimizer modules

## Guardrails

1. No silent null fallback for supported advanced types in property-boundary modules.
2. No new advanced index API without at least one production call path or explicit dormant status.
3. No CANARY/test status should imply production readiness unless the code is on an active build/runtime path.
4. No documented GA family may remain partially implemented behind an `Unsupported` protocol/storage/runtime path.

## Verification

- `zig build`
- `zig build test`
- persistence/reload roundtrip tests for advanced property types
- rollback tests for advanced property types
- protocol request/response tests for the documented annotation/constructor contract
- end-to-end DDL -> mutation -> query tests for specialized indexes
