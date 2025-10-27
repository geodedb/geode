# Geode Python Client

A modern, async Python client library for [Geode](https://github.com/yourusername/geode) graph database with full GQL (ISO/IEC 39075:2024) support.

## Features

- 🚀 **Async/await support** using asyncio
- 🔒 **QUIC + TLS 1.3** for secure, high-performance networking
- 📝 **Full GQL support** (98.6% ISO compliance)
- 🏗️ **Query builders** for programmatic query construction
- 🔐 **Authentication & RBAC** with RLS policy support
- 🏊 **Connection pooling** for concurrent workloads
- 📊 **Rich type system** including DECIMAL, temporal types, and advanced types
- 🎯 **Type hints** for excellent IDE support

## Installation

```bash
# Basic installation
pip install geode-client

# With QUIC support
pip install geode-client[quic]

# For development
pip install geode-client[dev]
```

## Quick Start

### Basic Usage

```python
import asyncio
from geode_client import open_database

async def main():
    # Open database connection
    client = open_database("process:./zig-out/bin/geode")

    async with client.connection() as conn:
        # Execute a simple query
        page, _ = await conn.query("RETURN 1 AS x, 'Hello' AS greeting")

        for row in page.rows:
            print(f"x={row['x'].as_int}, greeting={row['greeting'].as_string}")

asyncio.run(main())
```

### Query with Parameters

```python
async with client.connection() as conn:
    query = "MATCH (p:Person {name: $name}) RETURN p.age AS age"
    params = {"name": "Alice"}

    page, _ = await conn.query(query, params)
    age = page.rows[0]["age"].as_int
    print(f"Alice is {age} years old")
```

### Using Query Builder

```python
from geode_client import QueryBuilder

query_text, params = (
    QueryBuilder()
    .match("(p:Person {name: $name})-[:KNOWS]->(friend:Person)")
    .where("friend.age > 25")
    .return_("friend.name AS name", "friend.age AS age")
    .order_by("friend.age DESC")
    .limit(10)
    .with_param("name", "Alice")
    .build()
)

page, _ = await conn.query(query_text, params)
```

### Transactions

```python
async with client.connection() as conn:
    await conn.begin()
    try:
        await conn.query(
            "CREATE (p:Person {name: $name, age: $age})",
            {"name": "Bob", "age": 30}
        )
        await conn.commit()
    except Exception as e:
        await conn.rollback()
        raise
```

### Connection Pooling

```python
from geode_client import ConnectionPool

pool = ConnectionPool(
    dsn="quic:localhost:8443",
    min_size=2,
    max_size=10,
)

async with pool:
    async with pool.connection() as conn:
        page, _ = await conn.query("RETURN 1")
```

### Authentication

```python
from geode_client import AuthClient

async with client.connection() as conn:
    auth = AuthClient(conn)

    # Login
    session = await auth.login("username", "password")
    print(f"Token: {session.token}")

    # Create user
    user = await auth.create_user(
        username="newuser",
        email="user@example.com",
        password="secure123",
        roles=["user"]
    )

    # Check permission
    has_perm = await auth.check_permission(
        user_id=user.id,
        resource="data",
        action="read"
    )
```

## Connection Modes

### Process Mode (Default)

Spawns a Geode process and communicates via stdio:

```python
client = open_database("process:./zig-out/bin/geode?page_size=1000")
```

### QUIC Mode

Connects to a running Geode server via QUIC+TLS:

```python
client = open_database(
    "quic:localhost:8443?"
    "page_size=1000&"
    "ca_cert=/path/to/ca.crt&"
    "client_cert=/path/to/client.crt&"
    "client_key=/path/to/client.key"
)
```

## DSN Format

```
process:<path>?<options>
quic:<host:port>?<options>
```

### Options

- `page_size` - Results page size (default: 1000)
- `hello_name` - Client name (default: "geode-python")
- `hello_ver` - Client version (default: "0.1")
- `conformance` - GQL conformance level (default: "min")
- `ca_cert` - CA certificate path (QUIC only)
- `client_cert` - Client certificate path (QUIC only)
- `client_key` - Client key path (QUIC only)
- `skip_verify` - Skip TLS verification (QUIC only, insecure)

## Query Builders

### QueryBuilder

Build queries programmatically:

```python
from geode_client import QueryBuilder

query, params = (
    QueryBuilder()
    .match("(p:Person)")
    .where("p.age > 25")
    .optional_match("(p)-[:WORKS_AT]->(c:Company)")
    .return_("p.name", "c.name AS company")
    .order_by("p.name")
    .limit(100)
    .build()
)
```

### PatternBuilder

Build graph patterns:

```python
from geode_client import PatternBuilder, EdgeDirection

pattern = (
    PatternBuilder()
    .node("a", "Person", {"name": "$person1"})
    .edge("knows", "KNOWS", EdgeDirection.UNDIRECTED)
    .variable_length(1, 6)
    .node("b", "Person", {"name": "$person2"})
    .build()
)
# Result: (a:Person {name: $person1})-[knows:KNOWS*1..6]-(b:Person {name: $person2})
```

### PredicateBuilder

Build WHERE conditions:

```python
from geode_client import PredicateBuilder

predicate = (
    PredicateBuilder()
    .greater_than("p.age", "25")
    .is_not_null("p.email")
    .in_("p.role", ["admin", "user"])
    .build_and()
)
# Result: p.age > 25 AND p.email IS NOT NULL AND p.role IN ['admin', 'user']
```

## Type System

The client supports all GQL types:

```python
from geode_client import ValueKind

# Access typed values
row = page.rows[0]

# Basic types
int_val = row["count"].as_int
str_val = row["name"].as_string
bool_val = row["active"].as_bool
decimal_val = row["price"].as_decimal

# Temporal types
date_val = row["birthdate"].as_date
timestamp_val = row["created_at"].as_datetime

# Complex types
array_val = row["tags"].as_array
object_val = row["metadata"].as_object
bytes_val = row["data"].as_bytes
range_val = row["period"].as_range
```

## Advanced Features

### Pagination

```python
page, pager = await conn.query("MATCH (n) RETURN n", page_size=100)

# Process first page
for row in page.rows:
    process(row)

# Get more pages
async for next_page in pager():
    for row in next_page.rows:
        process(row)
```

### Concurrent Queries with Pool

```python
async def run_query(pool, query_id):
    async with pool.connection() as conn:
        page, _ = await conn.query(f"RETURN {query_id} AS id")
        return page.rows[0]["id"].as_int

results = await asyncio.gather(*[
    run_query(pool, i) for i in range(10)
])
```

## Examples

See the `examples/` directory for more examples:

- `basic_example.py` - Basic usage patterns
- `advanced_example.py` - Advanced features including auth and pooling

## Development

```bash
# Install in development mode
pip install -e ".[dev]"

# Run tests
pytest

# Format code
black geode_client/

# Type checking
mypy geode_client/

# Linting
ruff check geode_client/
```

## Requirements

- Python 3.9+
- `aioquic` (optional, for QUIC support)

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## Related

- [Geode Database](https://github.com/yourusername/geode) - The main Geode project
- [Go Client](../go/) - Official Go client
- [Rust Client](../rust/) - Official Rust client
