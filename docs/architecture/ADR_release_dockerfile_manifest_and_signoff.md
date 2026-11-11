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

## Amendment: runtime compatibility gate (SONNY-4884)

The GPU release image shipped on a CUDA Ubuntu 22.04 base (glibc 2.35) that
could not load the `x86_64-linux-gnu` release binary (GLIBC_2.36), and nothing
in the image build ran the binary. Two guards now apply:

- `release_binary.glibc_required` in the manifest records the release
  binary's glibc requirement. `tools/release_dockerfile_manifest.py` refuses
  (`sync`, `check`, `signoff`) any apt release base whose glibc is lower, or
  whose distro release is not in `BASE_IMAGE_PROFILES`. It also requires the
  OpenSSL 3 package name that distro uses (`libssl3t64` on Ubuntu 24.04 and
  Debian trixie).
- Every generated release Dockerfile runs `RUN ["/usr/local/bin/geode",
  "--version"]` after `USER`. If the loader rejects the copied binary, the
  image build fails. This check is authoritative: if it trips, raise
  `glibc_required` or move the base. The manual `Dockerfile.release.fips`
  carries the same step by hand.
- Regression: `tests/test_sonny4884_release_image_runtime_compat.py` (run in
  `governance-release-manifests` and `make docker-release-check`).

## Amendment: manual FIPS runtime gate (SONNY-4885)

`Dockerfile.release.fips` ran on bookworm (glibc 2.36), but the OpenSSL 3.6.2
provider tree it copies from `zig-fips:0.16.0` needs GLIBC_2.38, so the image
could not load its FIPS provider. The `geode --version` step did not catch
this, because `--version` never loads a provider. The FIPS runtime is now
`debian:trixie-slim` with `libssl3t64`, and two more checks apply:

- A manual manifest entry may record `glibc_required` and
  `openssl_provider_tree`. `manual_runtime_compat_errors()` reads the final
  `FROM` of the Dockerfile on disk and refuses a base whose glibc is lower or
  unknown, or the wrong OpenSSL 3 package name for its distro. With a provider
  tree, it also requires a `RUN` step after a non-root `USER` that runs
  `<tree>/bin/openssl list -providers` and checks that base and fips are
  active.
- That step is the authoritative gate. A loader failure exits non-zero. A
  failed FIPS self-test leaves `openssl list` exiting 0 with no fips provider
  listed, which is why the step checks for `status: active`.
- Regression: `tests/test_sonny4885_fips_release_runtime_compat.py` (same CI
  job and Make target).
