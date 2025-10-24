# Interfaces — Client Libraries

Protocol: Custom QUIC binary protocol (not HTTP). Messages: HELLO/RUN_GQL/PULL; results: SCHEMA/BINDINGS/EXPLAIN/PROFILE.

Go Client (clients/go/gql):
- Connect: `quic://host:port`
- Auth/session token; `conn.Query(ctx, gql, params, pageSize)` returns iterator
- Graph helpers: CreateNode/CreateEdge, ShortestPath, etc.
- Automatic paging via PULL; basic transaction support (BEGIN/COMMIT)

Zig Client (clients/zig/):
- Similar API: init → connect → login → query iterator
- Useful for tools/extensions in Zig

Other languages: Not yet official; protocol docs enable community clients.

Transport security: QUIC+TLS mandatory; dev mode can use self-signed; production should verify with CA.

Process mode: `process:` transport allows spawning local `geoded` via stdio (testing).
