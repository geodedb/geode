**Agent Task — Graph DB Alpha: Spec Compliance & Gap Closure**

**Goal.** Review the current implementation at **<TEMPLATE>** against the spec at @./specs/<TEMPLATE>. Produce an enterprise‑grade, secure, high‑performance graph database. This is alpha; **breaking changes are allowed**. If something's wrong, **fix it**. **Do not add legacy workarounds.**

**Inputs.**

* Implementation: <TEMPLATE>, default branch `main`.
* Spec: @./specs/<TEMPLATE>.
* Performance targets: >10000 ops/s for CRUD/traversals; latency P95/P99.
* Security baseline: (e.g., authN/Z, encryption in transit/at rest, auditability).
* Platform/constraints: Zig 0.15.2, Linux | Mac | Windows, x86_64 | ARM64 | RISC-V.

**Deliverables.**

1. `GAP_REGISTER.md` (canonical tracker).
2. Code changes (PRs/patches) that close gaps; updated tests/benchmarks/docs.
3. `CHANGELOG.md` (highlight **breaking changes**), `MIGRATION_GUIDE.md` (if APIs change).
4. `BENCHMARK_REPORT.md` (methodology + results), `SECURITY_NOTES.md` (threats & controls).
5. `ADRs/` for any spec deviations or architectural decisions.

**Gap Register schema (use this exact table header).**
`ID | Title | Type[perf|correctness|security|api|ops|docs] | Spec Ref | Evidence/Link | Severity[P0..P2] | Fix Plan | Owner | Status[Open|In‑Progress|Blocked|Closed] | PR/Commit | Notes`

**Operating principles.**

* Favor **correctness, simplicity, and performance** over backward compatibility.
* **Break contracts** if needed; remove dead code; **no shims**.
* Every fix includes: tests (unit/integration), benchmarks, docs, and an ADR if the spec changes.

**Method (iterate until all gaps are Closed).**

1. **Analyze:** Map implementation → spec. Identify bottlenecks, errors, omissions, security issues, API inconsistencies, ops gaps (observability, config, backup/restore).
2. **Record:** Populate `GAP_REGISTER.md` with clear evidence and severity (P0=release‑blocking).
3. **Plan:** Prioritize P0/P1; draft a short Fix Plan per gap.
4. **Implement:** Make minimally sufficient changes; remove workarounds; refactor as needed.
5. **Validate:**

   * **Correctness:** All tests green; add missing coverage.
   * **Performance:** Add/extend benchmarks (e.g., micro: core storage/index/GC; macro: traversal/path queries; optionally LDBC SNB‑style workloads). Show before/after.
   * **Security:** Apply baseline controls (authN/Z paths, input validation, encryption, secrets handling, audit logs).
   * **Ops:** Health checks, metrics, structured logs, safe config, graceful shutdown, recovery tests.
6. **Close:** Link PRs/commits in the register; update CHANGELOG/MIGRATION_GUIDE; move status to Closed.
7. **Repeat** until no Open gaps remain.

**Acceptance criteria (stop conditions).**

* 100% spec coverage or explicit ADR exceptions.
* All **P0/P1 gaps Closed**; no critical static‑analysis/security findings.
* Benchmarks meet or exceed 10000 ops/s for CRUD/traversals; latency P95/P99 with methodology documented.
* Docs (README/CHANGELOG/MIGRATION_GUIDE) reflect final behavior and breaking changes.

**Output format for each iteration (append to `PROGRESS_LOG.md`).**
`Iteration N — Date | Summary of new gaps | Gaps closed (IDs) | Key code changes (links) | Test/bench highlights | Perf deltas | Security/ops notes | Risk/next steps`

**Constraints.**

* No TODO placeholders for critical paths—implement now or file as P0/P1.
* Keep commits and PRs small, atomic, and well‑described.
* Prefer removing complexity over adding configuration.
