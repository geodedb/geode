# Technical Analysis Report: `build.zig.zon` Library Integrations

Date: 2026-04-01  
Repository snapshot: worktree state on 2026-04-01, based on `966a9f1fa46fc087c955a7d19cf61673a140997f`  
Environment: Linux x86_64, Zig 0.15.1, worktree `codex/session-20260401-124312`

## A) Executive summary

Decision: adopt an externalize-by-default policy and complete the migration wherever the remaining local code was only compatibility indirection.

Key reasons:

1. The main unfinished work was no longer architectural uncertainty. It was leftover wrapper code, unused top-level dependencies, and missing governance.
2. The thin wrappers were removable without destabilizing the tree. After the closure pass, `zig build` and `zig build test` remain green.
3. Direct runtime paths now use the external libraries for MFA verification, HNSW, R-tree, and Raft instead of local façade modules.
4. Declared-but-unused top-level dependencies were audit noise. `ds`, `cuda`, `tls`, and now `metrics` have been removed from the top-level dependency set; `uri` and `toml` remain only as explicit transitive exceptions.
5. The remaining local layers are now intentional product code rather than fake integrations:
   - `src/types/url.zig` is an ownership adapter over `advanced_types_lib`
   - `src/keys/manager.zig` is an environment/policy helper over `fle_lib`
   - `src/distributed/raft_consensus.zig` and `src/distributed/raft_persistent.zig` are Geode integration layers over `raft`
6. CI now enforces the migration invariants so the repo cannot drift back to declared-only dependencies or wrapper regressions silently.

Primary tradeoff:

- Geode keeps a small number of local ownership/policy adapters. That is intentional. Full deletion of those files would require broader domain-model or persistence-format changes, not just dependency migration.

## B) Feature scope & requirements

### Feature scope

Feature: library integrations for all top-level dependencies declared in `build.zig.zon`.

In scope:

- top-level dependency declarations in `build.zig.zon`
- build wiring in `build.zig`
- source and test imports in `src/` and `tests/`
- removal of thin wrappers and declared-only dependencies
- governance artifacts and CI enforcement

Out of scope:

- product-level redesign of Geode value ownership and persistence formats
- replacing Geode-specific policy logic with generic library behavior when that would change user-visible semantics

### Decision question

Identify and complete all incomplete integrations from the libraries in `build.zig.zon`, with allowed outcomes:

- keep
- improve
- replace
- hybrid
- defer with explicit evidence

### Inputs

Provided:

- `build.zig.zon`
- `build.zig`
- source and test tree
- TAR / ADR drafts

Unavailable:

- production metrics
- incident history
- cost exports

### Functional requirements

1. Every top-level dependency must be either direct, transitive-only, or removed.
2. Thin wrappers and zero-value re-export modules must be removed where feasible.
3. Runtime code must call external library APIs directly when the local code adds no product-specific behavior.
4. Test-only compatibility helpers must not be on the runtime auth path.

### Non-functional requirements

- Build health: `zig build` and `zig build test` must pass.
- Security: MFA and crypto changes must preserve feature-flag gating and avoid fake verification paths.
- Maintainability: dependency ownership must be obvious from code and CI.
- Supply chain: no unused top-level dependencies.

### Acceptance criteria

1. `ds`, `cuda`, `tls`, and any newly-unused top-level dependency are removed.
2. `mfa`, `thread_pool`, `rtree`, `hnsw`, `raft`, and `metrics` no longer exist as runtime compatibility wrappers.
3. MFA runtime code imports `auth_lib` directly.
4. HNSW, R-tree, and Raft runtime code import external modules directly.
5. CI fails if banned wrappers or declared-only dependencies come back.
6. TAR and ADR reflect the stronger migration policy and current worktree state.

## C) Current system: architecture, evidence, and key gaps

### Architecture and data flow

Current structure after the closure pass:

1. `build.zig.zon` pins the remaining top-level libraries.
2. `build.zig` wires direct libraries into `root_mod` and the `geode` executable, with no top-level wiring for removed packages.
3. Runtime source code imports external libraries directly using their integration aliases:
   - `auth_lib`
   - `hnsw_lib`
   - `rtree_lib`
   - `raft`
   - `advanced_types_lib`
   - `fle_lib`
4. Local files remain only where Geode still owns data layout, persistence, or environment-specific policy.

### Evidence-backed status

Direct integrations:

- `yaml`, `strings`, `repl`, `vulkan`, `json`, `quic`, `slog`, `config`, `cli`, `dns`, `spice`, `mcp`, `protobuf`, `grpc_zig`, `uuid`, `wal`, `graph_storage`, `raft`, `audit`, `hnsw`, `rtree`, `concurrency`, `advanced_types`, `fle`, `gql`, `timeseries`, `auth`

Transitive-only integrations:

- `uri` via `json`
- `toml` via `config`

Removed from top-level because they were unused or wrapper-only:

- `ds`
- `cuda`
- `tls`
- `metrics`

### Gap closures completed

Completed in code:

1. Removed top-level unused dependency wiring for `ds`, `cuda`, `tls`, and `metrics`.
2. Removed `src/transport/thread_pool.zig`, `src/monitoring/metrics.zig`, `src/index/hnsw.zig`, `src/index/rtree.zig`, and `src/distributed/raft.zig`.
3. Rewired runtime imports to `hnsw_lib`, `rtree_lib`, and `raft`.
4. Moved runtime MFA verification and CLI enrollment/verification to `auth_lib.mfa`.
5. Reduced `src/security/mfa.zig` to explicit test-support/compliance helpers instead of a runtime compatibility module.
6. Added `scripts/verify_dependency_integrations.py` and wired it into `verify-fast` and `verify-all`.

### Remaining intentional adapters

These are not considered unfinished integrations:

- `src/types/url.zig`: owns Geode URL/Domain value memory while delegating parsing/validation to `advanced_types_lib`
- `src/keys/manager.zig`: Geode environment and rewrap helpers on top of `fle_lib.KeyManager`
- `src/distributed/raft_consensus.zig`: cluster integration logic on top of external `raft`
- `src/distributed/raft_persistent.zig`: file-opening convenience around external `raft.FileStorage`

### Reliability and security evidence

Validated locally on 2026-04-01:

- `zig build`
- `zig build test`
- `python3 scripts/verify_dependency_integrations.py`

Security-relevant closure:

- CLI MFA verification no longer prints success without checking the TOTP value.
- Runtime MFA verification no longer depends on the local `mfa` support module.

## D) Alternatives: options, pros/cons, migration/ops impact

### Option 1: Keep selective migration and tolerate wrappers

Pros:

- lowest short-term change volume

Cons:

- stale wrapper files keep obscuring ownership
- unused dependencies remain audit scope
- CI cannot distinguish real integration from declared intent

### Option 2: Fully externalize where the local code is only indirection

Pros:

- strongest consistency between dependency list and runtime behavior
- smallest long-term audit and maintenance surface
- cleanest CI policy

Cons:

- higher one-time code churn
- requires care around module boundaries and test-support code

### Option 3: Full subsystem replacement, including domain ownership adapters

Pros:

- maximum standardization

Cons:

- changes value ownership, persistence, and product policy surfaces
- much larger regression and schedule risk
- not justified by current evidence

## E) Decision matrix

Weights:

- correctness / truthful integration state: 30
- regression risk: 20
- maintainability: 20
- security posture: 15
- migration effort: 15

| Option | Correctness | Risk | Maintainability | Security | Effort | Weighted total |
|---|---:|---:|---:|---:|---:|---:|
| Keep selective wrappers | 2 | 4 | 2 | 3 | 5 | 2.95 |
| Externalize thin layers, keep intentional adapters | 5 | 4 | 5 | 5 | 4 | 4.65 |
| Full subsystem replacement | 5 | 1 | 4 | 4 | 1 | 3.10 |

Sensitivity notes:

- If migration effort is weighted more heavily, the chosen option still wins because the removals were low-risk and compile-tested.
- If correctness weight is reduced sharply, the chosen option still wins because CI governance and unused-dependency removal materially improve maintainability and security.

## F) Risks & mitigations

1. Risk: MFA support helpers leak back into runtime code.
   Mitigation: CI now forbids `@import("mfa")` in `src/` outside the explicit test-support export in `src/lib.zig`.

2. Risk: removed wrapper files get reintroduced.
   Mitigation: CI now checks that deleted compatibility files stay deleted.

3. Risk: future top-level dependencies are added without direct consumers.
   Mitigation: CI audits `build.zig.zon` against expected evidence and explicit transitive-only exceptions.

4. Risk: ownership adapters such as `src/types/url.zig` are mistaken for unfinished migrations.
   Mitigation: ADR now distinguishes intentional product adapters from compatibility wrappers.

## G) Recommendation & roadmap + verification plan

Recommendation:

- Keep the current closure set.
- Continue using the stronger rule: externalize by default, keep local code only when it owns product-specific state, policy, or persistence.

No-regrets follow-up work:

1. If `uri` or `toml` ever gain direct product-level use, move them from transitive-only to direct and add explicit evidence.
2. If `src/types/url.zig` stops needing owned slices, migrate call sites to `advanced_types.Url`/`Domain` directly.
3. If `src/keys/manager.zig` helpers shrink further, split env-key loading from rewrap operations and reduce the surface again.

Verification plan:

1. `zig build`
2. `zig build test`
3. `python3 scripts/verify_dependency_integrations.py`
4. Keep `verify-fast` and `verify-all` green in CI

## H) Evidence appendix

Commands run:

```bash
git rev-parse HEAD
zig version
zig build
zig build test
python3 scripts/verify_dependency_integrations.py
rg -n '@import\("mfa"\)|mfa_stub|@import\("index/hnsw\.zig"\)|@import\("index/rtree\.zig"\)|@import\("distributed/raft\.zig"\)' src tests
```

Observed results:

- `git rev-parse HEAD` -> `966a9f1fa46fc087c955a7d19cf61673a140997f`
- `zig version` -> `0.15.1`
- `zig build` -> passed
- `zig build test` -> passed
- `python3 scripts/verify_dependency_integrations.py` -> passed
- runtime-only banned imports reduced to zero; only test-support `@import("mfa")` remained

Artifacts added:

- `scripts/verify_dependency_integrations.py`
- updated `docs/TAR_BUILD_ZIG_ZON_LIBRARY_INTEGRATIONS_2026-04-01.md`
- updated `docs/architecture/ADR_build_zig_zon_library_integration_governance.md`

## I) Open questions / follow-ups

1. Should `uri` stay top-level, or should it be pulled only through `json` once the build graph is simplified further?
2. Should `toml` stay top-level, or should Geode rely entirely on `config` for TOML reachability?
3. If Geode eventually changes URL/Domain storage ownership, should `src/types/url.zig` be retired in favor of direct `advanced_types_lib` values?
