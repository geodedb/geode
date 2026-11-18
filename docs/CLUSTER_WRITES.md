# Cluster writes: what a leader replicates, what it refuses

In cluster mode (`GEODE_CLUSTER_TOKEN` set) a write is evaluated on the leader,
serialized into a Raft entry and applied on every node. A follower answers
`ClusterNotLeader` (SQLSTATE `40001`); a shape the leader cannot serialize
answers `ClusterWriteNotReplicable` (`40001`) and writes nothing. Standalone
mode is unaffected. Reference for the codecs: `src/distributed/cluster_replication.zig`.

## Replicated (SONNY-6718 and earlier)

| Write | Notes |
|---|---|
| `CREATE` / `INSERT` of nodes and relationships | One chain or several (`CREATE (a:A), (b:B), (a)-[:R]->(b)`): one entry. A variable a later chain names is the node the first mention made. At most 32 nodes and 32 relationships per entry. |
| `MERGE (n:L {..})` of one node | Matched: nothing is proposed, or `SET` / `ON MATCH SET` is. Not matched: created with its `ON CREATE SET` / `SET`. |
| `MATCH ... SET` / `REMOVE`, label add / remove | The leader resolves the match and evaluates the expressions; followers apply concrete values by node id. |
| `MATCH ... DELETE` / `DETACH DELETE` | By node / relationship id. |
| `MATCH ... CREATE` between matched nodes | Head-only named chains, each variable resolving to exactly one node. |

Property values that replicate: null, integer, float, boolean, string,
**DECIMAL** (an exact numeric literal such as `3.5`: coefficient and scale
travel, so `1.50` stays `1.50` on every node), and the extended values the
property store holds (lists, dates and times, ...), in their property-store
encoding. A statement that writes once per row is held and proposed as one
entry (or none).

## Refused (deliberate residuals, `40001`, nothing written)

* A relationship `MERGE` (`MERGE (a)-[:R]->(b)`) and a `MERGE` with a `RETURN`:
  the created id (the Raft index) is unknown before commit.
* A `CREATE` that mints a NEW node inside a pattern that also names a
  MATCHed one (`MATCH (a) CREATE (a)-[:R]->(:New)`): a follower would have to
  re-resolve the match. Create the node first, then `MATCH ... CREATE` the
  relationship.
* A property value the property store cannot hold (a map, a node, a path).
* More than 32 nodes or 32 relationships in one entry, or an entry over the
  batch byte cap.
* `MERGE` / `SET` / `DELETE` whose match a statement's own held earlier write
  could change (the leader cannot tell what the MERGE would have matched).
* Surfaces with no replication slice at all: `CREATE`/`DROP GRAPH`, indexes,
  constraints, auth / policy / tenant DDL, `geode.ts.*` writes, mutating
  TDE / CDC / FLE procedures (`cluster.gateUnreplicatedWrite()`).

## Rolling upgrade

A DECIMAL or extended property travels as property tag 5 / 6 of the existing
payload magics (`GNC1`, `GNC2`, `GMRG`, `GUPD`, `GBAT`). A node running a binary
older than SONNY-6718 cannot apply such an entry (`CorruptPayload`): upgrade
every node before the first write that carries a decimal, or list, date, ...
