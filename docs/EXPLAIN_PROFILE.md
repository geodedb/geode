# EXPLAIN and PROFILE Commands

This document describes the EXPLAIN and PROFILE commands for query analysis and performance profiling in Geode.

## Overview

Geode provides two commands for understanding query execution:

- **EXPLAIN**: Shows the query execution plan without executing the query
- **PROFILE**: Executes the query and returns execution statistics

These commands are essential for query optimization, performance tuning, and understanding how Geode processes your queries.

## EXPLAIN Command

The EXPLAIN command displays the execution plan for a query without actually running it. This is useful for understanding how Geode will execute a query before committing to the execution.

### Syntax

```gql
EXPLAIN <statement>
```

### Basic Examples

**Explain a Simple MATCH Query:**

```gql
EXPLAIN MATCH (p:Person) RETURN p.name
```

**Output:**

```
| plan              |
|-------------------|
| EXPLAIN           |
| MATCH             |
|   NodeScan        |
| RETURN            |
|   Project         |
```

**Explain with WHERE Clause:**

```gql
EXPLAIN MATCH (p:Person) WHERE p.age > 25 RETURN p.name, p.age
```

**Output:**

```
| plan              |
|-------------------|
| EXPLAIN           |
| MATCH             |
|   NodeScan        |
|   Filter          |
| RETURN            |
|   Project         |
```

**Explain Relationship Traversal:**

```gql
EXPLAIN MATCH (p:Person)-[:WORKS_FOR]->(c:Company) RETURN p.name, c.name
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| MATCH                   |
|   NodeScan              |
|   ExpandRelationships   |
| RETURN                  |
|   Project               |
```

### Understanding Plan Output

The execution plan shows the logical operators Geode will use:

- **NodeScan**: Scans all nodes in the graph (or nodes matching a label)
- **ExpandRelationships**: Traverses relationships from source nodes
- **Filter**: Applies WHERE clause predicates to filter results
- **Filter (FILTER clause)**: Applies FILTER clause predicates
- **Project**: Selects and transforms columns for RETURN clause
- **Sort**: Orders results for ORDER BY clause
- **Limit**: Restricts output rows for LIMIT clause
- **Aggregate**: Groups and aggregates data for aggregation functions

### EXPLAIN with Different Statement Types

**CREATE Statement:**

```gql
EXPLAIN CREATE (p:Person {name: 'Alice', age: 30})
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| CREATE                  |
|   CreateNodes           |
|   CreateRelationships   |
```

**DELETE Statement:**

```gql
EXPLAIN MATCH (p:Person) WHERE p.temp = true DELETE p
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| DELETE                  |
|   DeleteNodes           |
```

**MERGE Statement:**

```gql
EXPLAIN MERGE (p:Person {email: 'user@example.com'})
ON CREATE SET p.created = datetime()
ON MATCH SET p.accessed = datetime()
```

**Output:**

```
| plan                    |
|-------------------------|
| EXPLAIN                 |
| ExecuteStatement        |
```

### Advanced Examples

**Complex Query with Aggregation:**

```gql
EXPLAIN MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE p.age > 25
RETURN c.name, count(p) AS employee_count
ORDER BY employee_count DESC
LIMIT 10
```

**Union Query:**

```gql
EXPLAIN
MATCH (p:Person) RETURN p.name AS name
UNION
MATCH (c:Company) RETURN c.name AS name
```

## PROFILE Command

The PROFILE command executes a query and returns execution statistics. Unlike EXPLAIN, PROFILE actually runs the query and provides real metrics about the execution.

### Syntax

```gql
PROFILE <statement>
```

### Basic Examples

**Profile a Simple Query:**

```gql
PROFILE MATCH (p:Person) RETURN p.name
```

**Output:**

```
| metric              | value |
|---------------------|-------|
| rows_returned       | 42    |
| columns             | 1     |
| execution_time_ms   | 1     |
```

### Profiling Metrics

PROFILE returns the following metrics:

1. **rows_returned**: Number of rows returned by the query
2. **columns**: Number of columns in the result set
3. **execution_time_ms**: Execution time in milliseconds (placeholder value in current implementation)

### Examples by Query Type

**Profile with Aggregation:**

```gql
PROFILE MATCH (p:Person) RETURN count(p) AS person_count
```

**Profile with WHERE Clause:**

```gql
PROFILE MATCH (p:Person) WHERE p.age > 30 RETURN p.name, p.age
```

**Profile Relationship Traversal:**

```gql
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.industry = 'Technology'
RETURN p.name, c.name
```

**Profile CREATE Statement:**

```gql
PROFILE CREATE (p:Person {name: 'Bob', age: 35})
```

**Output:**

```
| metric              | value |
|---------------------|-------|
| rows_returned       | 0     |
| columns             | 0     |
| execution_time_ms   | 1     |
```

**Profile Empty Result:**

```gql
PROFILE MATCH (p:NonExistent) RETURN p
```

**Output:**

```
| metric              | value |
|---------------------|-------|
| rows_returned       | 0     |
| columns             | 1     |
| execution_time_ms   | 1     |
```

### Performance Analysis Examples

**Compare Different Query Approaches:**

```gql
-- Approach 1: Filter in WHERE
PROFILE MATCH (p:Person) WHERE p.age > 30 RETURN p.name

-- Approach 2: Filter with label test
PROFILE MATCH (n) WHERE n:Person AND n.age > 30 RETURN n.name
```

**Analyze Join Performance:**

```gql
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company),
              (p)-[:LIVES_IN]->(city:City)
WHERE c.industry = 'Tech' AND city.country = 'USA'
RETURN p.name, c.name, city.name
```

**Test Pagination Impact:**

```gql
-- Without LIMIT
PROFILE MATCH (p:Person) RETURN p.name ORDER BY p.name

-- With LIMIT
PROFILE MATCH (p:Person) RETURN p.name ORDER BY p.name LIMIT 100
```

## Implementation Details

### Parser

Both EXPLAIN and PROFILE are parsed as top-level statements that wrap another statement.

**Parser Functions (parser.zig:2554-2572):**

```zig
fn parseExplainStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.EXPLAIN);
    const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
    query_stmt_ptr.* = try self.parseStatement();
    return .{ .Explain = .{ .query = query_stmt_ptr } };
}

fn parseProfileStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.PROFILE);
    const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
    query_stmt_ptr.* = try self.parseStatement();
    return .{ .Profile = .{ .query = query_stmt_ptr } };
}
```

### AST Structures

**AST (ast.zig:46-47):**

```zig
pub const Statement = union(enum) {
    // ... other statements ...
    Explain: ExplainStatement,
    Profile: ProfileStatement,
    // ... other statements ...
};

pub const ExplainStatement = struct {
    query: *Statement,
};

pub const ProfileStatement = struct {
    query: *Statement,
};
```

### Execution

**EXPLAIN Execution (execution.zig:863-940):**

The `executeExplain` function analyzes the wrapped statement and generates a plan description based on the query structure:

- **Query statements**: Show MATCH, NodeScan, ExpandRelationships, Filter, RETURN, Project operators
- **CREATE statements**: Show CREATE, CreateNodes, CreateRelationships
- **DELETE statements**: Show DELETE, DeleteNodes
- **Other statements**: Show generic ExecuteStatement

**PROFILE Execution (execution.zig:942-988):**

The `executeProfile` function:

1. Executes the wrapped query using `executeStatementWithContext`
2. Collects execution metrics (rows returned, column count)
3. Returns statistics as a result set with two columns: metric and value

**Execution Handlers (execution.zig:646-651):**

```zig
.Explain => |exp| {
    return executeExplain(allocator, exp, context);
},
.Profile => |prof| {
    return executeProfile(allocator, prof, context);
},
```

## Use Cases

### Query Optimization

Use EXPLAIN to understand which operators are being used and identify potential bottlenecks:

```gql
-- Check if index is being used
EXPLAIN MATCH (p:Person {email: 'user@example.com'}) RETURN p

-- Verify filter order
EXPLAIN MATCH (p:Person)-[:KNOWS]->(f:Person)
WHERE p.age > 25 AND f.age > 25
RETURN p.name, f.name
```

### Performance Tuning

Use PROFILE to measure actual execution performance:

```gql
-- Measure query before optimization
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.name = 'Acme'
RETURN p.name

-- Measure after adding index
-- CREATE INDEX ON :Company(name)
PROFILE MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
WHERE c.name = 'Acme'
RETURN p.name
```

### Understanding Behavior

Use both commands to understand how Geode processes complex queries:

```gql
-- Understand plan
EXPLAIN MATCH (p:Person)
WHERE p.age > 30 OR p.department = 'Engineering'
RETURN p.name, p.age
ORDER BY p.age DESC
LIMIT 50

-- Verify actual execution
PROFILE MATCH (p:Person)
WHERE p.age > 30 OR p.department = 'Engineering'
RETURN p.name, p.age
ORDER BY p.age DESC
LIMIT 50
```

## Testing

Comprehensive unit tests are available in:

- `geodetestlab/specs/explain_profile_unit_tests.yml`

Test coverage includes:

- EXPLAIN with various query types (MATCH, CREATE, DELETE, MERGE)
- EXPLAIN with WHERE, ORDER BY, LIMIT clauses
- EXPLAIN with relationships and complex patterns
- PROFILE execution with metric validation
- PROFILE with aggregation and filtering
- Edge cases (empty results, union queries)

## GQL Compliance

These features implement ISO/IEC 39075:2024 GQL standard query explanation capabilities:

- EXPLAIN statement for query plan visualization
- PROFILE statement for execution profiling
- Query optimization hints and analysis

## Current Limitations

1. **Simplified Plans**: EXPLAIN shows logical operators but not detailed cost estimates
2. **Placeholder Timing**: PROFILE execution_time_ms is currently a placeholder (always returns 1)
3. **No Index Information**: Plans don't currently show index usage
4. **No Operator Statistics**: PROFILE doesn't show per-operator metrics
5. **No Memory Usage**: Memory consumption not tracked

## Future Enhancements

- **Cost-Based Plans**: Include estimated costs and row counts per operator
- **Actual Timing**: Real execution time measurements in PROFILE
- **Per-Operator Stats**: Detailed metrics for each operator (rows processed, time spent)
- **Memory Profiling**: Track memory allocation and usage
- **Index Usage**: Show which indexes are being used in the plan
- **Warnings**: Detect and warn about potential performance issues
- **Visual Plans**: Tree or graph visualization of query plans
- **Comparison Mode**: Compare plans for different query formulations

## See Also

- [Session Management](SESSION_MANAGEMENT.md)
- [Transaction Management](TRANSACTION_MANAGEMENT.md)
- [MERGE Operations](MERGE_AND_LABEL_TESTS.md)
- [GQL Compliance](GQL_COMPLIANCE.md)
