# Geode — Known Limitations & Workarounds

Discovered during integration testing on 2026-03-13.
Tested against v0.1.23 (local binary) and v0.1.4-beta.6 (`geodedb/geode:latest` Docker image).

---

## 1. MERGE … ON CREATE SET … RETURN fails

**Error:** `RETURN` (Geode returns a non-00000 status with the literal word "RETURN" as the error)

**Reproduction:**

```gql
MATCH (u:User {id: $userId}), (g:Group {id: $groupId})
MERGE (u)-[r:BELONGS_TO]->(g)
ON CREATE SET r.joined_at = $joinedAt
RETURN u, g, r.joined_at AS joined_at
```

**Also fails:** Simple MERGE with RETURN (no ON CREATE SET):

```gql
MATCH (a:PersonA {id: $aId}), (b:PersonB {id: $bId})
MERGE (a)-[r:FRIENDS]->(b)
RETURN a.name AS aName, b.name AS bName
-- Error: RETURN
```

**Workaround:** Use a check-then-create approach with separate queries:

```javascript
// 1. Check if relationship exists
const existing = await geode.query(
  `MATCH (u:User {id: $userId})-[r:BELONGS_TO]->(g:Group {id: $groupId})
   RETURN u, g, r.joined_at AS joined_at`,
  { userId, groupId }
);
if (existing[0]) return existing[0];

// 2. Create without RETURN
await geode.query(
  `MATCH (u:User {id: $userId})
   MATCH (g:Group {id: $groupId})
   CREATE (u)-[:BELONGS_TO {joined_at: $joinedAt}]->(g)`,
  { userId, groupId, joinedAt: now }
);

// 3. Fetch to confirm
const created = await geode.query(
  `MATCH (u:User {id: $userId})-[r:BELONGS_TO]->(g:Group {id: $groupId})
   RETURN u, g, r.joined_at AS joined_at`,
  { userId, groupId }
);
```

**Affected services:** `groupService.addUserToGroup`, `groupService.bulkAddUsersToGroup`, `featureRegistrationService`

---

## 2. LIMIT / OFFSET with parameterized values fails

**Error:** `integer_lit` (Geode expects a literal integer token, not a parameter reference)

**Reproduction:**

```gql
MATCH (n:User) RETURN n LIMIT $limit
-- with params: { limit: 10 }
-- Error: integer_lit
```

**Workaround:** Use string interpolation with validated integer:

```javascript
const safeLimit = Math.min(Math.max(parseInt(limit, 10) || 50, 1), 200);
const rows = await geode.query(
  `MATCH (n:User) RETURN n LIMIT ${safeLimit}`,
  {}
);
```

**Affected services:** `activityService.getRecentActivities`, `activityService.getUserActivities`, `activityService.getResourceTypeActivities`

---

## 3. MATCH (a), (b) CREATE (a)-[:REL]->(b) doesn't create relationships

**Symptom:** The query returns empty results AND the relationship is not created in the graph. No error is thrown.

**Reproduction:**

```gql
-- Setup
CREATE (x:CityNode {name: 'NYC'})
CREATE (y:CityNode {name: 'LA'})

-- This silently does nothing
MATCH (x:CityNode {name: $from}), (y:CityNode {name: $to})
CREATE (x)-[:ROAD {distance: $dist}]->(y)
-- Returns: [] and no relationship is created

-- Verify: no relationships exist
MATCH ()-[r:ROAD]->() RETURN r
-- Returns: []
```

**Variant — with RETURN also fails:**

```gql
MATCH (x:CityNode {name: $from}), (y:CityNode {name: $to})
CREATE (x)-[:FLIGHT]->(y)
RETURN x.name AS from_city, y.name AS to_city
-- Returns: []
```

**Workaround (partial):** Use separate MATCH clauses instead of a comma join:

```gql
MATCH (u:User {id: $userId})
MATCH (g:Group {id: $groupId})
CREATE (u)-[:BELONGS_TO {joined_at: $joinedAt}]->(g)
```

This appears to create the relationship (verified via subsequent MATCH), but does NOT return results itself. A follow-up query is needed to confirm.

**Affected services:** `genericDataService.createRelationship`, `groupService.addUserToGroup`, `graphService.traverse` (edge queries)

---

## 4. Inline CREATE with relationships loses parameter values on nodes

**Symptom:** When creating nodes and relationships in a single CREATE statement, parameter values are not bound to the node properties — they end up as `null`.

**Reproduction:**

```gql
CREATE (a:Animal {name: $aName})-[:EATS]->(b:Food {name: $bName})
RETURN a, b
-- with params: { aName: 'Cat', bName: 'Fish' }
```

**Result:**

```json
[{"a": {"name": null, "_labels": ["Animal"]}, "b": {"name": null, "_labels": ["Food"]}}]
```

The relationship IS created (verified via `MATCH ()-[r]->() RETURN r`), but both node `name` properties are `null` despite being passed as parameters.

**Plain CREATE without relationships works correctly:**

```gql
CREATE (n:Animal {name: $name})
-- name is properly set
```

**Workaround:** Create nodes first as separate statements, then create the relationship:

```javascript
await geode.query('CREATE (a:Animal {name: $name})', { name: 'Cat' });
await geode.query('CREATE (b:Food {name: $name})', { name: 'Fish' });
await geode.query(
  `MATCH (a:Animal {name: $aName})
   MATCH (b:Food {name: $bName})
   CREATE (a)-[:EATS]->(b)`,
  { aName: 'Cat', bName: 'Fish' }
);
```

**Affected services:** Any code that uses inline pattern creation (currently none in Orion — all services create nodes separately)

---

## 5. Parameterized MATCH fails for ANY relationship query (read or write)

**Symptom:** When MATCH uses `$param` syntax and the pattern includes relationship traversal (e.g. `-[:REL]->`), the query silently returns empty results. This affects **reads**, **creates**, and **deletes** — not just writes.

**Reproduction:**

```gql
-- Setup
CREATE (u:Xnode {id: 'x1', name: 'Alice'})
CREATE (g:Ynode {id: 'y1', name: 'Bob'})

-- This silently does nothing (no relationship created)
MATCH (u:Xnode {id: $uid})
MATCH (g:Ynode {id: $gid})
CREATE (u)-[:LINKED]->(g)
-- params: { uid: 'x1', gid: 'y1' }
-- Returns: [] and MATCH query confirms no relationship exists

-- This WORKS (hardcoded literals)
MATCH (u:Xnode {id: 'x1'})
MATCH (g:Ynode {id: 'y1'})
CREATE (u)-[:HARDLINKED]->(g)
-- Relationship IS created
```

**Key distinction:** `MATCH (n {id: $id}) RETURN n` works correctly with parameters when no relationship is traversed. As soon as a relationship pattern is added (even for reading), parameters cause silent failure.

**Read traversal also fails:**

```gql
-- FAILS (returns [])
MATCH (a:AAA {id: $id})-[:KNOWS]->(b:BBB) RETURN b
-- params: { id: 'a1' }

-- WORKS
MATCH (a:AAA {id: 'a1'})-[:KNOWS]->(b:BBB) RETURN b
```

**Workaround:** Use inline GQL string literals (properly escaped) instead of parameters for MATCH clauses when followed by relationship CREATE:

```javascript
function gqlLiteral(value) {
  const escaped = String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  return `'${escaped}'`;
}

const gql = `MATCH (u:User {id: ${gqlLiteral(userId)}})
             MATCH (g:Group {id: ${gqlLiteral(groupId)}})
             CREATE (u)-[:BELONGS_TO {joined_at: ${gqlLiteral(now)}}]->(g)`;
await geode.query(gql);
```

**Affected services:** All relationship creation — `groupService.addUserToGroup`, `genericDataService.createRelationship`, `featureRegistrationService.assignAdminsToFeature`

---

## 6. RETURN DISTINCT with function calls returns only one row

**Symptom:** When using `RETURN DISTINCT func(n)` where `func` returns a list/array (e.g. `labels(n)`), only one row is returned instead of all distinct values.

**Reproduction:**

```gql
-- Setup: create nodes with different labels
CREATE (a:LblA {name: 'a1'})
CREATE (b:LblB {name: 'b1'})
CREATE (c:LblC {name: 'c1'})

-- WITHOUT DISTINCT — returns all 3 rows (correct)
MATCH (n) RETURN labels(n) AS labels
-- Returns: [{labels: ["LblA"]}, {labels: ["LblB"]}, {labels: ["LblC"]}]

-- WITH DISTINCT — returns only 1 row (bug)
MATCH (n) RETURN DISTINCT labels(n) AS labels
-- Returns: [{labels: ["LblC"]}]
```

**Workaround:** Remove `DISTINCT` from the GQL query and deduplicate in application code:

```javascript
const rows = await geode.query('MATCH (n) RETURN labels(n) AS labels');
const labelSet = new Set();
for (const row of rows) {
  if (Array.isArray(row.labels)) {
    row.labels.forEach(l => labelSet.add(l));
  }
}
const uniqueLabels = Array.from(labelSet).sort();
```

**Affected services:** `schemaService.getNodeLabels`, `schemaService.getRelationshipTypes`

---

## 7. Single-quoted string literals silently become NULL (v0.1.4-beta.6 only)

**Symptom:** On the Docker image (`geodedb/geode:latest`, v0.1.4-beta.6), single-quoted string values in CREATE statements are silently stored as `null`. Only double-quoted strings work. Boolean and numeric literals are unaffected.

**Reproduction:**

```gql
-- Single quotes: values are NULL
CREATE (n:Test {name: 'Alice', age: 30}) RETURN n
-- Result: {name: null, age: 30}

-- Double quotes: values are correct
CREATE (n:Test {name: "Alice", age: 30}) RETURN n
-- Result: {name: "Alice", age: 30}
```

**Note:** This does NOT affect v0.1.23, which handles both quote styles correctly.

**Workaround:** Use double-quoted strings in `gqlLiteral`:

```javascript
function gqlLiteral(value) {
  if (value === null || value === undefined) return 'NULL';
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  const escaped = String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return `"${escaped}"`;
}
```

**Affected services:** All services using `gqlLiteral` for inline values when running against Docker image.

---

## Summary Table

| # | Issue | Error | Severity | Status |
|---|-------|-------|----------|--------|
| 1 | MERGE + RETURN | `RETURN` | High | **FIXED** — Parser now handles MATCH ... MERGE pattern |
| 2 | Parameterized LIMIT | `integer_lit` | Medium | **FIXED** — LIMIT/OFFSET now accept `$param` references |
| 3 | MATCH `,` CREATE rel | Silent no-op | High | **FIXED** — executeMatchCreateQuery now receives query parameters |
| 4 | Inline CREATE param binding | `null` values | Medium | **FIXED** — Inline CREATE hop properties use envFromContext |
| 5 | Parameterized MATCH + any relationship | Silent empty results | **Critical** | **FIXED** — Env uses `.param_names`/`.param_values` for relationship matching |
| 6 | DISTINCT with function calls | Only 1 row returned | Medium | **FIXED** — Hash key now serializes List/Map/Path contents |
| 7 | Single-quoted strings → NULL | Silent `null` values | **Critical** (v0.1.4 only) | **Won't Do** — Already fixed in v0.1.23; Docker-only issue in v0.1.4-beta.6 |

---

## Test Environments

### Local (v0.1.23)

- **Geode version:** v0.1.23 (`/usr/bin/geode`)
- **Transport:** QUIC (`quic://127.0.0.1:31410`) with `--insecure-tls-skip-verify`
- **Auth:** Admin user `geode` with password set via `ALTER USER geode SET PASSWORD`
- **CLI param format:** `--param key <json-literal>` (e.g., `--param name "\"Alice\""`)
- **String literals:** Both single and double quotes work

### Docker (v0.1.4-beta.6)

- **Image:** `geodedb/geode:latest`
- **Transport:** QUIC (`quic://soc-geode:3141`) with `--insecure-tls-skip-verify`
- **Auth:** Set via `GEODE_ADMIN_PASSWORD` env var, user `geode`
- **String literals:** Only double quotes work (single quotes → NULL)
- **Parameterized CREATE:** Also loses values (use inline literals for all CREATE)
