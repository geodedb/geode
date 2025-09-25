# Go GQL Client — Native Graph Values for Geode v0.16.0

- Package: geode/clients/go/gql
- Purpose: Provide a GQL-specific client with native typed values and simple DB/Conn/Query API
- **v0.16.0**: QUIC+TLS is now the only network transport (TCP removed)

## Quick Start

```go
package main

import (
    "context"
    "fmt"
    "geode/clients/go/gql"
)

func main() {
    // Network mode (QUIC+TLS) - v0.16.0 default
    db, _ := gql.Open("quic:127.0.0.1:8443?page_size=1000")
    
    // Process mode (for local development)
    // db, _ := gql.Open("process:./zig-out/bin/geoded?page_size=1000")
    
    conn, _ := db.Connect(context.Background())
    defer conn.Close()

    first, next, err := conn.Query(
        context.Background(),
        "RETURN 1 AS x ORDER BY x LIMIT 1",
        nil,
        100,
    )
    if err != nil { panic(err) }

    for _, r := range first.Rows {
        fmt.Println(r["x"].Int)
    }

    for {
        page, err := next(context.Background())
        if err != nil { break }
        for _, r := range page.Rows { fmt.Println(r["x"].Int) }
    }
}
```

## Connection Modes

### QUIC Mode (v0.16.0 Default)
```go
// Default QUIC connection
db, _ := gql.Open("quic:127.0.0.1:8443")

// With options
db, _ := gql.Open("quic:host:8443?page_size=5000&hello_name=myapp")
```

### Process Mode (Local Development)
```go
// Spawn local server process
db, _ := gql.Open("process:./zig-out/bin/geoded")

// With options
db, _ := gql.Open("process:/path/to/geoded?page_size=1000")
```

## v0.16.0 Breaking Changes

- **TCP Removed**: The `tcp:` DSN prefix is no longer supported. Use `quic:` for network connections.
- **Default Port**: Changed from 7567 to 8443 for QUIC connections
- **TLS Mandatory**: QUIC connections always use TLS 1.3 (currently with InsecureSkipVerify for development)

## Features

- Values are mapped to `gql.Value` with Kind {Null, Int, Bool, Str, Dec}
- DECIMAL uses `big.Rat` for arbitrary precision
- ORDER metadata (Ordered, OrderKeys) preserved on each Page
- PROFILE statements return empty result set with Final=true
- Transaction support via Begin/Commit/Rollback methods
- Automatic reconnection on connection loss (QUIC mode)

## Migration from v0.15.0

```go
// Old (v0.15.0)
db, _ := gql.Open("tcp:127.0.0.1:7567")  // NO LONGER WORKS

// New (v0.16.0)
db, _ := gql.Open("quic:127.0.0.1:8443") // Use QUIC
```

## Advanced Usage

### Transactions
```go
conn, _ := db.Connect(ctx)
defer conn.Close()

if err := conn.Begin(ctx); err != nil { return err }

// Execute queries...
first, next, _ := conn.Query(ctx, "INSERT ...", nil, 100)

if err := conn.Commit(ctx); err != nil {
    _ = conn.Rollback(ctx)
    return err
}
```

### Profile Mode
```go
prof, err := conn.Profile(ctx, "MATCH (n) RETURN n LIMIT 10")
if err != nil { return err }

fmt.Printf("Execution time: %dms\n", prof.ExecutionTimeMs)
for _, op := range prof.Operators {
    fmt.Printf("- %s: %d rows\n", op.Name, op.RowsProduced)
}
```

## Error Handling

The client returns typed errors for common scenarios:

- `ErrConnectionLost`: QUIC connection dropped
- `ErrInvalidDSN`: Malformed connection string
- `ErrUnsupportedTransport`: TCP or other removed transports
- `ErrTLSHandshake`: Certificate validation failed

## TLS Configuration

For production, configure proper TLS:

```go
// Custom TLS config (coming in future release)
// db, _ := gql.OpenWithTLS("quic:host:8443", &tls.Config{
//     RootCAs: certPool,
//     ServerName: "geode.example.com",
// })
```

Currently uses `InsecureSkipVerify` for development.