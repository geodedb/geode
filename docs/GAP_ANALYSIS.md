# Gap Analysis

**Last Updated**: January 25, 2026
**Verified By**: Requirements-to-Unit-Test Gap Analysis Audit
**GitLab Source of Truth**: https://gitlab.com/devnw/codepros/geode/geode/-/issues?label_name=gap

## Summary

| Category | Open Gaps | Severity |
|----------|-----------|----------|
| Test | 1 | High |
| **Total Open Gaps** | **1** | |

## Gaps

### GAP-0242: Bug #365/#366 regression tests do not reproduce bug conditions

- **GitLab issue:** [#376](https://gitlab.com/devnw/codepros/geode/geode/-/issues/376)
- **Category:** Test
- **Severity:** High
- **Requirement source:**
  - Bug #365: https://gitlab.com/devnw/codepros/geode/geode/-/issues/365
  - Bug #366: https://gitlab.com/devnw/codepros/geode/geode/-/issues/366
- **Current state (evidence):**
  - `tests/test_syntax_validation.zig:58-73` — Tests parser directly with `Lexer.init()` + `Parser.init()`, not server
  - `grep -rn "MATCH (n RETURN" geodetestlab/specs/*.yml` — 0 matches; server path untested
  - `src/migration/mod.zig` tests — Tests parseVersion, checksumPrefix, etc.; not QUIC stream opening
  - `grep -rn "migrate.*run" tests/ geodetestlab/` — 0 matches for integration test
  - Bug #365 state: **open**; Bug #366 state: **open**
- **Why this is a gap:** Tests added for GAP-0233/0234 exercise module internals but don't reproduce bug-triggering conditions. Parser tests != server behavior; migration module tests != QUIC connection flow.
- **Impact/Risk:** High — Bugs may regress undetected; false confidence from tests that don't verify fixes.
- **Recommended fix:**
  1. Add geodetestlab spec sending `MATCH (n RETURN n` to server, expecting status 42000
  2. Add integration test running `geode migrate run` with QUIC server
- **Acceptance criteria:**
  1. geodetestlab spec exists with `stdin: "MATCH (n RETURN n"` and `geode_query.status_class: "42000"`
  2. Integration test spawns server, runs `geode migrate run`, verifies no segfault

---

## Test Coverage Summary

| Component | Source Files | Inline Tests | External Tests | Status |
|-----------|-------------|--------------|----------------|--------|
| CLI | 11 | 185 | 15+ | Excellent |
| Security | 28 | 97 | 30+ | Excellent |
| Types | 20 | 87+ | 20+ | Excellent |
| GQL Parser | 9 | 52 | 61 (test_syntax_validation.zig) | Excellent |
| Graph | 42 | 50 | 15+ | Good |
| Distributed | 19 | 47 | 25+ | Good |
| Storage | 25 | 30 | 15+ | Moderate |
| Monitoring | 6 | 19 | 5+ | Good |
| MVCC Advanced | 7 | 21 | 10+ | Good |
| Query/Runtime | 2+ | 14 | 10+ | Good |
| Containers | 2 | 13 | 5+ | Good |
| Type Promotion | 1 | 21 | 5+ | Good |
| CDC Core | 3 | 18 | 5+ | Good |

## Governance Status

| Status | Count | Percentage |
|--------|-------|------------|
| TESTED | 3,120 | 83.0% |
| EXEMPT | 400 | 10.6% |
| BENCHED | 219 | 5.8% |
| IMPL | 15 | 0.4% |
| COMPLETE | 4 | 0.1% |
| STUB | 0 | 0.0% |
| **Total** | **3,758** | |

Note: 15 remaining IMPL entries are in test files, CLI files, and build scripts - not core source code.

## CI Enforcement Status

| Gate | Status | Evidence |
|------|--------|----------|
| Unit tests block merge | ✅ Enforced | `.gitlab-ci.yml:259` - `allow_failure: false` |
| ReleaseSafe tests | ✅ Enforced | `.gitlab-ci.yml:288` - `allow_failure: false` |
| GQL compliance tests | ✅ Enforced | `.gitlab-ci.yml:336` - `allow_failure: false` |
| Comprehensive tests | ✅ Enforced | `.gitlab-ci.yml:381` - `allow_failure: false` |
| CANARY lint | ✅ Enforced | `.gitlab-ci.yml:140` - `allow_failure: false` |
| Canaryscan verify | ✅ Enforced | `.gitlab-ci.yml:172` - `allow_failure: false` |
| Conformance sync | ✅ Enforced | `.gitlab-ci.yml:242` - `allow_failure: false` |

### Justified allow_failure: true

| Job | Line | Justification |
|-----|------|---------------|
| zig-format | 13 | Formatting is advisory, not blocking |
| governance-canary-drift | 111 | Warning only, count check is informational |
| governance-req-doc-reports | 213 | Reports are informational, not blocking |
| snapshot | 442 | Snapshot builds for non-tag commits |
| test-nix-flake | 559 | Nix builds may fail due to external dependencies |

## Test System Inventory

### Framework
- **Language**: Zig 0.15.2
- **Unit Tests**: Inline `test "..."` blocks in source files
- **Integration Tests**: External test files in `tests/` directory
- **E2E Tests**: `geodetestlab/` spec files with `extended_test_runner.py`
- **CI Runner**: GitLab CI with custom Zig Docker image

### Commands
```bash
# Unit tests
zig build test --summary all

# GQL compliance
python3 scripts/test/extended_test_runner.py --specs geodetestlab/specs/geode_gql_compliance.yml

# Comprehensive
make geodetestlab-comprehensive
```

---

**Resolved gaps have been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).**

Recent resolutions (January 25, 2026):
- GAP-0225 through GAP-0241: All resolved with unit tests and GitLab issues closed
