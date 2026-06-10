# Security Gap Analysis

Last updated: 2026-06-10

This file now contains only open/deferred security gaps. Historical and not-a-gap security findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| ID | Severity | Risk | Finding | Component | Issue | Status |
|---|---|---:|---|---|---|---|
| SEC-SUPPLY-01 | Medium | 32 | Single-signer supply-chain for pinned `devnw/zig/*` modules; add 2-reviewer rule on `build.zig.zon`. | supply chain | #822 | Open |
| SEC-SESS-LOG-01 | Low | 16 | Session token printed to stderr after `session rotate`. | `src/cli/session_cli.zig:569-570` | #820 | Open |
| SEC-LSP-BIND-01 | Low | 12 | Regression guard for `--lsp-bind-all`; ensure no future MR flips unauthenticated bind-all behavior. | `src/server/main.zig`; `src/cli/lsp/server.zig` | #823 | Open |
| SEC-S3-SIGV2-01 | Low | 8 | S3 backup signing still needs SigV4 migration/hardening. | `src/storage/s3_backup.zig:351-356` | #824 | Open |
| SEC-MFA-FIPS-01 | Info | 4 | TOTP HMAC-SHA1 only; add SHA-256/SHA-512 for FIPS-mode customers. | `src/security/mfa_risk.zig` | #821 | Backlog |
| SEC-INFRA-03 | Medium | 15 | Cluster token is a single shared bearer secret with no rotation. | `src/distributed/cluster_auth.zig:17-56` | #743 | Open / deferred |
| SEC-CLI-01 | Low | 6 | `--insecure-tls-skip-verify` remains available in release CLI paths. | `src/cli/main.zig`; `src/cli/cli_dispatcher.zig` | #744 | Open / deferred |
| SEC-MON-01 | Low | 6 | Metrics endpoint auth remains a timing-oracle concern when re-implemented/exposed. | `src/monitoring/metrics_server.zig` | #674 | Open / deferred |
| SEC-INFRA-02 | Medium | 2 | nginx h2c residual on Grafana vhost. | `config/nginx/conf.d/geode.conf` | #740 | Open / deferred |
| SEC-MIG-02 | Medium | 32 | No CI migration guard for `.gql` migration files. | `.gitlab-ci.yml` | n/a | Open; mirrored in GAP-0882 |
| LSP-SEC-002 | Medium | 32 | Vendored package constant-time compare needs vendored-patch story or fork pin. | vendored MCP/LSP package | #785 | Open |
| LSP-SEC-005 | Low | 8 | `publishDiagnostics` URI escaping hardening. | `src/cli/lsp` | #794 | Open |
| LSP-SEC-008 follow-up | Low | n/a | Hard-assert loopback when MCP/LSP auth mode is `.none`. | MCP/LSP bind config | n/a | Open / needs triage |
| GAP-0818 enforcement gate | Critical-latent | n/a | MCP-LSP RLS pre-condition is documented; enforcement remains tracked forward. | `docs/MCP_LSP_BRIDGE.md` / bridge execution | #795 | Open forward-looking gate |
