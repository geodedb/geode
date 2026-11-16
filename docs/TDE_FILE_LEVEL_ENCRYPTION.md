# TDE File-Level Encryption

**Status**: Implemented (single-tenant scope) — see [GAP_ANALYSIS.md](GAP_ANALYSIS.md) and [CLAUDE.md Known Limitations](../CLAUDE.md#known-limitations)
**Requirement**: REQ-TDE-FILELEVEL-001
**Last Updated**: January 28, 2026

## Overview

Geode implements Transparent Data Encryption (TDE) with AES-256-GCM. When
enabled, the storage engine's pages and WAL, its side files that hold
label, relationship-type and property-key names or indexed values, geode's
exact property index, the schema catalogs, time-series data and, in cluster
mode, the Raft log and snapshots are encrypted. What is not: see
[What TDE does not cover](#what-tde-does-not-cover).

This document covers the file-level encryption of index files, schema
catalogs, the cluster's Raft storage and other persistent data structures.

### What TDE does not cover

`zig build test-sonny6571-schema-names`, `test-sonny6571-tde-at-rest` and
`test-sonny6590-tde-side-files` write labels, relationship types, property
keys, an index, string and integer values and a time-series point through
real servers with `GEODE_TDE_KEY` set (one server, and a 3-node cluster),
and read every file under the data directories while running, after a
SIGKILL, after a restart and after a clean stop: none of them is found.
What stays in clear:

- File names, sizes and modification times.
- graph-storage files that hold ids, counts and checksums only: `labels.idx`,
  `edges.idx`, `edges_exist.idx`, `free.store`, `wal/graph.uuid`, and the
  manifests (authenticated with an HMAC under the key, not encrypted).
  `edges.idx` / `edges_exist.idx` show which nodes are connected and by
  which relationship-type id (the graph's shape, not its names or values).
- The Raft hard state (`<data_dir>/raft/hard_state`: the current term and
  the node id voted for, two u64 and a CRC32, 20 bytes) and `snapshot.meta`
  (index, term, voter ids). Deliberately not sealed (SONNY-6616): they hold
  no graph data, and the term, vote and voter ids are what every node
  already learns from the cluster's messages. Sealing them would mean
  replacing the raft library's `FileStorage` write of the hard state, the
  write the SONNY-6563 rule (no vote leaves before it is durable) rests on.
  They are protected against corruption (CRC), not against tampering by
  someone who can write the Raft directory; that person can equally roll
  the whole directory back, which sealing one file would not prevent.
- Plaintext copies written before an upgrade: replaced files are not
  scrubbed, so freed disk blocks, file-system snapshots and backups taken
  before the upgrade still hold what they held (see
  [Upgrading stores written before graph_storage 0.4.17](#upgrading-stores-written-before-graph_storage-0417)).
- With the `GEODE_TS_TDE=0` opt-out, time-series data (see
  [Time-series](#time-series)).

### Graph names (SONNY-6616)

`graph_registry.dat` (every graph's name, uuid, node and edge counts) and
`dropped_graphs.dat` (the names of dropped graphs) are sealed under
`GEODE_TDE_KEY` with the same envelope (graph-storage's
`GraphRegistry.saveToFileWith`; geode's consumer kind for the dropped
list), bound to graph-storage's `registry.SEAL_UUID`. A plaintext pair
written by an earlier build is read under the key and rewritten sealed
when the data directory is opened. Without the key, or under another key,
the data directory is refused (`SideFileEncrypted` / `SideFileAuthFailed`).
Requires graph-storage 0.4.20. An older geode cannot read a sealed
registry and refuses the data directory: there is no downgrade.

A graph whose manifests or WAL do not authenticate under the key is
refused with `58000 EncryptionKeyMismatch` (graph-storage 0.4.20; it was
`NoManifest`, which read as a missing graph).

### Sealed side files (SONNY-6590)

graph-storage 0.4.17 seals the side files that held names or indexed values
in plaintext beside the encrypted pages: `labels.dict` (label and
relationship-type names, every shard), `props.idx` (property-key names and
value hashes), `ordered_propidx.snap` (property-key names and indexed
values), `props.catalog` (key names of declared indexes) and every
`propidx_*.btree`. geode seals its own exact property index the same way:
`<graph dir>/prop_exact.idx` and `prop_rev.idx` hold property-key names and
a 64-bit unkeyed hash of every indexed value (a guessable value, such as a
small integer or a name from a list, is recoverable from its hash).

Envelope (graph-storage `side_file_crypto`, `docs/format-spec.md` §1.6 of
graph-storage): magic `00 00 00 00 G S E F`, version, kind, a random 96-bit
nonce, the AES-256-GCM ciphertext of the file's former layout and the tag.
Key: HKDF-SHA256 of `GEODE_TDE_KEY` (a key used for side files only).
Associated data: the header, the uuid of the graph (each shard has its own)
and the file name, so a file copied from another graph, shard or file name
fails authentication. geode's two files use the envelope kind
`prop_chain_index` (graph-storage's set of kinds is closed); the file name
keeps them apart.

When a graph is opened:

| What is found | Result |
| --- | --- |
| a graph-storage side file sealed under another key, modified, or copied from another graph | the graph is refused: `58000 SideFileAuthFailed` |
| a sealed graph-storage side file and no `GEODE_TDE_KEY` | refused: `58000 SideFileEncrypted` |
| a plaintext graph-storage side file in a store already sealed (manifest format_version 5) | refused: `58000 SideFileNotSealed` |
| a geode `prop_exact.idx` / `prop_rev.idx` that is plaintext, fails authentication or is stale | not used: the index is rebuilt from the pages and saved sealed (it is derived data) |

A refused graph refuses every read and write with the message above (the
server log names the graph); the server and its other graphs keep running.
None of the messages contains key material. To recover: restart with the
`GEODE_TDE_KEY` the graph was written with, or restore the graph's
directory from a backup.

### Time-series

Time-series data (`<data_dir>/timeseries`, and each graph's
`<graph dir>/timeseries`) is encrypted whenever `GEODE_TDE_KEY` is set
(WAL, segments and manifest; see docs/TIMESERIES.md). Before SONNY-6590 it
needed `GEODE_TS_TDE=1` as well, and a server with `GEODE_TDE_KEY` alone
wrote time-series values in plaintext to `<data_dir>/timeseries/ts.wal`.

| `GEODE_TDE_KEY` | `GEODE_TS_TDE` | Time-series |
| --- | --- | --- |
| set | unset, `1` or `true` | encrypted |
| set | `0` or `false` | plaintext, logged at ERROR on every start: only to read and export a store written before SONNY-6590 |
| unset | `1` or `true` | refused (no key) |
| any | anything else | refused (`InvalidTsTdeSetting`) |
| unset | unset, `0` or `false` | plaintext (no TDE) |

timeseries-storage 0.2.20 read the frames of a `ts.wal` it could not
decode as a torn tail and truncated the file, losing every point not yet
flushed to a segment; geode checked the WAL's layout itself before opening
a store. Since 0.2.21 (SONNY-6615) the library refuses such a WAL and
leaves it untouched, and geode maps its errors: an encrypted store opened
without the key (or with `GEODE_TS_TDE=0`) is refused
(`TimeseriesNeedsTdeKey`; a graph's store refuses the graph with 58000, the
server-wide one stops startup); a plaintext WAL under the key is handled
as a plaintext store (below); a WAL under another key (`WalAuthFailed`) or
damaged mid-log (`WalCorrupted`) is refused as itself and never replaced.

A time-series store written in plaintext and opened under the key:

- empty (every graph's own store, and the server-wide one if nothing was
  ever inserted): replaced by an encrypted store (moved aside with one
  rename, then deleted; a crash leaves the old store or none);
- holding data: not opened and not deleted (`TimeseriesNotEncrypted`). For
  the server-wide store, startup stops with the log line
  `timeseries.open_failed_fail_closed` naming the directory; for a graph's
  store, the graph is refused with `58000 TimeseriesNotEncrypted`.
  `GEODE_TS_DURABILITY=best_effort` does not turn it into an in-memory
  store. To keep the data: start once with `GEODE_TS_TDE=0`, export it
  (`CALL geode.ts.range`), stop, remove the `timeseries` directory, start
  without `GEODE_TS_TDE` and insert it again. The engine cannot list a
  store's series, so geode cannot migrate it in place.

## Enabling TDE

TDE is enabled by setting the `GEODE_TDE_KEY` environment variable:

```bash
# Generate a 256-bit key (64 hex characters)
export GEODE_TDE_KEY=$(openssl rand -hex 32)

# Or use a specific key
export GEODE_TDE_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# Start Geode server
./geode serve --listen 0.0.0.0:3141
```

### Key Requirements

| Parameter            | Value                      |
| -------------------- | -------------------------- |
| Algorithm            | AES-256-GCM                |
| Key Length           | 256 bits (32 bytes)        |
| Key Format           | 64 hexadecimal characters  |
| Environment Variable | `GEODE_TDE_KEY`            |

A `GEODE_TDE_KEY` that is set but is not exactly 64 hex characters is an
error, never "no key" (SONNY-6386). `geode serve` refuses to start before it
creates or opens the data directory, prints `[startup] GEODE_TDE_KEY is set
but unusable (InvalidKey) ... Refusing to start`, and never prints the value.
Before this, a malformed key silently opened the store with no page key and
every page was written in plaintext. The auth-chain HMAC key derivation
refuses a `GEODE_TDE_KEY` of the wrong length instead of using
`.geode_hmac_key`. An unset or empty `GEODE_TDE_KEY` still runs without page
encryption.

The storage-engine WAL is encrypted with `GEODE_TDE_KEY`, together with the
pages. There is no separate WAL key: `GEODE_WAL_KEY` was read only by the
logical `WriteAheadLog` wrapper formerly in `src/wal.zig`, which nothing in
the server instantiated (removed, SONNY-6422), so a server given
`GEODE_WAL_KEY` and no `GEODE_TDE_KEY` wrote its WAL in plaintext. A non-empty `GEODE_WAL_KEY` now refuses startup
(`[startup] GEODE_WAL_KEY is set, but the server does not use it ...`,
SONNY-6422); unset it and set `GEODE_TDE_KEY`.

## Encrypted File Types

### Index Persistence Files

The R-tree, Patricia trie, domain trie and JSONB inverted indexes have no
on-disk snapshot format: no compiled code writes or reads one, so there is no
index file for TDE to encrypt. The snapshot writers that used to be listed
here (`rtree_persist.zig`, `patricia_persist.zig`, `domain_trie_persist.zig`,
`jsonb_inverted_persist.zig`) were never compiled into any executable or test
and were removed in SONNY-6298.

| Index Type    | File Extension | Magic Header | Source File                  |
| ------------- | -------------- | ------------ | ---------------------------- |
| HNSW (Vector) | `.gdhw`        | `GDHW`       | `src/index/hnsw_persist.zig` |

`hnsw_persist.zig` is compiled by the `fuzz/targets/hnsw_snapshot_fuzz.zig`
fuzz target; no server code path calls it.

### Schema Catalogs

| Component           | File Name               | Source File                  |
| ------------------- | ----------------------- | ---------------------------- |
| Main Schema Catalog | `geode_catalog.dat`     | `src/schema/catalog.zig`     |
| FLE Schema Catalog  | `geode_fle_catalog.dat` | `src/schema/fle_catalog.zig` |

### Distributed Consensus (Raft)

Encrypted since SONNY-6571 (before it, the Raft log held every replicated
write in plaintext; the `src/distributed/raft_persistent.zig` wrapper an
earlier version of this page credited was reached by nothing in the server
and was removed by SONNY-6563).

The raft library's `FileStorage` keeps a node's Raft state under
`<data_dir>/raft`: `entries.wal` (the log), `hard_state`, `snapshot.meta` and
`snapshot.data`. With `GEODE_TDE_KEY` set, geode puts its own `Storage` in
front of it (`src/distributed/raft_tde_storage.zig`):

| File | Under TDE |
| --- | --- |
| `entries.wal` | each entry's data sealed (AES-256-GCM), authenticated with the entry's index, term and kind; the index and term themselves are in clear |
| `snapshot.data` | sealed: one record (a snapshot saved whole), or, for a snapshot staged off the Raft lock (a node's own, or one received from the leader; SONNY-6670), 64 KiB segments, each authenticated with its position and whether it is the last |
| `snapshot.stage.<n>.data` | a staged snapshot, sealed as it is written (segments as above); removed when it is committed or discarded, and on start |
| `snapshot.meta` | in clear: index, term, voter ids |
| `hard_state` | in clear: current term and vote (no graph data) |
| `tde.marker` | marks the directory encrypted; holds a salt and a key check value derived from `GEODE_TDE_KEY`, never the key |

Keys and nonces: nothing is sealed with `GEODE_TDE_KEY` itself. Each time the
directory is opened, geode draws a random 16-byte salt and derives a session
key with HKDF-SHA256 (`GEODE_TDE_KEY`, the salt, a Raft-specific label). The
nonce is a counter from 0 within the session, so a (key, nonce) pair repeats
only if two opens draw the same 128-bit salt. The derived keys are used for
nothing else, so their nonces cannot collide with the storage engine's.
Each record carries its salt, so records written in earlier sessions stay
readable. Durability is `FileStorage`'s unchanged: the log is appended and
fdatasync'ed by the wal library, the hard state and snapshots are written
to a temp file, fsync'ed, renamed and the directory fsync'ed, and a vote is
durable before the reply granting it is sent (SONNY-6563). A snapshot is
sealed, written and fsync'ed in its staged file without the Raft node lock,
and only renamed into place under it (SONNY-6670): a crash before the
rename leaves the previous snapshot.

On start, a cluster node with a data directory:

| `GEODE_TDE_KEY` | `<data_dir>/raft` | Result |
| --- | --- | --- |
| set | new, or empty | writes `tde.marker`, then encrypts |
| set | encrypted under this key | starts |
| set | encrypted under another key | refuses: `RaftStorageTdeKeyMismatch` |
| set | Raft state written without TDE | refuses: `RaftStoragePlaintextUnderTde`, and leaves the directory as it was |
| unset | encrypted | refuses: `RaftStorageNeedsTdeKey` |
| unset | written without TDE, or new | starts, plaintext (as before) |
| either | entry log with a damaged record (valid records after it), records that do not authenticate, or WAL-level encryption | refuses: `RaftStorageLogCorrupted` / `RaftStorageLogAuthFailed` / `RaftStorageLogEncryptionMismatch`, and leaves the directory as it was (SONNY-6622; it used to cut the log at the damage) |

**Enabling TDE on an existing cluster** (or upgrading a cluster that already
set `GEODE_TDE_KEY` from a build before SONNY-6571, whose Raft logs are
plaintext): a plaintext Raft directory is refused, not migrated; rewriting a
live log in place is not crash-safe, and the plaintext would remain in freed
disk blocks. Rebuild one node at a time while the others keep a leader: stop
the node, move its whole data directory aside, start it with
`GEODE_TDE_KEY` set and an empty data directory so it catches up from the
leader, check that it has (`SHOW CLUSTER STATUS`, a read of recent data),
then destroy the old directory and repeat on the next node. Moving only
`<data_dir>/raft` aside would replay the log onto the graph that is already
there.

**Changing `GEODE_TDE_KEY`** on a cluster node is refused by the Raft
directory as above; rebuild the node the same way.

**Downgrading** below SONNY-6571: an older build does not know
`tde.marker` and would hand the sealed entries to the apply path as if they
were commands. Do not start one on an encrypted Raft directory; rebuild the
node with an empty data directory instead.

## Technical Implementation

### Encryption Module

The core TDE functionality is implemented in `src/storage/tde_file_encryption.zig`:

```zig
// Write encrypted file
pub fn writeEncryptedFile(allocator: Allocator, path: []const u8, data: []const u8) !void

// Read and decrypt file
pub fn readDecryptedFile(allocator: Allocator, path: []const u8) ![]u8

// Load TDE key from environment
pub fn loadKey() ?[32]u8
```

### File Format

Encrypted files use the following format:

```
+------------------+
| Magic: GEOTDEFL  |  8 bytes - Identifies TDE-encrypted files
+------------------+
| Nonce            | 12 bytes - Unique per encryption
+------------------+
| Ciphertext       | Variable - Encrypted data
+------------------+
| Auth Tag         | 16 bytes - GCM authentication tag
+------------------+
```

### Encryption Process

1. **Save Operation**:
   - Buffer all data to memory using `ArrayList`
   - Call `tde.writeEncryptedFile()` which:
     - Generates a random 12-byte nonce
     - Encrypts data with AES-256-GCM
     - Writes magic header, nonce, ciphertext, and auth tag

2. **Load Operation**:
   - Call `tde.readDecryptedFile()` which:
     - Verifies magic header (`GEOTDEFL`)
     - Extracts nonce and ciphertext
     - Decrypts and authenticates data
   - Parse decrypted buffer using `fixedBufferStream`

### Overhead

| Component          | Size                   |
| ------------------ | ---------------------- |
| Magic Header       | 8 bytes                |
| Nonce              | 12 bytes               |
| Auth Tag           | 16 bytes               |
| **Total Overhead** | **36 bytes per file**  |

For typical index files (kilobytes to megabytes), this overhead is negligible (<1%).

### Measured overhead

Measured by `zig build test-sonny6435-tde-overhead` (SONNY-6435): the
storage engine geode opens every graph with, the same workload with page and
WAL encryption off and on (one operation inserts a node with a 512-byte
property and reads an earlier node's property), the two arms interleaved
batch by batch, medians, built ReleaseFast with the production-default
buffer pool. 2026-11-13, graph_storage 0.4.14, a shared and loaded 16-core
Threadripper PRO 3955WX dev host (load average 42 to 99 during the runs):

| Workload (WAL sync) | Plain | TDE | Overhead |
| --- | --- | --- | --- |
| `each_commit` (the default) | 53.5 ms/op | 54.1 ms/op | +1.0% (four runs: -0.0% to +1.2%) |
| `deferred`, no checkpoint in the timed window | 88.2 us/op | 114.0 us/op | +29.1% (four runs: +28.8% to +38.1%) |
| Reads that miss the buffer pool (8-page pool per shard) | 6.6 us/op | 10.6 us/op | +60.4% (four runs: +57.2% to +61.9%) |

With an fsync per commit the encryption disappears in the disk latency on
this host (an operation is three commits, about 18 ms per fsync). Without
it, encrypting the WAL records costs a little under a third of the commit
path's CPU time: about 26 us per operation, as on 0.4.13 (28 us), but
graph_storage 0.4.14 checksums WAL records with the CPU's CRC32C
instruction, which took about 50 us off both arms (0.4.13: 136.7 against
164.8 us/op, +18.7% to +20.9% over four runs), so the same cost is a larger
share. The +38.1% run was the first, at load average 99; the other three
were +28.8% to +29.6%, below the step's 35% bound. Storage with a faster
fsync lands between the two figures, so neither "<1%" nor "<5%" holds in
general. The step asserts that the encrypted arm
writes no plaintext, and checks the durable overhead below 5% and the
commit path's below 35% through `tests/perf_gate.zig` (reported by default,
enforced in the scheduled perf-gates CI job).

Reads that miss the buffer pool (SONNY-6452; taken once graph_storage
0.4.12 stopped losing the last 16 bytes of encrypted pages, SONNY-6441): two
checkpointed stores of 16000 nodes with a 512-byte property, an exact
8-page pool per shard (auto-size off), one operation reads the property of a
random node; the engines' own counters show 2.00 buffer-pool misses per
read in both arms. The store files sit in the OS page cache, so this is the
CPU cost of a miss, not disk latency. An encrypted miss decrypts the page
(AES-256-GCM, hardware AES): about 2 us more per miss than a plaintext
one, which only verifies the page's CRC32C. graph_storage 0.4.13 computes
that CRC with the CPU's CRC32C instructions (SSE4.2 / ARMv8, software
fallback; about 0.75 us per 8 KiB page instead of 15.6 us, by the library's
own measurement), and an encrypted page skips it. Before 0.4.13 the
software CRC made the plaintext miss the slower one (2026-11-13 with
graph_storage 0.4.12: 36.6 against 10.1 us/op, -72.5%). The step checks the
cold-read overhead below 80%. On a CPU without AES or CRC32C instructions
both arms are slower and the figure differs. The layers above the engine
(executor, query, network) do the same work in both arms and dilute every
figure here.

## Security Properties

### Confidentiality

- All persistent data encrypted with AES-256-GCM
- Key never written to disk
- Unique nonce per encryption prevents replay attacks

### Integrity

- GCM authentication tag detects tampering
- Invalid/corrupted files fail to decrypt with clear error

### Key Management

- Key loaded from environment variable at startup
- Key remains in memory only during server lifetime
- Integration with external KMS providers supported (see [KMS Provider System](KMS_PROVIDER_SYSTEM.md))

## Graceful Degradation

When TDE is not configured (`GEODE_TDE_KEY` not set, or set to the empty
string; a malformed value refuses startup, see Key Requirements):

- Files are written **unencrypted** (plaintext)
- Files can be read regardless of encryption state
- Mixed environments supported (encrypted + unencrypted files), except the
  cluster's Raft directory, which is either encrypted or not and refuses to
  start under the other setting (see Distributed Consensus (Raft))
- Warning logged when loading unencrypted files with TDE enabled

## CANARY Governance

All TDE-protected files include CANARY markers for requirement traceability:

```zig
// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=<Component>; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
```

### Component Aspects

| File                         | Aspect        |
| ---------------------------- | ------------- |
| `hnsw_persist.zig`           | HNSWIndex     |
| `catalog.zig`                | SchemaCatalog |
| `fle_catalog.zig`            | FLECatalog    |

## Testing

### Unit Tests

Each persistence module includes inline tests that verify:

- Successful save/load roundtrip
- Data integrity after encryption/decryption
- Error handling for corrupted files

### Integration Tests

The geodetestlab spec `tde_filelevel_encryption.yml` does not inspect any
file on disk. Every case (`tde-schema-catalog-encryption`,
`tde-rtree-index-encryption` and the others) creates a node whose properties
describe the file (name, extension, `encrypted: true`) and asserts that the
result contains that text; the cases pass whether or not anything is
encrypted.

Run tests:

```bash
# Run geodetestlab TDE tests
python3 geodetestlab/runner.py --spec tde_filelevel_encryption.yml

# Run unit tests
zig build test
```

## Migration Guide

### Upgrading Existing Installations

1. **Stop the server**
2. **Generate TDE key**: `export GEODE_TDE_KEY=$(openssl rand -hex 32)`
3. **Backup the key securely** (required for data recovery)
4. **Start the server** - existing unencrypted files will be read normally
5. **Trigger re-persistence** - indexes will be encrypted on next checkpoint

### Downgrading (Removing TDE)

1. **Stop the server**
2. **Unset the key**: `unset GEODE_TDE_KEY`
3. **Delete encrypted files** (they cannot be read without key)
4. **Restart and rebuild** indexes from source data

### Upgrading stores written before graph_storage 0.4.17

**Who is affected:** every data directory written with `GEODE_TDE_KEY` set by
a geode build that pins graph_storage 0.4.16 or older (SONNY-6590). Start the
new build with the same `GEODE_TDE_KEY`; no other step is needed for the
graph data:

1. Each graph's shards are upgraded when the graph is first opened
   (graph-storage, crash-safe at every step): a stale `labels.dict.tmp` is
   removed, `labels.dict`, `ordered_propidx.snap`, `props.catalog` and each
   `propidx_*.btree` are rewritten sealed, `props.idx` is emptied (rebuilt
   from the pages), and the next checkpoint or clean stop records manifest
   format_version 5.
2. geode deletes the graph's plaintext `prop_exact.idx` / `prop_rev.idx` when
   it opens the graph; the exact index is rebuilt from the pages on first use
   and saved sealed at the next checkpoint.
3. Empty time-series stores (every graph has one) are replaced by encrypted
   ones. A time-series store that holds data stops startup (server-wide
   store) or refuses its graph; see [Time-series](#time-series).

`test-sonny6590-tde-side-files` upgrades such a directory (written by a real
server, then put into the layout the old builds left: side files and exact
index in plaintext, manifests at format_version 4, time-series in plaintext)
and checks that every name, value and index reads back and that no file
holds any of them afterwards.

Plaintext copies are not scrubbed: freed disk blocks, file-system snapshots
and backups taken before the upgrade still hold the names. Treat them as
plaintext.

**Downgrade.** None. Once a graph has been checkpointed under the new build,
graph_storage 0.4.16 and older refuse it (`IncompatibleVersion` on the
manifest, `InvalidData` on a sealed `labels.dict`), so an older geode cannot
open it. Keep a backup taken before the upgrade if you may need to go back.

### Upgrading stores written before graph_storage 0.4.12

**Who is affected:** every data directory written with page encryption
(`GEODE_TDE_KEY` set) by a geode build that pins graph_storage 0.4.11 or
older. Stores written without `GEODE_TDE_KEY` are not affected.

**What was lost (SONNY-6441).** Those builds wrote the 16-byte AES-GCM tag
over the last 16 bytes of every encrypted page, so whatever a store kept
there never reached the disk. The page still authenticated, so nothing
reported an error. graph_storage 0.4.12 keeps the tag in the page header,
reads old pages, and returns their last 16 bytes as zero. At the 8 KiB page
geode uses:

| Store file | Lost bytes | After upgrading, without repair |
| --- | --- | --- |
| `nodes.store` | node in slot 169 of each page: `label_count`, `flags` (the deleted bit), `txn_stamp` | the node is present with label count 0 (its labels still read correctly); a deleted node in that slot is back; a node with no labels, properties or edges reads as absent |
| `adj_in_dir.store` | the last two incoming-edge heads of each page (destination ids `1020p + 1018`, `1020p + 1019`) | incoming edges to those nodes from that shard are invisible; the outgoing side is intact |
| adjacency chain blocks | the last entry of a full v1 (24-byte entry) block: entry 338 lost `rel_type` and `prop_head` (a v1 entry stores only its low 32 bits) | that edge reads with the wrong type and no properties: a typed MATCH misses it, and its properties, including the persisted public id of an edge written before inline edge ids, are unreachable |

v1 blocks are what stores kept before inline edge ids (graph_storage
0.2.24); later blocks (v2/v3) end before the tail at 8 KiB. Property and
variable-length stores, and slab adjacency blocks, kept the tail free and
lost nothing. graph_storage's `edge.legacyTailLoss` is the table of which
slot and bytes each entry format lost at each page size (at 4 KiB pages the
last v3 entry, at 32 KiB v1 and v3, at 64 KiB v3; geode uses 8 KiB).

**Before the first start of the new build:** stop the old server cleanly (a
clean shutdown checkpoints; a WAL tail replayed by the new engine is not seen
by the check below) and back up the data directory. Run the check before
starting the new build: every page the new engine writes moves to the new
page format, after which its damage can no longer be found.

**Check:**

```bash
GEODE_TDE_KEY=<key> geode storage verify --check tde-page-tail --data-dir /var/lib/geode
```

It reads the store files without opening the store (unlike the
`graph_store` check, which opens it and writes a checkpoint), takes the data
directory's lock (stop the server), and prints one JSON report: per graph
and shard, the pages still in the old format per store file
(`old_format_pages`) and what they lost: `nodes_liveness_unknown`,
`nodes_lost`, `in_dir_lost_heads` and `adjacency_entries` (file, page,
slot, edge id and neighbour of each damaged entry). Exit 0: nothing lost;
exit 1: something lost, or old pages found and no key to read them.
Without `GEODE_TDE_KEY` it can count old pages (their header carries no
checksum of their body and no new-format flag) but not list the records.
`adjacency_entries` reads blocks without consulting free space, so it can
name a block on a freed page; the repair walks only chains a node or a
directory head reaches, so such an entry stays listed.

**Repair:**

```bash
GEODE_TDE_KEY=<key> geode storage repair --tde-page-tail --i-have-a-backup --data-dir /var/lib/geode | tee tde-page-tail-repair.json
```

Offline: it takes the data directory's lock, refuses without
`--i-have-a-backup` (exit 2) or without the key (exit 1), checks first (the
`before` report, printed before anything is written), then repairs and checks
again (`after`). Exit 0 when the `after` report is clean. Keep its output: it
is the only record of the nodes whose liveness was lost. Per shard, in the
order graph_storage's operations guide requires, it restores:

- damaged adjacency entries, first and before any other write
  (graph_storage 0.4.13 `repairAdjTailEntries`): every edge is stored twice,
  in its source's outgoing chain and in an incoming chain keyed by its
  destination, and only the last slot of a full block can have lost bytes,
  so the lost fields are copied back from the other copy. geode never kept
  the incoming copy's `prop_head` current when it set an edge property
  after creating the edge, so before that the repair sets it from the edge
  index the old build wrote at its clean shutdown, where the index provably
  does not come from the damaged entry (`adjacency_mirrors_realigned`);
- `label_count` of each slot-169 node, from the node's label block (stored
  elsewhere, intact), and its creation stamp (geode always writes 1);
- the shard's live-node count, lowered by the nodes in `nodes_lost`
  (`node_count_corrected`): it still counted them, and geode refuses to load
  a graph whose shard holds fewer live nodes than it counts;
- the incoming-edge directory and chains of every shard with old directory
  pages, rebuilt from that shard's outgoing edges, after the adjacency repair
  (graph_storage's `migrateColocateInEdges`).

It rewrites those pages in the new format; a page holding only a lost node
is moved to the new format by rewriting another live node on it unchanged.
The `repaired` summary counts each step (`nodes_repaired`,
`adjacency_entries_repaired`, `adjacency_entries_unrepaired`,
`in_dir_rebuilt_shards`, `in_dir_blocked_shards`, ...) and lists each
adjacency entry it left, with graph_storage's reason, in
`adjacency_unrepaired`. A second run finds nothing to do.

**Not recoverable:**

- Whether a slot-169 node had been deleted. Nothing else records it: label
  index postings keep deleted nodes, a delete keeps the node's labels,
  properties and edge heads, the WAL is truncated at every checkpoint, and the
  shard's node count is a best-effort statistic. These nodes stay present and
  are listed in `nodes_liveness_unknown`; check them against your own data and
  delete the ones that should be gone.
- A slot-169 node with no labels, properties or edges: its whole record was
  the lost bytes. It stays absent and is listed in `nodes_lost`.
- An adjacency entry whose other copy cannot supply the lost bytes, listed
  in `adjacency_unrepaired` with the reason: `mirror_in_tail` (the same edge
  sits in the tail slot of both directions' full blocks, for example
  parallel edges between the same two nodes, and both copies lost the same
  bytes), `no_mirror` (no copy of the edge in the other direction on that
  shard), `prop_head_not_mirrored` (the only other copy is a legacy `adj_in`
  entry, whose property head is not kept current) or
  `wide_head_in_narrow_entry`. The entry is left as it is, and the directory
  of a shard with such an outgoing entry is not rebuilt (it would copy the
  damage over the incoming copy; `in_dir_blocked_shards`).
- The property head of a repaired outgoing entry when the edge index was
  rebuilt from the damaged pages (the old build did not shut down cleanly,
  or its index snapshot was missing): the head then comes from the incoming
  copy, which for an edge geode created before setting its properties
  still holds the head from creation, so the edge keeps its type but not
  its properties.
- An edge that an old build removed from a damaged full block: the removal
  moved the block's damaged last entry into the freed slot, where nothing
  marks it as damaged, so neither the check nor the repair can find it.

**No downgrade.** A build with graph_storage 0.4.11 or older cannot read a
page in the new format (`DecryptionFailed`), and the new build writes it on
the first change to a page, repair or not. To go back, restore the backup
taken before the upgrade.

## Troubleshooting

### Common Errors

| Error              | Cause                                | Solution                                   |
| ------------------ | ------------------------------------ | ------------------------------------------ |
| `InvalidMagic`     | File not TDE-encrypted or corrupted  | Check if file was created with TDE enabled |
| `DecryptionFailed` | Wrong key or corrupted data          | Verify `GEODE_TDE_KEY` matches original    |
| `KeyNotFound`      | TDE key not configured               | Set `GEODE_TDE_KEY` environment variable   |
| `InvalidKey` at startup (`GEODE_TDE_KEY is set but unusable`) | `GEODE_TDE_KEY` is not 64 hex characters | Fix the key (`openssl rand -hex 32` for a new store) or unset it |

### Verifying Encryption

Check if a file is encrypted:

```bash
# Encrypted files start with "GEOTDEFL"
head -c 8 path/to/file.gdrt
```

### Key Rotation

Key rotation requires:

1. Decrypt all files with old key
2. Re-encrypt with new key
3. Atomic swap of key in all cluster nodes

There is no automated key rotation: no command or KMS provider rotates
`GEODE_TDE_KEY` or re-encrypts the files under a new key (corrected
2026-11-12, SONNY-6435; [KMS Provider System](KMS_PROVIDER_SYSTEM.md),
"TDE-KMS Integration — Not Implemented").

## Related Documentation

- [Design: TDE and KMS](DESIGN_TDE_KMS.md) - Architecture and design decisions
- [KMS Provider System](KMS_PROVIDER_SYSTEM.md) - External key management integration
- [Field-Level Encryption](FIELD_LEVEL_ENCRYPTION.md) - Column-level encryption for sensitive fields
- [Security Progress](SECURITY_PROGRESS.md) - Overall security implementation status

## Changelog

### January 28, 2026

- Added TDE encryption to all index persistence files
- Added TDE encryption to Raft consensus state (not delivered: the wrapper
  was never reached by the server; the Raft log and snapshots are encrypted
  since SONNY-6571, 2026-11-15)
- Added TDE encryption to FLE catalog
- Created comprehensive geodetestlab spec
- Fixed Zig 0.15 ArrayList API compatibility
