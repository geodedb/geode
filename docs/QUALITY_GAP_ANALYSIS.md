# Quality Gap Analysis

Last updated: 2026-02-17

## Summary

- Total findings: 15
- Closed / Implemented: 15
- Blocked: 0
- Closed (Won't Do by policy): 0

All quality gaps in this tracker are now explicitly resolved as `Closed / Implemented` (or policy `Won't Do` where applicable).

## Policy Notes (Future Agents)

- CI/CD hash pinning and Docker tag pinning are governed by external platform controls (tracked in `docs/GAP_ANALYSIS.md`); do not reopen quality gaps for those controls unless org policy changes.
- Pre-commit hook enforcement is intentionally handled by external controls (pre-commit.ci and server-side policy). Do not reopen as a codebase quality gap unless those controls are removed.

## Stack-Ranked Findings

| Rank | Severity | PriorityScore | Category | Finding | Component | Evidence | GitLab Issue | Fix Summary | Owner | ETA/SLA | Status |
|---|---|---:|---|---|---|---|---|---|---|---|---|
| 1 | Critical | 100 | maintainability | `confidence::confirmed` giant execution function in hot path | Query execution | `tests/test_match_operations_parity_campaign.zig:95`; `tests/benchmark_match_operations_campaign.zig:96`; `.gitlab-ci.yml:143` | [#401](https://gitlab.com/devnw/codepros/geode/geode/-/issues/401) | Added staged parity + benchmark campaign (dedicated suites, build steps, and blocking governance gate) to safely decompose `match_operations` incrementally | core | 4-8w | Closed / Implemented |
| 2 | High | 80 | maintainability | `confidence::confirmed` production allocator policy violations | Transport/planner/security | `src/transport/grpc_tls.zig:31`; `src/planner/recursive.zig:839`; `src/security/user_management.zig:175`; `src/fle_integration.zig:193`; CI guard `/.gitlab-ci.yml:120` | [#522](https://gitlab.com/devnw/codepros/geode/geode/-/issues/522) | Replaced runtime `page_allocator` usage with explicit allocators and added blocking CI guard | core, transport, planner, security | 3-6w | Closed / Implemented |
| 3 | High | 80 | ci-cd | `confidence::confirmed` perf gate could pass without meaningful benchmark enforcement | CI quality gate | `/.gitlab-ci.yml:481`; `/.gitlab-ci.yml:498`; `/.gitlab-ci.yml:504`; `/.gitlab-ci.yml:516` | [#505](https://gitlab.com/devnw/codepros/geode/geode/-/issues/505) | Added benchmark regression signature checks + telemetry presence checks; job is merge-blocking | ci, perf | 2-4w | Closed / Implemented |
| 4 | High | 64 | maintainability | `confidence::confirmed` duplicated CLI transport result handling/formatting logic | CLI | `src/cli/transport_response.zig:25`; `src/cli/main.zig:2047`; `tests/test_cli_transport_response_parity.zig:30` | [#461](https://gitlab.com/devnw/codepros/geode/geode/-/issues/461) | Introduced shared transport-response renderer and parity golden tests (JSON/CSV/table) reused by both transport paths | cli | 3-6w | Closed / Implemented |
| 5 | High | 64 | perf | `confidence::confirmed` oversized Docker build context and non-minimal copy patterns | Containers/build | `/.dockerignore:4`; `/.dockerignore:8` | [#523](https://gitlab.com/devnw/codepros/geode/geode/-/issues/523) | Excluded `zig-out` by default; only allowlisted `zig-out/bin/geode` into context | infra | 1-3w | Closed / Implemented |
| 6 | High | 48 | ci-cd | `confidence::confirmed` non-blocking Windows quality path and unresolved POSIX coupling | Cross-platform CI/runtime | `.gitlab-ci.yml:497`; `.gitlab-ci.yml:519`; `.gitlab-ci.yml:178`; `tools/stdio_abstraction_guard.py:1`; `src/cli/main.zig:96` | [#348](https://gitlab.com/devnw/codepros/geode/geode/-/issues/348) | Windows CI path is now blocking with retry/timeout hardening; POSIX stdio access centralized with merge-blocking abstraction guard | ci, core | 3-6w | Closed / Implemented |
| 7 | High | 48 | ci-cd | `confidence::confirmed` external test harness dependency unpinned in CI | Compliance tests | `/.gitlab-ci.yml:53`; `/.gitlab-ci.yml:545`; `/.gitlab-ci.yml:593` | [#529](https://gitlab.com/devnw/codepros/geode/geode/-/issues/529) | Added pinned `GEODE_TEST_HARNESS_REF` and deterministic detached checkout in test jobs | ci, testing | 1-2w | Closed / Implemented |
| 8 | Medium | 48 | architecture | `confidence::confirmed` Docker definition sprawl and drift risk | Containers | `release/dockerfile_manifest.json:1`; `tools/release_dockerfile_manifest.py:1`; `.gitlab-ci.yml:193`; `docs/architecture/ADR_release_dockerfile_manifest_and_signoff.md:1` | [#408](https://gitlab.com/devnw/codepros/geode/geode/-/issues/408) | Added single Dockerfile manifest source, deterministic generator/check tooling, governance enforcement, and release sign-off report generation | infra | 3-6w | Closed / Implemented |
| 9 | Medium | 48 | ci-cd | `confidence::confirmed` duplicated release target metadata across CI and GoReleaser | Release pipeline | `release/target_manifest.json:1`; `.goreleaser.yaml:28`; `.gitlab-ci.yml:423`; `.gitlab-ci.yml:973`; `tools/release_target_manifest.py:95` | [#524](https://gitlab.com/devnw/codepros/geode/geode/-/issues/524) | Release targets/assets now come from one generated manifest consumed by CI cross-build, GoReleaser sync, and release asset publication | release, ci | 1-3w | Closed / Implemented |
| 10 | Medium | 48 | docs | `confidence::confirmed` `make test` scope mismatch in docs vs Makefile | Docs/dev workflow | `README.md:266`; `docs/QUICK_REFERENCE.md:43`; `Makefile:206`; `Makefile:220` | [#525](https://gitlab.com/devnw/codepros/geode/geode/-/issues/525) | Updated docs to reflect `make test` vs `make test-all` semantics | docs, core | 2-5d | Closed / Implemented |
| 11 | Medium | 48 | tests | `confidence::confirmed` copy-pasted REPL regression shell harnesses | Test scripts | Shared harness `tests/repl_regression_common.sh`; migrated `tests/repl_*_regression_test.sh`; no temp snippet usage (`rg -n "mktemp --suffix=.zig" tests/repl_*_regression_test.sh` => none) | [#526](https://gitlab.com/devnw/codepros/geode/geode/-/issues/526) | Centralized shell helpers and replaced ad-hoc temp Zig snippets with committed Zig test files/filters | repl, testing | 1-3w | Closed / Implemented |
| 12 | Medium | 48 | ci-cd | `confidence::confirmed` governance guard targets were stub/placeholder | Governance tooling | `scripts/trend_regression_guard.zig:38`; `scripts/slice_delta_guard.zig:24`; `Makefile:493` | [#527](https://gitlab.com/devnw/codepros/geode/geode/-/issues/527) | Replaced stubs with real policy evaluators and unit tests | tooling, ci | 1-2w | Closed / Implemented |
| 13 | Medium | 48 | ci-cd | `confidence::confirmed` global CI setup ran apt on all images and masked failures | CI config | Scoped apt only where needed (`/.gitlab-ci.yml:535`, `/.gitlab-ci.yml:583`) | [#528](https://gitlab.com/devnw/codepros/geode/geode/-/issues/528) | Removed global apt fallback behavior; kept package install in explicit Debian-based jobs | ci | 2-5d | Closed / Implemented |
| 14 | Medium | 48 | deps | `confidence::confirmed` stale/duplicate vendored package cache under `docker/zig-packages` | Container dependency cache | Added `tools/zig_package_cache_guard.py`; pruned stale cache dir `docker/zig-packages/N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o`; CI gate `/.gitlab-ci.yml` `governance-zig-package-cache` | [#508](https://gitlab.com/devnw/codepros/geode/geode/-/issues/508) | Added deterministic cache-closure guard and pruned unreachable stale entries | infra, deps | 1-2w | Closed / Implemented |
| 15 | Medium | 36 | deps | `confidence::confirmed` no deterministic local bootstrap for direct Ruff lint execution | Dev tooling | `Makefile:6`; `Makefile:493`; `Makefile:501` | [#530](https://gitlab.com/devnw/codepros/geode/geode/-/issues/530) | Added pinned ruff bootstrap venv and `make lint` workflow | tooling | 2-5d | Closed / Implemented |

## Findings by Category

- `maintainability`: `#401` (Closed), `#461` (Closed), `#522` (Closed)
- `ci-cd`: `#505` (Closed), `#348` (Closed), `#529` (Closed), `#524` (Closed), `#527` (Closed), `#528` (Closed)
- `perf`: `#523` (Closed)
- `architecture`: `#408` (Closed)
- `docs`: `#525` (Closed)
- `deps`: `#508` (Closed), `#530` (Closed)

## Blockers and Unblock Steps

None.

## Verification Executed for Closed Items

- `rg -n "std\.heap\.page_allocator" src --glob '!src/test*' --glob '!src/tests/**' --glob '!src/probe_*' --glob '!src/lib.zig'`
- `zig test scripts/trend_regression_guard.zig`
- `zig test scripts/slice_delta_guard.zig`
- `zig build test --summary all`
- `make test`
- `for s in tests/repl_*_regression_test.sh; do \"$s\"; done`
- `python3 tools/zig_package_cache_guard.py --strict-stale`
- `zig build test-match-parity --summary all`
- `GEODE_MATCH_BENCH_ENABLE=1 zig build test-match-bench --summary all`
- `zig build test-cli-transport-parity --summary all`
- `zig test tests/test_cross_platform_stdio.zig`
- `python3 tools/stdio_abstraction_guard.py --repo .`
- `python3 tools/release_target_manifest.py sync-goreleaser --manifest release/target_manifest.json --goreleaser .goreleaser.yaml --check`
- `python3 tools/release_dockerfile_manifest.py check --manifest release/dockerfile_manifest.json --repo-root .`
- `python3 tools/release_dockerfile_manifest.py signoff --manifest release/dockerfile_manifest.json --repo-root . --output /tmp/release-dockerfile-signoff.txt`
