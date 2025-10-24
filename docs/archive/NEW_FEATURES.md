# New Features Documentation

## Recent Additions (v0.19.0-dev)

This document describes the new features recently added to Geode Graph Database.

## 1. Index Operations

### CREATE INDEX

Geode now supports creating various types of indexes on node properties for improved query performance.

#### Syntax
```gql
CREATE [UNIQUE] INDEX [IF NOT EXISTS] index_name 
ON label(property1[, property2, ...]) 
[USING {btree | hash | fulltext | spatial | vector}]
```

#### Examples
```gql
-- Create a simple btree index
CREATE INDEX person_name_idx ON Person(name);

-- Create a unique index
CREATE UNIQUE INDEX person_email_idx ON Person(email);

-- Create index with specific type
CREATE INDEX location_idx ON Place(coordinates) USING spatial;

-- Create composite index on multiple properties
CREATE INDEX person_composite_idx ON Person(lastName, firstName);

-- Conditional creation
CREATE INDEX IF NOT EXISTS person_age_idx ON Person(age);
```

#### Supported Index Types
- **btree** (default): B-tree index for range queries and exact matches
- **hash**: Hash index for exact match lookups
- **fulltext**: Full-text search index (implementation in progress)
- **spatial**: R-tree index for geographic/spatial data (implementation in progress)
- **vector**: HNSW index for vector similarity search (implementation in progress)

### DROP INDEX

Remove an existing index from the database.

#### Syntax
```gql
DROP INDEX [IF EXISTS] index_name
```

#### Examples
```gql
-- Drop an index
DROP INDEX person_name_idx;

-- Conditional drop
DROP INDEX IF EXISTS old_index;
```

## 2. Backup and Restore Operations

### BACKUP TO

Create a backup of the database to a specified file path.

#### Syntax
```gql
BACKUP TO 'file_path'
```

#### Examples
```gql
-- Create a backup
BACKUP TO '/backups/geode_backup_2024.bak';

-- Backup to relative path
BACKUP TO './backups/daily.bak';
```

#### Backup File Format
- Header with version information
- Timestamp of backup creation
- Node and edge counts
- Index metadata
- Graph data (nodes, edges, properties)

### RESTORE FROM

Restore the database from a backup file.

#### Syntax
```gql
RESTORE FROM 'file_path' [TIMESTAMP 'timestamp'] [VERIFY ONLY]
```

#### Examples
```gql
-- Restore from backup
RESTORE FROM '/backups/geode_backup_2024.bak';

-- Restore to specific point in time
RESTORE FROM '/backups/daily.bak' TIMESTAMP '1234567890000';

-- Verify backup without restoring
RESTORE FROM '/backups/daily.bak' VERIFY ONLY;
```

## 3. Advanced Query Features

### UNION Operations

Combine results from multiple queries.

#### Syntax
```gql
query1 UNION [ALL | DISTINCT] query2
```

#### Examples
```gql
-- Union with deduplication (default)
MATCH (p:Person) WHERE p.age > 30 RETURN p.name
UNION
MATCH (p:Person) WHERE p.city = 'NYC' RETURN p.name;

-- Union keeping duplicates
MATCH (a:Author) RETURN a.name
UNION ALL
MATCH (e:Editor) RETURN e.name;

-- Explicit distinct
MATCH (n:Node1) RETURN n.id
UNION DISTINCT
MATCH (n:Node2) RETURN n.id;
```

### INTERSECT and EXCEPT

Set operations for query results.

```gql
-- Find common elements
MATCH (p:Person) WHERE p.age > 30 RETURN p.name
INTERSECT
MATCH (p:Person) WHERE p.city = 'NYC' RETURN p.name;

-- Find elements in first but not second
MATCH (a:Author) RETURN a.name
EXCEPT
MATCH (e:Editor) RETURN e.name;
```

### Variable-Length Path Patterns

Query for paths of variable length between nodes.

#### Syntax
```gql
(a)-[*min..max]->(b)  -- Between min and max hops
(a)-[*]->(b)          -- Any number of hops
(a)-[*n]->(b)         -- Exactly n hops
(a)-[*..max]->(b)     -- Up to max hops
(a)-[*min..]->(b)     -- At least min hops
```

#### Examples
```gql
-- Find all paths of any length
MATCH (person:Person {name: 'Alice'})-[*]->(friend:Person)
RETURN friend.name;

-- Find friends within 3 hops
MATCH (p1:Person)-[*1..3]->(p2:Person)
WHERE p1.name = 'Bob'
RETURN p2.name, length(path) as distance;

-- Exactly 2 hops
MATCH (a:Airport)-[*2]->(b:Airport)
RETURN a.code, b.code;

-- Find shortest paths up to length 5
MATCH path = (start:City {name: 'Paris'})-[*..5]->(end:City {name: 'Tokyo'})
RETURN path
ORDER BY length(path)
LIMIT 1;
```

## 4. Enterprise Audit Logging

Geode provides comprehensive audit logging for security compliance and monitoring.

### Configuration

#### Environment Variables
```bash
# Enable audit logging
export GEODE_AUDIT_ENABLED=true

# File-based logging
export GEODE_AUDIT_FILE_ENABLED=true
export GEODE_AUDIT_FILE_PATH=/var/log/geode/audit.log

# Windows Event Log (Windows only)
export GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED=true
export GEODE_AUDIT_WINDOWS_EVENTLOG_SOURCE=GeodeDB
```

#### Command-line Flags
```bash
# Enable with file output
geode --audit --audit-file /var/log/geode/audit.log query "MATCH (n) RETURN n"

# Enable with Windows Event Log
geode --audit --audit-eventlog GeodeApp query "MATCH (n) RETURN n"
```

### Event Categories
- **Authentication Events** (Event ID: 1001)
- **Command Execution** (Event ID: 1002)  
- **CLI Lifecycle** (Event ID: 1003)
- **General Events** (Event ID: 1000)

### Log Format (JSON)
```json
{
  "timestamp": 1759264693,
  "category": "command",
  "action": "query",
  "outcome": "success",
  "actor": "geode-cli",
  "details": {
    "query": "MATCH (n) RETURN n",
    "execution_time_ms": 42
  }
}
```

## 5. Type System Extensions

Geode supports an extensive type system with over 50 data types.

### Network Types
- **IP Addresses**: `inet '192.168.1.1'`, `inet6 '::1'`
- **CIDR Blocks**: `cidr '10.0.0.0/8'`
- **MAC Addresses**: `macaddr '08:00:2b:01:02:03'`

### Spatial Types
- **Points**: `point(1.5, 2.5)`
- **Lines**: `line '{1, 2, 3}'`  
- **Polygons**: `polygon '((0,0), (1,0), (1,1), (0,1))'`
- **Circles**: `circle '((0,0), 5)'`

### Temporal Types
- **Date**: `date '2024-03-15'`
- **Time**: `time '14:30:00'`
- **Timestamp**: `timestamp '2024-03-15 14:30:00'`
- **Interval**: `interval '1 day 2 hours'`

### Advanced Types
- **JSON/JSONB**: `jsonb '{"key": "value"}'`
- **XML**: `xml '<root><item>value</item></root>'`
- **UUID**: `uuid '550e8400-e29b-41d4-a716-446655440000'`
- **Arrays**: `array[1, 2, 3]`
- **Ranges**: `int4range '[1, 10)'`
- **Bit Strings**: `bit '101010'`
- **Vectors**: `vector '[1.0, 2.0, 3.0]'`

For complete type documentation, see [docs/TYPES_AND_FUNCTIONS.md](TYPES_AND_FUNCTIONS.md).

## Migration Guide

### From v0.18.0 to v0.19.0

1. **Index Creation**: Existing deployments should create indexes on frequently queried properties:
   ```gql
   CREATE INDEX person_name_idx ON Person(name);
   CREATE INDEX person_age_idx ON Person(age);
   ```

2. **Backup Strategy**: Implement regular backups:
   ```bash
   # Daily backup script
   #!/bin/bash
   DATE=$(date +%Y%m%d)
   geodec "BACKUP TO '/backups/geode_$DATE.bak'" --insecure
   ```

3. **Audit Logging**: Enable audit logging for production:
   ```bash
   export GEODE_AUDIT_ENABLED=true
   export GEODE_AUDIT_FILE_PATH=/var/log/geode/audit.log
   ```

## Performance Considerations

### Index Usage
- Indexes significantly improve query performance for filtered queries
- Consider creating indexes on:
  - Properties used in WHERE clauses
  - Properties used in ORDER BY
  - Properties used for JOIN conditions
- Monitor index size and maintenance overhead

### Variable-Length Paths
- Set reasonable max_len limits to prevent exhaustive searches
- Use shortest path algorithms when appropriate
- Consider using index hints for path traversal

### Backup and Restore
- Backup operations lock the database briefly
- Schedule backups during low-traffic periods
- Compress backups for storage efficiency
- Test restore procedures regularly

## Known Limitations

1. **Vector Indexes**: Currently stubbed, full implementation pending
2. **Spatial Indexes**: R-tree structure defined, search optimization pending
3. **Full-text Search**: Basic tokenization complete, ranking algorithms pending
4. **Distributed Backups**: Single-node backups only, distributed coordination pending

## Future Enhancements

- Incremental backup support
- Point-in-time recovery with WAL replay
- Online index creation without locking
- Automatic index recommendations
- Query plan hints for index usage
- Parallel index builds
- Compression for backup files
- Encrypted backups with key management