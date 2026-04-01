# ADR: Externalize `build.zig.zon` Libraries by Default

## Status

Accepted, 2026-04-01

## Context

Geode had reached an unstable middle state:

- some top-level libraries were directly integrated
- some were only transitive support libraries
- some local files were still wrapper or re-export layers even after the external library had already been adopted
- some dependencies stayed pinned at the top level with no runtime value

That model was no longer defensible once the codebase had enough direct external-library coverage to remove the compatibility layers safely.

The specific failures this ADR addresses:

1. declared-only or newly-unused dependencies widened audit scope without runtime value
2. thin wrappers obscured whether Geode or the external library owned the behavior
3. runtime code could still depend on support modules that should only exist for tests
4. nothing in CI enforced the intended migration state

## Decision

Geode will externalize top-level libraries by default.

Rules:

1. A top-level dependency must be one of:
   - direct integration with source/test evidence
   - explicitly transitive-only with a documented reason
   - removed
2. Thin wrappers and pure re-export modules are prohibited.
3. Runtime code must import the external library directly when the local file adds no Geode-specific behavior.
4. Local files are allowed only when they own:
   - product-specific state or memory ownership
   - persistence format or deployment integration
   - environment / policy behavior not provided by the external library
5. Test-support helpers must not remain on runtime code paths.
6. CI must enforce the above constraints.

Applied in this change:

- removed top-level `ds`, `cuda`, `tls`, and `metrics`
- removed thin wrapper files for thread-pool, metrics, HNSW, R-tree, and Raft re-export
- moved runtime MFA code to direct `auth_lib.mfa`
- kept only intentional adapters such as URL ownership, FLE env helpers, and Raft integration logic
- added `scripts/verify_dependency_integrations.py` and wired it into `verify-fast` / `verify-all`

## Consequences

Positive:

- the dependency list now matches actual runtime ownership more closely
- future regressions are caught by CI instead of code review memory
- security-sensitive flows such as MFA no longer route through compatibility modules in production

Negative:

- migration policy is stricter and requires build/test evidence before adding or keeping a top-level dependency
- a small number of intentional adapters remain, so “no local code at all” is still not the goal

## Consequences for remaining adapters

These are explicitly allowed under this ADR:

- `src/types/url.zig`: owned Geode URL/Domain values backed by `advanced_types_lib`
- `src/keys/manager.zig`: Geode master-key/env helpers over `fle_lib.KeyManager`
- `src/distributed/raft_consensus.zig`: cluster integration logic over `raft`
- `src/distributed/raft_persistent.zig`: persistence/open helpers over `raft.FileStorage`

These are not compatibility wrappers and should be judged on product behavior, not on migration completeness.

## Follow-up

1. Revisit whether `uri` and `toml` should remain top-level or be treated purely as transitive build graph details.
2. If URL/Domain ownership changes, evaluate retiring `src/types/url.zig`.
3. Keep the dependency audit updated whenever a new top-level package is added or removed.
