# Geode Client Libraries - v0.16.0

Comprehensive client libraries for Geode graph database supporting all features including RBAC, ABAC, transactions, and graph operations.

**v0.16.0 Breaking Changes:**
- TCP transport removed - QUIC+TLS is now mandatory for network connections
- Default port changed from 7567 to 8443
- All network connections use TLS 1.3

## Features Supported

### Core Database Features

- **QUIC Transport**: High-performance QUIC protocol with TLS 1.3 (mandatory in v0.16.0)
- **Transactions**: BEGIN, COMMIT, ROLLBACK with full ACID support
- **Paged Results**: Efficient streaming of large result sets
- **Query Profiling**: PROFILE and EXPLAIN for query optimization

### Authentication & Authorization

- **User Management**: Create, update, delete users
- **Role-Based Access Control (RBAC)**: Roles, permissions, hierarchical inheritance
- **Attribute-Based Access Control (ABAC)**: Row-Level Security policies
- **Session Management**: Secure token-based authentication
- **Multi-Factor Authentication**: Support for MFA flows

### Graph Operations

- **Node Management**: Create, update, delete nodes with labels and properties
- **Edge Management**: Create relationships with properties
- **Pattern Matching**: Complex MATCH patterns with WHERE clauses
- **Graph Algorithms**: Shortest path, all shortest paths
- **Variable-Length Paths**: Pattern matching with hop constraints

### Query Features

- **ORDER BY**: Multi-column sorting with ASC/DESC
- **LIMIT/OFFSET**: Pagination support
- **GROUP BY**: Aggregation with grouping
- **Aggregations**: COUNT, SUM, AVG, MIN, MAX, STDEV, VARIANCE
- **WITH Clause**: Query composition
- **OPTIONAL MATCH**: Left outer joins
- **Set Operations**: UNION, INTERSECT, EXCEPT

### Data Types

- **Basic Types**: null, bool, int, float, string
- **Decimal**: Arbitrary precision decimals
- **Arrays**: Nested arrays
- **Objects**: Nested objects/maps
- **Graph Types**: Nodes, edges, paths
- **Network Types**: IpAddr, Subnet (CIDR), Mac addresses
- **Geographic Types**: LatLon, LatLonAlt, Geometry (WKT/GeoJSON)
- **Specialized Types**: Hash, Currency (ISO 4217), LanguageTag (BCP-47)
- **Scientific Types**: Temperature, Pressure with units
- **Vector Types**: VectorF32 for embeddings

## Go Client

### Installation

```bash
cd clients/go/gql
go mod init myapp
go get .
```

### Quick Start

```go
package main

import (
    "context"
    "log"
    "geode/clients/go/gql"
)

func main() {
    // Connect with QUIC (v0.16.0: default port 8443)
    db, err := gql.Open("quic://127.0.0.1:8443")
    if err != nil {
        log.Fatal(err)
    }

    ctx := context.Background()
    conn, err := db.Connect(ctx)
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()

    // Authenticate
    auth := conn.Auth()
    session, err := auth.Login(ctx, "admin", "password")
    if err != nil {
        log.Fatal(err)
    }
    defer auth.Logout(ctx, session.Token)

    // Execute query
    page, pager, err := conn.Query(ctx,
        "MATCH (n:Person) RETURN n.name ORDER BY n.name LIMIT 10",
        nil, 100)
    if err != nil {
        log.Fatal(err)
    }

    // Process results
    for _, row := range page.Rows {
        name := row["n.name"].Str
        log.Printf("Person: %s", name)
    }
}
```

### Advanced Features

See `clients/go/example/full_features.go` for comprehensive examples including:

- User and role management
- RLS policy creation
- Transaction handling
- Graph operations (nodes, edges)
- Pattern matching
- Aggregations and GROUP BY
- Set operations

## Zig Client

### Installation

The Zig client is a standalone library that can be imported directly.

### Quick Start

```zig
const std = @import("std");
const client = @import("client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure and connect
    const config = client.Config{
        .host = "127.0.0.1",
        .port = 8443,  // v0.16.0: Default QUIC port
        .use_quic = true,  // v0.16.0: Only network transport
    };

    var geode = client.Client.init(allocator, config);
    defer geode.deinit();

    try geode.connect();
    defer geode.disconnect();

    // Authenticate
    try geode.login("admin", "password");
    defer geode.logout() catch {};

    // Execute query
    var iter = try geode.query(
        "MATCH (n:Person) RETURN n.name ORDER BY n.name LIMIT 10",
        null,
    );
    defer iter.close();

    // Process results
    while (try iter.next()) |row| {
        if (row.get("n.name")) |name| {
            std.debug.print("Person: {s}\n", .{name.string});
        }
    }
}
```

### Advanced Features

See `clients/zig/example.zig` for comprehensive examples including:

- User creation and management
- RLS policy configuration
- Transaction management
- Graph operations
- Pattern matching
- Aggregations
- Set operations

## Connection Strings

### QUIC (v0.18.0: Only Network Transport + mTLS)

```
quic://hostname:8443?page_size=100&hello_name=myapp&ca_cert=/path/ca.crt&client_cert=/path/client.crt&client_key=/path/client.key
```

- ca_cert: PEM trust root to verify server (sets verify on)
- client_cert/client_key: present client certificate for mTLS when server requires it
- skip_verify=1 can be used in dev to skip server verification (not recommended)

Default port is 8443. Server auto-generates self-signed certificates if missing.

### Process Mode (Local Development)

```
process:/path/to/geoded
```

**v0.16.0 Note**: TCP transport has been completely removed. Use QUIC for all network connections.

## API Reference

### Authentication

#### Go

```go
auth := conn.Auth()
session, err := auth.Login(ctx, username, password)
err := auth.Logout(ctx, token)
user, err := auth.CreateUser(ctx, username, email, password, roles, metadata)
err := auth.DeleteUser(ctx, userID)
role, err := auth.CreateRole(ctx, name, description, permissions)
err := auth.GrantPermission(ctx, roleID, permissionID)
allowed, err := auth.CheckPermission(ctx, userID, resource, action)
```

#### Zig

```zig
try client.login(username, password);
try client.logout();
try client.createUser(username, email, password, roles);
```

### Row-Level Security

#### Go

```go
policy := &gql.RLSPolicy{
    Name: "policy_name",
    Table: "table_name",
    Graph: "graph_name",
    Operation: "select",
    UsingExpression: "owner_id = current_user_id()",
    CheckExpression: "status = 'active'",
    Roles: []int64{1, 2},
    Enabled: true,
}
err := auth.CreateRLSPolicy(ctx, policy)
err := auth.EnableRLSPolicy(ctx, policyID, enabled)
```

#### Zig

```zig
try client.createRLSPolicy(
    name, table, graph, operation,
    using_expr, check_expr, roles
);
```

### Extended Type Operations

#### Go

```go
// Network types
result, err := conn.Query(ctx, 
    `RETURN IpAddr("192.168.1.1") AS ip, 
            Subnet("10.0.0.0/8") AS subnet,
            Mac("aa:bb:cc:dd:ee:ff") AS mac`,
    nil, 100)

// Geographic types  
result, err := conn.Query(ctx,
    `RETURN LatLon(51.5074, -0.1278) AS london,
            distance_haversine($p1, $p2) AS dist`,
    map[string]interface{}{
        "p1": gql.LatLon{Lat: 0, Lon: 0},
        "p2": gql.LatLon{Lat: 0, Lon: 1},
    }, 100)

// Vector similarity search
result, err := conn.Query(ctx,
    `MATCH (n:Document) 
     WHERE vector_knn(n.embedding, $query, 10, "cosine")[0].score > 0.8
     RETURN n`,
    map[string]interface{}{
        "query": []float32{0.1, 0.2, 0.3},
    }, 100)
```

#### Zig

```zig
// Network types
var iter = try client.query(
    \\RETURN IpAddr("2001:db8::1") AS ipv6,
    \\       ip_contains(Subnet("192.168.0.0/16"), IpAddr("192.168.1.1")) AS contains
, null);

// Geographic types
const params = .{
    .p1 = LatLon{ .lat = 51.5, .lon = -0.1 },
};
var iter = try client.query(
    "RETURN distance_haversine($p1, LatLon(48.8566, 2.3522)) AS dist",
    params);

// Vector operations
const embedding = [_]f32{0.1, 0.2, 0.3};
var iter = try client.query(
    "MATCH (n) WHERE vector_dot(n.embedding, $vec) > 0.5 RETURN n",
    .{ .vec = embedding });
```

### Graph Operations

#### Go

```go
graph := conn.Graph()

// Create node
node, err := graph.CreateNode(ctx, labels, properties)

// Create edge
edge, err := graph.CreateEdge(ctx, sourceID, targetID, label, properties)

// Pattern matching
pattern := &gql.GraphPattern{
    Nodes: []gql.NodePattern{{Variable: "n", Labels: []string{"Person"}}},
    Edges: []gql.EdgePattern{{Source: "n", Target: "m", Label: "KNOWS"}},
    Where: "n.age > 21",
}
iter, err := graph.Match(ctx, pattern)

// Shortest path
path, err := graph.ShortestPath(ctx, sourceID, targetID, maxHops)
```

#### Zig

```zig
// Create node
const node = try client.createNode(labels, properties);

// Create edge
const edge = try client.createEdge(source_id, target_id, label, properties);

// Pattern matching
var iter = try client.match(pattern, where_clause);

// Shortest path
const path = try client.shortestPath(source_id, target_id, max_hops);
```

### Transactions

#### Go

```go
err := conn.Begin(ctx)
// ... perform operations ...
err := conn.Commit(ctx)
// or
err := conn.Rollback(ctx)
```

#### Zig

```zig
try client.beginTransaction();
// ... perform operations ...
try client.commit();
// or
try client.rollback();
```

## Error Handling

Both clients provide detailed error information including:

- ISO SQL/GQL status codes
- Diagnostic messages with line/column anchors
- Additional status information for complex errors

## Performance Considerations

1. **Use QUIC when possible** for better performance and multiplexing
2. **Set appropriate page sizes** based on expected result sizes
3. **Use transactions** for multiple related operations
4. **Profile queries** to optimize performance
5. **Use prepared statements** (when available) for repeated queries

## Testing

### Go Client Tests

```bash
cd clients/go/gql
go test -v
```

### Zig Client Tests

```bash
cd clients/zig
zig test client.zig
```

## License

MIT License - See LICENSE file for details
