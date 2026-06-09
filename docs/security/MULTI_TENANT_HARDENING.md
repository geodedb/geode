<!-- CANARY: REQ=REQ-GAP-0842-INSECURE-BANNER-001; FEATURE="MultiTenantHardeningDoc"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=tests/test_gap0842_insecure_allow_all_banner.zig; OWNER=security; UPDATED=2026-06-08 -->

# Multi-Tenant Hardening — Production-Safe Configuration

This document states the production-safe configuration for deploying Geode as a
multi-tenant backend, and the specific footguns that disable tenant isolation.
It complements the project-wide caveat that Geode is **single-tenant-recommended
for production** (see [`CLAUDE.md`](../../CLAUDE.md), "Known Limitations"). If you
run multi-tenant, treat the rules below as mandatory.

Tracking: GAP-0842 (this doc + the startup banner) and GAP-0840 (strict-tenancy
mode). Source findings: [`docs/CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md`](../CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md).

## TL;DR — the production-safe configuration

1. **Never set `--insecure-allow-all` in production.** It bypasses ALL
   authorization (see below). It exists only for local development / debugging.
2. **Authentication must be enabled.** It is on by default (fail-closed);
   `--no-auth` is only available in debug builds and must never be used in
   production.
3. **Every session must present a concrete `tenant_id`.** A `Principal` with a
   real tenant scope is required for tenant isolation to apply. A session with
   no tenant scope — unset, empty, or the literal `"default"` — is treated as
   "all tenants" unless strict-tenancy mode is enabled.
4. **Enable strict-tenancy mode (GAP-0840) for multi-tenant deployments.** Set
   `--strict-tenancy` or `GEODE_STRICT_TENANCY=1` so that a tenant-scoped
   operation with no concrete tenant scope is **rejected** instead of silently
   reading every tenant's data. This is the complementary control to the
   `--insecure-allow-all` ban below.

## `--insecure-allow-all` bypasses tenant isolation (GAP-0842)

The `--insecure-allow-all` flag installs a process-wide kill switch that
short-circuits the central authorization decision (`gps.decide()` in
[`src/security/gps.zig`](../../src/security/gps.zig)) **before any tenant, RLS,
or FLE logic runs**. When set, `decide()` returns `allow` for every request.

Concretely, with `--insecure-allow-all` set, **all three** of the following are
disabled:

- **Tenant isolation** — every connection can read **every** tenant's data.
- **Row-level security (RLS)** — policies are not evaluated.
- **Field-level encryption (FLE) decrypt authorization** — the per-field
  `decrypt_field` GPS gate is bypassed.

This is a deployment-configuration cliff, not a code defect: the danger is
inheriting the flag from a non-production example (a dev `docker-compose`,
a copied `serve` invocation, a CI fixture). For a multi-tenant deployment this
is severe — a single misconfigured process exposes every tenant.

> Note: the **null-principal** path is **not** a bypass. An unauthenticated
> request fails closed with `unauthenticated` / `no_principal`
> ([`src/security/gps.zig`](../../src/security/gps.zig)). The only authorization
> bypass is `--insecure-allow-all`; isolation additionally depends on
> authentication being enabled and a `Principal` being present.

### Startup banner

When `--insecure-allow-all` is set, the server prints a prominent multi-line
banner to stderr at startup (in addition to a structured `WARN` log) so the
condition cannot be missed in a crowded startup log:

```text
========================================================================
  SECURITY WARNING: --insecure-allow-all IS ENABLED
------------------------------------------------------------------------
  ALL authorization checks are BYPASSED. This disables:
    * Tenant isolation  (every connection can read EVERY tenant's data)
    * Row-level security (RLS policies are NOT evaluated)
    * Field-level encryption (FLE) decrypt authorization
  NOT FOR PRODUCTION. Never set --insecure-allow-all on a deployment
  that holds more than one tenant's data. See
  docs/security/MULTI_TENANT_HARDENING.md.
========================================================================
```

The banner text is produced by `gps.insecureAllowAllBanner()` and pinned by
[`tests/test_gap0842_insecure_allow_all_banner.zig`](../../tests/test_gap0842_insecure_allow_all_banner.zig).

### Production refuse-to-start guard (GAP-0850)

As of GAP-0850, Geode **refuses to start** with `--insecure-allow-all` under
**production conditions**, before any listener binds. The guard fires when the
flag is set AND either of the following holds:

- the binary is a **release build** (`builtin.mode != .Debug`, i.e.
  release-safe / release-fast / release-small), or
- **`GEODE_ENV=production`** (case-insensitive) is set in the environment.

On a refusal the server logs a fatal SECURITY message naming the override and
exits non-zero — it never accepts a single request with authorization bypassed.

#### Break-glass override

For the rare legitimate recovery scenario (e.g. an operator deliberately needs
the bypass on a release binary in an isolated environment), set the explicit
override:

```
GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND=1
```

The verbose, unmistakable variable name is deliberate — it cannot be set by
accident and documents acknowledgement of the bypass in the deployment manifest.
With the override present the server starts and the prominent GAP-0842 banner
above still fires loudly.

A **Debug build with a non-production environment** (developer / test
workstation) is permitted without the override, so local testing of the bypass
is unaffected.

The decision is a pure, unit-testable function
(`gps.validateInsecureMode(insecure_allow_all, is_release, env_production, override)`
in [`src/security/gps.zig`](../../src/security/gps.zig)); the startup call site
in `src/server/main.zig` supplies the live build mode, `GEODE_ENV`, and override
values. Regression cover:
[`tests/test_gap0850_insecure_guard.zig`](../../tests/test_gap0850_insecure_guard.zig).

### Why there is no *multi-tenant-data-on-disk* auto-refuse

The GAP-0850 guard keys off the **deployment posture** (build mode / `GEODE_ENV`),
not the data. Geode deliberately does **not** additionally refuse to start with
`--insecure-allow-all` based on "more than one tenant's data is present on disk",
because that condition cannot be detected cheaply or safely:

- A tenant is a **per-record string tag** (`graph_store.tenant_id`, default
  `"default"`), **not** an on-disk directory. Storage is laid out **per graph**
  at `{data_dir}/graphs/{uuid}/...` — there is no per-tenant directory to
  enumerate.
- Answering "is more than one distinct tenant present?" would require a full
  scan of every node and edge across every graph at startup (and decrypting
  TDE-protected pages) before the listener is even up. That is expensive and
  fragile.

Inventing a data-scan heuristic here would create false negatives (missing the
very multi-tenant case it was meant to catch) and false positives (refusing to
start a legitimately single-tenant deployment). The posture-based GAP-0850 guard
plus the prominent banner plus strict-tenancy mode (GAP-0840) are the controls
we rely on instead.

## Strict-tenancy mode (GAP-0840) — the complementary control

`--strict-tenancy` (or `GEODE_STRICT_TENANCY=1`) closes the related "default
tenant sees all tenants" footgun. With strict tenancy enabled, a tenant-scoped
operation whose resolved tenant is unset, empty, or `"default"` is **rejected**
with `error.TenantScopeRequired` instead of being silently widened to all
tenants. Pair it with the `--insecure-allow-all` ban above:

- `--insecure-allow-all` ban → no global authorization bypass.
- `--strict-tenancy` → no accidental cross-tenant read from a missing scope.

See [`src/execution/tenancy.zig`](../../src/execution/tenancy.zig) and the
regression suite [`tests/test_gap0840_strict_tenancy.zig`](../../tests/test_gap0840_strict_tenancy.zig).

### Strict tenancy is the DEFAULT in multi-tenant deployments (GAP-0848)

GAP-0840 made strict tenancy purely **opt-in**, which left the dangerous default
intact: a deployment that had provisioned real tenants but forgot
`--strict-tenancy` still treated an unset/empty/`"default"` tenant as
"all tenants" — a silent cross-tenant leak. GAP-0848 flips that default.

**Detection signal.** A deployment is considered **multi-tenant** when the
durable tenant registry holds **at least one tenant whose id is not the implicit
`"default"` sentinel** (`tenant_registry.hasNonDefaultTenant`). The registry is
the single place a tenant record is created — only `CALL geode.tenant.create`
writes one — so a registered non-default tenant is the most truthful, O(n)
signal that an operator has actually provisioned tenants. (This is intentionally
distinct from the "tenant data present on disk" question, which is not cheaply
answerable — see the GAP-0850 section above.)

**Effective-mode resolution** (evaluated at startup, after the registry is
hydrated):

| Explicit `--strict-tenancy` | Multi-tenant signal | `GEODE_PERMISSIVE_TENANCY` | Effective mode |
|---|---|---|---|
| set | any | any | **strict** (operator asked) |
| unset | no | any | permissive (single-tenant, legacy — unchanged) |
| unset | yes | unset | **strict (auto-enabled — the GAP-0848 fix)** |
| unset | yes | set | permissive (explicit break-glass opt-out, loud warning) |

**Break-glass opt-out.** An operator who genuinely needs the legacy permissive
behaviour in a multi-tenant deployment must set `GEODE_PERMISSIVE_TENANCY=1`.
The server then logs a loud SECURITY warning that a missing tenant scope will
read **all** tenants' data. Single-tenant deployments are completely unaffected.

The decision is a pure, unit-testable resolver
(`tenancy.resolveEffectiveStrictTenancy(explicit_strict, multi_tenant, permissive_override)`
in [`src/execution/tenancy.zig`](../../src/execution/tenancy.zig)); the startup
call site `applyEffectiveStrictTenancy` in `src/server/main.zig` supplies the
live registry signal and `GEODE_PERMISSIVE_TENANCY`, applies the result via
`setStrictTenancy`, and logs the reason. Regression cover:
[`tests/test_gap0848_tenancy_default.zig`](../../tests/test_gap0848_tenancy_default.zig).

> **Serve-ordering (2026-06-09 follow-up).** `applyEffectiveStrictTenancy` — along
> with the tenant registry hydration and the per-tenant quota manager it depends
> on — now runs **before** the gRPC serve paths in `src/server/main.zig`, not just
> before the QUIC loop. Previously this state was initialized inside the
> `if (listen_quic)` block, so a gRPC-only deployment (`grpc_server.start()`) or
> the gRPC serve task in combined mode began accepting requests with strict
> tenancy unresolved and no quota manager published (gRPC handlers consult
> `getGlobalQuotaManager()`). Both gRPC and QUIC now inherit the resolved
> strict-tenancy mode and the hydrated registry before the first request is
> served.
>
> **Env parsing.** `GEODE_PERMISSIVE_TENANCY` (and the GAP-0850
> `GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND` break-glass override) are parsed
> **case-insensitively** (`TRUE`, `On`, `Yes` all work), matching
> `GEODE_STRICT_TENANCY` — a break-glass flag set in upper/mixed case must not
> silently fall through to the secure default.

## Tenant hierarchy (GAP-0838) — string-keyed, populate-able

The tenant `HierarchyManager`
([`src/security/rls_core.zig`](../../src/security/rls_core.zig)) models a
parent → child → sub-tenant tree (org → business-unit → engagement) and answers
"can tenant A see tenant B's data?" via `canAccessTenant`. As of GAP-0838 it is
keyed on the **string `tenant_id`** (matching HELLO/session/FLE/audit/proto and
`graph_store.DEFAULT_TENANT_ID = "default"`) instead of the old, never-bridged
`u64`, and it exposes a production provisioning API:

```zig
// Borrowed slices; the manager dupes/owns what it keeps. `parent` must already
// be registered (or null for a root). Returns error.TenantAlreadyExists /
// error.TenantNotFound on misuse.
try hierarchy_manager.addTenant("acme", null);            // root org
try hierarchy_manager.addTenant("acme-bu1", "acme");      // business unit
try hierarchy_manager.addTenant("acme-bu1-eng1", "acme-bu1"); // engagement
```

**Access semantics:** an accessor can access a target iff the accessor's
root-to-self path is a prefix of the target's path — i.e. the accessor is an
**ancestor of, or is,** the target. Parent → descendant is allowed; descendant →
ancestor is denied; siblings are denied; self-access is allowed; an unknown
tenant yields `error.TenantNotFound`.

**Populating it in production:** `addTenant` is the public seam. The live RLS
engine's `hierarchy_manager` is created at server init
([`src/server/main.zig`](../../src/server/main.zig) `RLSEngine.init`). Geode does
**not** yet ship a tenant registry or `CREATE TENANT` DDL to drive a hierarchy
automatically (that lifecycle surface is the separate GAP-0839); until it lands,
a deployment/embedder calls `addTenant` from its own provisioning code to
register the tree.

**Scope note:** GAP-0838 delivered the string-keyed, populate-able, tested
registry + `canAccessTenant`/`addTenant`. Wiring the live query/RLS evaluation
path to consult `canAccessTenant` on every read (so a parent tenant
automatically reads a descendant's rows) is a deliberately deferred
authz-semantics change — the current per-row tenant filter remains exact-match
on `tenant_id`. Regression suite:
[`tests/test_gap0838_tenant_hierarchy.zig`](../../tests/test_gap0838_tenant_hierarchy.zig)
(`zig build test-gap0838-tenant-hierarchy`).

## At-rest TDE is master-keyed, not per-tenant (GAP-0843 / GAP-0290)

Transparent Data Encryption (TDE) encrypts at-rest storage pages and backups
under a **single master key** (`GEODE_TDE_KEY`), **not** under per-tenant keys.
A single TDE/master-key compromise therefore spans **every** tenant's at-rest
data. Field-level encryption (FLE) is different — FLE field keys *are* derived
per tenant from `tenant_id` (see
[`docs/FIELD_LEVEL_ENCRYPTION.md`](../FIELD_LEVEL_ENCRYPTION.md)); this caveat is
specifically about the page/backup TDE layer.

### Why TDE cannot be per-tenant today

A geode "tenant" is a per-**record** string tag (`graph_store.tenant_id`,
default `"default"`), and storage is laid out per-**graph** at
`{data_dir}/graphs/{uuid}/...`. The per-graph storage engine is initialized with
one `encryption_key` (the master key) in
[`src/graph_store.zig`](../../src/graph_store.zig)
(`initGlobalAdapter` → `GraphConfig.encryption_key`). Because a single storage
**page** can hold records belonging to **multiple** tenants, there is no single
`tenant_id` that owns a page — so "encrypt each page under its tenant's key" is
not generally possible without **per-tenant page segregation**. That is a
storage-model redesign tracked under **GAP-0290** and is out of scope here.

### What GAP-0843 delivered (the tractable, correct subset)

- **`tde.encrypt_page` is a real encrypt, not a stub.** The handler
  ([`src/execution/storage_dispatch.zig`](../../src/execution/storage_dispatch.zig)
  `handleTdeEncryptPage`) performs an actual AES-256-GCM encrypt of the supplied
  page bytes via the TDE engine and returns the real `page_id`, `encrypted_size`,
  and `ciphertext` (`nonce ++ tag ++ data`, as `Bytea`). It previously returned a
  fabricated `success=true, page_id=0, encrypted_size=0` and discarded the input
  — a "reads as done but does nothing" hazard. With TDE disabled / no key it now
  reports `success=false` honestly. The key used is the **master key** (the only
  correct key at the multi-tenant page boundary).
- **The per-tenant key functions are correct, tested building blocks awaiting
  GAP-0290.** `tde.encryptForTenant` / `tde.decryptForTenant`
  ([`src/security/tde.zig`](../../src/security/tde.zig)) derive a per-tenant
  AES-256-GCM key via HKDF-SHA256 from the master key. They are correct **only**
  for a buffer of bytes known to belong to exactly **one** tenant (a future
  per-tenant backup/export — not a page). They are now compiled and regression-
  covered; data encrypted under tenant A's key cannot be decrypted under tenant
  B's (AEAD tag mismatch). The parallel file-level
  `encryptWithTenantKey`/`decryptWithTenantKey`
  ([`src/storage/tde_file_encryption.zig`](../../src/storage/tde_file_encryption.zig))
  are the same kind of building block.

Regression suite:
[`tests/test_gap0843_tenant_tde.zig`](../../tests/test_gap0843_tenant_tde.zig)
(`zig build test-gap0843-tenant-tde`). Source findings:
[`docs/CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md`](../CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md)
(GAP-0843 section).

### Operator guidance

Until GAP-0290 lands, treat the TDE master key as protecting **all** tenants'
at-rest data collectively. Protect `GEODE_TDE_KEY` (or the KMS-wrapped master
key) accordingly: a deployment that needs cryptographic at-rest separation
between tenants today must isolate at a higher level (e.g. a separate Geode
instance / data directory per tenant), since a shared instance shares the at-rest
key across tenants.

## Checklist

- [ ] `--insecure-allow-all` is **absent** from every production invocation,
      compose file, and CI fixture that touches production data.
- [ ] Authentication is enabled (default; no `--no-auth`).
- [ ] Each client connects with a concrete `tenant_id` (not unset/empty/`"default"`).
- [ ] `--strict-tenancy` / `GEODE_STRICT_TENANCY=1` is set for multi-tenant deployments.
- [ ] FLE-encrypted fields are configured (see
      [`docs/FIELD_LEVEL_ENCRYPTION.md`](../FIELD_LEVEL_ENCRYPTION.md)) and the
      `decrypt_field` privilege is granted only to the intended roles.
- [ ] At-rest TDE is understood to be **master-keyed, not per-tenant**
      (GAP-0843 / GAP-0290): the `GEODE_TDE_KEY` master key protects every
      tenant's at-rest pages/backups collectively. For cryptographic at-rest
      separation between tenants today, isolate per tenant at the instance /
      data-directory level.
