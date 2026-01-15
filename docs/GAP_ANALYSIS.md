# Gap Analysis
## Gaps

### GAP-0193: Governance policy target for 0 STUB/IMPL residuals not met
- **GitLab issue:** https://gitlab.com/devnw/geode/geode/-/issues/322
- **Category:** Code Quality
- **Severity:** Medium
- **Requirement source:** https://gitlab.com/devnw/geode/geode/-/issues/263; https://gitlab.com/devnw/geode/geode/-/issues/293; docs/GOVERNANCE.md:173
- **Current state (evidence):**
  - docs/GOVERNANCE.md:173 — policy targets 0 STUB / 0 IMPL residuals.
  - docs/status.csv:1649 — REQ-GQL-TDE-OVERHEAD-001 is still marked STUB.
  - rg -n ",IMPL," docs/status.csv | wc -l — 1221
- **Why this is a gap:** Governance policy states zero STUB/IMPL residuals, but the status ledger still contains both.
- **Impact/Risk:** Governance evidence completeness is violated; compliance reporting may be inaccurate.
- **Recommended fix:** Promote IMPL/STUB entries to TESTED/BENCHED or document approved exceptions; update status.csv and governance checks.
- **Acceptance criteria:** docs/status.csv has zero STUB/IMPL entries (or policy updated with explicit exceptions) and governance checks reflect the change.
