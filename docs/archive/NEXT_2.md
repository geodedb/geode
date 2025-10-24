# NEXT.md - Development Roadmap

_Based on GAP_ANALYSIS.md findings - Last Updated: 2025-01-29_

## Priority 1: Address Staleness (Sprint 1-2)

### Slice 1.1: Re-validate Core Protocol Features
- **Why**: Core protocol features (REQ-GQL-001 to REQ-GQL-009) are 120+ days stale
- **What**: Re-run existing tests and update UPDATED timestamps
- **Acceptance**: All TestCANARY_REQ_GQL_00* tests pass; timestamps refreshed
- **ISO Ref**: §7.1-7.3 (Protocol requirements)
- **Dependencies**: None
- **Scope**: 9 REQs, ~50 test files
- **DRI**: wire team
- **Target**: 2025-02-05

### Slice 1.2: Re-validate Engine Components
- **Why**: Engine features (REQ-GQL-010, 016, 017) critically stale
- **What**: Re-run engine tests, validate current behavior
- **Acceptance**: TestCANARY engine tests pass; benchmarks within 10% baseline
- **ISO Ref**: §10 (Query execution)
- **Dependencies**: Slice 1.1
- **Scope**: 15 REQs, ~75 test files
- **DRI**: engine team
- **Target**: 2025-02-10

## Priority 2: Promote Implementation Status (Sprint 2-3)

### Slice 2.1: Promote 2PC Features to TESTED
- **Why**: REQ-GQL-2PC-002 through 005 are IMPL but have tests
- **What**: Validate test coverage, update STATUS to TESTED
- **Acceptance**: TestCANARY_2PC_* pass; coverage >80%
- **ISO Ref**: §12.4 (Distributed transactions)
- **Dependencies**: None
- **Scope**: 4 REQs
- **DRI**: distributed team
- **Target**: 2025-02-08

### Slice 2.2: Promote WCOJ to TESTED
- **Why**: REQ-GQL-WCOJ-001 is IMPL but has comprehensive tests
- **What**: Validate WCOJ test suite, update STATUS
- **Acceptance**: TestCANARY_WCOJ_Suite all pass
- **ISO Ref**: §9.4.3 (Join algorithms)
- **Dependencies**: None
- **Scope**: 1 REQ
- **DRI**: planner team
- **Target**: 2025-02-08

### Slice 2.3: Add Property Access Tests
- **Why**: REQ-GQL-017 Property Access is IMPL, needs test enhancement
- **What**: Extend TestCANARY_REQ_GQL_017_PropertyAccess coverage
- **Acceptance**: Test covers all property access patterns; STATUS→TESTED
- **ISO Ref**: §8.3.1 (Property references)
- **Dependencies**: None
- **Scope**: 1 REQ
- **DRI**: engine team
- **Target**: 2025-02-12

## Priority 3: Performance Benchmarking (Sprint 3-4)

### Slice 3.1: 2PC Performance Benchmarks
- **Why**: Distributed transactions need performance baselines
- **What**: Create BenchmarkCANARY_2PC_* suite
- **Acceptance**: Benchmarks for prepare/commit/abort cycles; <100ms p99
- **ISO Ref**: §12.4.5 (Performance requirements)
- **Dependencies**: Slice 2.1
- **Scope**: 3 new benchmark files
- **DRI**: distributed team
- **Target**: 2025-02-15

### Slice 3.2: BM25 Full-Text Search Benchmarks
- **Why**: Search performance critical for user experience
- **What**: Create BenchmarkCANARY_FTS_BM25_*
- **Acceptance**: Index/search benchmarks; <10ms for 1M docs
- **ISO Ref**: Non-standard extension
- **Dependencies**: None
- **Scope**: 2 benchmark files
- **DRI**: search team
- **Target**: 2025-02-15

### Slice 3.3: Leiden Algorithm Benchmarks
- **Why**: Community detection performance at scale
- **What**: Create BenchmarkCANARY_Leiden_*
- **Acceptance**: Benchmark for 100K node graphs; <5s execution
- **ISO Ref**: Non-standard extension
- **Dependencies**: None
- **Scope**: 1 benchmark file
- **DRI**: graph team
- **Target**: 2025-02-18

### Slice 3.4: WCOJ Performance Validation
- **Why**: Join performance critical for complex queries
- **What**: Create BenchmarkCANARY_WCOJ_*
- **Acceptance**: Triangle query benchmark; beats nested loops by 2x
- **ISO Ref**: §9.4.3
- **Dependencies**: Slice 2.2
- **Scope**: 2 benchmark files
- **DRI**: planner team
- **Target**: 2025-02-18

## Priority 4: Governance Automation (Sprint 4)

### Slice 4.1: Automated Freshness Monitoring
- **Why**: Prevent future staleness accumulation
- **What**: CI job to flag items >45 days old
- **Acceptance**: Daily CI check; Slack alerts for stale items
- **ISO Ref**: N/A (Governance)
- **Dependencies**: None
- **Scope**: 1 CI workflow
- **DRI**: tooling team
- **Target**: 2025-02-20

### Slice 4.2: CANARY Scanner Integration
- **Why**: tools/canaryscan needs to handle CLAUDE.md format
- **What**: Fix scanner to skip documentation examples
- **Acceptance**: Scanner runs clean; GAP_ANALYSIS auto-generates
- **ISO Ref**: N/A (Tooling)
- **Dependencies**: None
- **Scope**: scanner.go update
- **DRI**: tooling team
- **Target**: 2025-02-22

## Priority 5: Complete STUB Implementations (Sprint 5-6)

### Slice 5.1: Investigate STUB Features
- **Why**: 6 features marked STUB need evaluation
- **What**: Document requirements, estimate effort
- **Acceptance**: Decision matrix: implement/defer/remove
- **ISO Ref**: Various
- **Dependencies**: Priority 1-2 complete
- **Scope**: 6 STUBs
- **DRI**: architecture team
- **Target**: 2025-03-01

## Success Metrics

1. **Staleness**: <5% of features older than 60 days
2. **Coverage**: >90% features at TESTED or BENCHED
3. **Performance**: All benchmarks meet baseline ±10%
4. **Automation**: Zero manual CANARY verification needed

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Test infrastructure breaks during re-validation | High | Run in staging first |
| Benchmarks reveal performance regressions | Medium | Profile and optimize before promoting |
| STUB features require major refactoring | Low | Defer to v0.19.0 |
| Scanner changes break existing workflows | Medium | Parallel run old/new versions |

## Stakeholder Sign-offs Required

- [ ] Engineering Manager: Priority order
- [ ] QA Lead: Test coverage requirements
- [ ] Performance Team: Benchmark baselines
- [ ] Security Team: No new vulnerabilities