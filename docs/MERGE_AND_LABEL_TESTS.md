# MERGE Operations and Label Test Expressions

This document describes MERGE operations with ON CREATE/ON MATCH clauses and label test expressions in WHERE clauses.

## MERGE with ON CREATE and ON MATCH

The `MERGE` statement provides upsert functionality - it either matches an existing node/edge or creates it if it doesn't exist. The `ON CREATE` and `ON MATCH` clauses allow you to perform different actions depending on whether the pattern was created or matched.

### Basic Syntax

```gql
MERGE <pattern>
[ON CREATE SET <property_assignments>]
[ON MATCH SET <property_assignments>]
[RETURN <return_items>]
```

### ON CREATE Clause

The `ON CREATE` clause executes when the pattern does not exist and must be created.

**Examples:**
```gql
-- Set properties when creating new node
MERGE (p:Person {email: 'alice@example.com'})
ON CREATE SET p.name = 'Alice', p.created = true
RETURN p

-- Set multiple properties of different types
MERGE (u:User {id: 123})
ON CREATE SET u.name = 'NewUser', u.count = 1, u.active = true
```

### ON MATCH Clause

The `ON MATCH` clause executes when the pattern already exists in the graph.

**Examples:**
```gql
-- Update properties when matching existing node
MERGE (p:Person {email: 'bob@example.com'})
ON MATCH SET p.accessed = true, p.last_seen = datetime()
RETURN p

-- Increment counter on match
MERGE (u:User {id: 456})
ON MATCH SET u.visit_count = u.visit_count + 1
```

### Combined ON CREATE and ON MATCH

You can use both clauses together to handle both scenarios:

```gql
-- Complete upsert logic
MERGE (p:Person {email: 'charlie@example.com'})
ON CREATE SET p.name = 'Charlie', p.created = datetime(), p.visits = 1
ON MATCH SET p.visits = p.visits + 1, p.last_visit = datetime()
RETURN p.name, p.visits, p.created
```

### Supported Property Types

The enhanced MERGE implementation supports setting properties of various types:

- **String**: `SET p.name = 'Alice'`
- **Integer**: `SET p.count = 42`
- **Boolean**: `SET p.active = true`
- **Decimal**: `SET p.price = 19.99` (converted to float internally)

### Implementation Details

**Expression Evaluation:**
All property values in SET clauses are now properly evaluated using the expression evaluator, supporting:
- Literal values (strings, integers, booleans)
- Decimal literals (converted to float)
- Future: Computed expressions

**Files Modified:**
- `src/execution.zig:2095-2167`: Enhanced MERGE ON CREATE/MATCH handling with full expression evaluation

**AST Structures:**
```zig
pub const MergeStatement = struct {
    pattern: GraphPattern,
    on_create: []SetClause = &.{},
    on_match: []SetClause = &.{},
    return_clause: ?ReturnClause = null,
};
```

## Label Test Expressions

Label test expressions allow you to filter nodes by their labels within WHERE clauses using the `node:Label` syntax.

### Syntax

```gql
WHERE <node_variable>:<label_name>
```

### Basic Label Tests

```gql
-- Match only Person nodes
MATCH (n)
WHERE n:Person
RETURN n

-- Match only Company nodes
MATCH (n)
WHERE n:Company
RETURN n.name
```

### Combining Label Tests with OR

Label tests can be combined with `OR` to match multiple label types:

```gql
-- Match Person OR Company nodes
MATCH (n)
WHERE n:Person OR n:Company
RETURN labels(n), n.name

-- Match any of three label types
MATCH (n)
WHERE n:Person OR n:Company OR n:Document
RETURN n
```

### Combining Label Tests with AND

For nodes with multiple labels, use `AND`:

```gql
-- Match nodes that have both Person AND Employee labels
MATCH (n)
WHERE n:Person AND n:Employee
RETURN n
```

### Combining with Property Predicates

Label tests can be combined with property predicates:

```gql
-- Match Person nodes with age > 25
MATCH (n)
WHERE n:Person AND n.age > 25
RETURN n.name, n.age

-- Match Person OR Company nodes that are active
MATCH (n)
WHERE (n:Person OR n:Company) AND n.active = true
RETURN n
```

### Negation

Label tests can be negated with `NOT`:

```gql
-- Match all nodes except Person nodes
MATCH (n)
WHERE NOT n:Person
RETURN n
```

### Using in DELETE

Label tests work in DELETE operations:

```gql
-- Delete all Person OR TempNode nodes
MATCH (n)
WHERE n:Person OR n:TempNode
DELETE n
```

### Implementation Details

**AST Structure:**
```zig
pub const Expr = union(enum) {
    // ... other expressions ...
    HasLabel: struct {
        node: []const u8,    // Node variable name
        label: []const u8    // Label to test
    },
};
```

**Parser:**
- Label tests are parsed in `parseCmpExpr()` at parser.zig:1350-1355
- Format: `identifier:Label` creates HasLabel expression

**Evaluator:**
- Label test evaluation in `eval.zig:1346-1361`
- Checks if node variable has the specified label
- Returns boolean value (true/false)

**Files Modified:**
- `src/gql/ast.zig:203-204`: Added HasLabel expression type
- `src/gql/parser.zig:1350-1355`: Parse label test syntax
- `src/gql/print.zig:621,261-264`: Print support for HasLabel
- `src/eval.zig:1346-1361`: Evaluate label tests

### Case Sensitivity

Label tests are **case-sensitive**:

```gql
-- These are different labels
WHERE n:Person  -- Matches "Person" label
WHERE n:person  -- Matches "person" label (different!)
```

## Testing

Comprehensive unit tests are available in:
- `geodetestlab/specs/merge_oncreate_unit_tests.yml` - MERGE operations
- `geodetestlab/specs/label_test_unit_tests.yml` - Label test expressions

## GQL Compliance

These features implement ISO/IEC 39075:2024 GQL standard:
- MERGE statement (§14.6)
- ON CREATE SET clause (§14.6.2)
- ON MATCH SET clause (§14.6.3)
- Label test expressions in boolean value expressions (§10.8)

## Performance Considerations

### MERGE Performance

- MERGE performs a graph scan to find matching nodes
- For better performance, ensure unique constraints on merge keys
- Pattern complexity affects match performance

### Label Test Performance

- Label tests are evaluated per-node during MATCH execution
- No special indexing on labels (currently)
- Combining multiple label tests with OR is efficient (short-circuit evaluation)

## Examples

### Complete MERGE Example

```gql
-- User visit tracking with upsert
MERGE (u:User {email: 'user@example.com'})
ON CREATE SET
    u.name = 'New User',
    u.first_visit = datetime(),
    u.visit_count = 1,
    u.status = 'active'
ON MATCH SET
    u.visit_count = u.visit_count + 1,
    u.last_visit = datetime()
RETURN u.name, u.visit_count, u.first_visit
```

### Complete Label Test Example

```gql
-- Find all entities (Person or Company) that are active
CREATE (p1:Person {name: 'Alice', active: true})
CREATE (p2:Person {name: 'Bob', active: false})
CREATE (c1:Company {name: 'Acme', active: true})
CREATE (d1:Document {title: 'Doc1', active: true})

MATCH (n)
WHERE (n:Person OR n:Company) AND n.active = true
RETURN labels(n) AS type, n.name AS name

-- Result:
-- ["Person"], "Alice"
-- ["Company"], "Acme"
```

## See Also

- [Session Management](SESSION_MANAGEMENT.md)
- [Transaction Management](TRANSACTION_MANAGEMENT.md)
- [GQL Compliance](GQL_COMPLIANCE.md)
