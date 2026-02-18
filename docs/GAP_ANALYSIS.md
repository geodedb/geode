# Security Gap Analysis

Last updated: 2026-02-17

## Summary

- Total findings: 16
- Closed: 15
- Blocked: 1
- Closed (Won't Do by policy): 2 (`#431`, `#432`)

## Policy Exceptions (Future Agents)

- CI/CD hash pinning and Docker tag pinning are intentionally handled by external release controls and platform governance; do not reopen unless platform policy changes.
- Pre-commit hook enforcement is intentionally handled outside this tracker (pre-commit.ci/server-side controls); do not treat as a missing security gap in this file.

## Stack-Ranked Findings

| Rank | Sev | Risk | Finding | Component | CWE/OWASP | Evidence(file:line) | Issue URL | Fix | Owner | Due | Status |
|---|---|---:|---|---|---|---|---|---|---|---|---|
| 1 | Critical | 80 | Deterministic AES-GCM nonce derivation in TDE file encryption (`confidence::confirmed`) | storage/crypto | CWE-323, OWASP A02 | `src/storage/tde_file_encryption.zig:86`<br>`src/security/test_tde_enforcement.zig:90` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/191> | Random nonce generation + nonce-randomization test | security/core | 2026-02-23 | Closed / Implemented |
| 2 | Critical | 80 | Auth/session secrets stored in `/tmp` and trusted by server auth paths (`confidence::confirmed`) | auth/session | CWE-256,CWE-732,CWE-922 | `src/security/auth_state.zig:24`<br>`src/cli/apikey_cli.zig`<br>`src/cli/session_cli.zig` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/480> | State moved to resolved user state dir (`GEODE_STATE_DIR`/XDG/Home), `0600` file mode | security | 2026-02-23 | Closed / Implemented |
| 3 | High | 64 | gRPC transport fails open to plaintext when TLS init fails (`confidence::confirmed`) | transport/gRPC | CWE-319,CWE-754 | `src/transport/grpc_server.zig:384` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/531> | Fail-closed default; debug-only explicit fallback gate | transport | 2026-03-18 | Closed / Implemented |
| 4 | High | 64 | Inter-node cluster links skip TLS certificate verification (`confidence::confirmed`) | distributed/cluster | CWE-295, OWASP A02 | `src/distributed/cluster.zig:961` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/226> | Secure default verification with optional explicit insecure override | distributed | 2026-03-18 | Closed / Implemented |
| 5 | High | 64 | Known CVEs in active Go dependencies (`confidence::confirmed`) | deps/go | OWASP A06,CWE-1104 | `go.mod` (`x/crypto v0.48.0`, `x/net v0.50.0`, `x/sys v0.41.0`) | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/491> | Upgraded vulnerable modules; refreshed `go.sum`/`vendor` | platform | 2026-03-18 | Closed / Implemented |
| 6 | Critical | 60 | CI executes remote GoReleaser bootstrap via `curl \| bash` (`confidence::confirmed`) | ci-cd/release | CWE-494, OWASP A08 | `.gitlab-ci.yml` snapshot/build-release install blocks | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/430> | Replaced with pinned tarball download + direct binary install | release-eng | 2026-02-23 | Closed / Implemented |
| 7 | Critical | 60 | Release artifacts unsigned and SBOM generation disabled (`confidence::confirmed`) | release pipeline | SLSA/OWASP A08 | `.goreleaser.yaml:697` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/483> | Requires platform signing/SBOM control-plane integration | release-eng | 2026-02-23 | Blocked (external signing/SBOM controls required) |
| 8 | Critical | 60 | Privileged dev container with Docker socket + host secret mounts (`confidence::confirmed`) | containers/dev env | CWE-250,CWE-269 | `docker-compose.dev.yml` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/485> | Removed `privileged`, Docker socket, and host SSH secret mount | dev-infra | 2026-02-23 | Closed / Implemented |
| 9 | High | 48 | Zig/toolchain download integrity bypass (`confidence::confirmed`) | build/supply chain | CWE-494 | `.gitlab-ci.yml`, `scripts/docker/install-zig.sh` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/431> | Migrated to zvm/`zig.sh` bootstrap; hash pinning tracked via external control | build-infra | 2026-03-18 | Closed (Won't Do: hash pinning via external controls) |
| 10 | High | 48 | gRPC session IDs are timestamp-derived and predictable (`confidence::confirmed`) | transport/session mgmt | CWE-330,CWE-384 | `src/transport/grpc_server.zig:64`<br>`src/server/quic_connection_handler.zig:597` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/532> | CSPRNG session IDs + jittered delay for invalid session probes | transport/security | 2026-03-18 | Closed / Implemented |
| 11 | High | 48 | Weak default credentials remain in compose fallbacks (`confidence::confirmed`) | deployment/compose | CWE-798, OWASP A07 | `docker-compose.yml`, `docker-compose.dev.yml`, `docker-compose.distributed.yml`, `docker-compose.example.yml` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/493> | Replaced weak fallback secrets with required env-variable injection | ops | 2026-03-18 | Closed / Implemented |
| 12 | High | 36 | Floating `latest` images in CI jobs (`confidence::confirmed`) | ci-cd/runtime | CWE-1104 | `.gitlab-ci.yml` image declarations | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/432> | Runtime pinning policy enforced outside repo-level controls | ci-maintainers | 2026-03-18 | Closed (Won't Do: docker tag pinning via external controls) |
| 13 | Medium | 36 | Release build depends on optional tests (`confidence::confirmed`) | ci-cd/release gating | OWASP CI hardening | `.gitlab-ci.yml` `needs` on release jobs | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/500> | Made required test/security dependencies mandatory | release-eng | 2026-05-17 | Closed / Implemented |
| 14 | Medium | 36 | No enforced security scanning stage in CI (`confidence::confirmed`) | ci-cd/security controls | OWASP A06/A08 | `.gitlab-ci.yml` `security` stage + jobs | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/495> | Added blocking secret and Trivy scans | ci-maintainers | 2026-05-17 | Closed / Implemented |
| 15 | Medium | 32 | Audit logging can be disabled in `ReleaseSafe` by env var (`confidence::confirmed`) | server/audit | CWE-693 | `src/server/main.zig:298` | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/498> | Restrict disable flag to Debug builds only | security/platform | 2026-05-17 | Closed / Implemented |
| 16 | Medium | 24 | Vendored grpc-zig test requirements pin vulnerable protobuf (`confidence::suspected`) | vendored deps | CWE-1104, OWASP A06 | CI grep audit found no active install path for affected files | <https://gitlab.com/devnw/codepros/geode/geode/-/issues/533> | Confirmed non-execution in active CI paths | deps-maintainers | 2026-05-17 | Closed / Implemented |

## Remaining Blockers

1. `#483` needs org-level signing/SBOM tooling enablement in release infrastructure (cosign identity policy, SBOM attestation policy, and CI secret/oidc wiring).
