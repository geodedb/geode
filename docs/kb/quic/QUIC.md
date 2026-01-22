# Geode QUIC Transport Guide

Complete documentation for QUIC/TLS 1.3 transport in Geode.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Build & Module Wiring](#build--module-wiring)
- [Public API](#public-api)
- [Connection Management Algorithms](#connection-management-algorithms)
- [Git Submodule Setup](#git-submodule-setup)
- [Client Integration](#client-integration)
- [Testing](#testing)
- [CANARY Evidence](#canary-evidence)
- [Troubleshooting](#troubleshooting)

---

## Overview

Geode uses QUIC over TLS 1.3 as its **only network transport**. No TCP fallback exists. For local development, process mode (stdio) remains available.

**Key Characteristics**:
- Vendored Zig QUIC implementation in `vendor/quic/`
- QUIC-only transport (TLS 1.3 required)
- Single-threaded per-connection (lock-free operation)
- Cross-platform: Linux (epoll), macOS (kqueue), Windows (IOCP)
- RFC 9000/9001/9002 conformance

---

## Architecture

### Module Structure

```
vendor/quic/
├── lib.zig                    # Public API wrapper
├── quic.zig                   # Main QUIC implementation
├── build.zig                  # QUIC build configuration
└── src/
    ├── quic/
    │   ├── api.zig            # QUIC API types
    │   ├── connection.zig     # Connection management
    │   ├── stream.zig         # Stream handling
    │   └── ...
    └── h3/                    # HTTP/3 implementation (optional)

src/
├── algorithms/
│   ├── drr.zig                # Deficit Round Robin scheduler
│   ├── congestion_newreno.zig # NewReno congestion control
│   ├── loss_recovery.zig      # Loss detection (RFC 9002)
│   ├── timer_heap.zig         # Binary min-heap for timers
│   └── sharding.zig           # Connection sharding (FNV-1a hash)
└── transport/
    ├── quic.zig               # Geode QUIC transport layer
    └── connection_manager.zig # Connection orchestration
```

### Transport Layer (`src/transport/quic.zig`)

- **Server (QuicTransport)**: QUIC when cert/key present; allocator-safe connection/stream lists
- **Client (QuicClient)**: QUIC when CA cert present; simplifies stream usage
- **Read/Write**: `writeStream` return value discarded; `readStream` errors map to 0 for non-blocking reads

---

## Build & Module Wiring

The vendored QUIC library is exposed using stable module names in `build.zig`:

### Named Modules

| Module | Source |
|--------|--------|
| `quic_tls` | `src/quic/tls/key_schedule.zig` |
| `quic_crypto` | `src/quic/crypto_quic.zig` |
| `quic_packet` | `src/quic/packet.zig` |
| `quic_varint` | `src/quic/varint.zig` |
| `quic_frame` | `src/quic/frame.zig` |
| `quic_recovery` | `src/quic/recovery.zig` |
| `quic_conn` | `src/quic/conn.zig` |
| `quic_transport_params` | `src/quic/transport_params.zig` |
| `quic_endpoint` | `src/quic/endpoint.zig` |
| `quic_tls13` | `src/quic/tls/tls13.zig` |
| `asn1` | `src/quic/tls/asn1.zig` |
| `sig` | `src/quic/tls/sig.zig` |
| `x509` | `src/quic/tls/x509.zig` |
| `ed25519` | `vendor/ed25519/src/ed25519.zig` |

---

## Public API

The public API is re-exported via `vendor/quic/lib.zig`:

### Types

- `QuicVersion`, `Role`, `LoopBackend`
- `QuicConfig`, `QuicEndpoint`, `QuicConnection`, `QuicStreamId`

### Endpoint Lifecycle

```zig
// Initialize/deinitialize
endpointInit(allocator, config) -> QuicEndpoint
endpointDeinit(endpoint)

// Event loop
poll(endpoint) -> events
scheduleTimer(endpoint, timeout)
cancelTimer(endpoint)
flush(endpoint)
```

### Connect/Accept

```zig
connect(endpoint, address) -> QuicConnection
accept(endpoint) -> QuicConnection
isHandshakeConfirmed(conn) -> bool  // Conservative false
handshakeComplete(conn) -> bool
handshakeDoneSeen(conn) -> bool
isDrained(conn) -> bool
```

### Streams

```zig
openStream(conn) -> QuicStreamId
openUni(conn) -> QuicStreamId
writeStream(conn, stream_id, data) -> usize
readStream(conn, stream_id, buffer) -> usize
isStreamFinished(conn, stream_id) -> bool
closeStream(conn, stream_id)
```

### Datagrams

```zig
sendDatagram(conn, data)
recvDatagram(conn) -> ?[]u8
```

### ALPN & Transport Parameters

```zig
getNegotiatedAlpn(conn) -> ?[]const u8
getPeerTransportParams(conn) -> TransportParams
```

### Close Paths

```zig
close(conn)                    // CONNECTION_CLOSE
closeConnection(conn, error)   // App-level close with error
closeConnectionSimple(conn)    // Convenience wrapper
destroy(endpoint, conn)
```

---

## Connection Management Algorithms

### 1. DRR (Deficit Round Robin) Scheduler

**File**: `src/algorithms/drr.zig`

Fair stream multiplexing with quantum-based credit allocation.

```zig
const drr = @import("algorithms").drr;

var streams = [_]drr.Stream{...};
var transmissions: [N]drr.Transmission = undefined;
const n = try drr.scheduleOnce(&streams, max_packet_size, &transmissions);
```

**Features**:
- Per-stream deficit tracking
- Handles blocked streams and flow control
- Configurable quantum for fairness
- O(S) complexity per round across S active streams

### 2. NewReno Congestion Control

**File**: `src/algorithms/congestion_newreno.zig`

RFC-compliant congestion control.

```zig
const newreno = @import("algorithms").congestion_newreno;

var cc = newreno.init(mss);
cc.onAck(acked_bytes, rtt);
cc.onLoss(lost_bytes);
const cwnd = cc.congestionWindow();
```

**Features**:
- Initial window: 10 MSS (RFC default)
- Slow start to congestion avoidance transition
- Multiplicative decrease on loss
- O(1) per ACK/loss event

### 3. Loss Recovery

**File**: `src/algorithms/loss_recovery.zig`

RFC 9002 compliant loss detection.

```zig
const recovery = @import("algorithms").loss_recovery;

var lr = recovery.init(config);
lr.onPacketSent(pkt_num, size, time);
const lost = lr.detectLoss(largest_acked, ack_time);
```

**Features**:
- PTO (Probe Timeout) calculation
- RTT estimation with smoothing
- Packet number space tracking

### 4. Timer Heap

**File**: `src/algorithms/timer_heap.zig`

Binary min-heap for efficient timer management.

**Features**:
- O(log n) insert/extract
- Supports timer cancellation
- Used for connection timeouts, PTO, idle timeout

---

## Git Submodule Setup

The QUIC library is a git submodule at `vendor/quic/`.

### Initial Clone

```bash
# Clone with submodules
git clone --recursive https://gitlab.com/devnw/codepros/geode.git

# Or if already cloned
git submodule update --init --recursive
```

### Makefile Targets

```bash
make quic-status    # Check submodule status
make quic-init      # Initialize submodule
make dev-setup      # Full development setup (includes QUIC)
```

### Updating the Submodule

```bash
cd vendor/quic
git pull origin main
cd ../..
git add vendor/quic
git commit -m "Update QUIC submodule"
```

---

## Client Integration

### Zig Client

Uses the vendored QUIC directly via `vendor/quic/lib.zig`.

```zig
const quic = @import("vendor_quic");

var client = try quic.QuicClient.init(allocator, config);
defer client.deinit();

try client.connect(server_address);
const stream = try client.openStream();
try stream.write(query);
const response = try stream.read(buffer);
```

### Go Client

Uses stdio mode for process communication (quic-go incompatible with vendor/quic).

```go
cmd := exec.Command(geode_path, "serve", "--stdio")
stdin, _ := cmd.StdinPipe()
stdout, _ := cmd.StdoutPipe()
```

### Python/Rust Clients

Use the aioquic/quiche libraries respectively with `geode/1` ALPN.

---

## Testing

### Unit Tests

```bash
zig build test
```

### E2E Tests

```bash
# Basic QUIC over GQL
zig test tests/e2e_quic_basic.zig

# TLS/QUIC comprehensive
zig test tests/e2e_quic_tls_comprehensive.zig
```

### CANARY Tests

- `canary_quic.zig` - Core QUIC feature coverage
- `canary_quic_tls.zig` - TLS integration tests

### Benchmarks

```bash
# Frame latency variance
zig test tests/benchmark_quic_frame_latency_variance.zig
```

---

## CANARY Evidence

**Requirement**: REQ-GQL-074 (Network Transport)

### Test Coverage

| Test Name | Aspect |
|-----------|--------|
| `TestCANARY_REQ_GQL_074_QUICCore` | Core initialization |
| `TestCANARY_REQ_GQL_074_QUICListener` | Server listener |
| `TestCANARY_REQ_GQL_074_QUICAccept` | Connection accept |
| `TestCANARY_REQ_GQL_074_QUICStream` | Stream operations |
| `TestCANARY_REQ_GQL_074_QUICStreamOpen` | Stream creation |
| `TestCANARY_REQ_GQL_074_QUICClientConnect` | Client connection |
| `TestCANARY_REQ_GQL_074_QUICMultiplexing` | Stream multiplexing |
| `TestCANARY_REQ_GQL_074_QUICTLS` | TLS handshake |
| `TestCANARY_REQ_GQL_074_QUICTLSComprehensive` | Full TLS suite |
| `TestCANARY_REQ_GQL_074_QUICConnectionParams` | Transport parameters |
| `TestCANARY_REQ_GQL_074_QUICPerformanceMetrics` | Performance |
| `TestCANARY_REQ_GQL_074_QUICErrorHandling` | Error paths |
| `TestCANARY_REQ_GQL_074_QUICConnectionRecovery` | Recovery |

### Benchmark

- `BenchmarkCANARY_REQ_GQL_074_QuicFrameLatencyVarianceEnvelope`

---

## Troubleshooting

### Submodule Not Initialized

```bash
make quic-status
git submodule update --init --recursive
```

### Build Errors

1. Verify submodule: `make quic-status`
2. Check `vendor/quic/lib.zig` exists
3. Ensure Zig 0.15.1 compatibility

### Connection Failures

```bash
# Check certificates
openssl x509 -in certs/server.crt -text -noout

# Enable debug logging
GEODE_LOG_LEVEL=debug ./zig-out/bin/geode serve --listen 0.0.0.0:7567
```

### ALPN Mismatch

Ensure all clients use `geode/1` as the ALPN protocol identifier.

### Client Compatibility

| Client | Library | Compatible |
|--------|---------|------------|
| Zig | vendor/quic | Yes (native) |
| Python | aioquic | Yes |
| Go | quic-go | No (use stdio) |
| Rust | quiche | Yes |

---

## Usage Examples

### Start Server

```bash
# Generate certificates
./zig-out/bin/cert_gen

# Start QUIC server
./zig-out/bin/geode serve --listen 0.0.0.0:7567
```

### Client Query

```bash
# Query via QUIC
./zig-out/bin/geode query "RETURN 1 AS x" --server 127.0.0.1:7567 --format json
```

### Performance Tuning

```bash
# Increase UDP buffer sizes
sysctl -w net.core.rmem_max=26214400
sysctl -w net.core.wmem_max=26214400
```

---

## Notes

- TCP transport has been removed; production deployments require valid cert/key
- `isHandshakeConfirmed` is conservative (returns false) to avoid stale pointer dereference
- Default behavior returns 0 on non-blocking reads for CLI line-reading compatibility
- Zig 0.15.1 adjustments applied to vendor source

---

*Last Updated: December 2025*
