# Quality Gap Analysis

Last updated: 2026-06-11

This file now contains only open/deferred quality gaps. Historical quality findings live in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Open / Deferred Findings

| ID / Issue | Severity | Area | Finding | Status |
|---|---|---|---|---|
| #474 | High | CLI architecture | `cli/main.zig` is monolithic and high-churn; command parsing/transport/auth flows need phased extraction. | Blocked / design required |
| #520 | High | Core architecture | Mutable singleton/global-state reliance across core modules. | Blocked / context-threading design required |
| #515 | High | Transport parity | gRPC transport missing message types present in QUIC handler. | Blocked / feature sprint |
| #462 | High | Storage architecture | `GraphStore` remains a god object with many responsibilities. | Blocked / extraction plan |
| #409 | High | Query eval | Large `evalExpr` switch needs family-specific dispatch/extraction. | Blocked / design required |
| #405 | High | API shape | Functions with excessive parameters need context structs. | Blocked / high-risk migration |
| #521 | High | CLI parsing | CLI argument parsing duplicated across call sites. | Blocked / parser design required |
| #719 / #804 | High | Execution maintainability | `executeMatchQueryImpl` and sibling match functions remain too large. | Open / deferred |
| #721 | High | Error handling | 653 `catch {}` sites, including CLI/transport hot paths, need categorization and policy. | Open / deferred |
| #556 / #809 / #810 | Medium | Error handling | Surviving `catch unreachable` and `unreachable` hot-path sites need invariant audit or error-union rewrites. | Open |
| #725 | Medium | Tooling/docs CI | Ruff, shellcheck, and markdownlint debt remains. | Open |
| #736 / #815 | Medium | Concurrency | Lock-tier discipline and QUIC lock TODOs need enforcement/design. | Open |
| #730 | Medium | Governance tooling | CANARY parser/generator regex coverage needs golden tests. | Open / partial |
| #733 | Medium | Tests | Parser, match, and execution hot paths need inline/unit test backfill. | Open |
| #806 | Medium | LSP maintainability | `features.zig` aggregates all LSP handlers in one large file. | Open |
| Q9/Q13/Q15/Q17/Q18/Q19 | Medium/Low | Migration quality residuals | Migration monolith, API contract, docs, and ownership residuals remain from the re-audit. | Open |
