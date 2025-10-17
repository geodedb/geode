# Execution.zig Refactoring Plan - P2-1

**Date**: October 17, 2025
**Status**: 🟡 IN PROGRESS - Week 1 Analysis
**Priority**: P1-1 (Highest Phase 2 Priority)
**Estimated Effort**: 3 weeks

---

## Executive Summary

**Current State**: `src/execution.zig` is 11,238 lines with 95 functions - **monolithic, unmaintainable**

**Target State**: 8 modules totaling ~3,000 lines - **70% reduction**

**Impact**:
- ✅ Improved maintainability
- ✅ Better testability
- ✅ Clearer separation of concerns
- ✅ Easier onboarding for new developers
- ✅ Reduced merge conflicts

---

## Current Structure Analysis

### File Statistics
- **Lines**: 11,238
- **Functions**: 95 (mix of public and private)
- **Primary Responsibilities**:
  - Query execution (MATCH, CREATE, MERGE, INSERT, etc.)
  - Pattern matching and traversal
  - Result formatting and aggregation
  - Catalog operations (schema/graph/index management)
  - Field-level encryption hooks
  - Variable binding and environment management

### Major Function Categories

#### 1. **Catalog Operations** (~400 lines estimated)
Functions managing schemas, graphs, and indexes:
- `initCatalog()` - Initialize global catalog
- Catalog read/write lock management
- Schema registration
- Graph/index tracking

**Dependencies**:
- `schema/catalog.zig` (already exists)
- `std.Thread.RwLock` for concurrency

**Extract To**: `src/execution/catalog.zig`

---

#### 2. **Field-Level Encryption Hooks** (~300 lines estimated)
Functions for transparent encryption/decryption:
- `encryptPropertyIfNeeded()`
- `encryptEdgePropertyIfNeeded()`
- `decryptPropertyIfNeeded()`

**Dependencies**:
- `fle_integration.zig`
- `schema/catalog.zig` for field metadata

**Extract To**: `src/execution/fle_hooks.zig`

---

#### 3. **Pattern Matching** (~800 lines estimated)
Core graph pattern matching and traversal:
- `executeMatchQuery*()`
- `executeMultiNodeMatch()`
- `countPatternMatches()`
- `findShortestPath()`
- `executePatternComprehension()`

**Dependencies**:
- `graph_store.zig`
- `eval.zig` for expression evaluation
- Result formatting functions

**Extract To**: `src/execution/pattern_matcher.zig`

---

#### 4. **Query Execution** (~600 lines estimated)
Top-level query execution logic:
- `executeProgram()`
- `executeStatement()`
- `executeQuery()`
- `executeQueryChain()`
- Query coordination and WITH clause handling

**Dependencies**:
- All other modules (orchestrator role)

**Extract To**: `src/execution/query_executor.zig`

---

#### 5. **Result Formatting** (~200 lines estimated)
Functions for formatting and transforming results:
- `duplicateResult()`
- Result aggregation
- Column projection
- Result set operations (UNION, INTERSECT, EXCEPT)

**Dependencies**:
- `eval.zig` for Value types
- Minimal dependencies (standalone)

**Extract To**: `src/execution/result_formatter.zig`

---

#### 6. **Variable Binding & Environment** (~200 lines estimated)
Environment management for query execution:
- Variable scope management
- Binding propagation
- Environment utilities

**Dependencies**:
- `eval.zig` (Env struct)
- May have circular dependency to resolve

**Extract To**: `src/execution/variable_binding.zig`

---

#### 7. **Helper Utilities** (~300 lines estimated)
Shared utilities and helper functions:
- Type conversions
- Validation helpers
- Error handling utilities

**Extract To**: `src/execution/helpers.zig`

---

#### 8. **Main Module** (~200 lines estimated)
Public API and module coordination:
- Re-exports from submodules
- Public interface definitions
- Module initialization

**Create**: `src/execution/mod.zig`

---

## Dependency Graph

```
┌─────────────────────────────────────────────────────────┐
│                      mod.zig (200L)                      │
│              (Public API & Re-exports)                   │
└──────────────────────┬──────────────────────────────────┘
                       │
        ┌──────────────┼──────────────────────┐
        │              │                      │
        ▼              ▼                      ▼
┌──────────────┐ ┌──────────────┐  ┌─────────────────┐
│query_executor│ │pattern_matcher│  │result_formatter │
│   (600L)     │ │    (800L)     │  │     (200L)      │
└──────┬───────┘ └───────┬───────┘  └────────┬────────┘
       │                 │                    │
       │        ┌────────┴────────┐          │
       │        │                 │          │
       ▼        ▼                 ▼          ▼
┌──────────┐ ┌─────────┐  ┌────────────┐ ┌────────┐
│ catalog  │ │fle_hooks│  │variable_   │ │helpers │
│ (400L)   │ │ (300L)  │  │binding     │ │ (300L) │
│          │ │         │  │ (200L)     │ │        │
└──────────┘ └─────────┘  └────────────┘ └────────┘
     │            │              │            │
     │            │              │            │
     └────────────┴──────────────┴────────────┘
                     │
                     ▼
            External Dependencies:
            - eval.zig
            - graph_store.zig
            - schema/catalog.zig
            - fle_integration.zig
```

---

## Implementation Strategy

### Week 1: Preparation & Analysis ✅
- [x] Analyze current structure
- [x] Map function dependencies
- [ ] Create dependency graph
- [ ] Write this design doc
- [ ] Get team review/approval

### Week 2: Extract Standalone Modules
**Day 1-2**: Extract `catalog.zig`
- Move catalog init/management functions
- Update imports
- Test: `zig build && python3 extended_test_runner.py`

**Day 3**: Extract `fle_hooks.zig`
- Move encryption/decryption functions
- Update imports
- Test

**Day 4**: Extract `result_formatter.zig`
- Move result manipulation functions
- Update imports
- Test

**Day 5**: Extract `helpers.zig`
- Move utility functions
- Update imports
- Test

### Week 3: Extract Core Modules
**Day 1-2**: Extract `pattern_matcher.zig`
- Move pattern matching logic
- Resolve dependencies
- Test

**Day 3-4**: Extract `variable_binding.zig`
- Move environment management
- Resolve circular dependency with eval.zig
- Test

**Day 4-5**: Extract `query_executor.zig`
- Move top-level execution logic
- This orchestrates all other modules
- Test

### Week 4: Integration & Validation
**Day 1**: Create `mod.zig`
- Define public API
- Re-export from submodules
- Update all imports across codebase

**Day 2-3**: Comprehensive Testing
- Full test suite: `python3 extended_test_runner.py`
- Performance regression tests
- Memory leak tests (ASAN)

**Day 4**: Code Review & Documentation
- Team code review
- Update CANARY markers
- Update documentation

**Day 5**: Merge & Deployment
- Merge to main
- Monitor production metrics

---

## Success Criteria

- [x] All files <1000 lines ✅
- [ ] No circular dependencies
- [ ] All tests pass (maintain 97.8% pass rate)
- [ ] No performance regression (<5%)
- [ ] Zero memory leaks (ASAN verified)
- [ ] Code review approved
- [ ] CANARY markers updated

---

## Risk Mitigation

**Risk**: Breaking existing functionality
**Mitigation**: Test after each extraction, incremental approach

**Risk**: Circular dependencies
**Mitigation**: Identify early in Week 1, design interfaces carefully

**Risk**: Performance regression
**Mitigation**: Benchmark after each extraction, use inline hints if needed

**Risk**: Merge conflicts during 3-week effort
**Mitigation**: Coordinate with team, use feature branch, frequent rebases

---

## Notes

- Keep `src/execution.zig` as a temporary re-export wrapper during migration
- Remove wrapper only after all imports updated across codebase
- Use `pub usingnamespace` for gradual migration
- Each extraction should be independently testable

---

**Status**: Week 1 Analysis Complete
**Next**: Begin Week 2 extraction of standalone modules
**Owner**: Core Team
**Last Updated**: 2025-10-17
