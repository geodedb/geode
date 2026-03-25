# Geode DSN (Data Source Name) Specification

**Version**: 1.1.0
**Status**: Official Specification
**Last Updated**: 2026-03-25

This document defines the official DSN (Data Source Name) format for Geode client libraries. All client implementations MUST conform to this specification.

## Overview

A DSN (Data Source Name) is a connection string that specifies how to connect to a Geode database server. It encodes the transport protocol, server address, authentication credentials, graph target, and connection options in a single URL-like string.

## DSN Format

```
<scheme>://[<username>:<password>@]<host>[:<port>][/<graph>][?<parameters>]
```

### Alternative Formats

For convenience, these alternative formats are also supported:

```
# Scheme-less (defaults to quic://)
<host>:<port>[/<graph>][?<parameters>]
<host>[/<graph>][?<parameters>]
```

## Supported Schemes

| Scheme | Transport | Default Port | TLS | Description |
|--------|-----------|--------------|-----|-------------|
| `quic://` | QUIC | 3141 | Required | **Recommended.** High-performance UDP-based transport with built-in TLS 1.3 |
| `grpc://` | gRPC | 50051 | Optional | Standard gRPC over HTTP/2 |
| (none) | QUIC | 3141 | Required | Scheme-less defaults to QUIC transport |

**Note**: Use `quic://` as the default transport for optimal performance.

## Host Specification

### IPv4 Addresses

```
quic://192.168.1.100:3141
quic://127.0.0.1:3141
```

### IPv6 Addresses

IPv6 addresses MUST be enclosed in square brackets:

```
quic://[::1]:3141
grpc://[2001:db8::1]:50051
quic://[fe80::1%eth0]:3141
```

### Hostnames

```
quic://localhost:3141
quic://geode.example.com:3141
```

## Graph Specification

The graph name is an optional path component in the DSN. When present, the session is bound to the named graph at connection time, before any queries are executed.

### Graph Binding Behavior

| Scenario | Result |
|----------|--------|
| Graph exists | Session bound; `USE GRAPH` rejected for session lifetime |
| Graph not exists + Admin/ReadWrite role | Auto-created, session bound |
| Graph not exists + ReadOnly/User role | `HELLO` fails with permission error |
| Graph not exists + auth disabled | Auto-created, session bound |
| No graph in DSN | Normal behavior; `USE GRAPH` allowed |

### Graph Isolation

When a session is bound to a graph via DSN, issuing `USE GRAPH` returns SQLSTATE `42000` (syntax error or access rule violation). The bound graph cannot be changed for the lifetime of the connection. Clients MUST NOT attempt `USE GRAPH` after establishing a graph-bound session.

### Examples with Graph Path

```
# Bind to graph "social" on connect
quic://localhost:3141/social

# Bind to graph with authentication
quic://admin:secret@geode.example.com:3141/social

# Bind to graph with parameters
quic://localhost:3141/analytics?page_size=500

# Bind to graph via gRPC
grpc://localhost:50051/my-graph
```

## Authentication

### URL-Embedded Credentials

Credentials can be embedded in the URL using standard HTTP basic auth format:

```
quic://username:password@localhost:3141
```

Special characters in credentials MUST be percent-encoded:

- `@` → `%40`
- `:` → `%3A`
- `/` → `%2F`
- `%` → `%25`
- Space → `%20` or `+`

Example with special characters:

```
quic://user%40domain:p%40ss%3Dword@localhost:3141
```

### Query Parameter Credentials

Credentials can also be specified via query parameters:

```
quic://localhost:3141?username=admin&password=secret
```

**Aliases**:

- `username`, `user` → Authentication username
- `password`, `pass` → Authentication password

## Query Parameters

### Standard Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `page_size` | integer | 1000 | Results page size (1-100,000) |
| `hello_name` | string | varies | Client name sent in HELLO handshake |
| `hello_ver` | string | varies | Client version sent in HELLO handshake |
| `conformance` | string | "min" | GQL conformance level ("min", "full") |
| `graph` | string | - | Graph name (alternative to path-based specification). Reserved for future use; path format is primary. |

### Authentication Parameters

| Parameter | Aliases | Type | Description |
|-----------|---------|------|-------------|
| `username` | `user` | string | Authentication username |
| `password` | `pass` | string | Authentication password |

### TLS Parameters

| Parameter | Aliases | Type | Default | Description |
|-----------|---------|------|---------|-------------|
| `tls` | - | boolean | true | Enable/disable TLS (gRPC only, QUIC always uses TLS) |
| `insecure_tls_skip_verify` | - | boolean | false | Skip TLS certificate verification (testing only) |
| `ca` | `ca_cert` | string | - | Path to CA certificate file |
| `cert` | `client_cert` | string | - | Path to client certificate file (for mTLS) |
| `key` | `client_key` | string | - | Path to client private key file (for mTLS) |
| `server_name` | - | string | - | SNI server name for TLS |

### Timeout Parameters

| Parameter | Aliases | Type | Default | Description |
|-----------|---------|------|---------|-------------|
| `connect_timeout` | `timeout` | integer | 30 | Connection timeout in seconds |
| `timeout_ms` | - | integer | 30000 | Connection timeout in milliseconds |

**Note**: When both `connect_timeout` (seconds) and `timeout_ms` (milliseconds) are specified, `timeout_ms` takes precedence.

### Boolean Parameter Values

Boolean parameters accept:

- **True**: `true`, `1`, `yes`, `on`
- **False**: `false`, `0`, `no`, `off`

## Examples

### Basic Connection

```
# QUIC transport (recommended)
quic://localhost:3141

# gRPC transport
grpc://localhost:50051

# Scheme-less (defaults to QUIC)
localhost:3141
```

### With Authentication

```
quic://admin:secret@localhost:3141
quic://localhost:3141?username=admin&password=secret
```

### With Options

```
quic://localhost:3141?page_size=500&hello_name=my-app
grpc://localhost:50051?tls=0&insecure_tls_skip_verify=true
```

### Full Examples

```
# QUIC with all options
quic://admin:secret@geode.example.com:3141?page_size=500&hello_name=my-app&hello_ver=1.0.0&conformance=min

# gRPC with mTLS
grpc://localhost:50051?ca=/path/to/ca.crt&cert=/path/to/client.crt&key=/path/to/client.key

# IPv6 with authentication
quic://admin:secret@[2001:db8::1]:3141?insecure_tls_skip_verify=true

# Development/testing
grpc://localhost:50051?tls=0
```

### With Graph Binding

```
# Connect and bind to a specific graph
quic://localhost:3141/social

# Admin connecting to analytics graph on remote host
quic://admin:secret@geode.example.com:3141/analytics?page_size=500&hello_name=reporting-service

# gRPC with mTLS bound to a graph
grpc://localhost:50051/my-graph?ca=/path/to/ca.crt&cert=/path/to/client.crt&key=/path/to/client.key

# IPv6 with authentication and graph
quic://admin:secret@[2001:db8::1]:3141/social
```

## Protocol Changes

This section documents the protocol-level fields added to support graph-bound sessions.

### HelloRequest (field 7)

```
field 7: graph  optional string
```

When the DSN includes a graph path component, the client MUST populate `HelloRequest.graph` with the graph name. The server processes this field during the HELLO handshake before the session is fully established.

### HelloResponse (field 6)

```
field 6: graph  optional string
```

The server echoes the bound graph name in `HelloResponse.graph` on success. If graph binding fails (e.g., graph not found and caller lacks create permission), the server returns a HELLO error response instead.

### Auto-Create Semantics

When `HelloRequest.graph` names a graph that does not exist, the server applies the following rules:

1. If the authenticated user has `Admin` or `ReadWrite` role, the server creates the graph and binds the session to it.
2. If the authenticated user has `ReadOnly` or `User` role, the HELLO fails with a permission error.
3. If authentication is disabled, the server creates the graph and binds the session to it.

Auto-created graphs use server default storage and configuration settings.

### Graph-Bound Session Enforcement

Once `HelloResponse.graph` is returned, the session enforces graph isolation for its entire lifetime:

- All queries execute against the bound graph; explicit `USE GRAPH` statements are rejected with SQLSTATE `42000`.
- Disconnecting and reconnecting does NOT automatically rebind to the same graph; the client must re-specify the graph in the DSN or HELLO.
- The bound graph name is treated as immutable for the session; server-side graph renames do not retroactively rebind the session.

## Environment Variables

Implementations MAY support the following environment variables as fallback defaults:

| Variable | Description |
|----------|-------------|
| `GEODE_HOST` | Default host if DSN is empty |
| `GEODE_PORT` | Default port if not specified |
| `GEODE_TLS_CA` | Default CA certificate path |
| `GEODE_USERNAME` | Default username |
| `GEODE_PASSWORD` | Default password |
| `GEODE_TRANSPORT` | Default transport (`quic` or `grpc`) |
| `GEODE_GRAPH` | Default graph name if not specified in DSN |

## Error Handling

### Required Errors

Implementations MUST return an error for:

- Unsupported scheme (e.g., `http://`, `https://`, `tcp://`)
- Missing host when scheme is present
- Invalid port number (not 1-65535)
- Invalid IPv6 address format

### Optional Strict Mode

Implementations MAY provide a strict parsing mode that additionally returns errors for:

- Invalid numeric parameter values (instead of using defaults)
- Unknown/unrecognized parameters
- Invalid boolean values

### Validation

Implementations SHOULD validate:

- Hostnames for security (null bytes, excessive length)
- Page size within valid range (1-100,000)
- Port numbers within valid range (1-65535)

## Security Considerations

### Credential Handling

1. Credentials in DSN strings SHOULD NOT be logged
2. Implementations MUST provide a way to redact credentials from DSN strings for logging
3. Password memory SHOULD be zeroed before deallocation (where language allows)

### TLS

1. QUIC transport ALWAYS uses TLS 1.3 (cannot be disabled)
2. `insecure_tls_skip_verify=true` SHOULD only be used for development/testing
3. mTLS requires both `cert` and `key` to be specified together

### Input Validation

1. Hostnames MUST be validated for null bytes and other injection attacks
2. URL decoding MUST handle malformed percent-encoding gracefully
3. Input length limits SHOULD be enforced to prevent resource exhaustion

## Client Implementation Reference

| Client | File | Function | Graph Support |
|--------|------|----------|---------------|
| Go | `config.go` | `ParseDSN()` | Path component → `Config.Graph` |
| Rust | `src/dsn.rs` | `Dsn::parse()` | Path component → `Dsn.graph` |
| Python | `geode_client/transport.py` | `parse_dsn()` | Path component → `DsnConfig.graph` |
| Zig | `src/config.zig` | `parseDSN()`, `parseDSNStrict()` | Path component → `Config.graph` |
| Node.js | `src/config.ts` | `parseDSN()` | Path component → `DsnConfig.graph` |

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-02-05 | Initial specification |
| 1.1.0 | 2026-03-25 | Add graph path support, graph-bound sessions, auto-create semantics |

## License

Apache License 2.0
Copyright (c) 2025-2026 CodePros
