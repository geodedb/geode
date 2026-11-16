# Field-Level Encryption (FLE) for Geode

<!-- CANARY: FLE_DOCUMENTATION - Field-Level Encryption Design & Implementation -->
<!-- CANARY: REQ=REQ-FLE-DOC-001; FEATURE="FieldLevelEncryption"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2025-10-15 -->

## Overview

Geode implements **native, application-level field-level encryption** that provides:

- **Transparent encryption/decryption** for authorized users
- **RBAC/ABAC-gated access** to plaintext values
- **Equality search** on encrypted fields via blind indexes: designed, **not
  available** (see "Searchable fields today" below); `MERGE` on an encrypted
  field is refused (SONNY-6362)
- **Online key rotation** with zero downtime
- **Hierarchical key management** (TRK → SK → FEK/BIK)
- **AEAD encryption** using Zig `std.crypto` (AES-256-GCM, ChaCha20-Poly1305)

This feature is implemented with regression testing and follows NIST cryptographic standards. (The 97.4% geodetestlab figure previously cited here is a dated historical snapshot — see [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) for the current canonical baseline.)

---

## Architecture

### 1. Key Hierarchy

```
Master Key (GEODE_MASTER_KEY)
 └─ TRK (Tenant Root Key) [KEK]
     └─ SK (Schema Key) [KEK], per (tenant, schema)
         ├─ FEK (Field Encryption Key) [DEK], per (tenant, schema, field, version)
         └─ BIK (Blind Index Key) [HMAC key], per searchable field
```

**Master key:** the first 32 bytes of `GEODE_MASTER_KEY`, used as raw bytes
(the value is not hex-decoded: a 64-character hex string contributes its
first 32 characters). It must be at least 32 bytes long (SONNY-6422): a
shorter value used to be hashed with SHA-256 into a key, so any short string
worked as the master key. Now `geode serve` refuses to start with
`[startup] GEODE_MASTER_KEY is set but unusable: it is N bytes and must be at
least 32 bytes` (the value is never printed) and the key loader returns
`MasterKeyTooShort`. An empty value counts as unset (`MasterKeyRequired`).
No KMS supplies the master key in this release.

#### Master key format

`GEODE_MASTER_KEY_FORMAT` says how `GEODE_MASTER_KEY` is read (SONNY-6430):

| `GEODE_MASTER_KEY_FORMAT` | `GEODE_MASTER_KEY` must be | Master key |
| --- | --- | --- |
| unset (or empty) | at least 32 bytes | its first 32 bytes, as raw bytes (the legacy reading) |
| `raw` | exactly 32 bytes | those bytes |
| `hex` | exactly 64 hex characters (either case) | the 32 bytes they encode |
| `base64` | standard, padded base64 of exactly 32 bytes (44 characters) | the 32 bytes it encodes |

For a new deployment use a full 256-bit key:

```bash
export GEODE_MASTER_KEY_FORMAT=hex
export GEODE_MASTER_KEY=$(openssl rand -hex 32)
```

Anything else refuses startup before the data directory is opened, naming
the variables and never printing the value: an unknown format, a value that
does not match its format (a 63- or 66-character hex value is never
truncated), or `GEODE_MASTER_KEY_FORMAT` without `GEODE_MASTER_KEY`.

**Existing deployments keep their key.** Before SONNY-6430 the value was
always read the legacy way, so a 64-character hex value (`openssl rand -hex
32`) gave a key of its first 32 characters, 128 bits of entropy, and the
rest was ignored. Reading that same value as hex would give a different key
and make every field encrypted under the old one unreadable, so the format
is never inferred from the value: with `GEODE_MASTER_KEY_FORMAT` unset the
key is exactly what it was. A value longer than 32 bytes now starts with a
warning (`[startup] WARNING: GEODE_MASTER_KEY is N bytes and
GEODE_MASTER_KEY_FORMAT is not set, so only its first 32 bytes are the FLE
master key ...`). To keep the same key and drop the warning, set
`GEODE_MASTER_KEY` to its first 32 characters and
`GEODE_MASTER_KEY_FORMAT=raw`. Moving encrypted data to a full-entropy key
(`hex` or `base64` of a new value) needs the fields re-encrypted; there is
no master-key rotation command in this release.

#### Master key check value

A data directory records which master key its encrypted fields use
(SONNY-6435). On the first `geode serve` start with a `GEODE_MASTER_KEY`, the
server writes `fle_master_key.kcv` beside the FLE catalog in the data
directory: one line holding the key's check value, an HMAC-SHA256 of a fixed
label under a key HKDF-derived from the master key. It identifies the key
and does not reveal it. Like the catalog, it is written mode 0600, never
through a symbolic link, and encrypted under `GEODE_TDE_KEY` when that is
set.

Every later start with a key compares it with the recorded value:

- the same key (in the same `GEODE_MASTER_KEY_FORMAT`) starts;
- another key, or the same characters read in another format, refuses to
  start (`[startup] GEODE_MASTER_KEY is not the key this data directory's
  encrypted fields were written with ...`), naming the file and never the
  key. Without the check that server started, could not read the old
  fields, and wrote new ones under the new key;
- a check file that cannot be read or is not a check file refuses to start;
- a data directory with no recorded value (created without a key, or by a
  server from before this check) records one and is checked from then on.

Without `GEODE_MASTER_KEY` nothing is read or written: a deployment that
does not use FLE is never blocked. If no field was ever encrypted and you
mean to change the key, remove `fle_master_key.kcv` and start with the new
key; otherwise re-encrypt the fields first. Back the file up with the data
directory.

The same check runs wherever a master key is used, not only at server start
(SONNY-6442): `geode fle migrate-encrypt` checks it before anything else
(`[geode fle] ... refusing to run`), and the in-process FLE key manager
checks it on first use (`[fle] ... refusing to use it`), against the data
directory the FLE catalog lives in (`--data-dir`, else `GEODE_DATA_DIR`).
Each records a value where none is. With no data directory the catalog is in
memory and nothing is checked. All three call one helper,
`src/keys/master_key_check.zig` `verifyOrRecord`.

**Derivation:** HKDF-SHA256 with context strings:

- TRK: `"geode/trk/{tenant_id}"`
- SK: `"geode/sk/{schema}"`
- FEK: `"geode/fek/{field}"`
- BIK: `"geode/bi/{field}"`

### 2. AEAD Encryption

**Algorithms:**

- **AES-256-GCM**: Default on AES-NI/ARM-CE hardware (NIST SP 800-38D)
- **ChaCha20-Poly1305**: Fallback for non-AES platforms; constant-time

**Additional Authenticated Data (AAD):**

```
tenant_id␟schema␟field␟record_id␟key_version
```

(␟ = 0x1F separator)

This cryptographically binds ciphertext to its context, preventing cross-record/field attacks.

### 3. Envelope Format (V1)

Binary serialization (little-endian):

```
[alg_id:u8][key_version:u16][nonce:12][tag:16][ciphertext_len:u32][ciphertext]
```

- `alg_id`: 1 = AES-256-GCM, 2 = ChaCha20-Poly1305
- `key_version`: For rotation tracking
- `nonce`: 96-bit unique per (key, record, write)
- `tag`: 128-bit authentication tag
- `ciphertext`: Encrypted field value

### 4. Blind Index for Equality Search

For fields marked `@searchable`, Geode maintains:

```
BI = HMAC-SHA256(BIK, normalize(plaintext))
```

**Normalization:** ASCII lowercase + trim whitespace

**Storage:** Index maps `BI → [record_ids]`

**Query Rewrite (not implemented):** `WHERE p.email = "alice@example.com"`
was meant to become a BI token lookup.

**Leakage:** Reveals equality patterns (same plaintext → same BI) and frequency. Document this risk.

#### Searchable fields today (SONNY-6342)

- A field cannot be made searchable through the supported surface:
  `CALL geode.fle.configureField` reads only `algorithm` and `visibility`
  from its config map, so every field it configures reports
  `searchable = false` in `getFieldConfig` / `listEncryptedFields`
  (SONNY-6335 item 5). A `searchable` key other than `false` is refused
  with `error.SearchableFieldsUnsupported` (SONNY-6348; it used to be
  dropped silently). The `@searchable` annotation belongs to the FLE DDL,
  which is not available.
- Query planning does not use blind indexes: no `WHERE` predicate on an
  encrypted field is rewritten to a blind-index lookup. The predicate rewrite
  that was meant to do it (`planner/rewrite.zig` `performFLERewrite`, with
  `fle_integration.computeBlindIndex`) had no caller and did not compile; it
  was removed. `fle_integration.lookupEncryptedField` /
  `matchesEncryptedField`, which no query path called, were removed too
  (SONNY-6348).
- So equality search through blind indexes is not available.

---

## GQL Schema Extensions (Geode-Only)

> **Note:** These annotations are **non-standard** ISO GQL extensions, clearly marked as Geode-specific.

### DDL Annotations

Not supported: Geode has no `CREATE NODE TYPE` statement and no field
annotations (both are syntax errors). Declare an encrypted field with
`CALL geode.fle.configureField` (below). The block sketches the intended
schema form.

```text
CREATE NODE TYPE Person (
  id UUID PRIMARY KEY,
  name STRING,
  ssn STRING
    @encrypted(alg:"AES-256-GCM", key_scope:"field", rotate:"90d")
    @classify(tags:["PII","Restricted"])
    @visible(to_roles:["pii_reader"]),
  email STRING
    @encrypted(alg:"CHACHA20-POLY1305")
    @searchable(index:"blind-hmac-sha256")
);
```

**Annotations:**

- `@encrypted(alg, key_scope, rotate)`: Enable encryption
  - `alg`: "AES-256-GCM" or "CHACHA20-POLY1305"
  - `key_scope`: "field" (per-field FEK) or "schema" (shared SK)
  - `rotate`: Optional rotation interval hint

- `@searchable(index)`: Enable equality search via blind index
  - `index`: "blind-hmac-sha256" (only supported option)

- `@visible(to_roles)`: RBAC gate for plaintext access
  - `to_roles`: List of roles permitted to see plaintext

- `@classify(tags)`: Sensitivity tags for audit/compliance
  - `tags`: e.g., ["PII", "PHI", "Restricted"]

### Query Helpers

Not supported: there is no `PLAINTEXT()` or `CIPHERTEXT()` function.

```text
-- Force plaintext projection (requires privilege)
RETURN PLAINTEXT(p.ssn)

-- Force ciphertext projection (always allowed)
RETURN CIPHERTEXT(p.ssn)
```

### Admin Commands

```bash
# Key rotation
geode key rotate --tenant T --schema S --field F --scope [FEK|SK|TRK]
geode show rotation-status --tenant T

# Access control
geode policy grant plaintext S.F --role R
geode policy revoke plaintext S.F --role R

# Migration
geode migrate encrypt --tenant T --field S.F --batch 1000
```

---

## Managing FLE Schema via `CALL geode.fle.*` (Supported, Stable Surface — GAP-0845)

<!-- CANARY: REQ=REQ-GAP-0845-FLE-CALL-DOC-001; FEATURE="FLECallProcedureSurface"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/fle_decrypt_denied_placeholder.yml; OWNER=security; UPDATED=2026-06-08 -->

> **The `CALL geode.fle.*` procedures are the supported, stable path for FLE
> schema management.** First-class GQL FLE DDL (declaring `@encrypted` /
> `@visible` / `@searchable` directly in `CREATE` / `ALTER` statements) is a
> **future enhancement** and is **not** currently available — see
> [`docs/GQL_AUTH_DDL.md`](GQL_AUTH_DDL.md) ("FLE DDL … not part of this
> surface"). Until that lands, configure encrypted fields **only** through the
> `CALL` procedures documented here. Downstream consumers (e.g. CaaST) should
> depend on this surface, not on annotation DDL.

These procedures use ISO/IEC 39075:2024 `CALL`-procedure form (the same shape as
`CALL geode.fts.search` / `CALL geode.ts.*`); they ride the generic GQL rows
wire protocol, so there is no client or proto change. Procedure names are
case-insensitive (normalized to lowercase per RQ-0022).
Implementation: [`src/execution/storage_dispatch.zig`](../src/execution/storage_dispatch.zig)
(`fle_table`); access policy: [`src/execution/procedure_access.zig`](../src/execution/procedure_access.zig).

### Administrative surface (GAP-0853)

**The `CALL geode.fle.*` procedures ARE the supported administrative surface for
FLE policy/catalog configuration. There is no GQL FLE DDL, and none is planned.**

Rationale: standard GQL (ISO/IEC 39075:2024) defines no FLE DDL, so any DDL form
would be a non-standard Geode extension to the grammar. Keeping FLE
administration on `CALL` procedures keeps the surface **versionable and additive**
(new keys/procedures can ship without grammar changes), routes every call —
read AND write — through the single GPS procedure gate (see authz below), and
matches the established admin surface for other subsystems
(`CALL geode.tenant.*`, `CALL geode.fts.*`, `CALL geode.ts.*`).

#### Authorization (who may call)

The mutating procedures are security administration (SONNY-6334): they
decide who reads which encrypted field in plaintext. They are **Admin
only**, checked in `procedure_registry.executeCallProcedure` before the GPS
procedure gate (`fle_admin.requireAdmin`, the same rule as the auth DDL):
any other role is refused with 42501 and an `access_denied` audit event,
and nothing changes in memory or on disk. With authentication off
(embedded use) every caller is an implicit admin; `--insecure-allow-all`
bypasses the check, as it bypasses all authorization. The read-only
procedures pass the GPS procedure gate (`.read`) and name no roles:
whether a field is encrypted is visible to any authenticated reader; who
may read it in plaintext is not exposed by any procedure.

| Procedure | Who may call |
|-----------|--------------|
| `geode.fle.configureField` | Admin. |
| `geode.fle.grantPlaintext` | Admin. |
| `geode.fle.revokePlaintext` | Admin (SONNY-6327). |
| `geode.fle.grantRole` | Admin (SONNY-6341). |
| `geode.fle.revokeRole` | Admin (SONNY-6341). |
| `geode.fle.getFieldConfig` | Any role/policy with `read` on the procedure. |
| `geode.fle.listEncryptedFields` | Any role/policy with `read` on the procedure. |

The key-affecting `tde.*` procedures (`initialize_key_hierarchy`,
`rotate_keys`, `configure_*`, `zeroize_keys`, `cleanup_key_hierarchy`,
`backup_encrypted`, `encrypt_backup`, `create_encrypted_backup`,
`restore_with_keys`, `restore_with_historical_keys`) are Admin only too.

Every `configureField`, `grantPlaintext`, `revokePlaintext`, `grantRole`
and `revokeRole` is an audit event (`configuration_change`; result `success` or `failure`, a failed
save included, with the error name): the caller, the procedure, the field
as `type.field`, and the role (grant, revoke) or the visibility roles
(configure); for `grantRole` / `revokeRole`, `user=<u> role=<r>`. No key
material is involved.

The offline `geode fle grant-plaintext` / `revoke-plaintext` commands work
on the data directory with the server stopped; whoever can run them owns
the files.

`configureField` declares **which** fields are encrypted; it does **not** grant
decryption. Reading decrypted plaintext is a separate, per-field authorization
(the `visibility` roles set on the field plus the `decrypt_field` /
`READ_PLAINTEXT` privilege) — see [Permissions](#permissions) below.

#### The internal security graph is never FLE-encrypted (GAP-0854)

FLE **never** applies to the internal `__geode_security` graph — the HMAC-chained
store that holds users, roles, policies, and grants. That graph is excluded from
FLE encrypt **and** decrypt at every node site
([`src/graph_store.zig`](../src/graph_store.zig) `isSecurityGraphName`), because
FLE-encrypting an admin record would corrupt the plaintext-computed audit HMAC
chain and trip `AuthChainTampered` on restart. So a `configureField('User', …)`
call cannot accidentally encrypt the security graph's own `User` records; it
configures FLE only for application-graph data. The security graph remains
protected at rest by TDE. See the GAP-0854 closure in
[`docs/GAP_ANALYSIS.md`](GAP_ANALYSIS.md) and regression
`tests/test_gap0854_fle_chain.zig`.

### Procedure reference

#### `CALL geode.fle.configureField(type_name, field_name [, config])`

Configures (creates or updates) a field as FLE-encrypted in the FLE catalog.
This is the write/declare path — the equivalent of an `@encrypted` annotation.

| Argument | Type | Required | Notes |
|----------|------|----------|-------|
| `type_name` | STRING | yes | Node/edge label the field belongs to (e.g. `'Person'`). |
| `field_name` | STRING | yes | Property name to encrypt (e.g. `'ssn'`). |
| `config` | MAP | no | `{ algorithm: <str>, visibility: [<role>, ...] }`. |

`config` keys actually read by the server:

- `algorithm` — `'AES-256-GCM'` (default) or `'CHACHA20-POLY1305'`. Unknown
  values fall back to `AES-256-GCM`.
- `visibility` — list of role names permitted to decrypt the field (e.g.
  `['admin']`). Other keys shown in older examples (`keyVersion`, etc.) are
  accepted/ignored for forward-compatibility.

Returns one row: `status` (STRING, `"configured"`).

```gql
CALL geode.fle.configureField('Person', 'ssn',
  { algorithm: 'AES-256-GCM', visibility: ['pii_reader'] })
RETURN 'configured' AS status;
```

#### `CALL geode.fle.revokePlaintext(type_name, field_name, role)`

The online equivalent of `geode fle revoke-plaintext` (SONNY-6327), the
mirror of `CALL geode.fle.grantPlaintext(type_name, field_name, role)`:
removes `role` from the field's visibility roles. Every read that starts
after the call returns sees the revoke (the catalog is the only decision
source; there is no decision cache). Revoking a role that has no access is a
no-op; an unknown type or field is an error. Refused in cluster mode. If the
catalog cannot be saved the revoke stays in effect in the running server
and the call fails with 58030 (`FleRevokeNotPersisted`): retry it, or the
role regains access at the next start.

Returns one row: `status` (STRING, `"revoked"`).

#### `CALL geode.fle.grantRole(user, role)` / `CALL geode.fle.revokeRole(user, role)`

SONNY-6341. An **FLE role** is a name in a field's `visibility` list (for
example `'pii'` or `'admin'`); it is not an auth role (`Admin`,
`ReadWrite`, `ReadOnly`) and not a custom role. A session names the FLE role
it wants in its HELLO (`role`; the CLI's `geode query --role <r>`). With authentication on, the session acts under
that role only if its authenticated user **holds** it: `grantRole` gives
`user` the role, `revokeRole` takes it away. Both are Admin only and audited,
refused in cluster mode, and stored as `FleRoleGrant` records in the
HMAC-chained `__geode_security` graph (loaded at startup; a dropped user's
grants go with it). A grant that cannot be saved is not applied (58030); a
revoke is in force at once and, if it cannot be saved, reports 58030 (retry
it). `user` must exist (42002); `role` is non-empty, letters, digits, `_`
and `-` only (22023). Returns one row: `status` (`granted`, `revoked` or
`not granted`).

A HELLO naming a role the user does not hold is not refused (clients that
always send a role keep connecting): the session has **no** FLE role, so
encrypted fields read as for a role not in their list, and the HELLO is an
`access_denied` audit event naming the user and the requested role. Grants
and revokes count from the next request of every live session. The Admin
builtin holds no FLE role implicitly; an Admin grants one to itself, which
leaves an audit record. With authentication off (embedded use) the named
role is used as before; `--insecure-allow-all` bypasses the check as it
bypasses all authorization.

**Upgrade (BREAKING):** after upgrading no user holds any FLE role, so
readers that saw plaintext read `[REDACTED]` until an Admin runs
`CALL geode.fle.grantRole('<user>', '<fle role>')` for each of them.

#### Read semantics (SONNY-6327)

Nodes and edges are read by the same policy, on every read surface
(`n.p` / `r.p` in RETURN, WHERE, ORDER BY and aggregates, `properties()`,
map projection, `RETURN n` / `RETURN r` / paths over QUIC and gRPC, JSON):

- a field that is not encrypted: the stored value;
- the request's FLE role is in the field's visibility roles AND GPS
  allows `decrypt_field` for the authenticated principal on the session's
  graph (SONNY-6334: the Admin builtin role, or an `ALLOW DECRYPT_FIELD`
  policy; a `DENY DECRYPT_FIELD` refuses, Admin included): the decrypted
  value; a value that does not decrypt is refused (58030,
  `FleDecryptionFailed`), never shown as stored;
- any other principal (role not listed, or GPS refuses): `[REDACTED]`; an
  `n.p` / `r.p` read of a searchable
  (blind-indexed) field is refused (42501, `SearchNotPermitted`). A
  predicate on the plaintext therefore never matches for that principal;
- the FLE catalog cannot be loaded: refused (58030).

The FLE role is the one the session's HELLO named (`role`), when its user
holds it (`grantRole` above, SONNY-6341); GPS must also allow
`decrypt_field`. QUIC and gRPC install the same request context
(`ServerState.installRequestThreadState`: tenant, FLE role, GPS gate) for
every request that runs or encodes a statement, and clear it afterwards.
In-process callers with no principal and no request context (embedders,
background work) are decided by the role list alone.

An inline property map on an encrypted field (`MATCH (n:L {ssn: '...'})`,
`-[:R {p: '...'}]->`) compares the stored envelope and never matches; use
`WHERE` (SONNY-6335 item 3, open). While any FLE field is configured the QUIC
write fast paths and the aggregate pushdowns decline to the executor.

`MERGE` whose pattern names a property that is FLE-encrypted in any type
(`MERGE (n:L {ssn: '...'})`, `MERGE (n {ssn: '...'})`, a relationship
property) is refused (0A000, SONNY-6362) before anything is written: the
stored value is randomized ciphertext, so the pattern value never matched
it and MERGE created a duplicate every time. Any type, because a value is
encrypted under its node's first label, which the pattern may not name.
MERGE on an unencrypted key and set the encrypted field with `ON CREATE
SET` / `SET`. Matching on an encrypted value needs deterministic or
blind-index encryption (SONNY-6350). The internal `__geode_security` graph
is never encrypted and is exempt.

#### Encryption identity (SONNY-6335, SONNY-6347)

Every encrypted string property is encrypted, and decrypted, under one
identity (`fle_integration.recordIdentity`): the record's stored tenant, the
node's first label or the edge's type, the field, and the record id `<id>`
(node) or `edge_<id>` (edge). The executor's FLE hook and the graph-store
write primitives (which encrypt a plaintext value that reaches them without
the hook: raft apply, internal callers) both use it. Because the tenant is
the record's, a parent tenant that the tenant hierarchy lets read a child
tenant's row (GAP-0846) decrypts it like the child does (SONNY-6347).

A graph-store write primitive keeps a value as it is only when it
authenticates as this record's envelope for the field (AEAD under the field
key and one of the identities below), which is how the executor's
already-encrypted value, an undo, or a replay of stored bytes are not
encrypted twice. Any other value, including a plaintext that merely has the
shape of an envelope, is encrypted (SONNY-6347; the primitives used a shape
test, so a crafted string of that shape was stored in the clear).

Readers try, in order: the current identity; the writer's request tenant in
place of the record's (values written before SONNY-6347, when the identity
used the request tenant: such a value written by a parent tenant into a
child's row still decrypts only for the parent); and the identity the
graph-store primitives wrote before SONNY-6335 (tenant and schema `default`,
record id `node_<id>` / `edge_<id>`).

#### No index over an encrypted field (SONNY-6335)

An index holds the values it indexes in its own files. Over an encrypted
field it would hold ciphertext (a fulltext search, an equality or range seek
and a UNIQUE check would never match: the envelope has a fresh random nonce
per write) or, maintained from a decrypted value, the plaintext. So:

- `CREATE INDEX` of any type (btree, hash, fulltext, vector, ...) over an
  encrypted field, and `CREATE CONSTRAINT ... IS UNIQUE` / `NODE KEY` over
  one, are refused (0A000). `NOT NULL` / `EXISTS` constraints are allowed.
- `CALL geode.fle.configureField` on a field that has an index or a UNIQUE /
  NODE KEY constraint over it, in any graph, is refused (0A000): drop it
  first.
- The two checks do not race (SONNY-6347): an index or constraint DDL
  reserves its fields from its check until its catalog row is recorded, and
  `configureField` checks the rows and those reservations and encrypts the
  field under the same lock, so one of the two is refused.
- An index made over a field before the field was encrypted (an existing
  deployment) is named in a `SECURITY` error line when the catalog is opened
  (server start), and is not used: an equality seek, a posting count and an
  ordered scan over an encrypted field fall back to a scan or a sort
  (SONNY-6347; a seek over such an index returned no rows). A fulltext one
  refuses `geode.fts.search` / `phrase` / `proximity` (0A000) instead of
  matching nothing. Its files may hold values written before the field was
  encrypted: drop it (`DROP INDEX`).

Searchable (blind-index) fields exist only in the FLE catalog (a field a
catalog file marks `searchable`): no `CALL` procedure can declare one
(`configureField` refuses a `searchable` key), a write adds its blind-index
entry, and nothing reads the blind index, so there is no equality search on
an encrypted field (see "Searchable fields today" above; SONNY-6335 item 5).

#### `CALL geode.fle.getFieldConfig(type_name, field_name)`

Reads the FLE configuration of a single field.

Returns one row: `encrypted` (BOOL), `algorithm` (STRING, `"none"` when not
encrypted), `searchable` (BOOL).

```gql
CALL geode.fle.getFieldConfig('Person', 'ssn');
-- encrypted | algorithm   | searchable
-- true      | aes256_gcm  | false
```

#### `CALL geode.fle.listEncryptedFields(type_name)`

Lists all encrypted fields configured on a type.

Returns one row per encrypted field: `field_name` (STRING), `algorithm`
(STRING), `searchable` (BOOL).

```gql
CALL geode.fle.listEncryptedFields('Person');
```

### End-to-end example: declare → write → read with/without role

This mirrors the regression harness spec
[`fle_decrypt_denied_placeholder.yml`](../../geode-test-harness/geodetestlab-cli/specs/fle_decrypt_denied_placeholder.yml)
(GAP-0301), which is run in CI.

```gql
-- 1. Declare the encrypted field (admin). Only the 'admin' role may decrypt.
CALL geode.fle.configureField('Person', 'ssn',
  { algorithm: 'AES-256-GCM', visibility: ['admin'] })
RETURN 'configured' AS status;

-- 2. Create a readonly user that is NOT granted decrypt access.
CREATE USER pii_reader SET PASSWORD 'reader-pass-123' ROLE readonly;

-- 2b. Let the admin user act under the FLE role 'admin' (SONNY-6341: a
--     session acts under an FLE role only if its user holds it).
CALL geode.fle.grantRole('geode', 'admin');

-- 3. Write a row (admin). The engine encrypts ssn transparently on write;
--    the plaintext never lands on disk.
CREATE (p:Person { user_id: 'P001', ssn: 'SECRET-123-45-6789', city: 'Denver' })
RETURN p.user_id AS user_id;
```

```bash
# 4a. Admin reads under the FLE role 'admin' (--role sends it in HELLO):
#     plaintext (the Admin builtin passes GPS decrypt_field, and the user
#     holds the FLE role). Without --role, or before step 2b: [REDACTED].
geode query -U geode -P "$GEODE_ADMIN_PASSWORD" --role admin \
  "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn"
#   ssn
#   SECRET-123-45-6789

# 4b. Readonly user reads — the ROW is visible (row_count matches admin), but
#     the ssn field is [REDACTED], even naming --role admin: it does not hold
#     the FLE role (and GPS does not allow it decrypt_field).
#     Field visibility != row visibility.
geode query -U pii_reader -P reader-pass-123 --role admin \
  "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn, p.city AS city"
#   ssn          | city
#   [REDACTED]   | Denver
```

`tests/test_sonny6341_fle_role_binding.zig` runs this example as written.

The unauthorized reader gets a redacted placeholder for `ssn` (never raw
ciphertext, never plaintext) while still reading the non-encrypted `city`
field and seeing the same row count as the admin — the decrypt gate is
enforced per field, not per row.

### Future enhancement

First-class FLE DDL (honoring `@encrypted` / `@visible` / `@searchable` on
`CREATE` / `ALTER`) is planned but **not** currently implemented. The `CALL
geode.fle.*` surface above is the stable contract; do not depend on annotation
DDL for encryption configuration.

---

## Implementation Details

### Module Structure

```
src/crypto/
  ├── aead.zig           # AEAD wrapper (AES-256-GCM, ChaCha20-Poly1305)
  ├── hkdf.zig           # HKDF-SHA256 key derivation
  └── hmac.zig           # HMAC-SHA256 for blind indexes

src/keys/
  ├── types.zig          # KeyIds, KeyMetadata, RotationStats
  └── manager.zig        # KeyManager with cache and rotation

src/index/
  └── blind_index.zig    # BlindIndex for searchable fields

src/schema/
  └── annotations.zig    # Parse @encrypted/@searchable/@visible/@classify

src/planner/
  └── rewrite.zig        # Predicate rewriting for encrypted fields

src/exec/
  └── projection.zig     # Decrypt-on-projection with RBAC gates
```

### Encrypt-on-Write Hook

**Location:** `src/storage/graph_store.zig:setNodeProperty()` and `setEdgeProperty()`

**Flow:**

1. Check if field is `@encrypted` via schema catalog
2. Get FEK from KeyManager for `(tenant, schema, field, version)`
3. Construct AAD: `tenant␟schema␟field␟record_id␟version`
4. Encrypt: `EnvelopeV1 ← AEAD.encrypt(FEK, plaintext, AAD)`
5. If `@searchable`: compute `BI ← HMAC(BIK, normalize(plaintext))` and update blind index
6. Store envelope bytes (or base64)

### Decrypt-on-Projection Hook

**Location:** `src/execution.zig:writeValue()` for Node/Edge properties

**Flow:**

1. Detect encrypted field via schema catalog
2. If user has `READ_PLAINTEXT(field)` privilege:
   - Parse envelope
   - Get FEK from KeyManager
   - Decrypt: `plaintext ← AEAD.decrypt(FEK, envelope, AAD)`
   - Return plaintext
3. Else: return `"[REDACTED]"` or ciphertext blob

### Predicate Rewrite Hook

**Location:** `src/planner/rewrite.zig` (called before execution)

**Flow:**

1. For `WHERE p.field = "literal"` on encrypted field:
   - If field not `@searchable`: **error SearchNotPermitted**
   - If user lacks `READ_PLAINTEXT(field)`: **error SearchNotPermitted**
   - Else: compute `BI ← HMAC(BIK, normalize("literal"))` and rewrite to BI lookup

---

## Key Rotation

### FEK Re-Encryption (vN → vN+1)

1. **Create vN+1:** `KeyManager.rotateFEK(tenant, schema, field)`
2. **New writes:** Use vN+1
3. **Background migration:**

   ```zig
   for record in all_records:
     pt = decrypt(record.value, FEK_vN, AAD_vN)
     env = encrypt(pt, FEK_vN+1, AAD_vN+1)
     record.value = env
   ```

4. **Mixed-version reads:** KeyManager supports both vN and vN+1 simultaneously
5. **Opportunistic re-encrypt:** On read, if vN detected, re-encrypt to vN+1

### SK/TRK Rewrap (No Data Re-Encryption)

1. **Rewrap child keys:** Decrypt with old parent, re-encrypt with new parent
2. **Update metadata:** Rotate timestamps
3. **No data rewrite:** Actual field values unchanged

---

## RBAC/ABAC Enforcement

### Permissions

- `READ_PLAINTEXT(schema.field)`: View decrypted value
- `READ_CIPHERTEXT(schema.field)`: View ciphertext (always granted if node readable)
- `WRITE(schema.field)`: Set value (engine encrypts automatically)

### Enforcement

**Projection:**

```zig
if (!rbac.canReadPlaintext(user, schema, field)) {
    return "[REDACTED]"; // or ciphertext blob
}
```

**Filters:**

```zig
if (field.encrypted && !field.searchable) {
    return error.SearchNotPermitted;
}
if (field.encrypted && !rbac.canReadPlaintext(user, schema, field)) {
    return error.SearchNotPermitted;
}
```

**CLI Grants:**

```bash
GRANT READ_PLAINTEXT ON Person.ssn TO ROLE pii_reader;
REVOKE READ_PLAINTEXT ON Person.ssn FROM ROLE analyst;
```

---

## Performance

### Targets

- **Encryption:** Encrypt+BI for 2 KiB field ≤ 250 µs (x86-64 AES-NI)
- **Key cache hit:** ≤ 10 µs
- **Overhead:** 5-10% for read-heavy workloads with proper caching

### Optimization

1. **Key caching:** KeyManager maintains LRU cache with hit/miss tracking
2. **Batch operations:** Encrypt/decrypt multiple fields in parallel for graph traversals
3. **Selective encryption:** Only encrypt genuinely sensitive fields
4. **Hardware acceleration:** AES-NI auto-detected and used when available

### Monitoring

```zig
stats = KeyManager.cacheStats();
// { hits: 1234, misses: 56 }
// cache hit rate = 95.7%
```

---

## Security Considerations

### Threat Model

**Protected Against:**

- ✅ At-rest data compromise (without keys)
- ✅ Ciphertext tampering (authenticated encryption)
- ✅ Cross-record/field ciphertext swapping (AAD binding)
- ✅ Plaintext leakage in logs (never logged)
- ✅ Unauthorized plaintext access (RBAC gates)

**Not Protected Against:**

- ❌ Compromise of master/TRK keys
- ❌ Frequency analysis via blind indexes (document risk)
- ❌ Access pattern leakage (timing/volume)
- ❌ Spectre-class CPU vulnerabilities
- ❌ Physical memory attacks (cold boot)

### Mitigations

**Nonce reuse prevention:**

- Random 96-bit nonces via `std.crypto.random`
- Deterministic nonces only in tests

**Secure memory cleanup:**

```zig
defer std.crypto.secureZero(u8, &fek);
defer std.crypto.secureZero(u8, plaintext);
```

**Logging:**

- Never log plaintext or keys
- Audit by key IDs and operation counts
- Redact all sensitive values

**Limits:**

- Max plaintext: 64 KiB (configurable)
- AEAD usage limits enforced (track operations per key)

**The FLE catalog fails closed (SONNY-6324):**

The catalog (`geode_fle_catalog.dat` in the data directory) says which
fields are encrypted and who may read them in plaintext.

- A change whose save fails is an error (58030). `configureField` and a
  plaintext grant are undone. A revoke stays in effect in the running
  process and is reported as not saved (`FleRevokeNotPersisted`): retry it;
  any later saved change of the catalog also saves it. With no data
  directory the catalog is memory-only and nothing is saved.
- A catalog file that exists and cannot be loaded (corrupt, truncated,
  another or no `GEODE_TDE_KEY`, a symbolic link, unreadable) stops the
  server at startup with the file and the cause. An embedded or CLI session
  gets `FleCatalogUnavailable` (58030) from every use of the catalog, and
  every string property write and string property read is refused until
  it is restored. An absent file is an empty catalog.
- A string value that must be encrypted and cannot be is refused
  (`EncryptionRequired`, 58030), never stored in plaintext.

---

## Testing

### Unit Tests

Located in module files:

- `src/crypto/aead.zig:test` - Round-trip, bad AAD, envelope serialization
- `src/crypto/hmac.zig:test` - RFC 4231 vector (Jefe), normalization
- `src/crypto/hkdf.zig:test` - Key hierarchy derivation
- `src/keys/manager.zig:test` - Cache, rotation, FEK/BIK
- `src/index/blind_index.zig:test` - Put, lookup, remove

Run: `zig build test -Doptimize=ReleaseSafe`

### Integration Tests

GeodeTestLab specs in `geodetestlab/specs/encryption/`:

- `encryption_basic.yml` - Encrypt-on-write, decrypt-on-projection, RBAC
- `encryption_blind_index.yml` - Equality search via BI
- `encryption_rotation.yml` - Online FEK rotation
- `encryption_migration.yml` - Plaintext → encrypted backfill
- `encryption_rbac.yml` - Grant/revoke READ_PLAINTEXT

Run: `python3 extended_test_runner.py`

### Acceptance Criteria

1. **Correctness:** AEAD auth fails closed; AAD binds context
2. **Transparency:** Authorized users see plaintext; unauthorized see redaction
3. **Rotation:** Rewrap/re-encrypt online with progress telemetry
4. **Search:** Equality predicates on @searchable fields work (not met: see
   "Searchable fields today")
5. **Performance:** <250 µs encrypt+BI; <10 µs key cache hit

---

## Migration from Plaintext

### Process

1. **ALTER schema** to add `@encrypted` annotation (not supported as GQL:
   there is no `ALTER NODE TYPE`; use `CALL geode.fle.configureField`):

   ```text
   ALTER NODE TYPE Person ALTER PROPERTY ssn
     SET @encrypted(alg:"AES-256-GCM") @classify(tags:["PII"]);
   ```

2. **New writes:** Immediately encrypted

3. **Backfill existing data:**

   ```bash
   geode migrate encrypt --tenant default --field Person.ssn --batch 1000
   ```

   - Iterates records in batches
   - Encrypts plaintext → envelope
   - Resumable on failure

4. **Access during migration:**
   - Authorized users: still see values (plaintext or decrypted)
   - Unauthorized users: redacted even if still plaintext in storage

5. **Verify completion:**
   - Ensure no version-0 values remain
   - All records have EnvelopeV1

---

## Compliance

### Standards

- **NIST SP 800-38D:** GCM mode specification
- **NIST SP 800-57:** Key management lifecycle
- **RFC 5869:** HKDF key derivation
- **ISO/IEC 39075:2024:** GQL baseline (extensions clearly marked)

### Regulatory Alignment

- **GDPR:** Encryption at rest, pseudonymization, right to erasure (key destruction)
- **HIPAA:** PHI encryption, access controls, audit logging
- **PCI-DSS:** Cardholder data encryption, key rotation
- **SOC 2:** Confidentiality controls, security monitoring

---

## Future Work

### Planned Enhancements

1. **Post-Quantum Cryptography (PQC):**
   - Kyber for key wrapping
   - Dilithium for signatures
   - See `specs/security/field-level-enc-research-report-pqc-PR.md`

2. **External KMS Integration:**
   - AWS KMS, Azure Key Vault, GCP KMS
   - HSM support for TRK storage

3. **Advanced Searchable Encryption:**
   - Range queries (experimental)
   - Substring search (limited)
   - Order-preserving encryption (evaluate risks)

4. **Performance Improvements:**
   - SIMD acceleration for batch operations
   - GPU offload for high-volume encryption
   - Streaming encryption for large fields

### Research Areas

- Homomorphic encryption for computation on encrypted data
- Zero-knowledge proofs for search without decryption
- Secure multi-party computation for tenant isolation

---

## References

- [FLE Research Prompt](../specs/security/field-level-enc-research-PR.md)
- [FLE Design Report](../specs/security/field-level-enc-research-report.md)
- [FLE Implementation Spec](../specs/security/field-level-enc-research-report-code-PR.md)
- [FLE Geode Integration](../specs/security/field-level-enc-research-report-pqc-PR.md)
- [FLE Commit Plan](../specs/security/field-level-enc-research-report-pqc-commit-by-commit.md)
- [Zig std.crypto Documentation](https://ziglang.org/documentation/0.15.1/std/#std.crypto)

---

**Last Updated:** January 2026
**Status:** IMPLEMENTED - Core components complete
**Test Baseline:** see [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) (canonical); the prior 97.4% (1644/1688 geodetestlab) is a dated historical snapshot
**Security Review:** Pending external audit
