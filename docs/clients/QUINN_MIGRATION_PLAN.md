# Rust Client: Migration from Quiche to Quinn

## Status: Dependencies Updated, Code Migration Needed

### Completed
✅ Updated Cargo.toml to use `quinn = "0.11"` and `rustls = "0.23"`
✅ Removed `boring` and `quiche` dependencies

### Required Code Changes

#### 1. Update `src/client.rs` imports
```rust
// Replace:
use quiche;
use std::net::UdpSocket;

// With:
use quinn::{Endpoint, ClientConfig, Connection as QuinnConnection};
use rustls::{Certificate, PrivateKey, RootCertStore};
use std::sync::Arc;
```

#### 2. Simplify Connection Structure
Quinn handles UDP sockets internally, so remove manual socket management:

```rust
pub struct Connection {
    // Remove: socket, conn (quiche)
    connection: QuinnConnection,  // Quinn connection
    page_size: usize,
    stream_id: u64,
    // Remove manual buffers - Quinn handles internally
}
```

#### 3. Connection Establishment
Replace quiche's manual TLS handshake with Quinn's high-level API:

```rust
impl Connection {
    async fn new(...) -> Result<Self> {
        // Configure TLS
        let mut roots = RootCertStore::empty();
        if !skip_verify {
            // Load CA cert
        }

        let client_config = ClientConfig::with_root_certificates(roots);

        // Create endpoint
        let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
        endpoint.set_default_client_config(client_config);

        // Connect
        let connection = endpoint
            .connect(peer_addr, &host)?
            .await?;

        // Send HELLO on first stream
        let mut stream = connection.open_bi().await?;
        // ... HELLO handshake

        Ok(Self { connection, ... })
    }
}
```

#### 4. Stream Management
Replace quiche's stream API with Quinn's:

```rust
// Instead of: conn.stream_send(stream_id, data, fin)
let (mut send, mut recv) = self.connection.open_bi().await?;
send.write_all(data).await?;
let response = recv.read_to_end(MAX_SIZE).await?;
```

#### 5. Async/Await
Quinn is async-first, so methods need to be async:

```rust
// Change all methods from:
pub fn query(&mut self, query: &str) -> Result<Page>

// To:
pub async fn query(&mut self, query: &str) -> Result<Page>
```

### Testing Strategy

1. Build test: `cd clients/rust && cargo build`
2. Unit test existing functionality
3. Integration test with test harness: `cd clients/test-harness && make build-rust`
4. Full test suite: `make test-rust`

### Reference Implementation

See `vendor/quic/test-clients/quinn-client/` for working quinn example.

Key differences from test client:
- Test client uses simple HTTP/0.9 protocol
- Geode client needs bidirectional streams with JSON protocol
- Need to handle HELLO handshake, query/response flow, paging

### Estimated Effort

- Core connection rewrite: 2-3 hours
- Stream management: 1-2 hours
- Testing and debugging: 2-3 hours
- **Total**: 5-8 hours

### Benefits of Quinn

✅ Pure Rust - no C++ dependencies
✅ Better Nix compatibility
✅ Cleaner async API
✅ Active maintenance
✅ Better error handling

### Migration Priority

**Medium-High**: Blocks Rust client tests, but Python/Go are higher priority for immediate test coverage.
