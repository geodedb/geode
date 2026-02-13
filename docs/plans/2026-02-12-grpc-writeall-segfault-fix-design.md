# Design: Fix gRPC handler segfault on aarch64 under rapid sequential writes (#479)

## Root Cause

Two bugs combine to cause the segfault:

1. **Partial writes in grpc-zig transport**: `writeFrame` calls `ioWrite()` but ignores the return value. Both `stream.write()` and `SSL_write()` can return fewer bytes than requested. On aarch64 under load, partial writes are common, corrupting HTTP/2 framing.

2. **No error recovery in streaming**: `handleExecuteStreaming` uses `try` for all writes. On failure, the HTTP/2 stream is left without TRAILERS, corrupting connection state.

## Fix Strategy

### Layer 1: Write-all I/O wrappers (grpc_tls.zig)

- Fix `sslWrite` to loop until all bytes written
- Add `rawAccept` plaintext wrapper with write-all semantics
- All connections (TLS and plaintext) get write-all behavior

### Layer 2: Server integration (grpc_server.zig)

- Always set `on_tls_accept` (TLS or raw wrapper)
- Add error recovery in `handleExecuteStreaming`

### Layer 3: Tests

- Zig unit tests for write-all behavior
- Geodetestlab spec for rapid sequential writes
