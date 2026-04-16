# Geode Security Audit — Phase 2 Scan

**Root:** `/home/benji/src/devnw/codepros/geode/geode` **Date:** 2026-04-16

## Tools Ran

semgrep (387 rules / 1,157 files, 10 findings). Missing: gitleaks, trufflehog, trivy, grype, syft, osv-scanner, bandit, shellcheck, hadolint, checkov. Fallback: `git ls-files` + 2,620-commit grep.

## Findings

### HIGH

**H1. RLS bytecode VM unbounded stack** `confidence::confirmed`
`src/security/rls_core.zig:642-848`. `evaluateCompiledExpression` uses `var stack: [64]Value = undefined` and does `sp += 1` on every push (`push_const`, `push_true`, `load_row`, `load_user`, `load_session`) with NO `sp < 64` check — a compiled policy with 65+ pushes writes OOB into the caller frame inside the auth fast-path. Pops (`pop`, `eq`, `neq`) silently no-op on underflow instead of failing closed. Mitigated only because policies are manually pinned today (GAP-0510). Fix: `if (sp >= stack.len) return error.RLSStackOverflow` / underflow on every opcode.

**H2. `audit.jsonl` tracked in git history** `confidence::confirmed`
`git ls-files` shows `audit.jsonl` tracked (0 bytes; committed `c8b7c44f`). `.gitignore` now excludes it but history retains. Signing key `audit.jsonl.key` (0600) correctly untracked. Convention in `src/security/audit.zig:343-345` writes keys beside the log at repo root — recurrence one mistake away. Fix: `git rm --cached audit.jsonl`; move keys under `$GEODE_DATA_DIR/keys/` with `fchmod(0o600)`.

**H3. Audit verifier ignores `seq_no`** `confidence::suspected`
`src/cli/geode_audit_verify.zig:60-128` checks `prev_hash == last_hash` but never parses the record's `seq_no` against its running counter. Tail-insert with skipped `seq_no` (42 → 44) is not flagged. Fix: parse and assert strict monotonicity.

### MEDIUM

**M1. Vault CLI subprocess hardening incomplete** `confidence::confirmed`
`src/security/vault_kms_provider.zig:163,251,270` spawn `vault kv list/get/put` via `std.ChildProcess`. `validateKeyName` (`:38-47`) blocks argv injection per issue #435. Residual: `self.key_path` at `:163` is NOT validated (malicious `VAULT_KEY_PATH` env escapes); `env_map = &std.process.EnvMap.init(...)` at `:167` passes empty env so `VAULT_ADDR`/`VAULT_TOKEN` are NOT inherited — child likely cannot authenticate in prod today. Fix: validate `key_path`; explicitly populate `VAULT_*`.

**M2. RLS interpreter fallback on raw policy text** `confidence::suspected`
`src/security/rls_core.zig:631` — `expr.compiled == null` → `context_evaluator.evaluate(expr.raw, ...)`. Tests at `:2530-2903` feed strings like `"owner_id = 42"`, `"has_permission('admin_access')"` — an in-process string interpreter inside the auth boundary. Any write path that persists unparsed policy text is a code-execution surface until GAP-0510 lands. Fix: reject `raw != null and compiled == null` fail-closed.

**M3. Prometheus metrics lacks loopback enforcement** `confidence::confirmed`
`src/monitoring/metrics_server.zig:47-97` — handlers are Zig-0.16 stubs (`self.running=false`). `resolveMetricsBindAddress` at `:102` accepts any `GEODE_METRICS_BIND`. When re-wired, `0.0.0.0` with no auth is one env var away. Fix: require bearer/mTLS for non-loopback binds.

**M4. Blake2b legacy path does not force reset** `confidence::confirmed`
`src/security/geode_auth_lib.zig:1068-1092`. Uses `constantTimeEqual64` (good), but emits only an audit event on match — does NOT set `password_reset_required`. Accounts never re-authenticating keep the static-salted hash forever. Fix: set `password_reset_required=true` inside `verifyBlake2bLegacy` on match.

### LOW

**L1. `GEODE_CLUSTER_INSECURE=1` works in release** `confidence::confirmed`
`src/distributed/{federation.zig:309, query_transport.zig:542, cluster.zig:1236, twophase.zig:238,429, raft_consensus.zig:311}` — all WARN and call `connectInsecure`. No `builtin.mode` gate. Fix: require Debug build or signed op-ack.

**L2. Semgrep ERRORs in helper scripts** `confidence::confirmed`
`scripts/fuzz_go.py:10,31` and `scripts/tag.py:9` use `subprocess` with `shell=True` + tainted argv. CI-write pivot only. Fix: list-form argv.

**L3. Nginx `$http_host` reflection + h2c smuggling** `confidence::confirmed`
`config/nginx/conf.d/geode.conf:7,20,26,46,63,89`. Only live if bundled docker-compose nginx is deployed. Fix: pin `server_name`, explicit `proxy_set_header Host`.

**L4. `--insecure-tls-skip-verify` in release CLI** `confidence::confirmed`
`src/cli/main.zig:1054`, `src/cli/cli_dispatcher.zig:490`. Fix: refuse when `GEODE_ENV=production`.

### OK (spot-checked)

- gRPC plaintext fallback gated to `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK` AND `builtin.mode == .Debug`; release fails closed with `error.TlsRequired` (`src/transport/grpc_server.zig:144-150,620-662`).
- QUIC `allow_insecure` default `false` (`src/transport/quic.zig:172`); self-signed cert gen only on first start with missing certs (`:251-273`).
- Password verify uses `std.crypto.timing_safe.eql` (`src/security/geode_auth_lib.zig:1023-1031`); session token compare constant-time (`src/security/authn.zig:188-201`).
- Audit events SHA-256 chained; DIGESTs Ed25519-signed (`src/security/audit.zig:459-477`).

## Gaps & Blockers

No CVE/SBOM scan on 24 `build.zig.zon` deps (scanners missing). GAP-0510 parser→bytecode pipeline blocks live H1/M2 validation.
