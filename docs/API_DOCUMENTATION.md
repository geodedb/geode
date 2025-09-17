# Geode Graph Database API Documentation

## Table of Contents
1. [Overview](#overview)
2. [Connection Management](#connection-management)
3. [Query Language (GQL)](#query-language-gql)
4. [Graph Operations](#graph-operations)
5. [Transactions](#transactions)
6. [Indexing](#indexing)
7. [Monitoring & Metrics](#monitoring--metrics)
8. [Distributed Operations](#distributed-operations)

## Overview

Geode is a high-performance, distributed graph database that implements the ISO/IEC 39075:2024 GQL standard. It provides ACID transactions, automatic sharding, and comprehensive monitoring capabilities.

### Key Features
- **GQL Compliance**: Full support for ISO GQL standard
- **ACID Transactions**: Multi-version concurrency control (MVCC)
- **Distributed**: Raft consensus and 2PC for distributed transactions
- **High Performance**: QUIC transport, B-tree indexes, cost-based optimizer
- **Monitoring**: Built-in metrics, query profiling, and tracing

## Connection Management

### QUIC Connection (Recommended)
```go
import "geode/clients/go/gql"

// Connect using QUIC with TLS
client, err := gql.Connect("quic://localhost:7567", gql.Config{
    TLSConfig: &tls.Config{
        ServerName: "localhost",
    },
    MaxConnections: 10,
    ConnectTimeout: 5 * time.Second,
})
defer client.Close()
```

### TCP Connection (Legacy)
```go
// Connect using TCP
client, err := gql.Connect("tcp://localhost:7567", gql.Config{
    MaxConnections: 10,
})
```

### Connection Pooling
```go
pool, err := gql.NewPool("quic://localhost:7567", gql.PoolConfig{
    MaxSize:     100,
    MinSize:     10,
    MaxIdleTime: 5 * time.Minute,
})
defer pool.Close()

// Get connection from pool
conn := pool.Acquire()
defer conn.Release()
```

## Query Language (GQL)

### Basic Queries

#### MATCH Pattern
```gql
MATCH (n:Person {name: 'Alice'})-[:KNOWS]->(friend)
RETURN friend.name, friend.age
ORDER BY friend.age DESC
LIMIT 10
```

#### Path Patterns
```gql
MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person)
WHERE a.name = 'Alice' AND b.city = 'NYC'
RETURN path
```

#### Optional Match
```gql
MATCH (p:Person)
OPTIONAL MATCH (p)-[:WORKS_AT]->(c:Company)
RETURN p.name, c.name
```

### Aggregations

#### GROUP BY with Aggregates
```gql
MATCH (p:Person)-[:PURCHASED]->(product:Product)
RETURN p.age_group, 
       COUNT(*) AS purchase_count,
       SUM(product.price) AS total_spent,
       AVG(product.price) AS avg_price
GROUP BY p.age_group
ORDER BY total_spent DESC
```

#### COLLECT Aggregate
```gql
MATCH (p:Person)-[:LIKES]->(movie:Movie)
RETURN p.name, COLLECT(movie.title) AS liked_movies
```

### Mutations

#### CREATE Nodes and Edges
```gql
CREATE (p:Person {name: 'Bob', age: 30})
CREATE (c:Company {name: 'TechCorp'})
CREATE (p)-[:WORKS_AT {since: 2020}]->(c)
RETURN p, c
```

#### UPDATE Properties
```gql
MATCH (p:Person {name: 'Bob'})
SET p.age = 31, p.city = 'San Francisco'
RETURN p
```

#### DELETE Operations
```gql
MATCH (p:Person {name: 'Bob'})-[r:WORKS_AT]->(c:Company)
DELETE r
```

#### MERGE (Upsert)
```gql
MERGE (p:Person {email: 'alice@example.com'})
ON CREATE SET p.created = timestamp()
ON MATCH SET p.last_seen = timestamp()
RETURN p
```

### Set Operations

#### UNION
```gql
MATCH (p:Person)-[:LIVES_IN]->(city:City {name: 'NYC'})
RETURN p.name AS name
UNION
MATCH (c:Company)-[:LOCATED_IN]->(city:City {name: 'NYC'})
RETURN c.name AS name
```

#### INTERSECT
```gql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name
INTERSECT
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Bob'
RETURN friend.name
```

## Graph Operations

### Pattern Matching API
```go
// Create pattern matcher
matcher := geode.NewPatternMatcher(client)

// Define pattern
pattern := matcher.Pattern().
    Node("p", "Person").WithProperty("age", geode.GreaterThan(25)).
    Edge("knows", "KNOWS").To(
        matcher.Node("f", "Person").WithProperty("city", "NYC")
    )

// Execute match
results, err := pattern.Match()
for _, result := range results {
    fmt.Printf("Person: %s knows %s\n", 
        result.Get("p").Property("name"),
        result.Get("f").Property("name"))
}
```

### Graph Traversal
```go
// Breadth-first traversal
traversal := geode.NewTraversal(client).
    Start("Person", "name", "Alice").
    Follow("KNOWS").
    MaxDepth(3).
    Where(func(node geode.Node) bool {
        return node.Property("age").(int) > 25
    })

nodes, err := traversal.Execute()
```

### Shortest Path
```go
// Find shortest path between two nodes
path, err := client.ShortestPath(
    geode.Node{Label: "Person", Properties: map[string]any{"name": "Alice"}},
    geode.Node{Label: "Person", Properties: map[string]any{"name": "Bob"}},
    geode.PathOptions{
        MaxLength: 6,
        EdgeTypes: []string{"KNOWS", "WORKS_WITH"},
    },
)
```

## Transactions

### Basic Transaction
```go
// Start transaction
tx, err := client.BeginTx(context.Background(), gql.TxOptions{
    Isolation: gql.Serializable,
    ReadOnly:  false,
})
defer tx.Rollback()

// Execute queries in transaction
result1, err := tx.Query("CREATE (p:Person {name: $name})", 
    gql.Params{"name": "Charlie"})

result2, err := tx.Query("MATCH (p:Person) RETURN COUNT(p) AS count")

// Commit transaction
err = tx.Commit()
```

### Savepoints
```go
tx, _ := client.BeginTx(ctx, gql.TxOptions{})

// Create savepoint
tx.Savepoint("sp1")

// Do some work
tx.Query("CREATE (p:Person {name: 'Test'})")

// Rollback to savepoint if needed
if err != nil {
    tx.RollbackTo("sp1")
}

tx.Commit()
```

### Distributed Transactions
```go
// Two-phase commit transaction
dtx, err := client.BeginDistributedTx(ctx, gql.DTxOptions{
    Participants: []string{"shard1", "shard2", "shard3"},
    Timeout:      10 * time.Second,
})

// Prepare phase
prepared, err := dtx.Prepare()
if !prepared {
    dtx.Abort()
    return
}

// Commit phase
err = dtx.Commit()
```

## Indexing

### Create Index
```gql
CREATE INDEX person_name_idx ON Person(name)
CREATE INDEX person_age_city_idx ON Person(age, city)
```

### Drop Index
```gql
DROP INDEX person_name_idx
```

### Index Statistics
```go
stats, err := client.IndexStats("person_name_idx")
fmt.Printf("Index: %s\n", stats.Name)
fmt.Printf("Unique Values: %d\n", stats.UniqueValues)
fmt.Printf("Selectivity: %.2f\n", stats.Selectivity)
```

## Monitoring & Metrics

### Query Profiling
```go
// Enable profiling for a query
result, err := client.QueryWithProfile(
    "MATCH (p:Person)-[:KNOWS*2]->(f) RETURN f",
    gql.ProfileOptions{
        IncludeExplain: true,
        IncludeStats:   true,
        IncludeTime:    true,
    },
)

// Access profile data
profile := result.Profile()
fmt.Printf("Execution Time: %v\n", profile.Duration)
fmt.Printf("Rows Examined: %d\n", profile.RowsExamined)
fmt.Printf("Memory Used: %d bytes\n", profile.MemoryUsed)

// Print execution plan
for _, op := range profile.Operators {
    fmt.Printf("%s: %d rows, %v\n", op.Name, op.RowsProduced, op.Duration)
}
```

### Metrics Collection
```go
// Get metrics snapshot
metrics, err := client.Metrics()

// Query metrics
fmt.Printf("Queries/sec: %.2f\n", metrics.QueriesPerSecond)
fmt.Printf("Avg Latency: %v\n", metrics.AvgLatency)
fmt.Printf("Cache Hit Rate: %.2f%%\n", metrics.CacheHitRate*100)

// Connection pool metrics
poolMetrics := client.PoolMetrics()
fmt.Printf("Active Connections: %d\n", poolMetrics.ActiveConnections)
fmt.Printf("Idle Connections: %d\n", poolMetrics.IdleConnections)
```

### Custom Metrics
```go
// Register custom metric
client.RegisterMetric("custom_counter", gql.Counter)

// Increment counter
client.IncrementCounter("custom_counter")

// Record histogram value
client.RecordHistogram("request_size", float64(len(data)))
```

## Distributed Operations

### Sharding
```go
// Get shard for a key
shard := client.GetShard("user:12345")
fmt.Printf("Key maps to shard: %s\n", shard.ID)

// Query specific shard
result, err := client.QueryShard(shard.ID, 
    "MATCH (p:Person) RETURN p LIMIT 10")
```

### Replication
```go
// Configure replication
client.SetReplicationFactor(3)

// Write with consistency level
result, err := client.QueryWithConsistency(
    "CREATE (p:Person {name: 'Alice'})",
    gql.ConsistencyLevel{
        Write: gql.Quorum,
        Read:  gql.One,
    },
)
```

### Cluster Management
```go
// Get cluster status
status, err := client.ClusterStatus()
for _, node := range status.Nodes {
    fmt.Printf("Node %s: %s\n", node.ID, node.State)
}

// Add node to cluster
err = client.AddNode("node4", "192.168.1.4:7567")

// Remove node from cluster
err = client.RemoveNode("node3")

// Rebalance shards
err = client.RebalanceShards()
```

## Error Handling

### Error Types
```go
switch err := err.(type) {
case *gql.SyntaxError:
    fmt.Printf("Syntax error at position %d: %s\n", 
        err.Position, err.Message)
case *gql.ConstraintViolation:
    fmt.Printf("Constraint violated: %s\n", err.Constraint)
case *gql.TransactionConflict:
    fmt.Printf("Transaction conflict: %s\n", err.Message)
    // Retry transaction
case *gql.NetworkError:
    fmt.Printf("Network error: %s\n", err.Message)
    // Reconnect
}
```

### Retry Logic
```go
// Automatic retry with exponential backoff
result, err := gql.WithRetry(func() (any, error) {
    return client.Query("MATCH (p:Person) RETURN p")
}, gql.RetryOptions{
    MaxAttempts: 3,
    InitialDelay: 100 * time.Millisecond,
    MaxDelay: 5 * time.Second,
    Multiplier: 2,
})
```

## Performance Tips

1. **Use Indexes**: Create indexes on frequently queried properties
2. **Batch Operations**: Use batch inserts for bulk data loading
3. **Connection Pooling**: Reuse connections from a pool
4. **Query Optimization**: Use EXPLAIN to understand query plans
5. **Parameterized Queries**: Use parameters to enable query plan caching
6. **Limit Results**: Always use LIMIT for exploratory queries
7. **Profile Queries**: Use profiling to identify bottlenecks

## Examples

### Social Network Query
```gql
-- Find mutual friends
MATCH (user:Person {name: $userName})-[:KNOWS]->(friend)
MATCH (other:Person {name: $otherName})-[:KNOWS]->(friend)
RETURN friend.name AS mutual_friend
ORDER BY friend.influence_score DESC
LIMIT 10
```

### Recommendation Engine
```gql
-- Product recommendations based on similar users
MATCH (user:Person {id: $userId})-[:PURCHASED]->(product)
MATCH (other:Person)-[:PURCHASED]->(product)
WHERE other.id <> user.id
MATCH (other)-[:PURCHASED]->(recommendation)
WHERE NOT EXISTS {
    MATCH (user)-[:PURCHASED]->(recommendation)
}
RETURN recommendation, COUNT(*) AS score
ORDER BY score DESC
LIMIT 20
```

### Fraud Detection
```gql
-- Detect suspicious transaction patterns
MATCH path = (account:Account)-[:TRANSFER*3..5]->(destination:Account)
WHERE account.id = $accountId
  AND ALL(transfer IN relationships(path) WHERE 
    transfer.amount > 10000 AND 
    transfer.timestamp > timestamp() - duration('PT1H'))
RETURN path, destination
```