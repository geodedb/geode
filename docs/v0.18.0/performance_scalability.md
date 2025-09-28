# Performance & Scalability

- Deterministic guards cap runaway traversals (frontier, depth).
- Indexing (B-tree/Hash/R-tree/HNSW/etc.) critical for query speed.
- QUIC reduces latency; process: transport for local tests.
- Throughput bounded by WAL fsync (tune commit flush policy, batch ops).
- Scale reads with shards + coordinator; writes scale vertically until distributed writes land.
- Monitor p95 query duration, cache hit ratio, federation errors, CDC DLQ.
- Benchmarks indicate low overhead for encryption and federation; optimize with stats & plan selection.
