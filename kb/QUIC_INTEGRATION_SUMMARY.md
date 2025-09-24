# Geode QUIC/TLS Integration (REQ-GQL-074: Network Transport)

This document consolidates the final QUIC integration details, vendor wiring, test/bench coverage, and CANARY evidence in one place.

## Scope
- Runtime transport: QUIC over TLS 1.3 (primary), TCP fallback when TLS artifacts missing
- Vendored library in `vendor/quic/`, exported by `vendor/quic/lib.zig`
- Server/Client transport in `src/transport/quic.zig`
- Tests, benchmarks, and CANARYs for REQ-GQL-074

## Build & Module Wiring
Top-level `build.zig` defines stable module names and connects internal vendor modules.
- Named modules provided to vendor code:
  - quic_tls, quic_crypto, quic_packet, quic_varint, quic_frame, quic_recovery, quic_conn, quic_transport_params, quic_endpoint, quic_tls13
  - TLS helpers: asn1, sig, x509, ed25519
- Public API is exposed by `vendor/quic/lib.zig` as a thin re-export wrapper around `src/quic/api.zig`.

## Public API Surface (lib.zig)
- Types: QuicVersion, Role, LoopBackend, QuicConfig, QuicEndpoint, QuicConnection, QuicStreamId
- Endpoint lifecycle: endpointInit/endpointDeinit, poll, scheduleTimer, cancelTimer, flush
- Connect/Accept: connect, accept, handshakeComplete, isHandshakeConfirmed (conservative false), handshakeDoneSeen, isDrained
- Streams: openStream/openUni, writeStream/readStream, isStreamFinished, closeStream
- Datagrams: sendDatagram, recvDatagram
- ALPN/TP: getNegotiatedAlpn, getPeerTransportParams
- Close/Destroy: close, closeConnection, destroy
- Convenience wrappers: closeConnectionSimple(conn), acceptStream(conn) placeholder

## Transport Layer (src/transport/quic.zig)
- Server (QuicTransport): QUIC when cert/key present, TCP fallback otherwise; allocator-safe connection/stream lists; accepts connections/streams from vendor endpoint.
- Client (QuicClient): QUIC when CA cert present, else TCP; simplifies stream usage from caller perspective.
- Read/Write: writeStream return value is discarded; readStream errors map to 0 for non-blocking line reads gracefully.

## Tests & Benches
- Tests
  - e2e_quic_basic.zig: basic GQL program over QUIC
  - e2e_quic_tls_comprehensive.zig: TLS config, multiplexing, error structures (unit)
  - canary_quic.zig, canary_quic_tls.zig: feature CANARY coverage for QUIC aspects (Core/Listener/Stream/ClientConnect/TLS/FlowControl/IdleTimeout/Multiplexing)
- Benchmarks
  - tests/benchmark_quic_frame_latency_variance.zig: Frame latency variance envelope (REQ-GQL-074)

## CANARY Evidence (REQ-GQL-074) — Examples
- Tests:
  - TestCANARY_REQ_GQL_074_QUICCore
  - TestCANARY_REQ_GQL_074_QUICListener
  - TestCANARY_REQ_GQL_074_QUICAccept
  - TestCANARY_REQ_GQL_074_QUICStream
  - TestCANARY_REQ_GQL_074_QUICStreamOpen
  - TestCANARY_REQ_GQL_074_QUICClientConnect
  - TestCANARY_REQ_GQL_074_QUICMultiplexing
  - TestCANARY_REQ_GQL_074_QUICTLS, TestCANARY_REQ_GQL_074_QUICTLSComprehensive
  - TestCANARY_REQ_GQL_074_QUICConnectionParams
  - BenchmarkCANARY_REQ_GQL_074_QuicFrameLatencyVarianceEnvelope

## Usage
```bash
zig build
# Optional certificates
after build: ./zig-out/bin/cert_gen

# Server (QUIC)
./zig-out/bin/geoded --listen-quic 0.0.0.0:7567 --log_json --result-format json

# Client (QUIC default)
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --server 127.0.0.1:7567 --format json
```

## Notes & Compatibility
- Zig 0.15.1 adjustments applied in vendor source (syntax tweaks; varint encode style)
- TLS helpers (asn1/sig/x509/ed25519) are wired in build.zig
- isHandshakeConfirmed returns false without touching opaque connection state; infer readiness by successful ops

