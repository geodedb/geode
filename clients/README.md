# Geode Client Libraries

Official client libraries for Geode graph database in **Go**, **Python**, **Rust**, and **Zig** with full GQL (ISO/IEC 39075:2024) support.

## Client Repositories

All client libraries are maintained in separate repositories:

| Client | Repository | Status | Best For |
|--------|------------|--------|----------|
| **Go** | [geode-client-go](https://github.com/codeprosorg/geode-client-go) | Production | High-performance servers, CLI tools |
| **Python** | [geode-client-python](https://github.com/codeprosorg/geode-client-python) | Beta | Data science, web apps, scripting |
| **Rust** | [geode-client-rust](https://github.com/codeprosorg/geode-client-rust) | Alpha | Maximum performance, systems programming |
| **Zig** | [geode-client-zig](https://github.com/codeprosorg/geode-client-zig) | Alpha | Native integration, systems programming |

## Features Supported

### Core Database Features

- **QUIC Transport**: High-performance QUIC protocol with TLS 1.3 (mandatory)
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

## Client Feature Matrix

| Feature | Go | Python | Rust | Zig |
|---------|----|---------| -----|-----|
| **QUIC + TLS** | Full | Optional | Planned | Full |
| **Process Mode** | Yes | Yes | Yes | Yes |
| **Async/Await** | goroutines | Yes | Yes | No |
| **Query Builders** | Yes | Yes | Yes | Yes |
| **Auth/RBAC** | Yes | Yes | Planned | Yes |
| **Connection Pool** | Yes | Yes | Basic | Basic |
| **Type System** | Full | Full | Full | Full |
| **Production Ready** | Yes | Beta | Alpha | Alpha |

## Quick Start

### Go Client

```bash
go get github.com/codeprosorg/geode-client-go
```

```go
package main

import (
    "context"
    "log"
    gql "github.com/codeprosorg/geode-client-go"
)

func main() {
    db, err := gql.Open("quic://127.0.0.1:3141")
    if err != nil {
        log.Fatal(err)
    }

    ctx := context.Background()
    conn, err := db.Connect(ctx)
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()

    page, _, err := conn.Query(ctx,
        "MATCH (n:Person) RETURN n.name LIMIT 10",
        nil, 100)
    if err != nil {
        log.Fatal(err)
    }

    for _, row := range page.Rows {
        log.Printf("Person: %s", row["n.name"].Str)
    }
}
```

### Python Client

```bash
pip install geode-client
# Or with QUIC support
pip install geode-client[quic]
```

```python
import asyncio
from geode_client import open_database

async def main():
    client = open_database("process:./zig-out/bin/geode")

    async with client.connection() as conn:
        page, _ = await conn.query("RETURN 1 AS x")
        print(f"Result: {page.rows[0]['x'].as_int}")

asyncio.run(main())
```

### Rust Client

Add to `Cargo.toml`:
```toml
[dependencies]
geode-client = { git = "https://github.com/codeprosorg/geode-client-rust" }
tokio = { version = "1", features = ["full"] }
```

```rust
use geode_client::{Client, Result};

#[tokio::main]
async fn main() -> Result<()> {
    let client = Client::new("process:./zig-out/bin/geode")?;
    let mut conn = client.connect().await?;

    let page = conn.query("RETURN 1 AS x", None).await?;
    println!("Result: {}", page.rows[0].get("x").unwrap().as_int()?);

    Ok(())
}
```

### Zig Client

```bash
git clone https://github.com/codeprosorg/geode-client-zig
```

```zig
const std = @import("std");
const client = @import("geode_client");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = client.Config{
        .host = "127.0.0.1",
        .port = 3141,
        .use_quic = true,
    };

    var geode = client.Client.init(allocator, config);
    defer geode.deinit();

    try geode.connect();
    defer geode.disconnect();

    var iter = try geode.query(
        "MATCH (n:Person) RETURN n.name LIMIT 10",
        null,
    );
    defer iter.close();

    while (try iter.next()) |row| {
        if (row.get("n.name")) |name| {
            std.debug.print("Person: {s}\n", .{name.string});
        }
    }
}
```

## Connection Strings

### QUIC (Only Network Transport + mTLS)

```
quic://hostname:3141?page_size=100&hello_name=myapp&ca_cert=/path/ca.crt&client_cert=/path/client.crt&client_key=/path/client.key
```

- `ca_cert`: PEM trust root to verify server (sets verify on)
- `client_cert`/`client_key`: present client certificate for mTLS when server requires it
- `skip_verify=1`: can be used in dev to skip server verification (not recommended)

Default port is 3141. Server auto-generates self-signed certificates if missing.

### Process Mode (Local Development)

```
process:/path/to/geode
```

## Test Harness

The test harness for client library integration testing remains in this repository under `clients/test-harness/`.

## License

Apache License 2.0 - See LICENSE file for details
