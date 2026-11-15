# GQL ISO/IEC 39075:2024 Compliance Guide

Geode passes **120/120 cases of its ISO/IEC 39075:2024 GQL conformance suite** (parse-only scope) (`tests/gql_iso_conformance.zig`), making it one of the most standards-aligned GQL implementations available. "100%" below refers to that named conformance suite — not a blanket claim of full ISO coverage; documented residual limits (e.g. recursive-CTE working-set model, no `SEARCH`/`CYCLE`, Cypher-only extensions intentionally excluded) are listed in this guide.

## 📊 Compliance Overview

- **Conformance suite**: 120/120 cases pass (the named `tests/gql_iso_conformance.zig` suite; parse-only scope — it asserts the parser accepts/rejects each form, not executed-query results)
- **Standard**: ISO/IEC 39075:2024 Graph Query Language
- **Scope**: this is the curated conformance suite, not exhaustive ISO coverage; see residual limits in this guide
- **How to run**: `zig build test-iso-conformance --summary all` (dedicated named step; 120/120 verified 2026-11-15, the NEXT, SONNY-6555 page-clause, and SONNY-6564 21.3 identifier and 16.11 quantifier cases included). The executed-query `gql_conformance` harness suite is 21/21 after GAP-0892 (T1–T20 plus the `ZZ_cleanup` teardown) (`zig build test-gql-conformance`)
- **Last Updated**: 2026-06-10 (GAP-0861 claim rebaseline)

## ✅ Fully Supported Features

### Core Keywords (105+ supported)

All ISO GQL reserved keywords are recognized and functional:

```gql
-- Query keywords
MATCH, OPTIONAL, WHERE, RETURN, WITH, ORDER, BY, LIMIT, OFFSET, DISTINCT

-- Data manipulation
CREATE, DELETE, DETACH, SET, REMOVE, MERGE, ON, MATCH

-- Aggregation
COUNT, SUM, AVG, MIN, MAX, GROUP, HAVING

-- Transactions
START, TRANSACTION, COMMIT, ROLLBACK

-- Session management
USE, GRAPH, SESSION

-- Path quantifiers
ANY, SHORTEST, ALL, WALK, TRAIL, ACYCLIC, SIMPLE

-- And many more...
```

### Case-Sensitivity Contract

Per **ISO/IEC 39075:2024 RQ-0022**, GQL reserved keywords are recognized
case-insensitively. Geode extends the same contract to built-in functions
and stored procedures so the entire language surface behaves uniformly.
User-defined identifiers (labels, property keys, variable names) remain
case-sensitive — `:Person` and `:person` are distinct labels and `p.Name`
and `p.name` are distinct properties, matching the convention used by
SQL, Cypher, and Neo4j.

| Surface                      | Case Behavior     | Examples that resolve identically                          |
|------------------------------|-------------------|-------------------------------------------------------------|
| Reserved keywords            | **Insensitive**   | `MATCH` / `match` / `MaTcH`, `RETURN` / `return`            |
| Type names                   | **Insensitive**   | `INTEGER` / `integer`, `STRING` / `string`, `BOOLEAN`       |
| Boolean / null literals      | **Insensitive**   | `TRUE` / `true`, `FALSE` / `false`, `NULL` / `null`         |
| Built-in functions           | **Insensitive**   | `count()` / `COUNT()` / `Count()`, `abs(-5)` / `ABS(-5)`    |
| Stored procedures (CALL)     | **Insensitive**   | `algo.pageRank.stream()` / `ALGO.PAGERANK.STREAM()`         |
| Procedure aliases            | **Insensitive**   | `pagerank` / `PAGERANK` / `PageRank` (all map to the alias) |
| **User identifiers** below — |                   |                                                             |
| Labels                       | **Sensitive**     | `:Person` ≠ `:person` (two different labels)                |
| Property keys                | **Sensitive**     | `n.name` ≠ `n.Name` (two different properties)              |
| Variable / alias names       | **Sensitive**     | `(p)` ≠ `(P)` (two different bindings)                      |
| Role names (RBAC)            | **Sensitive**     | `ADMIN` ≠ `admin` (security policy decision)                |
| FLE field names              | **Sensitive**     | encrypted-field metadata is matched verbatim                |

**Where this is enforced:**

- **Lexer** — `src/gql/lexer.zig:keywordKind` calls `std.ascii.toUpper`
  on every identifier and looks the result up in a comptime `KeywordMap`
  whose entries are uppercase, so all 150+ keywords match any case.
- **Function registry** — `src/gql/language_metadata.zig:findFunction`
  uses `std.ascii.eqlIgnoreCase` (matches `findKeyword` and `findType`
  which were already case-insensitive).
- **Procedure registry** — `src/execution/procedure_registry.zig:executeCallProcedure`
  calls `extractNormalizedProcName` which ASCII-lowercases the procedure
  name once at the dispatch entry point, so every domain dispatcher
  (`algo_dispatch`, `audit_dispatch`, `storage_dispatch`, `auth_dispatch`)
  can keep its existing exact-match comparisons against canonical
  lowercase literals.
- **Function evaluator** — `src/eval.zig` uses `std.ascii.eqlIgnoreCase`
  throughout the function dispatch path so any uppercase or mixed-case
  spelling that escapes the first-pass handler still resolves correctly.
- **Tests** — `tests/test_procedure_case_insensitive.zig` covers
  ABS/COALESCE/SUBSTRING/TRIM (eval path), `findFunction`/`findProcedure`
  (metadata path), and `extractNormalizedProcName` (dispatch path) with
  uppercase, lowercase, and mixed-case inputs.

### Reserved Words and Identifiers (21.3, SONNY-6564)

ISO/IEC 39075:2024 21.3 splits the keywords into 262 **reserved words**
(222, plus 40 *pre-reserved* words such as `DATA`, `PRODUCT`, `QUERY`,
`VALUES`) and 48 **non-reserved words** (`TYPE`, `PROPERTY`, `NODE`, `EDGE`,
`GRAPH`, `LABEL`, `FIRST`, `TO`, ...). Syntax Rule 18: the case-normal form
(SR 17, upper case) of an unquoted identifier shall not be a reserved word;
a *delimited identifier* (`` `match` ``) may be any word. The lists are in
`src/gql/identifier_words.zig`, with the clause references.

Geode applies the rule to every name that binds or is referenced in a query
— node, edge and path variables, `SET` / `REMOVE` / `DELETE` targets, `FOR`
and `WITH ORDINALITY` / `OFFSET` variables, `UNWIND ... AS`, `LET`, `AS`
aliases (also on `YIELD` items), parameters (`$name`, session parameters),
`VALUES` column names, CTE names and list-comprehension variables:

```gql
MATCH (type:T) SET type.x = 1 REMOVE type.y RETURN type   -- TYPE is non-reserved: OK
MATCH (match:X) RETURN match                               -- 42000: `match` is a reserved word
MATCH (`match`:X) RETURN `match`                           -- OK: a delimited identifier
RETURN count(*) AS c, upper('a')                           -- OK: a call is the built-in
```

A refusal is `42000`, naming the word and its delimited form ("`` `sum` `` is a
reserved word (ISO/IEC 39075:2024 21.3) and cannot be used as an alias ...;
write it as a delimited identifier: `` `sum` ``"). A reserved word where an
expression starts is still the construct it begins: a built-in call
(`count(...)`, `upper(...)`), `COUNT { }` / `EXISTS { }` / `VALUE { }`, a typed
literal (`DURATION 'P1D'`), `LIST [...]`, or a niladic function
(`CURRENT_DATE`, `SESSION_USER`, ...). Until SONNY-6564 the parser had the
rule backwards: `RETURN MATCH` and `MATCH (match:X) RETURN match` parsed,
while `SET` / `REMOVE` / `DELETE` / `FOR` / `UNWIND` / `LET` took only plain
identifiers, so `MATCH (type:T) SET type.x = 1` was a syntax error.

**Documented non-conformances** (Geode extensions to 21.3 SR 18):

1. **Five reserved words stay binding names: `PATH`, `VALUE`, `COUNT`, `AVG`,
   `TIMESTAMP`.** Geode's own procedures yield columns with four of these
   names, so a `YIELD` binds them (verified 2026-11-15, SONNY-6596):
   `algo.bfs.stream` / `bfs`, `algo.dfs.stream` / `dfs` and
   `algo.dijkstra.stream` / `algo.shortestPath.dijkstra` / `dijkstra` yield
   `path` (src/execution/algo_dispatch.zig); `geode.ts.range`, `last` and
   `sample_by` yield `value` and `geode.ts.bucket_avg` yields `avg`
   (src/execution/ts_dispatch.zig); `geode.rls.policy_count` yields `count`
   (src/execution/rls_dispatch.zig). No procedure yields `timestamp` any
   more: the CDC procedures that did are refused (0A000, SONNY-6570), so
   `TIMESTAMP` stays a binding name for existing queries only. Renaming the
   columns (and then dropping this deviation) is a breaking change for every
   client and is a pending decision. They are also the reserved words most used as
   names: of 14,410 queries in Geode's tests, docs and examples and the
   integration-harness specs, a strict rule refused 260, and 123 of those
   used one of these five (`PATH` 56, `VALUE` 41, `COUNT` 20, `AVG` 4,
   `TIMESTAMP` 2). Each stays unambiguous (a call needs `(`, `COUNT { }` a
   brace, a typed literal a string, and a path-search prefix never starts
   with `PATH`).
2. **Labels, relationship types, property names and property keys take any
   word**, a reserved one included (`(o:Order {value: 1, data: 2})`,
   `n.count`). 21.3 makes `<label name>` and `<property name>` identifiers
   too, but a name is all these positions can hold, and the corpus above uses
   reserved words there thousands of times (`{value: ...}` and `{data: ...}`
   keys alone about 4,250 times in the harness specs, `n.value` 411 times, the
   labels `Product`, `Project` and `Next` about 120 times).
3. **A delimited identifier may name a binding variable** (`` (`match`) ``):
   21.3 makes a `<binding variable>` a `<regular identifier>`.
4. **A double-quoted sequence where an expression starts is a string
   literal.** 21.3 makes a `<double quoted character sequence>` a
   `<delimited identifier>` as well as (21.2) a `<character string
   literal>`. Where only a name can stand, Geode reads `"name"` as a
   delimited identifier, as `` `name` `` (SONNY-6596): a node, edge or path
   variable (`("n":L)`, `-["r"]->`, `"p" = (...)`), a label or relationship
   type (`:"My Label"`), a property name (`n."k"`), an alias (`AS "x"`), a
   `FOR` or `LET` variable, a parameter name (`$"p"`); a doubled
   quote stands for one and an empty one is refused (SR 4). Where an
   expression starts, the grammar admits both a `<character string literal>`
   and a `<binding variable reference>` (20.x) and gives no rule to choose:
   Geode reads the literal there (`RETURN "x"` is the string `'x'`; write a
   variable reference as `x` or `` `x` ``).

Every other reserved word (257 of 262) is refused as an unquoted binding
name. Of the 14,410 queries, 141 are refused: 44 of Geode's own (35 test
query literals and 8 doc examples, corrected; the rest expect the refusal)
and 97 in 39 integration-harness specs.

### Data Types & Literals

```gql
-- Primitive types
RETURN true, false, null
RETURN 42, -123, 3.14, 'hello world'

-- Numeric literals (21.2): exact without an exponent, approximate with one
RETURN 3.14      -- DECIMAL (exact numeric literal)
RETURN 1.5E0     -- DOUBLE  (approximate numeric literal, SONNY-6596)

-- Temporal types
RETURN date('2024-01-15')
RETURN datetime('2024-01-15T14:30:00')
RETURN time('14:30:00')

-- Collections
RETURN [1, 2, 3]
RETURN {name: 'Alice', age: 30}
```

### Graph Pattern Matching

```gql
-- Basic patterns
MATCH (person:Person) RETURN person

-- Relationship patterns
MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b

-- Variable-length paths
MATCH (a)-[*1..3]->(b) RETURN a, b
MATCH (a)-[*..5]->(b) RETURN a, b
MATCH (a)-[*2..]->(b) RETURN a, b

-- Path variables
MATCH path = (a)-[:KNOWS]->(b) RETURN path

-- Multiple patterns
MATCH (a)-[]->(b), (b)-[]->(c) RETURN a, b, c

-- Optional matching
OPTIONAL MATCH (n)-[]->(m) RETURN n, m

-- Abbreviated edge patterns (16.7)
MATCH (a)-(b) RETURN a, b      -- any direction
MATCH (a)<-(b) RETURN a, b     -- pointing left
MATCH (a)<->(b) RETURN a, b    -- left or right
```

**Abbreviated edge patterns (ISO/IEC 39075:2024 16.7, SONNY-6267).** The
<abbreviated edge pattern> tokens `<-`, `->` and `-` (Feature G044) and
`<->` (G045) parse and match; each is the empty full edge pattern of its
orientation (`-` is `-[ ]-`, `<->` is `<-[ ]->`). Every Geode edge is
directed, so `-`, `<->`, `-[ ]-` and `<-[ ]->` all match an edge in either
direction. The tilde forms `~`, `<~` and `~>` (and `~[ ]~` etc.) match
undirected edges, which Geode does not store (GH02): refused with 0A000.
`<--` is not GQL: 16.7 SR forbids juxtaposing `<-` with `-` without a
separator, because the two minus signs spell a <simple comment introducer>
(NOTE 238); it is a syntax error naming the GQL spellings. (`--(` and
`-->` are still accepted for compatibility.) Regression: `zig build
test-sonny6267-abbreviated-edge-patterns`.

### Operators & Expressions

```gql
-- Comparison operators
RETURN 1 = 1, 2 <> 2, 3 < 4, 5 >= 5

-- Logical operators  
RETURN true AND false, true OR false, NOT true

-- Arithmetic operators
RETURN 1 + 2 - 3 * 4 / 5

-- String operators
RETURN 'hello' || ' world'
RETURN 'hello' STARTS WITH 'he'
RETURN 'world' ENDS WITH 'ld'
RETURN 'hello world' CONTAINS 'lo wo'

-- Pattern matching
RETURN text =~ 'pattern.*'

-- Set operations
RETURN 1 IN [1, 2, 3]
RETURN x IS NULL
```

### Built-in Functions

#### Aggregation Functions

```gql
RETURN COUNT(*), COUNT(DISTINCT n.id)
RETURN SUM(n.value), AVG(n.age)
RETURN MIN(n.score), MAX(n.score)
```

#### String Functions

```gql
RETURN length('hello'), upper('world'), lower('HELLO')
RETURN substring('hello', 1, 3), replace('hello world', 'world', 'universe')
RETURN trim(' text '), reverse('hello'), split('a,b,c', ',')
```

#### Math Functions

```gql
RETURN abs(-5), sqrt(16), ceil(3.2), floor(3.8), round(3.5)
RETURN sign(-5), log(10), exp(2), rand()
```

#### List Functions

```gql
RETURN size([1,2,3]), head([1,2,3]), tail([1,2,3]), last([1,2,3])
RETURN range(1, 10)
```

`range(start, end[, step])` is a Geode extension: ISO/IEC 39075:2024 defines
no `range` function. Its end is **exclusive** (half-open, like Python's
`range`): `range(1, 10)` is `[1, 2, ..., 9]`, `range(1, 7, 2)` is
`[1, 3, 5]`, `range(5, 1, -2)` is `[5, 3]`. openCypher's `range()` includes
its end; a query ported from Cypher must add 1 (or subtract 1 for a negative
step) to the end. See [TYPES_AND_FUNCTIONS.md](TYPES_AND_FUNCTIONS.md#list-functions).

#### Type Functions

```gql
RETURN type(value), exists(n.property)
RETURN toString(123), toInteger('456')
```

#### Utility Functions

```gql
RETURN now(), rand()
```

### Data Manipulation Language (DML)

```gql
-- Creating nodes and relationships
CREATE (alice:Person {name: 'Alice', age: 30})
CREATE (alice)-[:KNOWS]->(bob)

-- Setting properties
MATCH (n:Person) SET n.updated = now()
MATCH (n) SET n.property = value

-- Removing properties
MATCH (n) REMOVE n.temporary_field

-- Deleting elements
MATCH (n:Person) DELETE n
MATCH (n) DETACH DELETE n

-- Merge (upsert) operations
MERGE (person:Person {email: 'alice@example.com'})
ON CREATE SET person.created = datetime()
ON MATCH SET person.last_seen = now()
```

### Query Composition

```gql
-- WITH clauses for query chaining
MATCH (person:Person)
WITH person.name AS name, count(person) AS count
WHERE count > 1
RETURN name, count

-- Ordering and pagination (14.9: the offset clause, OFFSET or SKIP,
-- before the limit clause; also after a WITH, a UNION and a FOR's RETURN)
MATCH (n:Person)
RETURN n.name, n.age
ORDER BY n.age DESC, n.name ASC
OFFSET 20 LIMIT 10
-- Geode extension: LIMIT 10 OFFSET 20 (limit first) means the same page.

-- Grouping and aggregation
MATCH (person:Person)-[:WORKS_AT]->(company:Company)
RETURN company.name, COUNT(person) AS employees
ORDER BY employees DESC
```

### Linear Composition with `NEXT` (9.2, Feature GQ20)

`<statement> NEXT [<yield clause>] <statement>` (ISO/IEC 39075:2024 9.2
`<procedure body>`): the result table of the statement before `NEXT` is the
working table of the one after it (9.2 GR 4), narrowed and renamed by an
optional `YIELD` (16.14). Geode runs it as its WITH chain: the `RETURN`
before `NEXT` projects the rows the next statement continues from, with its
`DISTINCT`, aggregates, `GROUP BY`, `ORDER BY`, `OFFSET` and `LIMIT`
(SONNY-6343).

```gql
MATCH (n:Person) RETURN n.city AS city, count(*) AS c
NEXT MATCH (m:Person) WHERE m.city = city AND c > 1 RETURN m.name

MATCH (n:Person) RETURN n.name AS name, n.age AS age ORDER BY age DESC LIMIT 3
NEXT YIELD name AS top RETURN top

RETURN 1 AS a NEXT RETURN a + 1 AS b NEXT RETURN b * 10 AS c
```

Refused with `0A000`: a `NEXT` after a statement with no `RETURN` at its
level (it has no result table), and a `NEXT` after a `UNION`, `INTERSECT`,
`EXCEPT` or `OTHERWISE`. A name the `RETURN` does not project reads `NULL`
after `NEXT` (as after a `WITH`) instead of being refused (a known
WITH-chain scoping defect). Covered by `zig build test-sonny6343-next-and-call`.

### Common Table Expressions (`WITH [RECURSIVE]`)

Geode executes both simple and recursive Common Table Expressions
(ISO/IEC 39075:2024 §7.18). A CTE's result is bound under its name as a list
value (one map per produced row) and is reachable from the main query and, for
recursive CTEs, from the recursive term via `UNWIND <cte> AS x`.

```gql
-- Simple (non-recursive) CTE: body runs once, bound as a named list value.
WITH evens AS (RETURN 2 AS n)
RETURN evens

-- Recursive CTE: anchor seeds the working set; the recursive term self-
-- references it with UNWIND and is re-run to a fixpoint. A WHERE in the
-- recursive term bounds the recursion (terminates by predicate). This yields
-- n = 1..5:
WITH RECURSIVE nums AS (
  RETURN 1 AS n
  UNION ALL
  UNWIND nums AS prev WHERE prev.n < 5 RETURN prev.n + 1 AS n
)
RETURN nums

-- Reachability / transitive closure: encode the successor relation in the
-- recursive term. Over a 1->2->3->4 chain, reachability from node 1 (anchor =
-- first hop, node 2) yields {2, 3, 4}:
WITH RECURSIVE reach AS (
  RETURN 2 AS node
  UNION
  UNWIND reach AS r WHERE r.node < 4 RETURN r.node + 1 AS node
)
RETURN reach
```

Verified semantics (regression-covered by `tests/e2e_recursive_queries.zig`,
the `test-recursive-cte` build step):

- **Fixpoint evaluation** — execute the anchor, then re-run the recursive term
  against only the previous iteration's NEW rows (the delta working set),
  accumulating each iteration's output into the final result, until an iteration
  produces no new rows (or the iteration cap is reached).
- **`WHERE` in the recursive term IS applied** — it bounds/terminates the
  recursion by predicate (transitive closure, bounded depth).
- **`UNION ALL` vs `UNION`** — `UNION ALL` keeps every produced row; `UNION`
  deduplicates against the accumulated set, which also terminates a cycle whose
  step only revisits already-seen rows.
- **Cycle safety via an iteration cap** — a cyclic `UNION ALL` recursion with no
  predicate is bounded by a hard cap of **100 iterations** (the
  `RECURSIVE_CTE_MAX_ITERATIONS` constant in
  `src/execution/query_execution.zig`); it terminates with a finite, capped
  result rather than hanging.

Residual limits (not yet supported / not covered):

- The recursive term operates on the working-set **list value** (consumed with
  `UNWIND`), not directly on live graph nodes. Graph reachability is modeled by
  encoding the successor relation (arithmetic / `CASE`) in the recursive term.
  Driving a recursive CTE off live `MATCH`-ed graph edges, and SQL-style
  `SEARCH` / `CYCLE` clauses, are not implemented.
- Property access on the bound CTE value (`RETURN cte.col`) returns the list,
  not per-row columns; use `UNWIND <cte> AS x` to project rows.
- For arbitrary-depth graph traversal prefer variable-length path patterns
  (`MATCH (a)-[:REL*1..10]->(b)`) or `MATCH SHORTEST`.

### Session & Transaction Management

```gql
-- Session management
USE GRAPH social_network
SET SESSION GRAPH = 'production'

-- Transaction control
START TRANSACTION
MATCH (n:Person) SET n.processed = true
COMMIT

-- Alternative rollback
START TRANSACTION
CREATE (n:Test)
ROLLBACK
```

### Procedure Calls

```gql
-- Basic procedure calls
CALL db.labels()
CALL db.propertyKeys()

-- With YIELD clause
CALL db.labels() YIELD label
RETURN label ORDER BY label

-- With RETURN clause
CALL db.schema.nodeTypeProperties()
YIELD nodeType, propertyName, propertyTypes
RETURN nodeType, collect(propertyName) AS properties

-- Filtering a procedure's rows: the FILTER statement (14.6)
CALL db.labels() YIELD label
FILTER label <> 'Internal'
RETURN label ORDER BY label
```

#### Inline procedure calls (`CALL { }`, 15.2)

| Form | Status |
|------|--------|
| `CALL { <query> } RETURN ...` (with `GROUP BY`, `ORDER BY`, `SKIP`, `LIMIT`) | Supported |
| `CALL { <query> } WITH ... [WHERE ...] RETURN ...` | Supported |
| `CALL { ... }` inside an `IN (subquery)` (read-only) | Supported (SONNY-3248) |
| `CALL { ... }` followed by `MATCH`, a second `CALL`, or a write | Refused, `0A000` |
| `MATCH ... CALL { ... }` (a subquery per matched row) | Refused, `0A000` |
| `CALL (x, y) { ... }` (a variable scope clause) | Refused, `0A000` |
| `OPTIONAL CALL ...` | Refused, `0A000` |

Each refusal names the form; none is run in part (SONNY-6343,
`zig build test-sonny6343-next-and-call`).

### FILTER Statement (14.6)

`FILTER { <where clause> | <search condition> }` is a primitive query
statement (14.3): `FILTER WHERE c` and `FILTER c` are the same statement
(14.6 SR 2). Geode accepts it after `MATCH` (also after the MATCH's WHERE),
after `CALL ... [YIELD ...]`, and after `MATCH ... CALL ... YIELD ...`, any
number of times in a row. It keeps a row only when the condition is True;
False and Unknown (NULL) drop it (16.13 GR 2, 19.1 GR 2). After a `CALL`
the condition sees the yielded columns by the names the `YIELD` gives them
(aliases included); after `MATCH ... CALL` it also sees the MATCH variables.

```gql
MATCH (n:Person) FILTER n.age >= 18 FILTER WHERE n.active RETURN n.name
MATCH (p:Person) CALL db.labels() YIELD label FILTER label <> 'Person' RETURN p.name, label
```

A `WHERE` directly after `YIELD` (the Cypher form) is not ISO GQL (16.14
<yield clause> is `YIELD <yield item list>` only) and is refused with
42000, naming the FILTER form. A FILTER after an inline `LET` sees the
LET's variables (`MATCH (n) LET x = n.a * 2 FILTER x > 2 RETURN n`), and a
FILTER between two MATCH statements filters the rows matched so far
(`MATCH (a) FILTER a.k > 1 MATCH (a)-[:R]->(b) RETURN b`); a FILTER before
CREATE or MERGE is refused (SONNY-6467). Regression: `zig build
test-sonny6460-filter-statement`, `zig build test-sonny6467-query-residuals`.

## 🔧 Advanced Features

### Path Quantifiers

Variable-length edge patterns, in the ISO/IEC 39075:2024 16.11 form (Feature
G036, quantified edges; G060 bounded, G061 unbounded) or the Cypher form
inside the brackets. Both set the same length bounds and run on the same
variable-length expansion (SONNY-6564):

```gql
-- ISO 16.11 <graph pattern quantifier> after the edge pattern
MATCH (a)-[:R]->{1,2}(b) RETURN b      -- 1 to 2 hops
MATCH (a)-[:R]->{2}(b) RETURN b        -- exactly 2 (fixed quantifier)
MATCH (a)-[:R]->{1,}(b) RETURN b       -- at least 1
MATCH (a)-[:R]->{,3}(b) RETURN b       -- 0 to 3 (16.11 SR 2 d: lower bound 0)
MATCH (a)-[:R]->+(b) RETURN b          -- {1,}
MATCH (a)-[:R]->*(b) RETURN b          -- {0,}
MATCH (a)->{1,2}(b) RETURN b           -- an abbreviated edge, quantified

-- Cypher form, inside the brackets
MATCH (a)-[*]->(b) RETURN a, b         -- 1 or more (not ISO `*`, which is {0,})
MATCH (a)-[*3]->(b) RETURN a, b        -- exactly 3
MATCH (a)-[*2..5]->(b) RETURN a, b     -- 2 to 5
MATCH (a)-[*3..]->(b) RETURN a, b      -- at least 3
MATCH (a)-[*..4]->(b) RETURN a, b      -- 1 to 4
```

16.11 SR 3 is enforced: an upper bound must be above 0 and not below the
lower bound (`{0}`, `{3,1}` are 42000), and an edge takes one quantifier
(`-[:R*1..2]->{1,2}` is 42000). Not supported: a quantified parenthesized
path pattern, `((a)-[:R]->(b)){1,3}` (Feature G035, quantified paths).

### Error Handling

Comprehensive syntax validation with clear error messages:

```gql
-- Invalid syntax examples (will fail with clear errors)
MATCH (n:) RETURN n           -- Missing label name
RETURN (1 + 2                 -- Unclosed parenthesis
RETURN MATCH                  -- Reserved word as an identifier (21.3): 42000
```

## ✅ Complex Path Variable Assignment (Fixed January 2026)

Complex path variable assignment with labels, relationship types, and variable-length patterns now works correctly:

```gql
-- This pattern now works (GAP-0182 resolved)
MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person)
RETURN a.name, b.name, length(path)

-- All variations work correctly:
MATCH path = (a)-[*2..4]->(b) RETURN path
MATCH path = (a:Person)-[:KNOWS]->(b:Person) RETURN path
MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person) RETURN length(path) AS hops, b.name AS reachable
```

**Implementation Evidence:**

- Path variable binding in `src/execution/match_operations.zig:5320-5380`
- `length(path)` function in `src/eval.zig:3197-3205`
- Comprehensive tests in `geodetestlab/specs/gap_0180_0182_fixes.yml`

### Path Mode Specifiers

**Fully implemented as of January 2026** per ISO/IEC 39075:2024:

```gql
-- All path modes parsed AND executed with correct semantics
MATCH SHORTEST (a)-[*]->(b) RETURN a, b      -- Shortest path (Dijkstra-based)
MATCH ANY SHORTEST (a)-[*]->(b) RETURN a, b  -- Any shortest path
MATCH WALK (a)-[*]->(b) RETURN a, b          -- No restrictions (can revisit nodes/edges)
MATCH TRAIL (a)-[*]->(b) RETURN a, b         -- Edges cannot repeat
MATCH ACYCLIC (a)-[*]->(b) RETURN a, b       -- No repeated nodes (no cycles)
MATCH SIMPLE (a)-[*]->(b) RETURN a, b        -- No repeated nodes except start=end allowed
```

**Implementation Details**:

- Path modes stored in AST `Chain.path_mode` field
- `expandVariableLengthPathsWithMode()` in execution.zig handles all modes
- WALK allows full revisitation for graph exploration
- TRAIL ensures edge uniqueness for traversal analysis
- ACYCLIC prevents all cycles (default for backward compatibility)
- SIMPLE enables cycle detection (start node can equal end node)

## 🧪 Testing & Validation

### Running Compliance Tests

```bash
# Run the full compliance test suite
zig run test_gql_compliance.zig

# Debug specific syntax issues
zig run debug_set_parsing.zig

# Run all tests including compliance
make test
```

### Test Categories

The compliance suite tests these areas:

1. **Keywords**: All 105+ ISO GQL reserved words
2. **Data Types**: Primitive and complex type literals
3. **Graph Patterns**: Node, relationship, and path patterns
4. **Operators**: Comparison, logical, arithmetic, string
5. **Functions**: Aggregation, string, math, list, type functions
6. **Query Clauses**: WITH, ORDER BY, LIMIT, DISTINCT, etc.
7. **DML Operations**: CREATE, DELETE, SET, REMOVE, MERGE
8. **Session Management**: USE GRAPH, SET SESSION
9. **Transactions**: START, COMMIT, ROLLBACK
10. **Complex Queries**: Multi-clause and nested patterns

### Expected Output

```
🔍 GQL ISO/IEC 39075:2024 Compliance Test Suite
================================================

✅ MATCH keyword
✅ WHERE keyword
✅ CREATE keyword
... (96 passing tests)

==================================================
COMPLIANCE SUMMARY
==================================================
✅ Passed: 96
❌ Failed: 0
📊 Total:  96

🟢 Named conformance suite green (parse-only scope)
See residual limits in this guide — not a blanket full-ISO claim
```

## 📚 Additional Resources

- **ISO/IEC 39075:2024**: Official Graph Query Language standard
- **Test Files**:
  - `test_gql_compliance.zig` - Main compliance test suite
  - `debug_set_parsing.zig` - Debug utilities for syntax testing
- **Implementation Files**:
  - `src/gql/token.zig` - Lexer with all GQL keywords
  - `src/gql/parser.zig` - Parser with complete syntax support
  - `src/gql/ast.zig` - AST structures for all GQL constructs

## 🚫 Residual Limits — Intentionally Unsupported Statements (GAP-0871)

These forms parse but are refused with a **stable, documented contract** — not
silently ignored and not a moving target:

- **GQL `BACKUP ... TO` / `RESTORE ... FROM` statements are unsupported.** The
  parser accepts the forms (including `WITH INCREMENTAL/COMPRESSED/ENCRYPTED`,
  `VERIFY ONLY`, and `TO TIMESTAMP '<ts>'`), and the executor refuses every one
  with the named error `GqlBackupRestoreUnsupported`, surfaced on the wire as
  SQLSTATE **`0A000`** ("feature not supported") with a message naming the
  supported alternative. **The supported surface is the engine-backed CLI:**
  `geode backup create --output <file>` (a local file: there is no S3 /
  DigitalOcean Spaces target, and an `s3://` output is refused) and `geode restore <file> --data-dir <dir>` (a local
  backup file, restored offline into a new or empty directory). Regression:
  `tests/test_gap0871_gql_backup_refusal.zig` (`zig build test-gap0871`).
- **Recursive CTE `SEARCH` / `CYCLE` clauses are not implemented.**
  `WITH RECURSIVE` follows the working-set list-value model documented under
  [Common Table Expressions](#common-table-expressions-with-recursive) above:
  the recursive term operates on the accumulated working-set value (consumed
  with `UNWIND`), cycle safety comes from the 100-iteration hard cap
  (`RECURSIVE_CTE_MAX_ITERATIONS`), and depth/breadth ordering (`SEARCH`) or
  explicit cycle-mark columns (`CYCLE`) are unavailable. For arbitrary-depth
  graph traversal prefer variable-length path patterns
  (`MATCH (a)-[:REL*1..10]->(b)`) or `MATCH SHORTEST`.

## 🚀 Future Enhancements

All core GQL features are now fully implemented. Future work focuses on:

1. **Advanced Functions**: Additional built-in functions as they are standardized
2. **Performance Optimization**: Continued query execution performance improvements
3. **Extended Compliance**: Support for future GQL standard extensions
4. **GPU Acceleration**: Hardware-accelerated graph traversal operations

Geode's 109/109 ISO conformance-suite pass rate (parse-only scope) and broad GQL feature coverage make it a strong choice for graph applications that need standards-aligned query language support. Single-tenant deployments are development-ready; review the [Known Limitations](../CLAUDE.md#known-limitations) (multi-tenant, distributed cluster, backup) before production deployment.
