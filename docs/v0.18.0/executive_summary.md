# Executive Summary

Geode is an open-source, ACID-compliant graph database implementing the emerging ISO/IEC 39075:2024 Graph Query Language (GQL) standard
GitHub
en.wikipedia.org
. Written in Zig for low-level efficiency, Geode focuses on reliability, security, and deterministic behavior in graph processing. It supports the property graph model (nodes with labels and properties, connected by labeled, property-bearing edges) and offers full transactional integrity (MVCC with snapshot isolation)
GitHub
.

All client-server communication is secured over QUIC+TLS (no plaintext TCP)
GitHub
, and on-disk data can be encrypted (transparent data encryption)
GitHub
. Geode’s query engine executes GQL MATCH patterns with deterministic results ordering and bounded-depth path expansions to avoid combinatorial explosions
GitHub
GitHub
. It features a distributed query coordinator for federated read queries across multiple shards
GitHub
 (though cross-shard writes are not yet available
GitHub
).

Extensive auditing is built-in: every write operation can produce an append-only, tamper-evident audit log with hash-chaining and periodic signed digests
GitHub
. Operational capabilities include online backups to S3 (full and incremental) and change-data-capture (CDC) webhooks for integrations
GitHub
. Geode is released under the MIT License
GitHub
 and is targeted at backend engineers, data engineers, and SREs who need a graph database with strong consistency, security features, and adherence to open standards.

Note: Geode (spyderorg) is a graph database and is unrelated to Apache Geode, the in-memory key-value data grid
baeldung.com
.