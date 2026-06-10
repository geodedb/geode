# Design Note: Per-Tenant At-Rest Encryption (Deferred)

Status: **Deferred** — tracked as GAP-0851 (claim narrowing) and GAP-0290
(implementation). This note records the current shared-master-key reality, what
a per-tenant at-rest model would require, why it is deferred, and what *is*
per-tenant today.

Last updated: 2026-06-10

## Scope

This note covers **at-rest Transparent Data Encryption (TDE)**: the encryption
of storage **pages**, the **WAL**, and **backup** artifacts. It does **not**
cover field-level encryption (FLE), which has a different (per-tenant) key model
— see [What is per-tenant today](#what-is-per-tenant-today).

## Current model: a single master key (shared across all tenants)

At-rest TDE encrypts storage with **one master key** for the whole instance:

- The master key is loaded from `GEODE_TDE_KEY` (env-var only; KMS unwrap into the page path is not implemented)
  by `tde.loadKey` and wired into **every** per-graph storage engine through a
  single `GraphConfig.encryption_key` in
  [`src/graph_store.zig`](../../src/graph_store.zig) (`initGlobalAdapter`). Every
  graph's pages are encrypted under that same key (the WAL honors `GEODE_WAL_KEY` as an instance-wide override before falling back to `GEODE_TDE_KEY`) — there is no
  per-graph or per-tenant key at the page boundary.
- The key hierarchy
  ([`src/security/tde_hierarchy.zig`](../../src/security/tde_hierarchy.zig))
  derives distinct `data_key` and `backup_key` values from the master via
  domain-separated `SHA-256(master || domain)`. These domains separate
  **data vs. backup**, **not** tenant from tenant. AES-256-GCM is the page/WAL
  cipher (NIST SP 800-38D).

**Security consequence:** a single TDE/master-key compromise exposes **every**
tenant's at-rest data. There is no cryptographic at-rest separation between
tenants. A deployment that needs cryptographic at-rest separation must isolate
at a higher level today — a separate Geode instance / data directory per tenant.
This is documented for operators in
[`docs/security/MULTI_TENANT_HARDENING.md`](../security/MULTI_TENANT_HARDENING.md)
(the "At-rest TDE is master-keyed, not per-tenant" section and the checklist).

## Why per-tenant at-rest is not possible without a storage redesign

A geode "tenant" is a per-**record** string tag (`graph_store.tenant_id`,
default `"default"`); storage is laid out per-**graph**, and a single storage
**page** can hold records belonging to **multiple** tenants. There is therefore
no single `tenant_id` that owns a page, so "encrypt each page under its tenant's
key" is not generally expressible against the current storage layout. The
existing `tde.encrypt_page` handler correctly uses the master key — the only
correct key at the multi-tenant page boundary today.

## What per-tenant at-rest would require

Closing GAP-0290 (the implementation behind GAP-0851) needs all of:

1. **Per-tenant key hierarchy.** A tenant-scoped key derived from the master
   (the HKDF-SHA256 derivation already exists as a building block — see below),
   plus lifecycle: provisioning on tenant create, rotation, and revocation on
   tenant drop, all KMS-integrated.
2. **Page tagging / per-tenant page segregation.** A storage-model change so a
   page (and its WAL records) belongs to exactly one tenant, so it can be
   encrypted under that tenant's key. This is the hard part — it is a
   storage-engine redesign, not a key-management change.
3. **Backup / restore workflow.** Per-tenant backup export and restore that
   carry the correct key material (or KMS key references), including a
   cross-tenant restore guard so tenant A's backup cannot be restored into
   tenant B's keyspace.

## What IS per-tenant today

- **FLE (field-level encryption) keys are per-tenant.** FLE derives field keys
  per tenant from `tenant_id`; data encrypted for tenant A cannot be decrypted
  under tenant B's key. See
  [`docs/FIELD_LEVEL_ENCRYPTION.md`](../FIELD_LEVEL_ENCRYPTION.md). This is a
  real, shipped per-tenant cryptographic boundary — but it protects only the
  fields configured for FLE, not the whole page/WAL/backup surface.
- **Per-tenant key-derivation building blocks exist (but are not wired to
  pages).** `tde.encryptForTenant` / `tde.decryptForTenant`
  ([`src/security/tde.zig`](../../src/security/tde.zig)) and the file-level
  `encryptWithTenantKey` / `decryptWithTenantKey`
  ([`src/storage/tde_file_encryption.zig`](../../src/storage/tde_file_encryption.zig))
  derive a per-tenant AES-256-GCM key via HKDF-SHA256 from the master key and
  are regression-covered
  ([`tests/test_gap0843_tenant_tde.zig`](../../tests/test_gap0843_tenant_tde.zig)).
  They are correct **only** for a buffer of bytes known to belong to exactly one
  tenant (a future per-tenant backup/export), **not** for a shared page. They
  are the correct foundation for GAP-0290, not evidence that per-tenant at-rest
  exists.

## Why deferred

Per-tenant at-rest encryption requires the storage-model redesign in item 2
above (per-tenant page segregation), which is out of scope for the current
single-master-key TDE feature. Until GAP-0290 lands, the supported posture is:
at-rest TDE is master-keyed and shared across tenants; cryptographic at-rest
separation between tenants is achieved by instance/data-directory isolation, and
field-level secrets that need per-tenant keys use FLE.

## References

- [`docs/security/MULTI_TENANT_HARDENING.md`](../security/MULTI_TENANT_HARDENING.md)
  — operator-facing at-rest TDE caveat + checklist.
- [`docs/FIELD_LEVEL_ENCRYPTION.md`](../FIELD_LEVEL_ENCRYPTION.md) — per-tenant FLE keys.
- [`docs/CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md`](../CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md)
  — GAP-0843 source findings.
- `tests/test_gap0843_tenant_tde.zig` — key-isolation + page round-trip regression.
