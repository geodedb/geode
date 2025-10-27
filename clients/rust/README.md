# Geode Rust Client

A high-performance async Rust client library for [Geode](https://github.com/yourusername/geode) graph database with full GQL (ISO/IEC 39075:2024) support.

## Features

- 🚀 **Async/await** support using tokio
- 🔒 **QUIC + TLS 1.3** for secure, high-performance networking (planned)
- 📝 **Full GQL support** (98.6% ISO compliance)
- 🏗️ **Query builders** for programmatic query construction
- 🔐 **Authentication & RBAC** (planned)
- 🏊 **Connection pooling** for concurrent workloads
- 📊 **Rich type system** with Decimal, temporal types
- 🎯 **Type-safe** with Rust's strong type system

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
geode-client = "0.1"

# For async runtime
tokio = { version = "1", features = ["full"] }
```

## Quick Start

### Basic Usage

```rust
use geode_client::{Client, Result};

#[tokio::main]
async fn main() -> Result<()> {
    // Create client
    let client = Client::new("process:./zig-out/bin/geode")?;

    // Connect
    let mut conn = client.connect().await?;

    // Execute query
    let page = conn.query("RETURN 1 AS x, 'Hello' AS greeting", None).await?;

    for row in &page.rows {
        let x = row.get("x").unwrap().as_int()?;
        let greeting = row.get("greeting").unwrap().as_string()?;
        println!("x={}, greeting={}", x, greeting);
    }

    Ok(())
}
```

### Query with Parameters

```rust
use std::collections::HashMap;

let mut params = HashMap::new();
params.insert("name".to_string(), serde_json::json!("Alice"));
params.insert("age".to_string(), serde_json::json!(30));

let page = conn.query(
    "MATCH (p:Person {name: $name}) RETURN p.age AS age",
    Some(params)
).await?;
```

### Using Query Builder

```rust
use geode_client::QueryBuilder;

let (query, params) = QueryBuilder::new()
    .match_pattern("(p:Person {name: $name})-[:KNOWS]->(friend:Person)")
    .where_clause("friend.age > 25")
    .return_(&["friend.name AS name", "friend.age AS age"])
    .order_by(&["friend.age DESC"])
    .limit(10)
    .with_param("name", "Alice")
    .build();

let page = conn.query(&query, Some(params)).await?;
```

### Transactions

```rust
conn.begin().await?;

match conn.query("CREATE (p:Person {name: $name})", params).await {
    Ok(_) => conn.commit().await?,
    Err(e) => {
        conn.rollback().await?;
        return Err(e);
    }
}
```

### Connection Pooling

```rust
use geode_client::ConnectionPool;

let pool = ConnectionPool::new("process:./zig-out/bin/geode", 10)?;

let mut conn = pool.acquire().await?;
let page = conn.query("RETURN 1", None).await?;
```

## DSN Format

```
process:<path>?<options>
quic:<host:port>?<options> (planned)
```

### Options

- `page_size` - Results page size (default: 1000)

## Query Builders

### QueryBuilder

Build queries programmatically:

```rust
let (query, params) = QueryBuilder::new()
    .match_pattern("(p:Person)")
    .where_clause("p.age > 25")
    .return_(&["p.name", "p.age"])
    .order_by(&["p.name"])
    .limit(100)
    .build();
```

### PatternBuilder

Build graph patterns:

```rust
use geode_client::{PatternBuilder, EdgeDirection};

let pattern = PatternBuilder::new()
    .node("a", "Person")
    .edge("knows", "KNOWS", EdgeDirection::Undirected)
    .node("b", "Person")
    .build();
```

## Type System

```rust
use geode_client::Value;

let value = row.get("count").unwrap();

// Type-safe access
let int_val = value.as_int()?;
let str_val = value.as_string()?;
let bool_val = value.as_bool()?;
let decimal_val = value.as_decimal()?;
let array_val = value.as_array()?;
let object_val = value.as_object()?;
```

## Examples

Run examples:

```bash
cargo run --example basic
cargo run --example advanced
```

## Development

```bash
# Build
cargo build

# Test
cargo test

# Format
cargo fmt

# Lint
cargo clippy
```

## Requirements

- Rust 1.70+
- tokio runtime

## License

MIT License - see LICENSE file for details.

## Related

- [Geode Database](https://github.com/yourusername/geode) - Main Geode project
- [Python Client](../python/) - Official Python client
- [Go Client](../go/) - Official Go client
