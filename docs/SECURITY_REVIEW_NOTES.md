# Security Review Notes

Last updated: 2026-02-16
Repository: `/home/benji/src/devnw/codepros/geode/geode`
Scope: Security + delivery pipeline review (app, deps, CI/CD, containers, scripts, docs)

## Tool Availability + Versions

| Tool | Path | Version/Status |
|---|---|---|
| gitleaks | `/usr/bin/gitleaks` | version is set by build process |
| trufflehog | `/usr/local/bin/trufflehog` | 3.92.5 |
| osv-scanner | `/usr/local/bin/osv-scanner` | 2.3.2 |
| trivy | `/home/benji/.local/bin/trivy` | 0.69.0 |
| grype | `/home/benji/.local/bin/grype` | 0.107.0 |
| syft | `/home/benji/.local/bin/syft` | 1.41.1 |
| semgrep | `/home/benji/.local/bin/semgrep` | 1.150.0 |
| bandit | `/home/benji/.local/bin/bandit` | 1.9.3 |
| shellcheck | `/home/benji/.local/bin/shellcheck` | 0.9.0 |
| hadolint | `/home/benji/.local/bin/hadolint` | 2.14.0 |
| checkov | `/home/benji/.local/bin/checkov` | 3.2.499 |
| safety | `/home/benji/.local/bin/safety` | 3.7.0 |
| cargo/cargo-audit | `/home/benji/.cargo/bin/cargo` | cargo 1.91.1 (no `Cargo.lock` for audit) |
| govulncheck | `/home/benji/go/bin/govulncheck` | v1.1.4 |
| snyk | `/home/benji/.config/nvm/versions/node/v24.11.1/bin/snyk` | 1.1302.1 (not authenticated) |
| yq | missing | not installed |

## Scan Execution Ledger

- `gitleaks detect --source . --redact --report-format json --report-path /tmp/gitleaks.json` -> exit 1
- `trufflehog git file://$PWD --json > /tmp/trufflehog.json` -> exit 1
- `syft dir:. -o cyclonedx-json=/tmp/sbom.cdx.json` -> exit 0
- `grype sbom:/tmp/sbom.cdx.json -o json > /tmp/grype.json` -> exit 0
- `osv-scanner scan --recursive . --format json > /tmp/osv.json` -> exit 1
- `trivy fs . --format json -o /tmp/trivy-fs.json` -> exit 0
- `trivy config . --format json -o /tmp/trivy-config.json` -> exit 0
- `semgrep scan --config auto --metrics=off --json -o /tmp/semgrep.json` -> exit 2 (fallback used)
- `semgrep scan --config p/default --metrics=off --json -o /tmp/semgrep-default.json` -> exit 0
- `bandit -r . -f json -o /tmp/bandit.json` -> exit 1
- `git ls-files '*.sh' | xargs -r shellcheck -x` -> exit 123
- `git ls-files '*Dockerfile*' | xargs -r hadolint` -> exit 123
- `checkov -d . -o json > /tmp/checkov.json` -> exit 1
- `safety scan --json > /tmp/safety.json` -> exit 1 (fallback used)
- `safety check --full-report -r requirements.txt > /tmp/safety.txt` -> exit 2
- `cargo audit --json > /tmp/cargo-audit.json` -> exit 2 (no lockfile)
- `govulncheck -json ./... > /tmp/govulncheck.json` -> exit 1 (workspace/package layout limitations)
- `snyk test --all-projects --json > /tmp/snyk.json` -> skipped (unauthenticated)

## Output Artifacts

- `/tmp/security_tool_versions.txt`
- `/tmp/security_scan_status.txt`
- `/tmp/gitleaks.json`
- `/tmp/trufflehog.json`
- `/tmp/sbom.cdx.json`
- `/tmp/grype.json`
- `/tmp/osv.json`
- `/tmp/trivy-fs.json`
- `/tmp/trivy-config.json`
- `/tmp/semgrep-default.json`
- `/tmp/bandit.json`
- `/tmp/shellcheck.txt`
- `/tmp/hadolint.txt`
- `/tmp/checkov.json`
- `/tmp/safety.json`
- `/tmp/safety.txt`
- `/tmp/cargo-audit.json`
- `/tmp/govulncheck.json`
- `/tmp/snyk-whoami.txt`

## Notes

- Semgrep telemetry disabled (`--metrics=off`).
- Snyk execution was blocked by missing local auth session.
- Findings were manually validated in first-party source before issue updates/creation.
