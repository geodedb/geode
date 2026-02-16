# ADR: Release Dockerfile Manifest + Sign-Off Gate

- Status: Accepted
- Date: 2026-02-16
- Related: `#408`, `#524`

## Context

Release container definitions were split across `Dockerfile.release`, `Dockerfile.release.alpine`, and `Dockerfile.release.gpu` with repeated boilerplate and no single source of truth. This created drift risk between images and made release sign-off dependent on manual inspection.

## Decision

1. Introduce `release/dockerfile_manifest.json` as the single source of truth for release Dockerfile variants.
2. Generate and verify release Dockerfiles via `tools/release_dockerfile_manifest.py`.
3. Enforce manifest sync in CI with `governance-release-manifests` (`.gitlab-ci.yml`).
4. Require release-time Dockerfile sign-off by generating a SHA-256 attestation report in `build-release`:
   - `python3 tools/release_dockerfile_manifest.py signoff --manifest release/dockerfile_manifest.json --repo-root . --output /tmp/release-dockerfile-signoff.txt`

## Consequences

- Positive:
  - Docker release variants are deterministic and centrally managed.
  - Drift is merge-blocking in governance checks.
  - Release jobs emit a concrete sign-off artifact (hash attestation) before GoReleaser execution.
- Trade-offs:
  - Dockerfile edits must now go through the manifest + generator workflow.

## Operational Workflow

- Sync after manifest edits:
  - `python3 tools/release_dockerfile_manifest.py sync --manifest release/dockerfile_manifest.json --repo-root .`
- Validate locally/CI:
  - `python3 tools/release_dockerfile_manifest.py check --manifest release/dockerfile_manifest.json --repo-root .`
- Emit release sign-off report:
  - `python3 tools/release_dockerfile_manifest.py signoff --manifest release/dockerfile_manifest.json --repo-root . --output /tmp/release-dockerfile-signoff.txt`
