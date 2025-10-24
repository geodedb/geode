# Geode Binary Fixes Implementation Plan - October 2025

## Overview

This document outlines the implementation plan for fixing the remaining 277 test failures, which require changes to the geode Zig binary rather than the test framework.

**Current Status**: 81.8% test pass rate (1334/1630 passing)
**Goal**: Achieve >95% test pass rate through systematic geode binary improvements

---

## Priority Matrix

### Priority 1: High Impact, Medium Difficulty (54 tests, 19.5% of failures)

#### 1.1 Keywords as Identifiers (~30 tests)

**Impact**: Enables using reserved words as variable names (common in real-world queries)

**Current Behavior**:
```gql
-- This fails:
MATCH (path:Person) RETURN path.name
-- Error: Syntax error in query

-- This fails:
MATCH (a)-[property:KNOWS]->(b) RETURN property.since
-- Error: Syntax error in query
```

**Required Changes**:

**File**: `src/gql/lexer.zig`
```zig
// Current: Keywords are always tokenized as keywords
// Needed: Context-aware keyword handling

// Add context tracking to lexer
const LexerContext = enum {
    default,
    after_lparen,        // After '(' - identifier allowed
    after_lbracket,      // After '[' - identifier allowed
    variable_declaration,
    property_access,
};

// Modify tokenizeIdentifierOrKeyword
fn tokenizeIdentifierOrKeyword(self: *Lexer) !Token {
    const start = self.pos;
    while (self.pos < self.source.len and isIdentifierChar(self.source[self.pos])) {
        self.pos += 1;
    }

    const text = self.source[start..self.pos];

    // Check if this is a keyword
    const keyword_type = getKeywordType(text);

    // Allow keywords as identifiers in specific contexts
    if (keyword_type != null) {
        switch (self.context) {
            .after_lparen,
            .after_lbracket,
            .variable_declaration => {
                // Treat as identifier, not keyword
                return Token{ .type = .identifier, .text = text };
            },
            else => {
                return Token{ .type = keyword_type.?, .text = text };
            },
        }
    }

    return Token{ .type = .identifier, .text = text };
}
```

**Testing Strategy**:
1. Test each keyword individually as variable name
2. Test keywords in different contexts (nodes, relationships, properties)
3. Ensure keywords still work as keywords in normal positions
4. Add regression tests

**Estimated Effort**: 2-3 days
**Risk**: Medium - Could break existing keyword recognition

---

#### 1.2 WITH Clause After CREATE (~24 tests)

**Impact**: Enables data flow from CREATE to WITH to subsequent operations

**Current Behavior**:
```gql
-- This fails:
CREATE (n:Node {x: 1}) WITH n SET n.created = true RETURN n
-- Error: Syntax error in query

-- This works:
CREATE (n:Node {x: 1}) RETURN n
-- Success
```

**Root Cause**: Parser doesn't properly handle CREATE → WITH data flow

**Required Changes**:

**File**: `src/gql/parser.zig`
```zig
// Current: CREATE statement doesn't pass results to WITH
// Needed: CREATE must expose created entities for WITH clause

fn parseCreateStatement(self: *Parser) !*ast.CreateStatement {
    // ... existing CREATE parsing ...

    const create_stmt = try self.allocator.create(ast.CreateStatement);
    create_stmt.* = .{
        .patterns = patterns,
        .returning_clause = null,  // <-- Problem: no way to pass to WITH
    };

    return create_stmt;
}

// NEEDED: Add intermediate representation for CREATE results
fn parseCreateWithClause(self: *Parser) !*ast.Statement {
    // Parse CREATE
    const create_stmt = try self.parseCreateStatement();

    // Check for WITH
    if (self.currentToken().type == .keyword_with) {
        self.advance();

        // Create implicit binding of created variables
        const with_clause = try self.parseWithClause();

        // Wrap in composite statement that:
        // 1. Executes CREATE
        // 2. Passes results to WITH
        // 3. Continues with rest of query

        return try self.createCreateWithStatement(create_stmt, with_clause);
    }

    return create_stmt;
}
```

**File**: `src/execution/create.zig`
```zig
// Add result tracking to CREATE execution
pub fn executeCreate(
    self: *CreateExecutor,
    context: *ExecutionContext,
) !CreateResult {
    var created_nodes = std.ArrayList(NodeReference).init(self.allocator);
    var created_relationships = std.ArrayList(RelationshipReference).init(self.allocator);

    // ... execute CREATE ...

    // Return references for WITH clause
    return CreateResult{
        .nodes = created_nodes,
        .relationships = created_relationships,
        .variable_bindings = variable_map,  // <-- NEW
    };
}
```

**Testing Strategy**:
1. Test CREATE → WITH → SET
2. Test CREATE → WITH → MATCH
3. Test CREATE → WITH → RETURN
4. Test multiple WITH clauses
5. Ensure backward compatibility with CREATE without WITH

**Estimated Effort**: 3-5 days
**Risk**: High - Affects execution engine and data flow

---

### Priority 2: High Impact, High Difficulty (8 tests, 2.9% of failures)

#### 2.1 Memory Bugs - Invalid Free (5 tests)

**Tests Affected**:
- `selective-delete-performance`
- `performance-cleanup-medium`
- `performance-cleanup-large`
- `bulk-data-delete`
- `drop-test-data`

**Error Pattern**:
```
thread X panic: Invalid free
/nix/store/.../zig-0.15.1/lib/zig/std/heap/debug_allocator.zig:875:49
```

**Root Cause**: Double-free or freeing unowned memory during DELETE/DROP operations

**Investigation Steps**:

1. **Enable Memory Debugging**:
```bash
# Build with debug allocator
zig build -Doptimize=Debug -Dallocator=debug

# Run failing test with detailed output
./zig-out/bin/geode query --no-quic "CREATE (n:Test) DELETE n" 2>&1
```

2. **Check DELETE Implementation**:
```zig
// File: src/execution/delete.zig

// Likely issue: Freeing node/relationship data that's still referenced
pub fn executeDelete(
    self: *DeleteExecutor,
    context: *ExecutionContext,
) !void {
    for (self.to_delete.items) |entity| {
        switch (entity) {
            .node => |node| {
                // Problem: May be freeing without checking references
                context.graph.deleteNode(node.id);
                // Missing: Proper reference counting or ownership tracking
            },
            .relationship => |rel| {
                context.graph.deleteRelationship(rel.id);
            },
        }
    }
}
```

3. **Add Reference Counting**:
```zig
// Option 1: Reference counting
pub const NodeReference = struct {
    id: NodeId,
    ref_count: usize,

    pub fn acquire(self: *NodeReference) void {
        self.ref_count += 1;
    }

    pub fn release(self: *NodeReference) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.deinit();
        }
    }
};

// Option 2: Arena allocator for query lifetime
pub fn executeQuery(query: []const u8) !QueryResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();  // Frees everything at once

    const allocator = arena.allocator();
    // Use arena allocator for all query-scoped allocations
}
```

**Testing Strategy**:
1. Run with memory sanitizer
2. Add unit tests for DELETE operations
3. Test with valgrind or similar tools
4. Add stress tests for repeated DELETE operations

**Estimated Effort**: 3-7 days (debugging memory issues is time-intensive)
**Risk**: High - Memory bugs can be subtle and have cascading effects

---

#### 2.2 Memory Bugs - Incorrect Alignment (3 tests)

**Tests Affected**:
- `session-close` (multiple specs)

**Error Pattern**:
```
thread X panic: incorrect alignment
/nix/store/.../zig-0.15.1/lib/zig/std/hash_map.zig:784:44
```

**Root Cause**: Hash map key/value alignment mismatch during session cleanup

**Investigation**:

```zig
// File: src/session/session_manager.zig

// Likely issue: Hash map storing misaligned data
pub const SessionMap = std.HashMap(
    SessionId,
    SessionData,
    SessionIdContext,
    std.hash_map.default_max_load_percentage,
);

// Problem: SessionData may not be properly aligned
pub const SessionData = struct {
    id: SessionId,
    transaction_state: TransactionState,
    // Potential alignment issue here
    metadata: ?*Metadata,  // Pointer alignment
};

// Fix: Ensure proper alignment
pub const SessionData = struct {
    id: SessionId align(8),
    transaction_state: TransactionState align(8),
    metadata: ?*Metadata align(8),

    // Or use packed struct with explicit alignment
} align(8);
```

**Testing Strategy**:
1. Reproduce alignment error with minimal test case
2. Check all struct alignments in session code
3. Add alignment assertions
4. Test on different architectures

**Estimated Effort**: 2-4 days
**Risk**: Medium - Alignment issues are usually localized

---

### Priority 3: Medium Impact, Medium Difficulty (21 tests, 7.6% of failures)

#### 3.1 Transaction Auto-Transaction Architecture

**Issue**: `--no-quic` embedded mode has implicit auto-transaction that conflicts with explicit `START TRANSACTION`

**Current Behavior**:
```bash
# Embedded mode (--no-quic)
$ ./zig-out/bin/geode query --no-quic "START TRANSACTION"
# Error: TransactionAlreadyActive

# Each query has implicit transaction:
$ ./zig-out/bin/geode query --no-quic "CREATE (n:Node)"
# Implicit: START TRANSACTION; CREATE (n:Node); COMMIT;
```

**Options**:

**Option A: Add `--no-auto-transaction` Flag** (Recommended)
```zig
// File: src/cli/query.zig

pub const QueryOptions = struct {
    no_quic: bool = false,
    no_auto_transaction: bool = false,  // <-- NEW
    server: ?[]const u8 = null,
    format: OutputFormat = .json,
};

pub fn executeQuery(query: []const u8, options: QueryOptions) !void {
    var tx_manager = TransactionManager.init();

    if (!options.no_auto_transaction) {
        // Start implicit transaction
        try tx_manager.begin();
    }

    // Execute query
    const result = try self.engine.execute(query);

    if (!options.no_auto_transaction) {
        // Commit implicit transaction
        try tx_manager.commit();
    }

    return result;
}
```

**Usage**:
```bash
# Allow explicit transaction control
$ ./zig-out/bin/geode query --no-quic --no-auto-transaction \
  "START TRANSACTION; CREATE (n:Node); COMMIT"
```

**Option B: Detect Explicit Transaction Statements**
```zig
fn hasExplicitTransaction(query: []const u8) bool {
    // Parse and check for START TRANSACTION, COMMIT, ROLLBACK
    const tokens = try tokenize(query);
    for (tokens) |token| {
        if (token.type == .keyword_start_transaction or
            token.type == .keyword_commit or
            token.type == .keyword_rollback) {
            return true;
        }
    }
    return false;
}

pub fn executeQuery(query: []const u8, options: QueryOptions) !void {
    const use_auto_tx = !hasExplicitTransaction(query);

    if (use_auto_tx) {
        try tx_manager.begin();
    }

    // ... execute ...

    if (use_auto_tx) {
        try tx_manager.commit();
    }
}
```

**Testing Strategy**:
1. Test explicit transactions without auto-transaction
2. Test auto-transaction still works by default
3. Test transaction state isolation
4. Add regression tests

**Estimated Effort**: 2-3 days
**Risk**: Medium - Transaction handling is critical

---

### Priority 4: Low Impact (194 tests, 70% of failures)

These are lower priority as they represent edge cases, advanced features, or issues that don't block core functionality:

- Regex operators (10 tests)
- CALL subqueries (8 tests)
- Type mismatches (8 tests)
- GROUP BY validation (3 tests)
- Other parser edge cases (165 tests)

**Recommendation**: Address these incrementally after Priority 1-3 are complete.

---

## Implementation Roadmap

### Phase 1: Quick Wins (2-3 weeks)
1. ✅ Test framework fixes (COMPLETED)
2. **Keywords as identifiers** (30 tests)
3. **Transaction auto-transaction fix** (21 tests)
4. **Expected**: 85% pass rate

### Phase 2: Core Improvements (3-4 weeks)
1. **WITH clause after CREATE** (24 tests)
2. **Memory bug fixes** (8 tests)
3. **Expected**: 90% pass rate

### Phase 3: Advanced Features (4-6 weeks)
1. Regex operators (10 tests)
2. CALL subqueries (8 tests)
3. Type system improvements (8 tests)
4. **Expected**: 92-93% pass rate

### Phase 4: Edge Cases (ongoing)
1. GROUP BY validation
2. Complex nested queries
3. Advanced pattern matching
4. **Expected**: 95%+ pass rate

---

## Testing Strategy

### For Each Fix:

1. **Unit Tests**: Test the specific functionality in isolation
2. **Integration Tests**: Test with real-world query patterns
3. **Regression Tests**: Ensure existing tests still pass
4. **Performance Tests**: Verify no performance degradation
5. **Memory Tests**: Run with sanitizers to catch leaks

### Quality Gates:

- ✅ All existing passing tests still pass
- ✅ New tests for the fix pass
- ✅ No memory leaks (valgrind clean)
- ✅ No performance regressions (>10% slowdown)
- ✅ Code review approved
- ✅ Documentation updated

---

## Risk Mitigation

### High-Risk Changes (WITH clause, memory bugs):

1. **Feature Flags**: Hide behind compile-time flags until stable
2. **Extensive Testing**: >90% code coverage for affected modules
3. **Gradual Rollout**: Enable incrementally
4. **Rollback Plan**: Keep old code path available

### Medium-Risk Changes (keywords, transactions):

1. **Comprehensive Test Suite**: Test all edge cases
2. **Beta Testing**: Run on non-production workloads
3. **Performance Monitoring**: Track metrics

### Low-Risk Changes (misc fixes):

1. **Standard Testing**: Unit + integration tests
2. **Code Review**: Peer review before merge

---

## Resource Requirements

### Development Time:
- **Phase 1**: 80-120 hours (2-3 weeks)
- **Phase 2**: 120-160 hours (3-4 weeks)
- **Phase 3**: 160-240 hours (4-6 weeks)
- **Phase 4**: Ongoing

### Skills Needed:
- Zig programming (intermediate to advanced)
- Parser/lexer design
- Memory management and debugging
- Database transaction semantics
- Test-driven development

### Tools Needed:
- Zig 0.15.1+ compiler
- Memory sanitizers (AddressSanitizer, MemorySanitizer)
- Debugger (gdb/lldb)
- Profiling tools (perf, flamegraph)
- Test coverage tools

---

## Success Metrics

### Quantitative:
- **Pass Rate**: >95% (currently 81.8%)
- **Test Coverage**: >85% code coverage
- **Performance**: <5% regression on benchmarks
- **Memory**: 0 memory leaks detected

### Qualitative:
- **Code Quality**: Pass code review standards
- **Documentation**: All features documented
- **Maintainability**: Code is well-structured and commented

---

## Next Steps

### Immediate (This Week):
1. Set up development environment with debug tools
2. Create feature branch for keywords-as-identifiers
3. Write failing tests for keyword scenarios
4. Begin lexer modifications

### Short-term (Next 2 Weeks):
1. Complete keywords-as-identifiers implementation
2. Complete transaction auto-transaction fix
3. Run comprehensive test suite
4. Create pull request with documentation

### Medium-term (Next Month):
1. Begin WITH clause implementation
2. Start memory bug investigation
3. Regular progress reviews

---

## Conclusion

The remaining test failures are fixable but require systematic work on the geode binary. By following this phased approach with proper testing and risk mitigation, we can achieve >95% test pass rate within 2-3 months.

**Current Status**: 81.8% pass rate (1334/1630)
**Projected Status (Phase 1)**: 85% pass rate (~1385/1630)
**Projected Status (Phase 2)**: 90% pass rate (~1467/1630)
**Projected Status (Phase 3)**: 93% pass rate (~1516/1630)
**Projected Status (Phase 4)**: 95%+ pass rate (>1548/1630)

The test framework improvements completed today provide a solid foundation for validating these fixes as they are implemented.

---

*Created: October 9, 2025*
*Status: Implementation Plan - Ready for Development*
