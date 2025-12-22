# Geode Shell Testing Directory

This directory contains GQL test files for manual and automated testing of the Geode database shell.

## Files

### comprehensive_test.gql

A comprehensive GQL test file with 33 sections covering:

1. **Basic Expressions and Literals** - Numbers, strings, booleans, nulls, lists, maps
2. **Arithmetic Operations** - +, -, *, /, %, precedence, parentheses
3. **Comparison Operations** - =, <>, <, >, <=, >=, IS NULL
4. **Logical Operations** - AND, OR, NOT, XOR
5. **String Functions** - upper, lower, length, substring, contains, replace
6. **Mathematical Functions** - abs, sqrt, pow, trig, log, round
7. **List Functions** - indexing, size, head, tail, comprehensions, range
8. **Aggregation Functions** - count, sum, avg, min, max, collect
9. **Date and Time Functions** - datetime, date, time, duration
10. **Type Functions** - type checking, conversion, coalescing
11. **Conditional Expressions** - CASE/WHEN
12. **Graph Management** - CREATE/DROP/USE GRAPH
13. **Node Operations** - CREATE, labels, properties
14. **Relationship Operations** - CREATE relationships, types
15. **Pattern Matching** - MATCH, paths, variable length
16. **Filtering and Predicates** - WHERE, IN, EXISTS, STARTS WITH
17. **Ordering and Pagination** - ORDER BY, LIMIT, SKIP
18. **Aggregation** - GROUP BY, DISTINCT, collect
19. **UNION Operations** - UNION, UNION ALL
20. **Data Modification** - SET, REMOVE, labels
21. **MERGE Operations** - ON CREATE, ON MATCH
22. **DELETE Operations** - DELETE, DETACH DELETE
23. **WITH Clause** - Chaining, filtering aggregations
24. **UNWIND** - List expansion
25. **Subqueries** - EXISTS, COUNT
26. **Vector Operations** - vectorf32, distances, similarity
27. **Path Functions** - length, nodes, relationships
28. **Graph Algorithms** - shortestPath, allShortestPaths
29. **Index Operations** - CREATE/DROP INDEX
30. **Constraint Operations** - CREATE/DROP CONSTRAINT
31. **Transaction Control** - BEGIN, COMMIT, ROLLBACK
32. **Error Handling** - Division by zero, invalid types
33. **Cleanup** - Delete all data, drop graphs

## Usage

### Run Entire File

```bash
# From geode root directory
./zig-out/bin/geode query < testing/shell/comprehensive_test.gql

# Or with explicit path
./zig-out/bin/geode query - < testing/shell/comprehensive_test.gql
```

### Run in Interactive Shell

```bash
./zig-out/bin/geode shell

# Then copy/paste individual lines or sections
geode> RETURN 42 AS answer;
```

### Run Individual Queries

```bash
# Single query
./zig-out/bin/geode query "RETURN 1 + 1 AS result"

# Multi-line query
./zig-out/bin/geode query "
MATCH (p:Person)
WHERE p.age > 30
RETURN p.name, p.age
"
```

## Tips for Manual Testing

1. **Start with basics** - Test sections 1-4 first (expressions and operators)

2. **Build up data** - Run sections 12-14 to create test graphs, nodes, and relationships before testing pattern matching

3. **Test incrementally** - Don't run the entire file at once; test section by section

4. **Watch for errors** - Some queries may fail depending on database state or feature support

5. **Cleanup last** - Section 33 deletes all data, so save it for the end

## Notes

- Lines starting with `--` are comments and are ignored
- Each query should end with `;`
- Some advanced features may not be fully implemented yet
- Error handling queries (section 32) are expected to produce errors
