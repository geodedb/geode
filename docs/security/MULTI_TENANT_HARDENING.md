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

### Why there is no auto-refuse-to-start guard

Geode does **not** refuse to start with `--insecure-allow-all` when "more than
one tenant's data is present on disk", because that condition cannot be detected
cheaply or safely:

- A tenant is a **per-record string tag** (`graph_store.tenant_id`, default
  `"default"`), **not** an on-disk directory. Storage is laid out **per graph**
  at `{data_dir}/graphs/{uuid}/...` — there is no per-tenant directory to
  enumerate.
- Answering "is more than one distinct tenant present?" would require a full
  scan of every node and edge across every graph at startup (and decrypting
  TDE-protected pages) before the listener is even up. That is expensive and
  fragile.

Inventing a heuristic here would create false negatives (missing the very
multi-tenant case it was meant to catch) and false positives (refusing to start
a legitimately single-tenant deployment). Per the GAP-0842 guidance we instead
escalate to the prominent banner above plus this document, and rely on
strict-tenancy mode (GAP-0840) as the runtime control. If a future tenant
registry (GAP-0839) makes distinct-tenant detection O(1), an opt-in
refuse-to-start guard with an explicit override flag can be revisited.

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

## Checklist

- [ ] `--insecure-allow-all` is **absent** from every production invocation,
      compose file, and CI fixture that touches production data.
- [ ] Authentication is enabled (default; no `--no-auth`).
- [ ] Each client connects with a concrete `tenant_id` (not unset/empty/`"default"`).
- [ ] `--strict-tenancy` / `GEODE_STRICT_TENANCY=1` is set for multi-tenant deployments.
- [ ] FLE-encrypted fields are configured (see
      [`docs/FIELD_LEVEL_ENCRYPTION.md`](../FIELD_LEVEL_ENCRYPTION.md)) and the
      `decrypt_field` privilege is granted only to the intended roles.
