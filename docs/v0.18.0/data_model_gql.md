# Data Model & Query Language

Geode manages data as a property graph: vertices (nodes) and directed edges connecting them, both with user-defined properties. Nodes can be labeled (one or more), edges have a single label. Properties are schema-less name/value pairs. Each node/edge has a unique id. This aligns with ISO GQL’s property graph model (similar to Cypher conceptually).

Example GQL:
```
MATCH (p:Person)-[:KNOWS]->(f:Person)
WHERE p.age > 30
RETURN p.name AS person, f.name AS friend
```

Key features:
- Pattern matching with labels and property filters; OPTIONAL MATCH yields NULLs for missing sub-patterns (not row-elimination) (GitHub)
- Variable-length paths with bounded repetitions and deterministic ordering, e.g. `MATCH (a:Person)-[:KNOWS*1..3]->(b:Person)` (GitHub)
- Graph algorithms: `shortestPath(...)`, `allShortestPaths(...)`; returns path objects; examples supported in clients (GitHub)
- DML: `INSERT` (nodes/edges), `SET` (updates), `DELETE` and `DETACH DELETE`; edges via matched endpoints (GitHub, neo4j.com)
- Aggregations: COUNT/SUM/AVG/MIN/MAX with GROUP BY and HAVING; deterministic ORDER BY (GitHub)
- Set operations: UNION [ALL], INTERSECT, EXCEPT (GitHub)
- Subqueries & WITH: pipeline-style composition (GitHub)
- Ordering & Pagination: ORDER BY required for LIMIT/OFFSET (US001 policy); stable pagination via deterministic ties (GitHub)

Extended data types (selection):
- Numeric/Decimal (arbitrary precision)
- Temporal/Spatial (planned/partial)
- Network addresses (IP/CIDR, MAC) with helper predicates (GitHub)
- JSON objects/arrays with inverted index (GitHub)
- Specialized domain types (hash, ISO 4217 currency, BCP‑47 language tags)
- VectorF32 with HNSW for ANN similarity search (GitHub)

Diagnostics follow ISO/IEC 39075 status classes/codes; errors like unordered pagination surface US001; flagger_findings indicate implementation-defined behaviors (GitHub).