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

#### WITH Clause for Query Composition
```gql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WITH p, COUNT(friend) AS friend_count
WHERE friend_count > 5
RETURN p.name, friend_count
ORDER BY friend_count DESC
```

#### WITH and Aggregation
```gql
MATCH (p:Person)-[:PURCHASED]->(product:Product)
WITH p, SUM(product.price) AS total_spent
WHERE total_spent > 1000
MATCH (p)-[:LIVES_IN]->(city:City)
RETURN p.name, total_spent, city.name
```

### Path Queries

#### Variable-Length Paths
```gql
MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person)
WHERE a.name = 'Alice' AND b.city = 'NYC'
RETURN path
```

#### Shortest Path (Deterministic)
```gql
MATCH path = (a:Person {name: 'Alice'})-[:KNOWS*1..5]->(b:Person {name: 'Bob'})
RETURN path
ORDER BY length(path)
LIMIT 1
```

Note: When multiple shortest paths exist, geode applies deterministic tie-breaking based on:
1. Path length (shortest wins)
2. Start node ID (lexicographically smallest)
3. End node ID (lexicographically smallest)
4. Intermediate node IDs (lexicographically smallest)

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

### Full-Text Search Index
```go
// Create full-text index
err := client.CreateFullTextIndex("content_idx", gql.FullTextOptions{
    Fields: []string{"title", "description", "content"},
    Language: "english",
    Stopwords: gql.DefaultStopwords,
})

// Search using full-text index
results, err := client.FullTextSearch("content_idx", "graph database", gql.SearchOptions{
    MaxResults: 10,
    Highlight: true,
    ScoreThreshold: 0.5,
})

for _, result := range results {
    fmt.Printf("Score: %.2f, Doc: %s\n", result.Score, result.DocumentID)
    for _, highlight := range result.Highlights {
        fmt.Printf("  Match: %s at position %d\n", highlight.Text, highlight.Position)
    }
}

// Phrase search
results, err := client.PhraseSearch("content_idx", "graph database technology", 
    gql.SearchOptions{MaxResults: 5})

// Fuzzy search with edit distance
results, err := client.FuzzySearch("content_idx", "grph", gql.FuzzyOptions{
    MaxEditDistance: 2,
    MaxResults: 10,
})
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
fmt.Printf("Leader: %s\n", status.LeaderID)
fmt.Printf("Nodes: %d\n", len(status.Nodes))

// Add node to cluster
err = client.AddNode("node4", "192.168.1.4:7567")

// Remove node from cluster
err = client.RemoveNode("node3")
```

## Advanced Path Algorithms

### Dijkstra's Shortest Path
```go
// Find shortest weighted path
path, err := client.DijkstraPath(
    startNodeID, 
    endNodeID,
    gql.PathOptions{
        EdgeWeights: map[string]float64{
            "KNOWS": 1.0,
            "WORKS_WITH": 0.5,
            "RELATED_TO": 2.0,
        },
    },
)

fmt.Printf("Path length: %.2f\n", path.Weight)
for _, node := range path.Nodes {
    fmt.Printf("-> %d ", node)
}
```

### PageRank Calculation
```go
// Calculate PageRank for all nodes
rankings, err := client.PageRank(gql.PageRankOptions{
    DampingFactor: 0.85,
    MaxIterations: 100,
    Tolerance: 0.0001,
})

// Get top 10 nodes by PageRank
for i, result := range rankings[:10] {
    fmt.Printf("%d. Node %d: score %.4f\n", i+1, result.NodeID, result.Score)
}
```

### Betweenness Centrality
```go
// Calculate betweenness centrality
centrality, err := client.BetweennessCentrality(gql.CentralityOptions{
    SampleSize: 1000, // Sample 1000 nodes for large graphs
    Normalized: true,
})

// Find most central nodes (important connectors)
for _, result := range centrality[:5] {
    fmt.Printf("Node %d: centrality %.4f\n", result.NodeID, result.Score)
}
```

### Community Detection
```go
// Detect communities using Louvain algorithm
communities, err := client.LouvainCommunities(gql.CommunityOptions{
    Resolution: 1.0, // Higher values create more communities
})

for _, community := range communities {
    fmt.Printf("Community %d: %d nodes, modularity %.3f\n", 
        community.ID, len(community.Nodes), community.Modularity)
}
```

## Schema Constraints

### Define Node Constraints
```gql
-- Create node constraint with required properties
CREATE CONSTRAINT person_constraint ON Person
REQUIRE (name STRING NOT NULL, age INTEGER NOT NULL)
CHECK (age >= 0 AND age <= 150)

-- Add unique constraint
CREATE CONSTRAINT person_email_unique ON Person
REQUIRE (email STRING) UNIQUE

-- Pattern constraint for property
CREATE CONSTRAINT email_format ON Person
REQUIRE (email STRING)
CHECK (email MATCHES '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
```

### Define Edge Constraints
```gql
-- Edge constraint with cardinality
CREATE CONSTRAINT knows_constraint ON KNOWS
FROM Person TO Person
CARDINALITY (0, 500)  -- Max 500 KNOWS relationships per person

-- Edge with required properties
CREATE CONSTRAINT works_at ON WORKS_AT
FROM Person TO Company
REQUIRE (start_date DATE NOT NULL, position STRING NOT NULL)
```

### Validate Schema
```go
// Validate node against constraints
err := client.ValidateNode(node)
if err != nil {
    if validationErr, ok := err.(*gql.ValidationError); ok {
        fmt.Printf("Validation failed: %s\n", validationErr.Message)
        fmt.Printf("Constraint: %s\n", validationErr.ConstraintType)
    }
}

// Check cardinality constraints
violations, err := client.CheckCardinality("Person", "KNOWS")
for _, violation := range violations {
    fmt.Printf("Node %d exceeds cardinality limit\n", violation.NodeID)
}
```

## Enhanced Distributed Transactions

### Two-Phase Commit with Savepoints
```go
// Start distributed transaction with enhanced options
dtx, err := client.BeginDistributedTx(ctx, gql.DTxOptions{
    Participants: []string{"shard1", "shard2", "shard3"},
    IsolationLevel: gql.Serializable,
    Timeout: 30 * time.Second,
})

// Create savepoint
dtx.CreateSavepoint("before_bulk_insert")

// Bulk operations
for _, data := range bulkData {
    err := dtx.Query(fmt.Sprintf("CREATE (p:Person %s)", data))
    if err != nil {
        // Rollback to savepoint on error
        dtx.RollbackToSavepoint("before_bulk_insert")
        break
    }
}

// Two-phase commit
if dtx.Prepare() {
    err = dtx.Commit()
} else {
    dtx.Abort()
}
```

### Lock Management
```go
// Acquire locks explicitly
lock, err := client.AcquireLock(gql.LockRequest{
    ResourceID: nodeID,
    LockType: gql.ExclusiveLock,
    Timeout: 5 * time.Second,
})
defer lock.Release()

// Check lock status
status, err := client.LockStatus(nodeID)
fmt.Printf("Lock held by: %s\n", status.Holder)
fmt.Printf("Waiters: %d\n", len(status.Waiters))
```

### Recovery and Fault Tolerance
```go
// Enable automatic recovery
client.EnableRecovery(gql.RecoveryOptions{
    LogFile: "/var/log/geode/recovery.log",
    CheckpointInterval: 5 * time.Minute,
    MaxRetries: 3,
})

// Manual recovery from log
err := client.RecoverFromLog("/var/log/geode/recovery.log")

// Check transaction status after crash
status, err := client.GetTransactionStatus(txID)
switch status {
case gql.Committed:
    fmt.Println("Transaction was committed")
case gql.Aborted:
    fmt.Println("Transaction was aborted")
case gql.InDoubt:
    fmt.Println("Transaction in doubt, manual resolution needed")
}
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