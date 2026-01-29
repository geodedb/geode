# Geode API Reference

## Index Operations

### CREATE INDEX

Creates an index on node properties for improved query performance.

#### Syntax

```gql
CREATE [UNIQUE] INDEX [IF NOT EXISTS] index_name
ON label(property[, ...])
[USING {btree | hash | fulltext | spatial | vector}]
```

#### Parameters

- `UNIQUE`: Optional. Creates a unique constraint on the indexed property
- `IF NOT EXISTS`: Optional. Prevents error if index already exists
- `index_name`: Name of the index to create
- `label`: Node label to index
- `property`: Property or properties to index
- `USING`: Optional. Specifies index type (default: btree)

#### Index Types

##### btree (Default)

B-tree index for range queries and sorted access.

```gql
CREATE INDEX person_age_idx ON Person(age) USING btree;
```

##### hash

Hash index for exact match lookups.

```gql
CREATE INDEX person_email_idx ON Person(email) USING hash;
```

##### fulltext

Full-text search index with tokenization and ranking.

```gql
CREATE INDEX article_content_idx ON Article(content) USING fulltext;
```

##### spatial

R-tree index for geographic and spatial data.

```gql
CREATE INDEX location_coords_idx ON Location(coordinates) USING spatial;
```

##### vector

HNSW index for vector similarity search.

```gql
CREATE INDEX embedding_idx ON Document(embedding) USING vector;
```

### DROP INDEX

Removes an existing index.

#### Syntax

```gql
DROP INDEX [IF EXISTS] index_name
```

#### Parameters

- `IF EXISTS`: Optional. Prevents error if index doesn't exist
- `index_name`: Name of the index to drop

#### Example

```gql
DROP INDEX IF EXISTS person_age_idx;
```

## Backup and Restore

### BACKUP TO

Creates a backup of the database.

#### Syntax

```gql
BACKUP TO 'file_path' [OPTIONS]
```

#### Parameters

- `file_path`: Path where backup file will be created

#### Options

- `COMPRESSED`: Enable gzip compression
- `INCREMENTAL`: Create incremental backup (requires base backup)
- `METADATA ONLY`: Backup only schema and indexes, not data

#### Examples

```gql
-- Full backup
BACKUP TO '/backups/full_backup.bak';

-- Compressed backup
BACKUP TO '/backups/compressed.bak.gz' COMPRESSED;

-- Incremental backup
BACKUP TO '/backups/incremental.bak' INCREMENTAL FROM '/backups/full_backup.bak';
```

### RESTORE FROM

Restores database from a backup file.

#### Syntax

```gql
RESTORE FROM 'file_path' [TIMESTAMP timestamp] [VERIFY ONLY]
```

#### Parameters

- `file_path`: Path to backup file
- `TIMESTAMP`: Optional. Restore to specific point in time
- `VERIFY ONLY`: Optional. Verify backup integrity without restoring

#### Examples

```gql
-- Basic restore
RESTORE FROM '/backups/full_backup.bak';

-- Point-in-time restore
RESTORE FROM '/backups/full_backup.bak' TIMESTAMP '2024-01-15T10:30:00Z';

-- Verify backup
RESTORE FROM '/backups/full_backup.bak' VERIFY ONLY;
```

## Variable-Length Path Patterns

### Syntax

```gql
(start)-[relationship*min..max]->(end)
```

### Patterns

#### Any Length (*)

Matches paths of any length.

```gql
MATCH (a:Person)-[*]->(b:Company) RETURN b;
```

#### Exact Length (*n)

Matches paths of exactly n hops.

```gql
MATCH (a:Person)-[*2]->(b:Person) RETURN b;
```

#### Range (*min..max)

Matches paths between min and max hops.

```gql
MATCH (a:Person)-[*1..3]->(b:Person) RETURN b;
```

#### Up To (*..max)

Matches paths up to max hops.

```gql
MATCH (a:Person)-[*..5]->(b:Person) RETURN b;
```

#### At Least (*min..)

Matches paths of at least min hops.

```gql
MATCH (a:Person)-[*2..]->(b:Person) RETURN b;
```

### Functions

#### length(path)

Returns the length of a path.

```gql
MATCH path = (a)-[*]->(b) RETURN length(path);
```

#### nodes(path)

Returns all nodes in a path.

```gql
MATCH path = (a)-[*]->(b) RETURN nodes(path);
```

#### relationships(path)

Returns all relationships in a path.

```gql
MATCH path = (a)-[*]->(b) RETURN relationships(path);
```

#### shortestPath()

Finds the shortest path between nodes.

```gql
MATCH path = shortestPath((a:Person)-[*]->(b:Company))
RETURN path;
```

#### allShortestPaths()

Finds all shortest paths between nodes.

```gql
MATCH path = allShortestPaths((a:Person)-[*]->(b:Company))
RETURN path;
```

## Vector Operations

### Vector Search Functions

#### similarity(vector1, vector2)

Calculates similarity between two vectors (0 to 1, higher is more similar).

```gql
MATCH (d:Document)
WHERE similarity(d.embedding, [0.1, 0.2, 0.3]) > 0.8
RETURN d;
```

#### distance(vector1, vector2, metric)

Calculates distance between vectors using specified metric.

```gql
MATCH (d:Document)
WHERE distance(d.embedding, [0.1, 0.2, 0.3], 'l2') < 0.5
RETURN d;
```

Supported metrics:

- `'l2'`: Euclidean distance
- `'cosine'`: Cosine distance (1 - cosine similarity)
- `'dot'`: Negative dot product

#### knn(property, query_vector, k)

Returns k nearest neighbors.

```gql
MATCH (d:Document)
WITH d, knn(d.embedding, [0.1, 0.2, 0.3], 10) AS neighbors
RETURN neighbors;
```

## Spatial Operations

### Spatial Functions

#### point(x, y)

Creates a 2D point.

```gql
CREATE (l:Location {coordinates: point(40.7128, -74.0060)});
```

#### distance(point1, point2)

Calculates distance between two points.

```gql
MATCH (l:Location)
WHERE distance(l.coordinates, point(40.0, -74.0)) < 100
RETURN l;
```

#### within(geometry, boundary)

Tests if geometry is within boundary.

```gql
MATCH (l:Location)
WHERE within(l.coordinates, polygon(...))
RETURN l;
```

#### bbox(min_x, min_y, max_x, max_y)

Creates a bounding box for spatial queries.

```gql
MATCH (l:Location)
WHERE intersects(l.area, bbox(40.0, -75.0, 41.0, -73.0))
RETURN l;
```

## Full-Text Search

### Text Search Functions

#### CONTAINS

Searches for text within a property.

```gql
MATCH (a:Article)
WHERE a.content CONTAINS 'graph database'
RETURN a;
```

#### STARTS WITH

Matches text at the beginning of a property.

```gql
MATCH (p:Person)
WHERE p.name STARTS WITH 'John'
RETURN p;
```

#### ENDS WITH

Matches text at the end of a property.

```gql
MATCH (e:Email)
WHERE e.address ENDS WITH '@example.com'
RETURN e;
```

#### REGEX

Matches using regular expressions.

```gql
MATCH (p:Product)
WHERE p.code =~ '^SKU-[0-9]{4}$'
RETURN p;
```

#### score()

Returns relevance score for full-text search results.

```gql
MATCH (a:Article)
WHERE a.content CONTAINS 'machine learning'
RETURN a, score() AS relevance
ORDER BY relevance DESC;
```

## Index Management

### SHOW INDEXES

Lists all indexes in the database.

```gql
SHOW INDEXES;
```

Returns:

- Index name
- Label
- Properties
- Type (btree, hash, fulltext, spatial, vector)
- Unique constraint
- Statistics (entries, size, last updated)

### ANALYZE INDEX

Updates index statistics for query optimization.

```gql
ANALYZE INDEX index_name;
```

### REBUILD INDEX

Rebuilds an index from scratch.

```gql
REBUILD INDEX index_name;
```

## Transaction Control

### BEGIN

Starts a new transaction.

```gql
BEGIN;
```

### COMMIT

Commits the current transaction.

```gql
COMMIT;
```

### ROLLBACK

Rolls back the current transaction.

```gql
ROLLBACK;
```

### SAVEPOINT

Creates a savepoint within a transaction.

```gql
SAVEPOINT my_savepoint;
```

### ROLLBACK TO

Rolls back to a specific savepoint.

```gql
ROLLBACK TO my_savepoint;
```

## System Functions

### db.info()

Returns database information.

```gql
RETURN db.info();
```

### db.indexes()

Returns index information.

```gql
RETURN db.indexes();
```

### db.stats()

Returns database statistics.

```gql
RETURN db.stats();
```

### db.constraints()

Returns constraint information.

```gql
RETURN db.constraints();
```

## Error Codes

Geode follows ISO/IEC SQL error code standards:

- `00000`: Success
- `0A000`: Feature not supported
- `22000`: Data exception
- `23000`: Integrity constraint violation
- `42000`: Syntax error or access rule violation
- `42P01`: Undefined table
- `42P07`: Duplicate table/index
- `53000`: Insufficient resources
- `58000`: System error
- `XX000`: Internal error

## Performance Tips

### Index Usage

1. Create indexes on frequently queried properties
2. Use unique indexes for properties with high cardinality
3. Use hash indexes for exact match queries only
4. Use btree indexes for range queries and sorting
5. Use vector indexes for similarity search
6. Use spatial indexes for geographic queries

### Query Optimization

1. Use EXPLAIN to understand query plans
2. Limit result sets with LIMIT clause
3. Filter early in the query with WHERE clauses
4. Use index hints when necessary
5. Avoid cartesian products without filters

### Backup Best Practices

1. Schedule regular full backups
2. Use incremental backups between full backups
3. Enable compression for large databases
4. Verify backups regularly with VERIFY ONLY
5. Store backups in multiple locations
6. Test restore procedures periodically
