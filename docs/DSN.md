# Geode DSN (Data Source Name) Specification

**Version**: 1.2.0
**Status**: Official Specification
**Last Updated**: 2026-11-14

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

A DSN has no fragment: a `#` anywhere after the scheme ends the authority
and starts a fragment, which is refused (`DsnFragment` in geode;
geode-client-zig reports it as `InvalidDSN`), never ignored. A `#` in a
user name, password or graph name is written `%23`.

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

The host grammar the geode binary accepts (the MCP endpoint DSN, the CLI
`--dsn` and `--server`, SONNY-6484; and, since SONNY-6487, every other
address it parses: `geode serve --listen` and `--listen-grpc`,
`GEODE_PEERS` / `--peers`, `geode lsp --listen`, `--audit-syslog`, Kafka
brokers and KMS endpoints, all through `src/client/host_port.zig`):

| Form | Host | Port |
|------|------|------|
| `name` / `192.0.2.1` | as written | the scheme's default |
| `name:port` / `192.0.2.1:port` | as written | `port` |
| `:port` (CLI `--server` only) | `127.0.0.1` | `port` |
| `[ipv6]` | `ipv6` (brackets removed) | the scheme's default |
| `[ipv6]:port` | `ipv6` | `port` |
| `[ipv6%zone]:port` | `ipv6%zone` (the zone is written raw, not as RFC 6874 `%25`) | `port` |

Refused with `InvalidAddress`, never reinterpreted:

- an unbracketed IPv6 literal (`::1`, `2001:db8::1`, `::1:3141`): its last
  colon cannot be told apart from a port separator (`::1` used to become
  host `:` port 1);
- an unterminated bracket (`[::1`), anything but `:port` after the
  bracket (`[::1]3141`), or brackets around anything but an IPv6 address
  (`[127.0.0.1]`, `[]`);
- a port that is not 1-5 digits or is above 65535 (empty, `http`, `+80`,
  `3_141`, `70000`). No parser replaces a bad port with a default any more
  (`--listen` used to fall back to 3141, `--audit-syslog` to 514,
  `GEODE_CLUSTER_PORT` to 4242, and, before geode-client-zig v0.3.16, the
  lenient `parseDSN` behind the MCP endpoint to 3141).

**Port 0.** The grammar accepts `0`: for a listener (`geode serve --listen :0`) it
means "any free port". A client cannot dial it, so it is refused with
`InvalidPort` on every client path. geode refuses it on the addresses it
parses before building a client (`--server` and the host part of `--dsn`
for `geode query`, `shell`, `auth login`, `backup create`, `restore`,
`migrate run` and the REPL's `\connect`; `parseHostPort` in
`src/client/zig_quic_bridge.zig`). geode-client-zig (since v0.3.17,
SONNY-6550) refuses it in `parseDSN` and `parseDSNStrict`, which is how the
MCP endpoint DSN is refused, and in `GeodeClient.connect`, for a client
whose `Config` was built in code. (A geode client on port 0 used to fail
at the first send with a bare `Unexpected`.)

**How the MCP endpoint reports a bad DSN** (`geode mcp --endpoint`,
SONNY-6494). geode-client-zig v0.3.17 parses the DSN with this grammar and
names the fault; geode turns each error into a message (the DSN itself is
never echoed, since it may carry a password). The CLI reports a bad
`--server` or `--dsn` (`geode query`, `shell`, `auth login`, `backup
create`, `restore`, `migrate run`) with the same messages, printed as
`Error: <message>` (SONNY-6531; one mapping,
`zig_quic_bridge.endpointErrorMessage`): the grammar's `InvalidAddress` is
reported as `InvalidDSN`, and the address is not echoed either. `geode mcp` refuses a bad
`--endpoint` at startup (exit 2, `Error: --endpoint: <message>`); a tool
call answers `Error: <message>` (`isError: true`) and a resource read
`{"error": "<message>"}`:

| Error | Cause | Message starts with |
|-------|-------|---------------------|
| `InvalidDSN` | unbracketed IPv6 host, text after `]` other than `:port`, brackets around a non-IPv6 host, empty host | `Invalid Geode endpoint DSN: the host must be ...` |
| `InvalidPort` | port not 1-5 digits, above 65535, or 0 | `Invalid Geode endpoint DSN: the port must be 1-65535 ...` |
| `UnsupportedScheme` | a scheme other than `quic://` / `grpc://` | `Invalid Geode endpoint DSN: unsupported scheme ...` |
| `InputTooLong` | a percent-decoded credential or parameter over the client's limit | `Invalid Geode endpoint DSN: a credential or parameter value is too long` |
| `Ipv6ZoneUnsupported` | an IPv6 address with a zone (`[fe80::1%eth0]`) | `Invalid Geode endpoint DSN: an IPv6 address with a zone ...` |
| `InsecureTlsRefused` | `insecure=true` under production posture (SONNY-6453) | `Refused: the endpoint DSN sets insecure=true ...` |
| `InvalidPercentEncoding` | a `%` not followed by two hex digits in the user name, password, graph path or a query value (SONNY-6544, SONNY-6550) | `Invalid Geode endpoint DSN: a % must start a %XX escape ...` |
| `UnencodedCredentialDelimiter` | an `@` after the host: a password with a raw `/`, `?` or `#`, or an `@` in the graph path or a query value (SONNY-6544, SONNY-6550) | `Invalid Geode endpoint DSN: an @ follows the host ...` |
| `DsnFragment` | a fragment (`#...`); geode-client-zig reports it as `InvalidDSN`, geode names it (SONNY-6550) | `Invalid Geode endpoint DSN: a fragment (#...) is not allowed ...` |
| `TimeoutOutOfRange` | `parseDSNStrict` only: a `connect_timeout` / `timeout_ms` outside its range (SONNY-6550; no geode path parses strictly today) | `Invalid Geode endpoint DSN: the timeout is out of range ...` |

Any other failure (the server cannot be reached, TLS, authentication)
keeps the generic `Failed to initialize client` / `Failed to connect to
Geode server` or the transport error's name.

`geode serve --listen` also takes `<port>` or `:<port>` (0.0.0.0) and a host
without a port (port 3141; `--listen localhost` used to bind
0.0.0.0:3141). `--listen [::1]:3141` binds the IPv6 loopback, and geode's
own QUIC client (the cluster peer dialler and the test client) dials
`[ipv6]:port`. `--listen-grpc` parses the same grammar but still refuses
IPv6: grpc-zig binds IPv4 only.

The CLI's QUIC client (`geode query`, `geode shell`, `geode backup`, ...)
and the MCP endpoint client reach IPv6 servers (geode-client-zig v0.3.16,
SONNY-6494): an address literal is dialled as written, an IPv6 one
bracketed from an IPv6 endpoint (`[::]:0`); a host name is looked up in both
address families through the system resolver (hosts file and DNS) and its
first IPv4 address is used, otherwise its first IPv6 address. The TLS
server name stays the host as given. An IPv6 address with a zone
(`[fe80::1%eth0]:3141`) parses but cannot be dialled (the QUIC library's
dialler has no zone support): the CLI refuses it with
`Ipv6ZoneUnsupported` and says why. Before v0.3.16 the CLI refused every
IPv6 destination with `Ipv6EndpointUnsupported`.

### Hostnames

```
quic://localhost:3141
quic://geode.example.com:3141
```

## Graph Specification

The graph name is an optional path component in the DSN. When present, the session is bound to the named graph at connection time, before any queries are executed.

The graph path (everything after the `/` that ends the authority, up to
`?`) is percent-decoded with the same strict rule as the credentials
(SONNY-6550): a `%` must start a `%XX` escape of two hex digits, so a
literal `%` is written `%25`, and `+` is a literal plus (not a space).
`quic://localhost:3141/my%5Fgraph` binds `my_graph`; `/50%off` is refused
with `InvalidPercentEncoding`. A `?`, `#` or `@` in a graph name is written
`%3F`, `%23` or `%40`. The `graph=` query parameter is decoded the same way.
The CLI's `--dsn` and the MCP endpoint both decode it (the CLI sent it
undecoded before).

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
- `:` → `%3A` (in the user name; see below)
- `/` → `%2F`, `?` → `%3F`, `#` → `%23`
- `%` → `%25`
- Space → `%20`

Example with special characters:

```
quic://user%40domain:p%40ss%3Dword@localhost:3141
```

**Where the userinfo ends (RFC 3986 §3.2).** The authority runs from after
`scheme://` to the first `/`, `?` or `#`. The userinfo is everything before
the **last** `@` of the authority, and it splits into user name and password
at its **first** `:`. So a password that holds a raw `@` or `:` still parses:
`quic://admin:p@ss:word@[::1]:3141` is user `admin`, password `p@ss:word`,
host `[::1]`, port 3141. Both parts are then percent-decoded (RFC 3986
§2.1): a `%` must start `%` followed by two hex digits, and anything else is
an error (`InvalidPercentEncoding`), never passed through as typed; `+` is a
literal plus. A raw `/`, `?` or `#` in a credential ends the authority early,
so a DSN with an `@` after the host is refused
(`UnencodedCredentialDelimiter`) instead of being dialled at a host made of
part of the password. A scheme-less DSN (`admin:pw@host:3141`) follows the
same rule. Every geode path applies these rules with one implementation:
geode-client-zig's `config.redact` (v0.3.17, SONNY-6550), which parses the
`geode mcp --endpoint` DSN and which geode's CLI (`geode query` /
`geode shell` `--dsn`, SONNY-6544) uses through the re-exports in
`src/client/dsn_credentials.zig`.

### Query Parameter Credentials

Credentials can also be specified via query parameters:

```
quic://localhost:3141?username=admin&password=secret
```

**Aliases**:

- `username`, `user` → Authentication username
- `password`, `pass` → Authentication password

The values are percent-decoded like the userinfo (a `%` must start a `%XX`
escape, `+` is a literal plus); if a key appears more than once, the last
one wins. **Precedence:** per field, a value in the userinfo takes
precedence over the query parameter, so `quic://admin:s3cret@host:3141?password=other`
logs in with `s3cret`, and `quic://admin@host:3141?password=s3cret` takes the
user name from the userinfo and the password from the query (an empty
userinfo user name counts as absent). geode's CLI (`geode query` /
`geode shell` `--dsn`) reads them (SONNY-6551; it read only the userinfo
before, so the harness form `localhost:3141?insecure=true&user=geode&pass=...`
sent no credentials). Of the other query parameters the CLI reads none.
The `geode mcp --endpoint` DSN follows the same precedence (SONNY-6550):
geode-client-zig's `parseDSN` (v0.3.17) lets the query parameter overwrite
the userinfo, so geode puts the userinfo's values back after parsing
(`src/mcp/client.zig`). Another program that parses a DSN with
geode-client-zig directly gets the query parameter's value.

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

**Range.** A timeout is 1-3,600,000 milliseconds: `connect_timeout` 1-3600
seconds, `timeout_ms` 1-3600000. geode-client-zig's `parseDSNStrict`
refuses a value outside it with `TimeoutOutOfRange`, including
`connect_timeout` seconds whose milliseconds overflow a 32-bit integer
(e.g. `5000000`, which panicked the parser before v0.3.17); its lenient
`parseDSN` keeps the default timeout for an overflowing `connect_timeout`.
The `geode mcp --endpoint` DSN is parsed leniently; the CLI's `--dsn` reads
no timeout parameter (use `--timeout`).

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
- Invalid port text: not 1-5 decimal digits, or above 65535
- Invalid IPv6 address format (unbracketed, or brackets around a non-IPv6 host)

Port 0 is valid host:port grammar (see "Port 0" under Host
Specification): a client MUST refuse it before dialling, and MAY do so when
parsing. geode and geode-client-zig (v0.3.17) refuse it when parsing a
client address or DSN, and geode-client-zig's `connect` refuses it too
(`InvalidPort`).

Implementations MUST also return an error for a malformed percent-escape
(`%` not followed by two hex digits) in the user name, password, graph path
or a query value, an `@` after the authority, and a fragment.

### Optional Strict Mode

Implementations MAY provide a strict parsing mode that additionally returns errors for:

- Invalid numeric parameter values (instead of using defaults)
- Unknown/unrecognized parameters
- Invalid boolean values

### Validation

Implementations SHOULD validate:

- Hostnames for security (null bytes, excessive length)
- Page size within valid range (1-100,000)
- Port numbers within valid range (1-65535) before dialling

## Security Considerations

### Credential Handling

1. Credentials in DSN strings SHOULD NOT be logged
2. Implementations MUST provide a way to redact credentials from DSN strings for logging
3. Password memory SHOULD be zeroed before deallocation (where language allows)

geode's redaction is `geode.dsn_credentials.redacted` (`{f}`; since
SONNY-6550 a re-export of geode-client-zig's `config.redacted`), used by
every client-side line that shows a server address or DSN (SONNY-6544): the
userinfo is dropped (`quic://admin:s@cret@[::1]:3141/g` prints as
`quic://[::1]:3141/g`), the value of a query parameter whose name contains
`pass`, `pwd`, `secret`, `token`, `auth`, `credential`, `key`, `session`,
`cookie` or `signature` (any case) prints as `***`, a fragment is not shown,
and a DSN with an `@` after the authority prints as `<address redacted>`.
The error messages for a malformed DSN never include the DSN.

### TLS

1. QUIC transport ALWAYS uses TLS 1.3 (cannot be disabled)
2. `insecure_tls_skip_verify=true` SHOULD only be used for development/testing
3. mTLS requires both `cert` and `key` to be specified together

### Input Validation

1. Hostnames MUST be validated for null bytes and other injection attacks
2. URL decoding MUST refuse malformed percent-encoding (never pass it through as typed)
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
| 1.2.0 | 2026-11-14 | Userinfo ends at the last `@` of the authority; strict percent-decoding of credentials, graph path and query values (`+` literal); fragments, an `@` after the authority and port 0 refused; userinfo takes precedence over query credentials; timeout range |

## License

Apache License 2.0
Copyright (c) 2025-2026 CodePros
