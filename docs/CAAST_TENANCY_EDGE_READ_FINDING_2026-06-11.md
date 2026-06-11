# CaaST Multi-Tenant Integration — Native-Tenancy Edge-Read Defect (2026-06-11)

**Source:** Downstream finding from the CaaST platform's multi-tenant integration against Geode.
**Verified by:** Claude Opus 4.8 against the live `geode:local` build (geode CLI `forward-principal` + a CaaST data-plane connection using native `tenant_id` HELLO) on 2026-06-11.
**Audience:** Geode maintainers + other agents acting on these issues.
**GitLab is the source of truth for gap status.** This document proposes one new GAP ID (**GAP-0891**); file an issue and reconcile with `docs/GAP_ANALYSIS.md` when actioned.
**Related:** Extends `CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md` (GAP-0838 … GAP-0846), in particular GAP-0841 (Go client native tenancy).

---

## Summary

| ID | Area | Title | Severity | Status | One-line recommendation |
|----|------|-------|----------|--------|--------------------------|
| GAP-0891 | Tenancy | A native `tenant_id` (HELLO field 3) connection returns tenant-scoped **nodes** but **ZERO edges** for every read — edge traversal fails-closed under native tenancy | **High** | Open | Tag edges with `tenant_id` on write under native tenancy (or derive edge visibility from endpoint visibility) so a native-tenant connection can read its own edges, as the GPS principal path already does. |

A Geode connection that authenticates with native tenancy (`HelloRequest.tenant_id`, proto field 3) can read its tenant's **nodes** but receives **zero edges** from any edge-bearing query — `MATCH ()-[r]->()`, a labelled `MATCH ()-[r:REL]->()`, a directed/undirected traversal from a known node, even an OPTIONAL MATCH. The same data, read either (a) without native tenancy or (b) via the **GPS principal-forwarding** path (`forward-principal user:tenant`), returns the edges correctly *and* with correct tenant isolation. So the data is present and correctly associated with the tenant; only the native-tenant **read path** drops edges.

This breaks every edge-dependent read for tenant-scoped data (graph/neighbourhood views, relationship existence checks, any traversal), which forces downstream consumers off the native-tenancy path for those reads.

---

## Reproduction

Single tenant `t_DEMO` seeded into graph `caast_data`: one `Engagement {id:'ENG-DEMO'}` with 23 outgoing edges (`HAS_ASSET`×6, `HAS_EVIDENCE`×10, `HAS_INTERVIEW`×4, `HAS_POAM`×2, `ASSESSES`×1) to 23 neighbour nodes. All nodes carry a `tenant_path` property (FLE-protected) and were written through a connection that set `HELLO.tenant_id = t_DEMO`.

### A. GPS principal forwarding — nodes AND edges visible (correct)

```
geode query --dsn 'quic://geode:***@geode:3141?graph=caast_data&insecure_tls_skip_verify=true' \
  --forward-principal 'u_alice:t_DEMO' "MATCH (n:Asset) RETURN count(n)"          => 6
  ... "MATCH ()-[r:HAS_ASSET]->() RETURN count(r)"                                => 6
  ... "MATCH (e:Engagement {id:'ENG-DEMO'})-[r]->(m) RETURN count(r)"             => 23
```

### B. Native `tenant_id` HELLO connection — nodes visible, edges ALWAYS zero (defect)

The CaaST data-plane pool opens `...?graph=caast_data&tenant=t_DEMO&role=admin` (the Go client sends `HELLO.tenant_id=t_DEMO`, field 3, + `role`, field 8). Instrumented inside the handler, the *same connection* reports:

```
tenant_id="t_DEMO" tenant_path="t_DEMO"
MATCH (n) RETURN count(n)                                  => 1     # bare unlabelled scan: near-zero
MATCH (n:Asset) RETURN count(n)                            => 0     # bare labelled scan: zero
MATCH (n:Asset) WHERE (n.tenant_path = $p OR
                       n.tenant_path STARTS WITH $p+'/')   => 6     # adding a tenant_path predicate: correct
MATCH ()-[r]->() RETURN count(r)                           => 0     # ALL edges
MATCH ()-[r:HAS_ASSET]->() RETURN count(r)                 => 0     # labelled edges
MATCH (e:Engagement {id:'ENG-DEMO'})-[r]->(m) ...          => 0     # traversal from a visible anchor
MATCH (e:Engagement {id:'ENG-DEMO'}) OPTIONAL MATCH
       (e)-[r]-(m) RETURN type(r), m.id                    => anchor row only, m = NULL
```

Node reads work **only** when the query carries an explicit `tenant_path` predicate; a bare/aggregate node scan returns near-zero. Edge reads return **zero under every shape tried** (labelled, unlabelled, directed, undirected, optional, scoped).

### C. Edges written through the native-tenant connection are also unreadable

Creating an edge through the native-tenant connection (`MATCH (a) MATCH (b) MERGE (a)-[:HAS_ASSET]->(b)`, both endpoints in-tenant) succeeds — the existence check before it reports "not present", the MERGE runs, the handler returns `created:true` — yet an immediate re-read of edges through the same connection still returns **zero**. So this is not a stale-write or seed-tagging artefact: the native-tenant **read** path does not surface edges at all.

---

## Impact

- Any edge-dependent read on tenant-scoped data returns nothing: neighbourhood/graph views, relationship existence/idempotency checks, path queries, anything that projects `type(r)` / `EdgeValue` / `PathValue`.
- Native tenancy (the mechanism a single-`tenant_id` HELLO selects) is therefore unusable on its own for any graph-shaped feature — the headline use case of a graph database. Consumers must route edge reads through a connection that is **not** natively-tenant-scoped (losing layer-1 isolation) or adopt GPS principal forwarding.
- Secondary: bare/aggregate node scans under native tenancy also fail-closed (return ~0 unless a `tenant_path`-style predicate is supplied), which is surprising and easy to mis-read as "no data".

---

## Likely mechanism (hypothesis for maintainers)

The native-tenant filter appears to be applied as a per-row predicate that requires a tenant attribute on the scanned row. Nodes can satisfy it (they carry the tenant tag / a `tenant_path`-style property the planner can use), so a node scan **with** a tenant predicate returns rows. **Edges carry no tenant attribute for the filter to test**, so every edge scan fails-closed to empty — independent of label, direction, or an OPTIONAL MATCH. The GPS principal path (`forward-principal`) evaluates visibility through GPS/RLS, which *does* cover edges (it returns 6/23 correctly), confirming the data and the tenant association are intact and the gap is specifically in the native-tenant edge **read/filter** path (and/or edges not being tenant-tagged on write under HELLO `tenant_id`).

Files most likely involved (native-tenant query filtering vs. GPS/RLS): `src/security/rls_core.zig`, `src/security/gps.zig`, `src/security/principal.zig`, `src/multitenancy/registry.zig`, `src/graph_store.zig`, and the HELLO `tenant_id` plumbing in `src/server/quic_connection_handler.zig`.

## Recommendation

1. Make a native-`tenant_id` connection able to read its own edges: tag edges with the writer's `tenant_id` on write under native tenancy, **or** derive edge visibility from endpoint visibility (an edge is visible iff both endpoints are), matching the behaviour the GPS path already provides.
2. Fix bare/aggregate node scans under native tenancy so they return the tenant's rows without requiring a caller-supplied `tenant_path` predicate (fail-open *within* the tenant, not fail-closed).
3. Until (1) lands, document that native `tenant_id` HELLO is node-only and that graph-shaped reads require GPS principal forwarding.

---

## Downstream mitigation in CaaST (for traceability)

CaaST's per-entity graph endpoints (`GET /api/v1/caast/<entity>/<id>/graph`) regressed to "anchor node only, zero edges" once data-plane reads were routed to per-tenant pools. CaaST's interim fix (ADR-018): keep the **anchor-visibility gate** on the per-tenant pool (node reads work, so a caller can only expand a neighbourhood anchored on an entity inside their own subtree — BOLA-safe) and run the one-hop **edge traversal** through the shared/default connection (`connDB`), the only driver-supported connection that returns edges. The neighbour set is not additionally tenant-filtered there (the `tenant_path` property is FLE-encrypted and reads as NULL off the non-tenant connection), an accepted limitation tracked in CaaST ADR-018 until GAP-0891 is fixed. CaaST entity ids are unique per tenant and the corpus is seeded per-tenant, so practical exposure is limited to genuinely cross-tenant shared/reference nodes.
