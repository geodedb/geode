# Architecture & Storage

High-Level Flow:
- Parse → Logical plan (NodeScan/Expand/Filter/Project/Group/Order/Limit/SetOp)
- Optimize deterministically; cost-based selection
- Execute via physical operators; index scans; graph traversal via CSR
- Stream results via SCHEMA + paged BINDINGS; PROFILE for operator timings

Storage & ACID:
- Slotted pages on disk; WAL-before-data (ARIES-style)
- MVCC with Snapshot Isolation; optimistic conflicts on commit
- On-page vacuum (PageCompact) with FSM tracking
- Durability: fsync on commit by default; configurable batching windows
- Dir fsync for durable renames; WAL segmentation + archival

Indexes:
- B-tree, Hash, Patricia (CIDR/prefix), R-tree (spatial), Interval, Inverted FTS (BM25 in progress), Bitmap, HNSW (vector)
- Transactional maintenance; planner leverages indexes; unique constraints

Determinism & Guards:
- Bounded expansions (default length 64, frontier 100k)
- Stable ordering for pagination; ExecutionGuardTrip on limit breach

Clustering & Federation:
- Coordinator/shards over QUIC; distributed top‑K/merge; reads federated
- No cross‑shard writes yet; groundwork for Raft/2PC noted

Observability:
- JSON logs (no secrets); Prometheus metrics (query, federation, storage, CDC, backup)
- System procedures (e.g., system.federation.status, system.resources)