# ADR: Unify Query Planning, EXPLAIN, PROFILE, and Execution Around a Canonical Operator Graph

Date: 2026-04-01
Status: Proposed
Decision owner: Architecture

## Context

The current query planner and execution system is fragmented:

1. `src/planner.zig` provides legality checks and a minimal heuristic result.
2. `src/server/query_plan_cache.zig` builds shared optimizer hints.
3. `src/server/explain_payload.zig` and `src/server/profile_payload.zig` synthesize wire payloads from query traits.
4. `src/execution*` performs primary execution through AST-interpreted logic.

Observed consequences:

- EXPLAIN can report impossible operators for trivial scalar queries.
- PROFILE exposes synthetic timings and allocations as if they were measured.
- Optimizer hints are currently not consumed by execution.
- RLS is applied post-execution in transport handlers.
- Planner pipeline code can drift outside normal build coverage.

## Decision

Introduce a canonical operator graph as the single shared representation for:

1. planning
2. EXPLAIN
3. PROFILE
4. incremental execution lowering

Immediate rules:

1. EXPLAIN must be generated only from the canonical operator graph.
2. PROFILE must report measured runtime instrumentation or clearly labeled estimates attached to canonical operators.
3. Shared optimizer output must either populate the canonical graph or be removed.
4. RLS must move into execution as a mandatory operator or execution-stage filter, not a transport-only post-pass.

## Rationale

This is the smallest architectural move that fixes the most serious defects first:

- truthfulness of EXPLAIN
- truthfulness of PROFILE
- planner/execution consistency
- testability
- future optimization headroom

It avoids the immediate risk of a full executor replacement while still establishing the architecture needed for one.

## Consequences

Positive:

- One source of truth for plan structure
- More trustworthy operator-level observability
- Clear migration path from AST-driven execution to planner-driven execution
- Better test coverage and ownership boundaries

Negative:

- Temporary dual-path complexity during migration
- Requires adapter logic between current executor semantics and canonical operators
- Some existing explain/profile code will need to be retired

## Alternatives Considered

### Patch current system only

Rejected because:

- it preserves duplicated planner surfaces
- it does not make EXPLAIN/PROFILE trustworthy
- it does not create a path to planner-driven execution

### Immediate full planner-driven executor replacement

Not selected now because:

- migration risk is too high relative to current evidence
- current executor semantics are deeply embedded in AST-driven code paths
- incremental proof is preferable

## Implementation Notes

Suggested sequence:

1. Define canonical operator graph types and serializer.
2. Route EXPLAIN to canonical graph only.
3. Add real PROFILE instrumentation or explicit measured/estimated provenance.
4. Lower read-only query subsets onto canonical execution.
5. Move RLS into execution.
6. Remove synthetic explain/profile builders and unused hint plumbing.

## Verification

Success criteria:

1. Golden EXPLAIN tests pass for scalar, scan, traversal, aggregate, sort, limit, and union queries.
2. PROFILE metrics are derived from runtime instrumentation, not fixed formulas.
3. Execution consumes canonical plan metadata for read-only query subsets in scope.
4. RLS cannot be bypassed across QUIC, gRPC, or direct executor calls.
