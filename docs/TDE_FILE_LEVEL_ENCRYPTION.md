# TDE File-Level Encryption

**Status**: Implemented (single-tenant scope) — see [GAP_ANALYSIS.md](GAP_ANALYSIS.md) and [CLAUDE.md Known Limitations](../CLAUDE.md#known-limitations)
**Requirement**: REQ-TDE-FILELEVEL-001
**Last Updated**: January 28, 2026

## Overview

Geode implements Transparent Data Encryption (TDE) at the file level for all persistent storage components. When enabled, all data written to disk is encrypted using AES-256-GCM, ensuring data at rest is protected against unauthorized access.

This document covers the file-level encryption implementation that protects index files, schema catalogs, distributed consensus state, and other persistent data structures.

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

| Component     | File Name        | Source File                           |
| ------------- | ---------------- | ------------------------------------- |
| Raft State    | `raft_state.bin` | `src/distributed/raft_persistent.zig` |
| Raft Snapshot | `snapshot.bin`   | `src/distributed/raft_persistent.zig` |
| Raft Log      | `raft_log.bin`   | `src/distributed/raft_persistent.zig` |

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
buffer pool. 2026-11-12, a shared and loaded 16-core Threadripper PRO 3955WX
dev host:

| WAL sync | Plain | TDE | Overhead |
| --- | --- | --- | --- |
| `each_commit` (the default) | 53.3 ms/op | 53.7 ms/op | +0.7% (four runs: -1.3% to +0.7%) |
| `deferred`, no checkpoint in the timed window | 151.9 us/op | 181.5 us/op | +19.5% (three runs: +19.5% to +21.0%) |

With an fsync per commit the encryption disappears in the disk latency on
this host (an operation is three commits, about 18 ms per fsync). Without
it, encrypting the WAL records costs about a fifth of the commit path's CPU
time. Storage with a faster fsync lands between the two figures, so neither
"<1%" nor "<5%" holds in general. The step asserts that the encrypted arm
writes no plaintext, and checks the durable overhead below 5% and the
commit path's below 35% through `tests/perf_gate.zig` (reported by default,
enforced in the scheduled perf-gates CI job).

Not measured: reads that miss the buffer pool. With a pool smaller than the
store, the encrypting engine loses committed node records (graph_storage
0.4.10; `test-sonny6435-tde-small-pool-node-loss`, intentionally red), so a
cold-read figure would time that defect. The layers above the engine
(executor, query, network) do the same work in both arms and dilute the
figure.

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
- Mixed environments supported (encrypted + unencrypted files)
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
| `raft_persistent.zig`        | RaftState     |
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
- Added TDE encryption to Raft consensus state
- Added TDE encryption to FLE catalog
- Created comprehensive geodetestlab spec
- Fixed Zig 0.15 ArrayList API compatibility
