# Internal Auth Storage with HMAC Chain Verification

**Date:** 2026-02-24
**Status:** Approved
**Author:** Design collaboration

## Problem

Authentication credentials are stored in an external flat file (`~/.local/state/geode/geode_auth_state.db`) with plain text passwords in a pipe-delimited format. This is a security flaw:

1. Credentials exist outside the database's encryption boundary (TDE does not protect them)
2. Passwords are stored in plain text on disk
3. The file is trivially readable/modifiable by anyone with filesystem access
4. Two disconnected auth systems exist: `auth_state.zig` (CLI, plain text) and `geode_auth_lib.zig` / SecurityManager (server, Argon2id, in-memory only)

## Solution

Unify authentication into a single system where auth records (users, roles, permissions, policies) are stored as nodes/edges in the `__geode_security` graph within `graph_store.dat`. All passwords are Argon2id hashed. An HMAC chain provides tamper detection. The external `auth_state.zig` file system is removed entirely.

## Architecture

### Current State

```
auth_state.zig ──> ~/.local/state/geode/geode_auth_state.db (plain text, external)
                        │
                        ▼
                   CLI commands (geode user, geode role)

geode_auth_lib.zig ──> SecurityManager (in-memory only, volatile)
                        │
                        ▼
                   Server runtime (QUIC connections)
```

### Target State

```
graph_store.dat ──> __geode_security graph (encrypted via TDE, HMAC-verified)
       │
       ├──> Server startup: load + verify HMAC chain → populate SecurityManager
       ├──> Server runtime: mutations write to graph store + update HMAC chain
       ├──> CLI online: manage auth via QUIC to running server
       └──> CLI offline: bootstrap/emergency access to graph store directly
```

### Key Invariants

1. No plain text passwords anywhere -- disk or memory
2. Auth data encrypted at rest via TDE (same as all graph data)
3. HMAC chain verifies integrity on every server startup
4. Offline CLI can bootstrap initial admin user into graph store directly
5. All runtime auth management goes through the server

## Data Model

### Auth Records in `__geode_security` Graph

Builds on existing node labels in `src/storage/user_storage.zig`: `User`, `Role`, `Permission`, `Policy`.

**User Node Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `username` | String | Unique identifier |
| `email` | String | Optional |
| `password_hash` | String | Argon2id PHC format: `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>` |
| `hash_algorithm` | String | `"argon2id"` or `"blake2b"` (legacy migration only) |
| `is_active` | Bool | Account enabled/disabled |
| `is_superuser` | Bool | Admin privileges |
| `is_default_user` | Bool | Auto-created admin |
| `password_reset_required` | Bool | Force password change on next login |
| `mfa_enabled` | Bool | Multi-factor auth enabled |
| `failed_login_attempts` | Int | Rate limiting counter |
| `lockout_until` | Int | Unix timestamp, 0 if not locked |
| `created_at` | Int | Unix timestamp |
| `password_changed_at` | Int | For password expiry policy |
| `hmac` | String | HMAC-SHA256 over all other fields (hex) |

**AuthChainRoot Node** (single node, label `AuthChainRoot`):

| Property | Type | Description |
|----------|------|-------------|
| `chain_hash` | String | HMAC-SHA256 over all user/role HMACs concatenated in ID order |
| `record_count` | Int | Expected number of auth records |
| `last_verified` | Int | Unix timestamp of last successful verification |
| `hmac_key_id` | String | Identifies which HMAC key was used |

**Role, Permission, Policy nodes** keep their existing structure, each gains an `hmac` property.

**Edges (relationships):**

- `User -[:HAS_ROLE]-> Role`
- `Role -[:GRANTS]-> Permission`
- `User -[:SUBJECT_TO]-> Policy`

## HMAC Chain Verification

### Chain Construction

1. For each auth record (User, Role, Permission, Policy), compute per-record HMAC:
   - Serialize all properties (except `hmac` itself) in deterministic key-sorted order
   - `record_hmac = HMAC-SHA256(hmac_key, serialized_properties)`
   - Store as the `hmac` property on that node
2. Collect all record HMACs in node-ID order (ascending)
3. Concatenate and compute: `chain_hash = HMAC-SHA256(hmac_key, concat(all_record_hmacs) || record_count)`
4. Store `chain_hash` and `record_count` on the `AuthChainRoot` node

### HMAC Key Resolution (priority order)

1. `GEODE_AUTH_HMAC_KEY` environment variable
2. Derived from `GEODE_TDE_KEY` via HKDF (if TDE enabled)
3. Loaded from `.geode_hmac_key` file in data directory (0o600 permissions)
4. If none available: server refuses to start

### Verification Points

- **Server startup:** Full chain verification before accepting connections. Broken chain = refuse to start + tamper alert.
- **After any auth mutation:** Recompute modified record's HMAC, update chain hash.
- **Periodic:** Background check every N minutes (configurable, default 5 min).

### Failure Modes

| Condition | Action |
|-----------|--------|
| Missing `AuthChainRoot` node | First boot: create it. Otherwise: tamper alert, refuse to start. |
| `record_count` mismatch | Records added/removed outside server. Tamper alert, refuse to start. |
| Any record HMAC mismatch | Record modified outside server. Tamper alert, refuse to start. |
| `chain_hash` mismatch | Chain integrity broken. Tamper alert, refuse to start. |
| HMAC key unavailable | Server refuses to start with clear error message. |

### Recovery

`geode auth reseal --data-dir <path>` recomputes the entire HMAC chain (requires the HMAC key). For recovery after legitimate manual edits.

## Server Startup & Runtime Flow

### Startup Sequence (modified `server_init.zig`)

```
1. Initialize GraphStore (existing)
2. Replay WAL (existing)
3. Load HMAC key (new)
   - GEODE_AUTH_HMAC_KEY env → HKDF from GEODE_TDE_KEY → .geode_hmac_key file
   - Fail if no key available
4. Load auth records from __geode_security graph (new)
   - Query all User, Role, Permission, Policy nodes
   - Verify HMAC chain
   - If chain broken: refuse to start, log tamper alert
5. Populate SecurityManager from verified auth records (modified)
   - SecurityManager hydrates from graph data instead of creating its own state
6. If no users exist (fresh database): bootstrap default admin (new)
   - Generate Argon2id-hashed password
   - Create User node + AdminRole node + HAS_ROLE edge
   - Compute HMAC chain
   - Print password to stderr (existing pattern)
   - Set password_reset_required = true
7. Initialize QUIC listener (existing)
```

### Runtime Auth Mutations

```
1. Validate request through SecurityManager (permissions check)
2. Perform mutation in SecurityManager (in-memory)
3. Write auth record to __geode_security graph in GraphStore
4. Compute new record HMAC
5. Update AuthChainRoot (recompute chain_hash, update record_count)
6. GraphStore marks dirty -> persistence thread flushes to disk
7. WAL captures the mutation for crash recovery
```

SecurityManager becomes a read cache over the graph store. All writes go through the graph store with HMAC updates.

### Offline CLI Path

```
1. Open graph_store.dat directly (with TDE decryption if needed)
2. Load HMAC key (same resolution as server)
3. Verify HMAC chain
4. Perform mutation (e.g., create admin user, reset password)
5. Recompute HMAC chain
6. Save graph_store.dat (with TDE re-encryption if needed)
```

Limited to bootstrap/emergency operations. Normal user management goes through the server.

## Removal of auth_state.zig

### Files Removed

- `src/security/auth_state.zig` -- entire external file-based auth system
- `~/.local/state/geode/geode_auth_state.db` -- no longer created or referenced

### Clean Break

No migration from old auth_state.db. New installations start fresh. Existing users must be re-created through the new system.

### CLI Command Changes

| Command | Current | New |
|---------|---------|-----|
| `geode user create` | Writes auth_state.db | Online: QUIC to server. Offline: direct graph store |
| `geode user list` | Reads auth_state.db | Online: QUIC to server. Offline: direct graph store |
| `geode user delete` | Writes auth_state.db | Online: QUIC to server |
| `geode role create` | Writes auth_state.db | Online: QUIC to server. Offline: direct graph store |
| `geode role grant` | Writes auth_state.db | Online: QUIC to server |
| `geode serve` | Loads auth_state.db | Loads from graph store, verifies HMAC chain |

### New CLI Commands

| Command | Purpose |
|---------|---------|
| `geode auth init --data-dir <path>` | Bootstrap admin user into graph store (offline) |
| `geode auth reseal --data-dir <path>` | Recompute HMAC chain after legitimate manual intervention |
| `geode auth verify --data-dir <path>` | Check HMAC chain integrity without starting the server |

### Online vs Offline Detection

- CLI tries to connect to server first (configured host/port)
- If reachable: use QUIC path
- If not reachable: check for `--offline` flag or if command is bootstrap-only (`auth init`, `auth reseal`, `auth verify`)
- Non-bootstrap commands without `--offline` and no server: error with guidance

## Security Properties

### Password Hashing -- Unified Argon2id

- All new passwords: Argon2id with OWASP parameters (`t=2, m=19456 KiB, p=1`)
- PHC format: `$argon2id$v=19$m=19456,t=2,p=1$<salt_hex>$<hash_hex>`
- 16 bytes cryptographic random salt per password
- Duplicate Argon2id in `user_management.zig` consolidated into single implementation
- Blake2b legacy: auto-upgrade to Argon2id on successful login, deprecated after one release

### At-Rest Protection Layers

| Layer | Protects | Key |
|-------|----------|-----|
| Argon2id | Password irreversibility | Per-password random salt |
| HMAC chain | Auth record integrity | HMAC key (env/derived/file) |
| TDE (AES-256-GCM) | Entire graph_store.dat | GEODE_TDE_KEY |
| WAL encryption | Write-ahead log entries | GEODE_WAL_KEY or GEODE_TDE_KEY |
| File permissions | Data directory | OS-level 0o600 |

### Constant-Time Comparison

Existing `std.crypto.timing_safe.eql()` in `geode_auth_lib.zig` applies to both password verification and HMAC verification.

### Key Rotation

- HMAC key: change env var/key file, run `geode auth reseal`
- TDE key: existing TDE re-encryption mechanism (auth data rotates with everything else)

## Testing Strategy

### Unit Tests (zig build test)

| Test | Description |
|------|-------------|
| HMAC chain construction | Build chain from known records, verify deterministic output |
| HMAC chain verification | Tamper with one record, verify detection |
| HMAC chain record count | Add/remove record, verify count mismatch detection |
| Auth record serialization | Deterministic property ordering for HMAC input |
| HMAC key derivation | HKDF from TDE key produces stable output |
| Graph store auth round-trip | Write User/Role nodes to `__geode_security`, reload, verify |
| Password hashing consolidation | Single Argon2id path produces valid PHC strings |
| Blake2b migration | Login with Blake2b hash triggers auto-upgrade to Argon2id |
| Offline CLI bootstrap | `auth init` creates admin user with valid HMAC chain |
| Offline CLI reseal | Modify record, reseal, verify new chain is valid |

### Integration Tests (geodetestlab)

| Test | Description |
|------|-------------|
| Fresh server start | Auto-creates admin, prints password, requires reset |
| Auth persistence | Create user, restart server, user still exists |
| Tamper detection | Modify graph_store.dat externally, server refuses to start |
| Online user management | Create/delete users via QUIC while server runs |
| TDE + auth | Auth records encrypted/decrypted correctly |
| Password reset flow | Default admin forced to change password on first login |
| Rate limiting persistence | Failed attempts survive server restart |

### Unchanged (existing tests remain)

- SecurityManager authentication logic (rate limiting, MFA, sessions)
- Password policy validation
- RBAC/ABAC permission evaluation
- QUIC transport layer
