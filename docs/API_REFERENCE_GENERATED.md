# GQL API Reference

> Auto-generated from `src/gql/language_metadata.zig` - DO NOT EDIT MANUALLY
>
> Last updated: 2026-01-03

This document provides a comprehensive reference for Geode's GQL implementation,
including all keywords, functions, types, and procedures.

## Table of Contents

- [Keywords](#keywords)
- [Functions](#functions)
- [Data Types](#data-types)
- [Procedures](#procedures)

---

## Keywords

### Clause Keywords

| Keyword | Description | GQL Compliant |
|---------|-------------|---------------|
| `CALL` | Call a procedure | Yes |
| `CASE` | Begin a CASE expression | Yes |
| `DELETE` | Delete nodes or edges | Yes |
| `DETACH` | Detach delete (remove edges first) | Yes |
| `ELSE` | ELSE branch in CASE expression | Yes |
| `END` | End of CASE expression | Yes |
| `EXPLAIN` | Explain query execution plan | Yes |
| `FILTER` | Filter clause | Yes |
| `FINISH` | Finish a linear graph query | Yes |
| `FOREACH` | Iterate over a list | Extension |
| `FROM` | Source specification | Yes |
| `INSERT` | Insert data | Yes |
| `JOIN` | Join operation | Yes |
| `LET` | Variable binding | Yes |
| `LIMIT` | Limit number of results | Yes |
| `LOAD` | Load data from file | Extension |
| `MATCH` | Pattern matching clause | Yes |
| `MERGE` | Match or create pattern | Yes |
| `OFFSET` | Skip results (alias for SKIP) | Yes |
| `OTHERWISE` | Otherwise branch | Yes |
| `PROFILE` | Profile query execution | Yes |
| `REMOVE` | Remove properties or labels | Yes |
| `REPLACE` | Replace existing data | Yes |
| `RETURN` | Return results from query | Yes |
| `SCAN` | Table scan operation | Extension |
| `SELECT` | Select clause (table-like) | Yes |
| `SET` | Set properties or variables | Yes |
| `SHOW` | Show metadata | Yes |
| `SKIP` | Skip N results | Yes |
| `THEN` | THEN branch in CASE | Yes |
| `UNWIND` | Unwind a list into rows | Yes |
| `VALUE` | Value specification | Yes |
| `VALUES` | Multiple values | Yes |
| `WHEN` | WHEN branch in CASE | Yes |
| `WHERE` | Filter condition | Yes |
| `WITH` | Intermediate result binding | Yes |

### DDL Keywords

| Keyword | Description | GQL Compliant |
|---------|-------------|---------------|
| `ASSERT` | Assert a constraint condition | Extension |
| `CONSTRAINT` | Define a constraint | Yes |
| `CREATE` | Create nodes, edges, graphs, or schemas | Yes |
| `DROP` | Drop graphs, schemas, or constraints | Yes |
| `GRAPH` | Graph reference | Yes |
| `INDEX` | Index definition | Yes |
| `KEY` | Key constraint | Yes |
| `PROPERTY` | Property definition | Yes |
| `REQUIRE` | Require constraint | Yes |
| `SCHEMA` | Schema definition | Yes |
| `TABLE` | Table reference | Yes |

### Boolean & Logical Keywords

| Keyword | Description |
|---------|-------------|
| `AND` | Logical AND operator |
| `CONTAINS` | String containment predicate |
| `ENDS` | String ends-with predicate |
| `EXISTS` | Existence predicate |
| `FALSE` | Boolean false literal |
| `IN` | Membership predicate |
| `IS` | Type/NULL checking predicate |
| `LIKE` | Pattern matching predicate |
| `NOT` | Logical NOT operator |
| `NULL` | NULL literal |
| `OR` | Logical OR operator |
| `STARTS` | String starts-with predicate |
| `TRUE` | Boolean true literal |
| `UNKNOWN` | Unknown truth value |
| `XOR` | Logical XOR operator |

### Transaction Keywords

| Keyword | Description |
|---------|-------------|
| `BEGIN` | Begin a transaction |
| `COMMIT` | Commit the current transaction |
| `READ` | Read transaction mode |
| `REPEATABLE` | Repeatable read isolation |
| `ROLLBACK` | Rollback transaction |
| `START` | Start transaction |
| `TRANSACTION` | Transaction keyword |
| `WRITE` | Write transaction mode |

### Path Pattern Keywords

| Keyword | Description |
|---------|-------------|
| `ACYCLIC` | Restricts path patterns to acyclic paths (no repeated nodes) |
| `SHORTEST` | Shortest path pattern |
| `SIMPLE` | Simple path (no repeated edges) |
| `TRAIL` | Trail path (no repeated edges) |
| `WALK` | Walk path (any path) |

### Set Operation Keywords

| Keyword | Description |
|---------|-------------|
| `EXCEPT` | Set difference operation |
| `INTERSECT` | Set intersection operation |
| `UNION` | Set union operation |

---

## Functions

### Aggregate Functions

#### `count(expr: ANY)` -> `INTEGER`

Count the number of non-null values

```gql
RETURN count(n)
```

#### `sum(expr: NUMERIC)` -> `NUMERIC`

Sum of numeric values

```gql
RETURN sum(n.amount)
```

#### `avg(expr: NUMERIC)` -> `FLOAT`

Average of numeric values

```gql
RETURN avg(n.score)
```

#### `min(expr: ANY)` -> `ANY`

Minimum value

```gql
RETURN min(n.created)
```

#### `max(expr: ANY)` -> `ANY`

Maximum value

```gql
RETURN max(n.price)
```

#### `collect(expr: ANY)` -> `LIST`

Collect values into a list

```gql
RETURN collect(n.name)
```

### Mathematical Functions

#### `abs(x: NUMERIC)` -> `NUMERIC`

Absolute value

```gql
RETURN abs(-5)
```

#### `ceil(x: FLOAT)` -> `INTEGER`

Ceiling (round up)

```gql
RETURN ceil(3.2)
```

#### `floor(x: FLOAT)` -> `INTEGER`

Floor (round down)

```gql
RETURN floor(3.8)
```

#### `round(x: FLOAT)` -> `INTEGER`

Round to nearest integer

```gql
RETURN round(3.5)
```

#### `sqrt(x: NUMERIC)` -> `FLOAT`

Square root

```gql
RETURN sqrt(16)
```

#### `rand()` -> `FLOAT`

Random number between 0 and 1

```gql
RETURN rand()
```

#### `sign(x: NUMERIC)` -> `INTEGER`

Sign of a number (-1, 0, or 1)

```gql
RETURN sign(-5)
```

#### `exp(x: NUMERIC)` -> `FLOAT`

Exponential (e^x)

```gql
RETURN exp(1)
```

#### `log(x: NUMERIC)` -> `FLOAT`

Natural logarithm

```gql
RETURN log(10)
```

#### `log10(x: NUMERIC)` -> `FLOAT`

Base-10 logarithm

```gql
RETURN log10(100)
```

#### `sin(x: NUMERIC)` -> `FLOAT`

Sine (radians)

```gql
RETURN sin(pi()/2)
```

#### `cos(x: NUMERIC)` -> `FLOAT`

Cosine (radians)

```gql
RETURN cos(0)
```

#### `tan(x: NUMERIC)` -> `FLOAT`

Tangent (radians)

```gql
RETURN tan(pi()/4)
```

#### `asin(x: NUMERIC)` -> `FLOAT`

Arc sine

```gql
RETURN asin(0.5)
```

#### `acos(x: NUMERIC)` -> `FLOAT`

Arc cosine

```gql
RETURN acos(0.5)
```

#### `atan(x: NUMERIC)` -> `FLOAT`

Arc tangent

```gql
RETURN atan(1)
```

#### `atan2(y: NUMERIC, x: NUMERIC)` -> `FLOAT`

Two-argument arc tangent

```gql
RETURN atan2(1, 1)
```

#### `pi()` -> `FLOAT`

Mathematical constant pi

```gql
RETURN pi()
```

#### `e()` -> `FLOAT`

Mathematical constant e

```gql
RETURN e()
```

#### `degrees(radians: NUMERIC)` -> `FLOAT`

Convert radians to degrees

```gql
RETURN degrees(pi())
```

#### `radians(degrees: NUMERIC)` -> `FLOAT`

Convert degrees to radians

```gql
RETURN radians(180)
```

### String Functions

#### `size(value: STRING|LIST)` -> `INTEGER`

Length of string or list

```gql
RETURN size('hello')
```

#### `length(path: PATH)` -> `INTEGER`

Length of a path

```gql
RETURN length(p)
```

#### `substring(str: STRING, start: INTEGER, length: INTEGER)` -> `STRING`

Extract substring

```gql
RETURN substring('hello', 1, 3)
```

#### `replace(str: STRING, search: STRING, replacement: STRING)` -> `STRING`

Replace occurrences in string

```gql
RETURN replace('hello', 'l', 'L')
```

#### `toLower(str: STRING)` -> `STRING`

Convert to lowercase

```gql
RETURN toLower('HELLO')
```

#### `toUpper(str: STRING)` -> `STRING`

Convert to uppercase

```gql
RETURN toUpper('hello')
```

#### `trim(str: STRING)` -> `STRING`

Remove leading/trailing whitespace

```gql
RETURN trim('  hello  ')
```

#### `lTrim(str: STRING)` -> `STRING`

Remove leading whitespace

```gql
RETURN lTrim('  hello')
```

#### `rTrim(str: STRING)` -> `STRING`

Remove trailing whitespace

```gql
RETURN rTrim('hello  ')
```

#### `left(str: STRING, n: INTEGER)` -> `STRING`

Get leftmost n characters

```gql
RETURN left('hello', 3)
```

#### `right(str: STRING, n: INTEGER)` -> `STRING`

Get rightmost n characters

```gql
RETURN right('hello', 3)
```

#### `split(str: STRING, delimiter: STRING)` -> `LIST`

Split string into list

```gql
RETURN split('a,b,c', ',')
```

#### `startsWith(str: STRING, prefix: STRING)` -> `BOOLEAN`

Check if string starts with prefix

```gql
RETURN startsWith('hello', 'he')
```

#### `endsWith(str: STRING, suffix: STRING)` -> `BOOLEAN`

Check if string ends with suffix

```gql
RETURN endsWith('hello', 'lo')
```

#### `contains(str: STRING, search: STRING)` -> `BOOLEAN`

Check if string contains substring

```gql
RETURN contains('hello', 'ell')
```

### List Functions

#### `head(list: LIST)` -> `ANY`

First element of list

```gql
RETURN head([1, 2, 3])
```

#### `last(list: LIST)` -> `ANY`

Last element of list

```gql
RETURN last([1, 2, 3])
```

#### `tail(list: LIST)` -> `LIST`

All but first element of list

```gql
RETURN tail([1, 2, 3])
```

#### `reverse(list: LIST)` -> `LIST`

Reverse a list

```gql
RETURN reverse([1, 2, 3])
```

#### `range(start: INTEGER, end: INTEGER, step: INTEGER)` -> `LIST`

Geode extension (ISO GQL has no range function): integers from start up to, not including, end, by step (default 1); openCypher's range() includes end

```gql
RETURN range(1, 10)
```

### Temporal Functions

#### `timestamp()` -> `INTEGER`

Current Unix timestamp in milliseconds

```gql
RETURN timestamp()
```

#### `date(value: STRING)` -> `DATE`

Create or get current date

```gql
RETURN date('2024-01-15')
```

#### `time(value: STRING)` -> `TIME`

Create or get current time

```gql
RETURN time('14:30:00')
```

#### `datetime(value: STRING)` -> `DATETIME`

Create or get current datetime

```gql
RETURN datetime('2024-01-15T14:30:00Z')
```

#### `duration(value: STRING)` -> `DURATION`

Create a duration

```gql
RETURN duration('P1DT2H')
```

### Graph Functions

#### `id(element: NODE|RELATIONSHIP)` -> `INTEGER`

Get element ID

```gql
RETURN id(n)
```

#### `type(rel: RELATIONSHIP)` -> `STRING`

Get relationship type

```gql
RETURN type(r)
```

#### `labels(node: NODE)` -> `LIST`

Get node labels

```gql
RETURN labels(n)
```

#### `properties(element: NODE|RELATIONSHIP)` -> `MAP`

Get all properties as map

```gql
RETURN properties(n)
```

#### `keys(element: NODE|RELATIONSHIP|MAP)` -> `LIST`

Get property keys

```gql
RETURN keys(n)
```

#### `nodes(path: PATH)` -> `LIST`

Get nodes in a path

```gql
RETURN nodes(p)
```

#### `relationships(path: PATH)` -> `LIST`

Get relationships in a path

```gql
RETURN relationships(p)
```

#### `indegree(node: NODE)` -> `INTEGER`

Number of incoming edges to a node

```gql
MATCH (n) RETURN n.name, indegree(n)
```

#### `outdegree(node: NODE)` -> `INTEGER`

Number of outgoing edges from a node

```gql
MATCH (n) RETURN n.name, outdegree(n)
```

### Path Functions

#### `shortestPath(pattern: PATTERN)` -> `PATH`

Find shortest path

```gql
MATCH p = shortestPath((a)-[*]-(b)) RETURN p
```

#### `allShortestPaths(pattern: PATTERN)` -> `LIST`

Find all shortest paths

```gql
MATCH p = allShortestPaths((a)-[*]-(b)) RETURN p
```

### Vector Functions

#### `vectorf32(list: LIST)` -> `VECTOR`

Create a float32 vector from list

```gql
RETURN vectorf32([1.0, 2.0, 3.0])
```

#### `vectori32(list: LIST)` -> `VECTOR`

Create an int32 vector from list

```gql
RETURN vectori32([1, 2, 3])
```

#### `vector_l2(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

L2 (Euclidean) distance between vectors

```gql
RETURN vector_l2(n.embedding, $query)
```

#### `vector_cosine(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Cosine distance between vectors

```gql
RETURN vector_cosine(n.embedding, $query)
```

#### `vector_dot(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Dot product of vectors

```gql
RETURN vector_dot(n.embedding, $query)
```

#### `distance(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Default distance metric (L2)

```gql
RETURN distance(n.embedding, $query)
```

#### `similarity(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Cosine similarity between vectors

```gql
RETURN similarity(n.embedding, $query)
```

#### `cosine(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Cosine similarity (alias)

```gql
RETURN cosine(n.embedding, $query)
```

#### `euclidean(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Euclidean distance (alias for vector_l2)

```gql
RETURN euclidean(n.embedding, $query)
```

#### `manhattan(v1: VECTOR, v2: VECTOR)` -> `FLOAT`

Manhattan (L1) distance between vectors

```gql
RETURN manhattan(n.embedding, $query)
```

### Conversion Functions

#### `toInteger(value: ANY)` -> `INTEGER`

Convert to integer

```gql
RETURN toInteger('42')
```

#### `toFloat(value: ANY)` -> `FLOAT`

Convert to float

```gql
RETURN toFloat('3.14')
```

#### `toString(value: ANY)` -> `STRING`

Convert to string

```gql
RETURN toString(42)
```

#### `toBoolean(value: ANY)` -> `BOOLEAN`

Convert to boolean

```gql
RETURN toBoolean('true')
```

### Predicate Functions

#### `all(variable: IDENTIFIER, list: LIST, predicate: BOOLEAN)` -> `BOOLEAN`

True if all elements satisfy predicate

```gql
RETURN all(x IN [1,2,3] WHERE x > 0)
```

#### `any(variable: IDENTIFIER, list: LIST, predicate: BOOLEAN)` -> `BOOLEAN`

True if any element satisfies predicate

```gql
RETURN any(x IN [1,2,3] WHERE x > 2)
```

#### `none(variable: IDENTIFIER, list: LIST, predicate: BOOLEAN)` -> `BOOLEAN`

True if no elements satisfy predicate

```gql
RETURN none(x IN [1,2,3] WHERE x > 5)
```

#### `single(variable: IDENTIFIER, list: LIST, predicate: BOOLEAN)` -> `BOOLEAN`

True if exactly one element satisfies predicate

```gql
RETURN single(x IN [1,2,3] WHERE x > 2)
```

#### `coalesce(values: ANY...)` -> `ANY`

Return first non-null value

```gql
RETURN coalesce(n.name, 'Unknown')
```

#### `nullIf(value: ANY, null_value: ANY)` -> `ANY`

Return NULL if values are equal

```gql
RETURN nullIf(n.status, 'inactive')
```

---

## Data Types

| Type | Description |
|------|-------------|
| `INTEGER` | 64-bit signed integer |
| `FLOAT` | 64-bit floating point number |
| `STRING` | Unicode string |
| `BOOLEAN` | Boolean (true/false) |
| `DATE` | Calendar date |
| `TIME` | Time of day |
| `DATETIME` | Date and time with timezone |
| `DURATION` | Time duration |
| `POINT` | Geographic point |
| `VECTOR` | Fixed-dimension numeric vector |
| `UUID` | UUID identifier |
| `BYTES` | Binary data |
| `JSON` | JSON document |
| `LIST` | Ordered collection |
| `MAP` | Key-value map |
| `NODE` | Graph node element |
| `RELATIONSHIP` | Graph relationship element |
| `PATH` | Graph path |
| `GRAPH` | Named graph |
| `ANY` | Any type |

---

## Procedures

Procedures are invoked using `CALL procedure.name()` syntax.

### Centrality Algorithms

#### `CALL algo.degree.stream()`

Compute degree centrality for all nodes

**Yields:** `nodeId: INTEGER`, `degree: INTEGER`

```gql
CALL algo.degree.stream() YIELD nodeId, degree
```

#### `CALL algo.betweenness.stream()`

Compute betweenness centrality for all nodes

**Yields:** `nodeId: INTEGER`, `betweenness: FLOAT`

```gql
CALL algo.betweenness.stream() YIELD nodeId, betweenness
```

#### `CALL algo.closeness.stream()`

Compute closeness centrality for all nodes

**Yields:** `nodeId: INTEGER`, `closeness: FLOAT`

```gql
CALL algo.closeness.stream() YIELD nodeId, closeness
```

#### `CALL algo.eigenvector.stream()`

Compute eigenvector centrality for all nodes

**Yields:** `nodeId: INTEGER`, `eigenvector: FLOAT`

```gql
CALL algo.eigenvector.stream() YIELD nodeId, eigenvector
```

#### `CALL algo.pagerank.stream()`

Compute PageRank for all nodes

**Yields:** `nodeId: INTEGER`, `score: FLOAT`

```gql
CALL algo.pagerank.stream({dampingFactor: 0.85}) YIELD nodeId, score
```

#### `CALL algo.harmonic.stream()`

Compute harmonic centrality for all nodes

**Yields:** `nodeId: INTEGER`, `harmonic: FLOAT`

```gql
CALL algo.harmonic.stream() YIELD nodeId, harmonic
```

#### `CALL algo.bridgeLeverage.stream()`

Compute bridge/leverage centrality for all nodes

**Yields:** `nodeId: INTEGER`, `bridgeLeverage: FLOAT`

```gql
CALL algo.bridgeLeverage.stream() YIELD nodeId, bridgeLeverage
```

#### `CALL algo.greyCardinal.stream()`

Compute grey cardinal composite centrality

**Yields:** `nodeId: INTEGER`, `composite: FLOAT`

```gql
CALL algo.greyCardinal.stream() YIELD nodeId, composite
```

### Community Detection

#### `CALL algo.louvain.stream()`

Detect communities using Louvain algorithm

**Yields:** `nodeId: INTEGER`, `community: INTEGER`

```gql
CALL algo.louvain.stream() YIELD nodeId, community
```

#### `CALL algo.labelPropagation.stream()`

Detect communities using label propagation

**Yields:** `nodeId: INTEGER`, `label: INTEGER`

```gql
CALL algo.labelPropagation.stream() YIELD nodeId, label
```

#### `CALL algo.leiden.stream()`

Detect communities using Leiden algorithm

**Yields:** `nodeId: INTEGER`, `community: INTEGER`

```gql
CALL algo.leiden.stream() YIELD nodeId, community
```

### Connectivity Analysis

#### `CALL algo.unionFind.stream()`

Find connected components using union-find

**Yields:** `nodeId: INTEGER`, `setId: INTEGER`

```gql
CALL algo.unionFind.stream() YIELD nodeId, setId
```

#### `CALL algo.scc.stream()`

Find strongly connected components

**Yields:** `nodeId: INTEGER`, `componentId: INTEGER`

```gql
CALL algo.scc.stream() YIELD nodeId, componentId
```

#### `CALL algo.articulationPoints.stream()`

Find articulation points (cut vertices)

**Yields:** `nodeId: INTEGER`

```gql
CALL algo.articulationPoints.stream() YIELD nodeId
```

#### `CALL algo.bridges.stream()`

Find bridge edges (cut edges)

**Yields:** `sourceId: INTEGER`, `targetId: INTEGER`

```gql
CALL algo.bridges.stream() YIELD sourceId, targetId
```

#### `CALL algo.biconnectedComponents.stream()`

Find biconnected components

**Yields:** `nodeId: INTEGER`, `componentId: INTEGER`

```gql
CALL algo.biconnectedComponents.stream() YIELD nodeId, componentId
```

### Path Finding

### Administrative

---

## See Also

- [GQL Compliance](GQL_COMPLIANCE.md) - ISO/IEC 39075:2024 conformance details
- [Types and Functions](TYPES_AND_FUNCTIONS.md) - Detailed type documentation
- [Quick Reference](QUICK_REFERENCE.md) - Common patterns and examples
