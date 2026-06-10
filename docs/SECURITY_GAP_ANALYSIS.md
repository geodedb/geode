# Security Gap Analysis

Last updated: 2026-06-10

This file now contains only open/deferred security gaps. Historical and not-a-gap security findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| ID | Severity | Risk | Finding | Component | Issue | Status |
|---|---|---:|---|---|---|---|
| SEC-SUPPLY-01 | Medium | 32 | Single-signer supply-chain for pinned `devnw/zig/*` modules; add 2-reviewer rule on `build.zig.zon`. | supply chain | #822 | Open |
| SEC-SESS-LOG-01 | Low | 16 | Session token printed to stderr after `session rotate`. | `src/cli/session_cli.zig:569-570` | #820 | Open |
| SEC-S3-SIGV2-01 | Low | 8 | S3 backup signing still needs SigV4 migration/hardening. | `src/storage/s3_backup.zig:351-356` | #824 | Open |
| SEC-MFA-FIPS-01 | Info | 4 | TOTP HMAC-SHA1 only; add SHA-256/SHA-512 for FIPS-mode customers. | `src/security/mfa_risk.zig` | #821 | Backlog |
| SEC-INFRA-03 | Medium | 15 | Cluster token is a single shared bearer secret with no rotation. | `src/distributed/cluster_auth.zig:17-56` | #743 | Open / deferred |
| SEC-CLI-01 | Low | 6 | `--insecure-tls-skip-verify` remains available in release CLI paths. | `src/cli/main.zig`; `src/cli/cli_dispatcher.zig` | #744 | Open / deferred |
| SEC-MON-01 | Low | 6 | Metrics endpoint auth remains a timing-oracle concern when re-implemented/exposed. | `src/monitoring/metrics_server.zig` | #674 | Open / deferred |
| SEC-INFRA-02 | Medium | 2 | nginx h2c residual on Grafana vhost. | `config/nginx/conf.d/geode.conf` | #740 | Open / deferred |
| SEC-MIG-02 | Medium | 32 | No CI migration guard for `.gql` migration files. | `.gitlab-ci.yml` | n/a | Open; mirrored in GAP-0882 |
| LSP-SEC-002 | Medium | 32 | Vendored `mcp` bearer compare (`checkAuth`, `std.mem.eql`) is not constant-time; no override hook in the pinned package, so the fix needs an upstream patch + fork pin. Mitigated at the geode boundary 2026-06-10 (commit `2b03d9ad`): geode-owned token compares audited constant-time (auth_lib api_keys SHA-256+`timing_safe.eql`; `src/security/authn.zig:526`), HTTP `http_bind` defaults to loopback and the CLI never exposes it (pinned by `zig build test-gap0885-lsp`), stdio never reaches `checkAuth`. | vendored MCP/LSP package | #785 | Open — mitigated/documented; fork-pin follow-up |
| GAP-0818 enforcement gate | Critical-latent | n/a | MCP-LSP RLS pre-condition is documented; enforcement remains tracked forward. | `docs/MCP_LSP_BRIDGE.md` / bridge execution | #795 | Open forward-looking gate |
