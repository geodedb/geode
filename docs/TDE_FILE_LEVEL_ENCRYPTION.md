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

When TDE is not configured (`GEODE_TDE_KEY` not set):

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

See [KMS Provider System](KMS_PROVIDER_SYSTEM.md) for automated key rotation support.

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
