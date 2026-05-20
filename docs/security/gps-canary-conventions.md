# GPS — CANARY Cross-Reference Conventions

## Background

The CANARY governance system tracks requirements from specification to source
code via inline markers of the form:

```
// CANARY: REQ=<id>; FEATURE="<name>"; ASPECT=<aspect>; STATUS=<status>; OWNER=<owner>; UPDATED=<date>
```

During Phase 0 the team discovered that the normalizer script
(`scripts/canary_normalizer.py` and `make status-generate`) strips any field
not in the canonical field list. The `SITE=` field that was used in early
drafts to cross-reference fail-open catalog row numbers was being silently
discarded, making catalog↔source traceability invisible to the governance
tooling.

## Convention adopted for GPS (Phase 2+)

**Use shared `REQ=` IDs and distinct `ASPECT=` tags — not `SITE=`.**

The `SITE=` convention is retired. The catalog cross-reference works as
follows:

1. Every catalog entry (e.g., `docs/security/gps-fail-open-sites.md`) assigns
   a `REQ=` identifier to a class of sites.
2. Each source-code instance of that class carries the same `REQ=` identifier
   with a distinct `ASPECT=` tag that identifies the specific site within the
   class.
3. The normalizer preserves both fields; `make status-generate` aggregates all
   markers sharing the same `REQ=` and reports the worst-case `STATUS` across
   all `ASPECT=` variants.

### Example: `REQ-GPS-INVARIANT-001`

The fail-open catalog uses `REQ=REQ-GPS-INVARIANT-001` for all nine documented
fail-open sites. Each source-code marker carries a specific `ASPECT=`:

| ASPECT | Location | Phase that closes it |
|--------|----------|----------------------|
| `FailOpenInterim` (execution.zig) | `src/execution.zig:842` — legacy `!isAuthEnabled()` shim | Phase 3 |
| `FailOpenInterim` (rls_core.zig) | `src/security/rls_core.zig:1083` — empty RLS policy default-allow | Phase 4 |
| `FailOpenInterim` (rls_core.zig VM) | `src/security/rls_core.zig:1366` — VM no-result | Phase 2 (CLOSED) |
| `ClassifierUnused` | `src/execution/procedure_registry.zig:105` — procedure dispatch | Phase 5 |

The `STATUS=COMPLETE` on the VM no-result site confirms Phase 2 closed it.
`STATUS=EXEMPT` on the remaining sites means they are documented open-with-
reason, not forgotten.

## Conventions summary

| Field | Required | Notes |
|-------|----------|-------|
| `REQ=` | yes | Use the class identifier from the requirement doc |
| `FEATURE=` | yes | Human-readable feature group name in quotes |
| `ASPECT=` | yes | Distinguishes this site within the class |
| `STATUS=` | yes | `TESTED`, `IMPL`, `EXEMPT`, `BENCHED`, or `COMPLETE` |
| `OWNER=` | yes | Team or person responsible |
| `UPDATED=` | yes | ISO date of last update |
| `TEST=` | optional | Cross-reference to test file (kept by normalizer) |
| `SITE=` | RETIRED | Stripped by normalizer — do not use |

## Status meanings

| Status | Meaning |
|--------|---------|
| `TESTED` | Implementation exists and is verified by a named automated test |
| `IMPL` | Implementation exists but no dedicated automated test yet |
| `EXEMPT` | Intentionally open with documented reason; not a defect |
| `BENCHED` | Deferred; not a production path today |
| `COMPLETE` | A previously `EXEMPT` or `IMPL` site that has been fully closed |

## Phase 2 CANARY count

At end of Phase 2 the GPS requirement family includes:

- `REQ-GPS-PDP-001` through `REQ-GPS-PDP-008` — decision engine types and
  evaluation order (8 requirements, all `STATUS=TESTED`).
- `REQ-GPS-INVARIANT-001` — 4 active markers (1 `COMPLETE`, 3 `EXEMPT`).
- `REQ-GPS-DERIVE-001`, `REQ-GPS-DERIVE-002` — principal derivation helper
  (2 requirements, all `STATUS=TESTED`).
- `REQ-GPS-CACHE-001` — auth-version cache invalidation (1 requirement,
  `STATUS=TESTED`).
- `REQ-GPS-PRINCIPAL-001` through `REQ-GPS-PRINCIPAL-006` — Phase 1
  principal type and wiring (6 requirements, all `STATUS=TESTED`).
- `REQ-GPS-AUDIT-001` — audit fields on decisions (1 requirement,
  `STATUS=IMPL`; dedicated audit test is Phase 3).

Total active GPS CANARY markers after Phase 2: ≥ 32.
