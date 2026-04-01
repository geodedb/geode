# Security Gap Analysis -- Migration Engine Audit

Last updated: 2026-04-01
Scope: `src/migration/mod.zig`, `src/cli/backup_cli.zig`
Audited by: Claude Opus 4.6 (adversarial security review)

## Summary

- **Total findings:** 13
- **Critical:** 0
- **High:** 4 -- 2 closed, 2 won't do
- **Medium:** 5 -- 3 closed, 2 won't do
- **Low:** 4 -- 2 closed, 2 won't do
- **Closed / Implemented:** 7
- **Won't Do:** 4 (unsigned ledger, weak checksum, GQL injection, missing authz, password exposure)
- **Won't Do + CLI backlog:** 2 (password exposure, GQL injection sandbox)
- **Open:** 0
- **Confidential issues:** 2 (#592, #598)

### Top 5 Risks

| Rank | Risk Score | Finding | Issue |
|------|-----------|---------|-------|
| 1 | 64 | Path traversal in applyUpMigrations (CWE-22) | [#572](https://gitlab.com/devnw/codepros/geode/geode/-/issues/572) |
| 2 | 64 | Unsigned ledger file -- full state forgery (CWE-345) | [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573) |
| 3 | 64 | GQL injection via migration file content (CWE-94) | [#598](https://gitlab.com/devnw/codepros/geode/geode/-/issues/598) (confidential) |
| 4 | 48 | JSON injection via unescaped row.name (CWE-74/116) | [#592](https://gitlab.com/devnw/codepros/geode/geode/-/issues/592) (confidential) |
| 5 | 36 | TOCTOU race in global migration lock (CWE-362/367) | [#606](https://gitlab.com/devnw/codepros/geode/geode/-/issues/606) |

### Critical Attack Chain

Ledger tampering (#573) -> injected name with `../` -> `applyDownMigrations` constructs `{name}.down.gql` -> `joinPath` joins unsanitized name (#572) -> `readFileAlloc` reads arbitrary file (8MB) -> content passed to `executor.execFn` = arbitrary GQL injection (#598). Combined effect: **full database compromise from filesystem write access to migrations dir**.

**Deployment model:** CLI tool requiring local shell access. Risk is significantly amplified in CI/CD pipelines and shared development environments where the migrations directory is writable by build processes.

## Stack-Ranked Findings Table

| Rank | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence (file:line) | Issue URL | Fix | Owner | Due | Status |
|------|----------|-----------|---------|-----------|-----------|---------------------|-----------|-----|-------|-----|--------|
| 1 | HIGH | 64 | Path traversal in applyUpMigrations | migration | CWE-22 / A01:2021 | mod.zig:273-274, 346 | [#572](https://gitlab.com/devnw/codepros/geode/geode/-/issues/572) | GAP-0285: name sanitization rejects `../`, `/`, `\`. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 2 | HIGH | 64 | Unsigned ledger file | migration | CWE-345 / A08:2021 | mod.zig:165-200, 235-255 | [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573) | GAP-0286: too invasive, needs separate sprint with migration path design | migration | -- | Won't Do |
| 3 | HIGH | 64 | GQL injection via migration file content | migration | CWE-94 / A03:2021 | mod.zig:348-351 | [#598](https://gitlab.com/devnw/codepros/geode/geode/-/issues/598) | SEC-598: needs DDL sandbox architecture | migration | -- | Won't Do |
| 4 | HIGH | 48 | JSON injection via unescaped row.name | migration | CWE-74, CWE-116 / A03:2021 | mod.zig:214-215 | [#592](https://gitlab.com/devnw/codepros/geode/geode/-/issues/592) | GAP-0287: std.json.stringify. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 5 | MEDIUM | 36 | TOCTOU race in global lock | migration | CWE-362, CWE-367 / A04:2021 | mod.zig:279-311 | [#606](https://gitlab.com/devnw/codepros/geode/geode/-/issues/606) | GAP-0293: std.Thread.Mutex. Commit 0d39cd15. | migration | -- | Closed / Implemented |
| 6 | MEDIUM | 36 | CLI path traversal in cmdMigrateCreate | cli | CWE-22 / A01:2021 | backup_cli.zig:1309-1351 | [#614](https://gitlab.com/devnw/codepros/geode/geode/-/issues/614) | GAP-0301: name sanitization. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 7 | MEDIUM | 36 | No authorization enforcement | migration | CWE-862 / A01:2021 | mod.zig (entire module) | [#617](https://gitlab.com/devnw/codepros/geode/geode/-/issues/617) | GAP-0300: needs architectural decision on auth boundary | migration | -- | Won't Do |
| 8 | MEDIUM | 24 | Integer overflow in statusReport version parsing | migration | CWE-190 / A04:2021 | mod.zig:449-452 | [#602](https://gitlab.com/devnw/codepros/geode/geode/-/issues/602) | GAP-0292: shared parseVersion with overflow guard. Commit c49dc110. | migration | -- | Closed / Implemented |
| 9 | MEDIUM | 24 | Weak checksum (28-bit FNV-1a prefix) | migration | CWE-328 / A02:2021 | mod.zig:110-127, 534 | [#612](https://gitlab.com/devnw/codepros/geode/geode/-/issues/612) | GAP-0294: breaking change, needs versioned ledger format | migration | -- | Won't Do |
| 10 | LOW | 16 | Resume slots silent overwrite + undefined memory | migration | CWE-908 | mod.zig:603-614 | [#620](https://gitlab.com/devnw/codepros/geode/geode/-/issues/620) | GAP-0289/0303: alloc.dupe + error on full. Commit 7c545694. | migration | -- | Closed / Implemented |
| 11 | LOW | 16 | --password visible in process listing | cli | CWE-214 / A07:2021 | backup_cli.zig:1186-1192 | [#627](https://gitlab.com/devnw/codepros/geode/geode/-/issues/627) | SEC-627: CLI backlog item | migration | -- | Won't Do |
| 12 | LOW | 12 | Ledger use_last enables stealthy field override | migration | CWE-345 / A08:2021 | mod.zig:178 | [#622](https://gitlab.com/devnw/codepros/geode/geode/-/issues/622) | SEC-622: parse option changed to error. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 13 | LOW | 8 | Global policy_mode unsynchronized | migration | CWE-362 | mod.zig:491 | [#625](https://gitlab.com/devnw/codepros/geode/geode/-/issues/625) | GAP-0302: std.atomic.Value. Commit 0d39cd15. | migration | -- | Closed / Implemented |

## Findings by Area

### Input Validation / Path Traversal

- **#572** (HIGH/64): `applyUpMigrations` joins user-supplied names via `std.fs.path.join` with no `..` sanitization
- **#614** (MEDIUM/36): `cmdMigrateCreate` takes migration name from CLI args without sanitization
- **#602** (MEDIUM/24): `statusReport` version parsing has no integer overflow guard

### Data Integrity

- **#573** (HIGH/64): Ledger JSON has no HMAC/signature -- full state forgery from filesystem write
- **#592** (HIGH/48): `writeLedgerJson` does not escape `row.name` -- JSON injection
- **#612** (MEDIUM/24): 28-bit FNV-1a prefix with `startsWith` matching -- weak integrity check
- **#622** (LOW/12): `use_last` duplicate field behavior enables stealthy field override

### Injection

- **#598** (HIGH/64): Migration file content (up to 8MB) passed verbatim to `executor.execFn` as GQL

### Access Control

- **#617** (MEDIUM/36): No authorization checks in migration module -- any caller can run migrations
- **#606** (MEDIUM/36): Global lock has TOCTOU race -- concurrent migration execution possible

### Operations / Hardening

- **#627** (LOW/16): `--password` CLI argument visible in process listing
- **#620** (LOW/16): Resume slots use `undefined` memory and silently overwrite when full
- **#625** (LOW/8): `policy_mode` global variable has no synchronization

## Roadmap

### Quick Wins (< 1 day each)

| Finding | Fix | Issue |
|---------|-----|-------|
| Path traversal in names | Add `containsAny(name, "../\\")` reject | #572 |
| JSON injection in writeLedgerJson | Escape `"`, `\`, control chars in `row.name` | #592 |
| Integer overflow in statusReport | Add `if (j > 17) break;` guard | #602 |
| CLI path traversal | Validate `[a-zA-Z0-9_-]` pattern | #614 |
| use_last -> error | Change parse option | #622 |
| policy_mode sync | Use `std.atomic.Value` | #625 |
| Resume slots init | Change `= undefined` to `= std.mem.zeroes(...)` | #620 |

### Medium (1-5 days each)

| Finding | Fix | Issue |
|---------|-----|-------|
| Unsigned ledger | HMAC-sign using existing key infra; verify on read | #573 |
| Weak checksum | Replace FNV-1a prefix with SHA-256; exact match | #612 |
| TOCTOU lock race | Add mutex; wire lock into apply functions | #606 |
| --password exposure | Add GEODE_PASSWORD env var + --password-file | #627 |

### Strategic (> 5 days)

| Finding | Fix | Issue |
|---------|-----|-------|
| GQL injection via file content | Restricted query executor for migrations (DDL-only sandbox) | #598 |
| Missing authorization | Auth context threading through migration API + role checks | #617 |

## Blockers and Unknowns

1. **GQL injection (#598):** Confirming whether the QueryExecutor can be sandboxed to DDL-only requires understanding the full query execution path. A simpler alternative is requiring signed migration files.

2. **Authorization (#617):** The migration module is a standalone library -- threading auth context requires API changes to all public functions. Need to decide: auth at module boundary vs. auth at CLI boundary only.

3. **Unsigned ledger (#573):** Migration path for existing unsigned ledgers needs design -- reject-and-require-re-init vs. auto-sign-on-first-read.

### What Would Confirm Suspected Issues

- **#622 (use_last override):** Craft a ledger JSON with duplicate `version` keys and verify the parser accepts the last value silently. (Confidence: suspected -> would confirm with test)
- **#625 (policy_mode race):** Run concurrent `enforcePolicy("STRICT")` and `isStrictPolicy()` calls across threads. (Confidence: suspected -- Zig's memory model may make this benign on x86, but UB per spec)
