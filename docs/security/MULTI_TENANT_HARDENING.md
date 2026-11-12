<!-- CANARY: REQ=REQ-GAP-0842-INSECURE-BANNER-001; FEATURE="MultiTenantHardeningDoc"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=tests/test_gap0842_insecure_allow_all_banner.zig; OWNER=security; UPDATED=2026-06-10 -->
<!-- CANARY: REQ=REQ-TENANT-DROP-CASCADE-001; FEATURE="TenantDropCascade"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=tests/test_gap0847_tenant_drop_cascade.zig; OWNER=security; UPDATED=2026-06-10 -->

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

**Populating it in production:** the supported production seam is the
`CALL geode.tenant.*` administrative procedure family (GAP-0839 — shipped), which
writes the **durable tenant registry** and populates the live RLS engine's
`hierarchy_manager` in one step. `CALL geode.tenant.create('acme-bu1', 'acme')`
both registers the durable record and calls `addTenant` for you, so an operator
never has to drive the hierarchy from embedder code. See the
[Tenant lifecycle administration](#tenant-lifecycle-administration-call-geodetenant--gap-0839--gap-0847)
section below for the full surface, durable registry, CLI, and **CALL-only DDL
scope** statement.

**Scope note:** GAP-0838 delivered the string-keyed, populate-able, tested
registry + `canAccessTenant`/`addTenant`. GAP-0846 then wired the live query read
path to consult `canAccessTenant` (via the fail-closed `canAccessTenantSafe`), so
a parent tenant automatically reads a descendant's rows while siblings and
descendant→ancestor reads stay denied. The fast exact-match path is preserved
when no hierarchy is provisioned (`hierarchy_manager.count() == 0`). Regression
suites:
[`tests/test_gap0838_tenant_hierarchy.zig`](../../tests/test_gap0838_tenant_hierarchy.zig)
(`zig build test-gap0838-tenant-hierarchy`) and
[`tests/test_gap0846_tenant_hierarchy_reads.zig`](../../tests/test_gap0846_tenant_hierarchy_reads.zig)
(`zig build test-gap0846`).

## Tenant lifecycle administration (`CALL geode.tenant.*`) — GAP-0839 / GAP-0847

Geode ships a first-class tenant lifecycle surface as a native **`CALL`
procedure family**, backed by a **durable, file-backed tenant registry** and a
`geode tenant` **CLI** subcommand. This is the supported way to create, inspect,
quota, and drop tenants in production.

**CALL-only administrative scope (no `CREATE/DROP TENANT` GQL DDL).** Tenant
administration is intentionally exposed **only** through the `CALL geode.tenant.*`
procedures (the ISO/IEC 39075:2024 `CALL <proc>(args) [YIELD …]` form) and the
`geode tenant` CLI — there is **no** `CREATE TENANT` / `DROP TENANT` GQL DDL
statement, and none is planned. Tenancy is a deployment-administration concern,
not a data-definition concern: keeping it on the `CALL` surface (a) avoids
grammar churn, (b) routes every operation through the single `admin_tenant`
GPS authorization gate (read **and** write — see below), and (c) matches the
other Geode administrative procedure families (`geode.fts.*`, `geode.ts.*`).
Treat `CALL geode.tenant.*` as the standard, supported tenant DDL surface.

**Surface** (each procedure is admin-only; see authz below):

| Procedure | Effect |
|---|---|
| `CALL geode.tenant.create(id[, parent])` | Register a tenant (durable) and add it to the hierarchy under `parent`. |
| `CALL geode.tenant.list()` | One row per registered tenant (id, parent, active, effective quota). |
| `CALL geode.tenant.show(id)` | 0 or 1 row for `id`. |
| `CALL geode.tenant.set_quota(id, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph)` | Set a per-tenant quota override (durable + live quota manager). |
| `CALL geode.tenant.drop(id[, cascade])` | Drop a tenant — see safe drop semantics below. |
| `CALL geode.tenant.backfill_edge_tags([dry_run])` | Re-tag legacy `default` edges from their endpoints and list mixed-tenant edges — see edge tenant tags below. |

**Authorization (fail-closed).** Every procedure in the family — **including the
read-only `list`/`show`** — is gated on the `admin_tenant` GPS action via
`gps.decide()` before any registry read or mutation. A non-admin caller is
rejected with `error.Unauthorized`; an unauthenticated caller with
`error.Unauthenticated`. (When authentication is disabled — local dev / CLI /
tests — the gate short-circuits to allow, identical to every other admin op.)

**Durability.** The registry persists to `{data_dir}/tenants/registry.jsonl`
(atomic temp-file + rename per mutation) and is hydrated at startup, so the
tenant set, parents, and quota overrides survive restart. A server always
has a resolved data directory (SONNY-6339), and it refuses to start when
`{data_dir}/tenants` cannot be created or `registry.jsonl` cannot be read
(SONNY-6346: it ran with an in-memory registry and a warning, so the
tenants were lost at the next restart). Only a caller without a data
directory (CLI, tests) gets the non-durable registry, which logs that it is
non-durable.

### Safe drop semantics (GAP-0847)

`CALL geode.tenant.drop` is **safe by default**. The pre-GAP-0847 drop removed
only the registry record and **orphaned** the tenant's data (nodes/edges stayed
tagged with a tenant id that no longer existed) and left the hierarchy node
dangling. The corrected semantics:

- **`cascade` (2nd arg) defaults to `false`.**
- A **non-cascade** drop is **REFUSED** when the tenant still owns data —
  `error.TenantHasData` if any node/edge is tagged with its id — or has child
  tenants — `error.TenantHasChildren`. The registry record and all data survive
  the refusal, so an operator never silently orphans data or descendants.
- A **`cascade = true`** drop deletes the tenant's **edges first, then its nodes**
  (referential consistency), recursively drops child tenants **bottom-up**
  (grandchildren before children), removes the hierarchy node, and finally removes
  the durable registry record. Deletion goes through the same `deleteEdge` /
  `deleteNode` store path as any other delete, so it is **WAL-logged and durable**
  when a storage adapter is wired, and it emits a summary `tenant_admin.drop`
  audit line with the deleted node/edge counts. The per-tenant scan filters
  strictly on `tenant_id`, so **other tenants' data is never touched**.
- The reserved **`default`** tenant (`graph_store.DEFAULT_TENANT_ID`, the implicit
  scope of every untagged row) can **never** be dropped — `drop('default'[, …])`
  is refused with `error.TenantReserved` **before any data is scanned**, with or
  without `cascade`. Cascading it would delete every untagged row in a
  single-tenant store. This is enforced both at the `CALL` dispatcher and in
  `TenantRegistry.drop`.
- The **registry itself** also refuses to drop a tenant that any other record
  names as its `parent` (`error.TenantHasChildren`), independent of whether the
  expr-RLS hierarchy engine is wired — the durable registry's parent links are
  the source of truth for the hierarchy.

> **Failure path (operator note, SONNY-6302).** A cascade drop deletes the
> tenant's rows with the checked store deletes. A delete that fails (the
> storage engine refused it, or out of memory) **fails the drop before the
> hierarchy node and the registry record are removed**: the tenant stays
> registered, the rows already deleted stay deleted (each delete is atomic in
> memory and in the engine), the rest remain, and
> `tenant_admin.drop_delete_failed` is logged with the error and the deleted
> and remaining counts. Re-run the drop to finish it. (Before SONNY-6302 an
> engine delete failure was logged and swallowed, so the drop removed the
> tenant and reported success with rows left behind.) A drop that removes a
> parent's children first and then fails on the parent leaves those children
> dropped.

`drop` returns a row with `tenant_id`, `dropped`, `nodes_deleted`,
`edges_deleted`. Examples:

```text
CALL geode.tenant.drop('acme')          -- refused if acme has data/children
CALL geode.tenant.drop('acme', true)    -- cascade: delete acme's data + subtree
```

Regression suite:
[`tests/test_gap0847_tenant_drop_cascade.zig`](../../tests/test_gap0847_tenant_drop_cascade.zig)
(`zig build test-gap0847`); lifecycle/registry/CLI cover:
[`tests/test_gap0839_tenant_lifecycle.zig`](../../tests/test_gap0839_tenant_lifecycle.zig)
(`zig build test-gap0839-tenant-lifecycle`) and
[`tests/test_gap0839_tenant_cli.zig`](../../tests/test_gap0839_tenant_cli.zig)
(`zig build test-gap0839-tenant-cli`).

### Edge tenant tags and `backfill_edge_tags` (SONNY-2693)

Every edge carries its own tenant tag, like every node. A tenant-scoped session
sees an edge only when **the edge's own tag and both of its endpoints** are
visible to it (hierarchy-aware, like node visibility). The rule is the same on
every read path: single hop, variable length, aggregation, OPTIONAL MATCH,
multi-hop patterns, pattern comprehensions, `COUNT {}`, `EXISTS {}`,
`shortestPath()` and the `CALL algo.*` procedures. An unscoped (admin) session
sees every edge.

There is **no exception for a `default` tag**. Unscoped and admin writes, and
follower replication, write `default`, and a `default` node is already hidden
from every tenant; a `default` edge is hidden the same way. Before SONNY-2693
some read paths admitted an edge whose endpoints were visible whatever its tag
(the GAP-0891 "endpoint bridge"). That showed a tenant another tenant's edge
between its own nodes, with its properties. It also kept legacy edges visible
that the pre-GAP-0891 worker bug had written as `default` between a tenant's
own nodes. Those legacy edges are now hidden from the tenant until they are
re-tagged:

```text
CALL geode.tenant.backfill_edge_tags(true)   -- dry run: report only
CALL geode.tenant.backfill_edge_tags()       -- re-tag, and report
```

The procedure scans every edge in every user graph, including edges evicted
from the cache, and returns one row per edge it re-tags or reports. The columns
are `edge_id`, `graph`, `edge_type`, `edge_tenant` (the tag before the run),
`from_tenant`, `to_tenant`, `action` and `reason`:

- **`retagged`** (`would_retag` in a dry run): the edge was tagged `default`
  and both endpoints belong to the same tenant T. It is now tagged T. This is
  the only change the procedure makes. Tags are compared exactly, so a tenant
  hierarchy does not make a parent's tag match a child's.
- **`mixed`**: the tags disagree in any other way. The endpoints belong to
  different tenants, or the edge carries a tenant tag its endpoints do not
  share, or an endpoint no longer resolves (its tenant is null). No tenant can
  see such an edge. The procedure leaves it unchanged, because only an operator
  can say whose it is.
- **`failed`** (SONNY-2733): the edge was due to be re-tagged, or could not be
  read, and the procedure failed on it. The edge is left as it was, `reason`
  names the error, and the run goes on to the next edge. A `failed` row with a
  null `edge_id` and reason `GraphLockTimeout` is a whole graph the procedure
  could not lock in time (see Locking below); none of its edges were scanned.
  Running the procedure again retries them. `reason` is null on every other
  row.

An edge whose tag equals both endpoints' tags is consistent and is not listed.
That includes a `default` edge between two `default` nodes.

**Review the dry run first.** The procedure cannot tell a legacy edge from a
`default` edge that an operator placed between two nodes of one tenant on
purpose. Such an edge is hidden from that tenant, and a real run moves it to
the tenant, which then sees it. So run the dry run, review every `would_retag`
row, and change or remove any edge that must stay `default` before the real
run.

With a storage adapter, each re-tag is written to storage before the cached
edge changes. It uses the same reserved key as the create path, so it survives
a restart. An edge whose tag cannot be stored is listed as `failed`, and
nothing about it changes. The tenant-keyed edge-type counts
(`db.relationshipTypes()` per tenant) move with the tag. A run that stops part
way keeps the re-tags it already made. Running it again is safe: an edge it
re-tagged is consistent and is not listed again.

**Locking (SONNY-2733).** The procedure works one graph at a time, in name
order. It takes that graph's write lock, re-tags that graph's edges, and
releases the lock before it takes the next graph, so it never holds two graph
locks. While it holds a graph, queries and writes on that graph wait, as they
do for any write; other graphs are not blocked. It waits for each graph's lock
the way a write statement does, for up to 120 seconds, and new readers of the
graph hold back meanwhile. A graph still busy after that is listed as `failed`
(see above) and the run goes on to the next graph. It skips the engine's own
graphs (named `__geode_…`, such as `__geode_security`) and any graph dropped
while it runs. Send the CALL as the only statement in its request: the server
then runs it without the statement lock it would take on the session graph.
Beside any other statement, including the `USE GRAPH` that the CLI's `-g` flag
prepends, it fails with `GraphLockHeld` and changes nothing.

The procedure is admin-only (the `admin_tenant` gate, like the rest of the
family), and it runs only in a session with no tenant scope. It changes every
tenant's edges, so a session scoped to a tenant is refused with
`TenantScopedSession`, even for a dry run. A real run is refused inside a
transaction with `BackfillInTransaction`, because a ROLLBACK could not undo its
re-tags. A cluster refuses a real run, as it does `create`/`drop`/`set_quota`,
because the re-tag has no Raft replication. A dry run is allowed in a
transaction and in a cluster. The result has one row per listed edge, so on a
large legacy store the dry run also shows how big the real run will be.

Regression suites:
[`tests/test_sonny2693_edge_tenant_rule.zig`](../../tests/test_sonny2693_edge_tenant_rule.zig)
(`zig build test-sonny2693-edge-tenant-rule`) and
[`tests/test_sonny2733_backfill_locking.zig`](../../tests/test_sonny2733_backfill_locking.zig)
(`zig build test-sonny2733-backfill-locking`).

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
- [ ] Tenant administration goes through `CALL geode.tenant.*` / the `geode
      tenant` CLI (the CALL-only DDL scope — GAP-0839); tenant `drop` is run with
      `cascade=true` only when intentionally deleting a tenant's data + subtree,
      and a non-cascade drop that returns `TenantHasData` / `TenantHasChildren` is
      understood as a refusal that protected live data (GAP-0847).
- [ ] After upgrading past SONNY-2693, `CALL geode.tenant.backfill_edge_tags()`
      has re-tagged legacy `default` edges between a tenant's own nodes. Its
      dry run was reviewed first for `default` edges placed on purpose, every
      `mixed` edge it lists has been reviewed, and no `failed` row remains.
