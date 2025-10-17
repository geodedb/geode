# P2-3 Analysis - Page Allocator Elimination (M3)

**Date**: October 17, 2025
**Status**: 🟡 ANALYSIS COMPLETE - Implementation Pending
**Priority**: P1-3 (High Priority Technical Debt)

---

## Executive Summary

**Goal**: Eliminate `std.heap.page_allocator` usage from production code (M3 remediation)
**Scope**: 156 usages across 50+ files
**Estimated Effort**: 1-2 weeks for complete elimination
**Risk**: MEDIUM - Requires careful allocator threading and testing

---

## Problem Statement

### What is page_allocator?

`std.heap.page_allocator` is Zig's simplest allocator that:
- **Never frees memory** by design (pages are returned to OS only on process exit)
- Suitable **only** for:
  - Short-lived CLI tools that exit quickly
  - Allocations that must live for the entire program duration
- **Unsuitable** for:
  - Long-running servers (accumulates memory until restart)
  - Any code with defer-based cleanup patterns
  - Test suites (memory leaks persist across tests)

### Current Impact

**Production Impact**:
- Memory leaks in long-running `geode serve` processes
- Degraded performance over time as memory accumulates
- Cannot use memory profiling tools effectively
- Test suite accumulates memory across tests

**Code Quality Impact**:
- Violates proper resource management patterns
- Prevents use of `defer allocator.free()` cleanup
- Makes memory leak detection difficult
- Inconsistent allocator usage across codebase

---

## Scope Analysis

### Total Usage Count
```bash
$ grep -r "std\.heap\.page_allocator" src --include="*.zig" | wc -l
156
```

### By File (Top 20)
| File | Count | Priority | Notes |
|------|-------|----------|-------|
| `execution.zig` | 22 | HIGH | Main query execution, hot path |
| `security/key_provider.zig` | 15 | HIGH | Security-critical, KMS operations |
| `gql/print.zig` | 14 | MEDIUM | AST printing, debugging |
| `planner.zig` | 11 | HIGH | Query planning, hot path |
| `types/jsonb.zig` | 9 | MEDIUM | JSONB operations |
| `gql/main.zig` | 6 | HIGH | Parser entry point |
| `graph/algorithms.zig` | 5 | HIGH | Graph algorithms |
| `exec.zig` | 5 | MEDIUM | Execution helpers |
| `wal/wal.zig` | 4 | HIGH | Write-ahead log, critical |
| `types/evaluator_functions.zig` | 4 | MEDIUM | Function evaluation |
| `storage/fs_fsync.zig` | 4 | HIGH | Storage layer |
| `types/xml.zig` | 3 | LOW | XML operations, rarely used |
| `execution/catalog.zig` | 3 | MEDIUM | Already using Catalog instance |
| `graph_store.zig` | 3 | HIGH | Graph storage operations |
| Others | <3 each | VARIES | Distributed across codebase |

### Usage Patterns Identified

#### Pattern 1: Global Functions Without Allocator Parameter (52 occurrences)
```zig
// BEFORE: No allocator parameter
pub fn someFunction() !Result {
    const allocator = std.heap.page_allocator;  // ❌ Memory leak
    const data = try allocator.alloc(u8, size);
    // ... never freed
}

// AFTER: Allocator as parameter
pub fn someFunction(allocator: Allocator) !Result {
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);  // ✅ Proper cleanup
}
```

#### Pattern 2: Struct Initialization Without Allocator Field (38 occurrences)
```zig
// BEFORE: page_allocator in init
pub fn init() !Self {
    const allocator = std.heap.page_allocator;
    return Self{
        .data = try allocator.alloc(u8, 100),
    };
}

// AFTER: Allocator stored in struct
pub fn init(allocator: Allocator) !Self {
    return Self{
        .allocator = allocator,
        .data = try allocator.alloc(u8, 100),
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
}
```

#### Pattern 3: Temporary Allocations (46 occurrences)
```zig
// BEFORE: page_allocator for temporary data
const temp = try std.heap.page_allocator.alloc(u8, 256);
// ... use temp
// ❌ Never freed - leaks 256 bytes

// AFTER: Use provided allocator
const temp = try allocator.alloc(u8, 256);
defer allocator.free(temp);  // ✅ Cleaned up
```

#### Pattern 4: Error Path Allocations (20 occurrences)
```zig
// BEFORE: page_allocator in error messages
return error.Foo; // Want to include context
const msg = try std.fmt.allocPrint(std.heap.page_allocator, "Error: {}", .{err});
// ❌ Leaked on error path

// AFTER: Use allocator or stack buffer
var buf: [256]u8 = undefined;
const msg = try std.fmt.bufPrint(&buf, "Error: {}", .{err});
// ✅ Stack allocation, no leak
```

---

## Prioritization Strategy

### Phase 1: High-Impact Core Files (Priority: HIGH)
**Files**: 7 files, ~70 usages
**Estimated Effort**: 3-4 days
**Impact**: Fixes hot paths and critical infrastructure

1. **execution.zig** (22 usages)
   - Main query execution path
   - Already has allocator parameter in most functions
   - Fix: Thread allocator through remaining calls

2. **planner.zig** (11 usages)
   - Query planning hot path
   - Similar to execution.zig pattern

3. **security/key_provider.zig** (15 usages)
   - KMS operations, security-critical
   - Needs careful allocator management

4. **wal/wal.zig** (4 usages)
   - Write-ahead log, critical for durability
   - High priority despite low count

5. **graph_store.zig** (3 usages)
   - Core graph storage operations

6. **storage/fs_fsync.zig** (4 usages)
   - Storage layer, critical path

7. **graph/algorithms.zig** (5 usages)
   - Graph algorithm implementations

### Phase 2: Medium-Impact Supporting Files (Priority: MEDIUM)
**Files**: 10 files, ~55 usages
**Estimated Effort**: 2-3 days
**Impact**: Improves general memory management

- `gql/print.zig` (14) - AST printing, debugging
- `types/jsonb.zig` (9) - JSONB operations
- `exec.zig` (5) - Execution helpers
- `types/evaluator_functions.zig` (4) - Function evaluation
- `execution/catalog.zig` (3) - Catalog operations (partially done)
- `gql/main.zig` (6) - Parser entry points
- Others with 2-3 usages each

### Phase 3: Low-Impact Utility Files (Priority: LOW)
**Files**: 30+ files, ~31 usages
**Estimated Effort**: 2-3 days
**Impact**: Completeness, cleanup

- `types/xml.zig` (3) - Rarely used XML operations
- `tools/*` - Development tools, CLI utilities
- `cli/*` - Command-line tools (short-lived, less critical)
- Test harness files (not production code)

---

## Implementation Pattern

### Standard Refactoring Steps

#### Step 1: Add Allocator Parameter
```zig
// Before
pub fn myFunction(x: i32) !Result

// After
pub fn myFunction(allocator: Allocator, x: i32) !Result
```

#### Step 2: Update Struct with Allocator Field
```zig
pub const MyStruct = struct {
    allocator: Allocator,  // Add this
    data: []u8,

    pub fn init(allocator: Allocator) !MyStruct {
        return MyStruct{
            .allocator = allocator,
            .data = try allocator.alloc(u8, 100),
        };
    }

    pub fn deinit(self: *MyStruct) void {
        self.allocator.free(self.data);  // Proper cleanup
    }
};
```

#### Step 3: Update All Callers
```zig
// Before
const result = try myFunction(42);

// After
const result = try myFunction(allocator, 42);
```

#### Step 4: Replace page_allocator References
```zig
// Before
const temp = try std.heap.page_allocator.alloc(u8, size);

// After
const temp = try allocator.alloc(u8, size);
defer allocator.free(temp);
```

---

## Partial Progress from P2-2

### Already Fixed in Catalog Module ✅
The new `Catalog` struct (P2-2 Phase 1) already uses dependency injection:

**File**: `src/execution/catalog.zig`
```zig
pub const Catalog = struct {
    allocator: std.mem.Allocator,  // ✅ DI pattern
    // ... fields

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !*Catalog {
        // Uses provided allocator, not page_allocator
    }
};
```

**Remaining in catalog.zig**:
- 3 usages in deprecated legacy functions (backward compatibility)
- Will be removed in Phase 3 cleanup

**Remaining in execution.zig**:
- ensureCatalogInstance() helper (TODO marked for P2-3)
- CREATE INDEX/GRAPH/SCHEMA string allocations
- Temporary buffers in various operations

---

## Benefits of Complete Elimination

### Memory Management ✅
- **Zero memory leaks** from allocator misuse
- Proper `defer` cleanup patterns throughout
- Memory profiling tools work correctly
- Test suite doesn't accumulate memory

### Performance 🚀
- Long-running servers maintain stable memory usage
- No gradual performance degradation
- Better cache locality from allocator reuse
- Reduced OS memory pressure

### Code Quality 📐
- Consistent allocator usage patterns
- Clear ownership and lifecycle
- Better testability (can use testing.allocator)
- Easier debugging with allocator tracking

### Production Readiness 🏭
- Suitable for long-running server processes
- Meets enterprise memory management standards
- Enables memory usage monitoring
- Improves reliability and stability

---

## Risks & Mitigation

### Risk 1: Cascading Changes
**Issue**: Changing one function signature requires updating all callers
**Mitigation**:
- Work file-by-file to limit scope
- Use compiler errors as checklist
- Test after each file completion

### Risk 2: Allocator Lifetime Issues
**Issue**: Passing wrong allocator scope could cause use-after-free
**Mitigation**:
- Use long-lived allocators (ArenaAllocator per-request)
- Clear ownership documentation
- Comprehensive testing with allocator tracking

### Risk 3: Performance Regression
**Issue**: Some operations might be slower with proper cleanup
**Mitigation**:
- Benchmark critical paths
- Use ArenaAllocator for batch operations
- Profile before/after comparison

### Risk 4: Breaking Backward Compatibility
**Issue**: Public API changes break external callers
**Mitigation**:
- Keep old signatures with "Legacy" suffix temporarily
- Deprecation warnings in documentation
- Phased rollout with compatibility layer

---

## Recommended Implementation Plan

### Week 1: Core Infrastructure (Phase 1)
**Days 1-2**: execution.zig (22 usages)
- Thread allocator through remaining CREATE/DROP operations
- Update ensureCatalogInstance() helper
- Comprehensive testing

**Days 3-4**: planner.zig (11 usages) + wal/wal.zig (4 usages)
- Query planner allocator threading
- WAL operations cleanup
- Integration testing

**Day 5**: security/key_provider.zig (15 usages)
- KMS operations with proper allocation
- Security review after changes
- Key rotation testing

### Week 2: Supporting Files (Phase 2) + Cleanup
**Days 1-3**: Medium-priority files (55 usages)
- types/jsonb.zig, gql/print.zig, etc.
- Systematic file-by-file approach
- Testing after each file

**Days 4-5**: Low-priority files (31 usages) + Documentation
- Utility files, tools, CLI
- Remove backward compatibility shims
- Update documentation

---

## Alternative: Incremental Approach

Instead of full elimination in 1-2 weeks, consider:

### Micro-Phase Approach
1. **This Session**: Fix execution.zig ensureCatalogInstance() (1 usage, already has TODO)
2. **Next Session**: Fix execution.zig CREATE/DROP operations (15-20 usages)
3. **Following Sessions**: One high-priority file per session
4. **Final Session**: Cleanup and remove deprecated code

**Advantages**:
- Lower risk per change
- Can validate in production between phases
- Easier to review and test
- Maintains working state throughout

---

## Success Criteria

✅ **Zero page_allocator usages** in production code paths
✅ **All tests pass** with proper allocator usage
✅ **No memory leaks** detected in test suite
✅ **Performance neutral** or improved in benchmarks
✅ **Documentation updated** with allocator patterns
✅ **Long-running server stability** verified

---

## Next Steps

### Immediate (This Session)
1. ✅ Complete P2-3 analysis (this document)
2. **Option A**: Start with execution.zig high-value subset (2-3 hours)
3. **Option B**: Create detailed file-by-file plan, defer implementation

### Short-Term (Next 1-2 Weeks)
1. Implement Phase 1 (core infrastructure files)
2. Comprehensive testing after each file
3. Production validation in staging environment
4. Monitor memory usage patterns

### Long-Term (Following Month)
1. Complete Phase 2 (supporting files)
2. Complete Phase 3 (utility files)
3. Remove all backward compatibility shims
4. Final production deployment

---

**Prepared by**: Core Team
**Date**: 2025-10-17
**Status**: Analysis Complete - Ready for Implementation
**Recommendation**: Start with execution.zig subset (ensureCatalogInstance + CREATE ops) as proof-of-concept, then systematic file-by-file elimination over 1-2 weeks.
