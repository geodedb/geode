# Auth DDL Persistence — write-through to the `__geode_security` graph + persistent per-graph grants

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use `- [ ]` checkboxes.

**Goal:** Make the auth DDL (`CREATE/ALTER/DROP USER`, `CREATE/DROP ROLE`, `GRANT/REVOKE`) — and the `geode.auth.*` procedures it routes through — persist to the on-disk `__geode_security` graph, so users, roles, password/role/active changes, and per-graph privilege grants survive a server restart. Additionally make `GRANT READ|WRITE|SCHEMA|ALL [ON GRAPH g] TO u` create a durable, enforced per-graph grant (today it is a no-op status stub; `handleUserEnableDisable` is also a no-op).

**Context / current state (verified):** The persistence machinery is fully built — `src/storage/user_storage.zig` `UserStorageBackend` (writes `User`/`Role`/`Permission`/`Policy`/`AuthChainRoot` nodes to a graph named `__geode_security`, flushed to the data dir), `src/security/auth_graph_manager.zig` `AuthGraphManager` (HMAC-chained, `createUser`/`updateUserPassword`/`assignUserRole`/`revokeUserRole` each internally call `sealChain`), and `src/server/server_init.zig` wires `SecurityManager` callbacks (`graphPersistUserCreate`/`graphPersistPassword`/`graphPersistRoleMembership`/`graphPersistLoginState`) to the AGM. **But** the `geode.auth.*` handlers in `src/execution/auth_dispatch.zig` call the low-level `src/security/user_management.zig` (`createUser`/`deleteUser`/`updateUserPassword`/`assignRole`) directly — `user_mgmt` has only a read-side `PersistentUserResolver` (no write callbacks), and `SecurityManager`'s callbacks are never invoked from this path. `g_custom_roles` / `g_policies` (for `geode.auth.role_create`/`policy_create`) are process-global hashmaps, never persisted. Per-graph access (`GraphRBACPolicy.graph_user_roles` in `src/security/multi_graph_security.zig`) is in-memory only and checked only at BIND time (`src/server/quic_connection_handler.zig` ~2920-2944), never at query time, and there is no `GraphGrant` concept in the persistent schema.

**Design (the seam):** Mirror the existing read-side `PersistentUserResolver` with a write-side **`PersistentUserWriter`** on `user_mgmt`, wired at startup to functions that delegate to the `AuthGraphManager` (exactly like the existing `graphPersistUserCreate` etc., but for the `user_mgmt` path). Every `user_mgmt` mutation (`createUser`, `createUserWithHash`, `deleteUser`, `updateUserPassword`, `assignRole`, new `setUserActive`) invokes the writer if installed → so all callers (the `geode.auth.*` handlers, mTLS, federation) get persistence for free. Custom roles and per-graph grants need a small **global `AuthGraphManager` accessor** reachable from `auth_dispatch.zig` (a `setGlobal`/`getGlobal` pair, set in `server_init`); `handleRoleCreate`/`handleRoleDelete`/`handleGrantRevoke` write through it. Add a new persistent **`GraphGrant`** node type (`(user_id, graph_name, action)`), hydrate it into `GraphRBACPolicy` at startup, and enforce it as an *additive widening* of the global role: at BIND time (extend the existing per-graph check) and at query time (a fallback in `execution.zig` `checkPermission` — if the global role denies, allow if a matching per-graph grant exists). Widening-only ⇒ cannot regress existing behavior.

**Tech Stack:** Zig 0.16; `src/security/` (user_management, auth_graph_manager, geode_auth_lib, multi_graph_security), `src/storage/user_storage.zig`, `src/execution/auth_dispatch.zig`, `src/execution.zig`, `src/server/server_init.zig` + `main.zig`, `zig build test`, `../geode-test-harness` geodetestlab (a *restart-survival* spec is the key acceptance test).

**Non-goals:** RLS policy (`g_policies` / `geode.auth.policy_create`) persistence — that's the separate deferred POLICY plan. No change to the existing `__geode_security` HMAC scheme beyond reusing `sealChain`. No new third-party deps. No change to the QUIC hot path beyond extending the existing BIND-time per-graph check.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `src/storage/user_storage.zig` | Modify | New `GraphGrantRecord` + `GRAPH_GRANT_LABEL`; new methods `persistGraphGrant`/`revokeGraphGrant`/`listGraphGrants`; confirm/expose `removeUser`, role write methods, a `listRoles`/`listUsers` reader |
| `src/security/auth_graph_manager.zig` | Modify | New wrappers (each re-seals the chain): `removeUser`, `setUserActive`, `createRole`→id, `removeRole`, `findRoleIdByName`, `findUserIdByName`, `grantUserGraphPermission`, `revokeUserGraphPermission`, `listGraphGrants`; global `setGlobal`/`getGlobal` accessor |
| `src/security/user_management.zig` | Modify | New `PersistentUserWriter` struct + `setPersistentUserWriter`; invoke it from `createUser`/`createUserWithHash`/`deleteUser`/`updateUserPassword`/`assignRole`; new `setUserActive(username,bool)` |
| `src/execution/auth_dispatch.zig` | Modify | `handleUserEnableDisable` → `user_mgmt.setUserActive`; `handleRoleCreate`/`handleRoleDelete` → also persist `Role` node via global AGM; `handleGrantRevoke` → record/remove a `GraphGrant` via global AGM + update in-memory `GraphRBACPolicy`; `hydrateCustomRolesFromGraph` |
| `src/security/multi_graph_security.zig` | Modify | `GraphRBACPolicy`: add a per-graph *grant* set (`(user_id, graph, action)`), `grant`/`revoke`/`has` API, and a `loadGraphGrants` loader |
| `src/execution.zig` | Modify | `checkPermission` fallback: on global-role denial, allow if the bound graph + user has a matching `GraphGrant` |
| `src/server/quic_connection_handler.zig` | Modify | Extend the BIND-time per-graph check to also consult the new grant set (additive allow) |
| `src/server/server_init.zig` | Modify | Define + wire the AGM-backed write functions onto `user_mgmt.PersistentUserWriter`; set the global AGM accessor; hydrate `g_custom_roles` and `GraphRBACPolicy` grants from the graph at startup |
| `src/server/main.zig` | Modify (maybe) | If wiring `setPersistentUserWriter` next to `setPersistentUserResolver` here is cleaner, do it here — implementer's call |
| `tests/test_auth_persistence.zig` | **Create** | Unit tests: `PersistentUserWriter` invocation; `GraphRBACPolicy` grant round-trip; `setUserActive` |
| `../geode-test-harness/geodetestlab-cli/specs/geode_auth_ddl_persistence.yml` | **Create** | **Restart-survival**: create user/role/grant → stop+restart geode (same data dir) → assert all survive and the grant is still enforced |
| `docs/GQL_AUTH_DDL.md`, `CLAUDE.md` | Modify | Remove the "not persistent" caveats; document the `GraphGrant` model + enforcement semantics |

---

### Task P1: `UserStorageBackend` — `GraphGrant` record + methods

**Files:** `src/storage/user_storage.zig`

- [ ] **Step 1:** Read `src/storage/user_storage.zig` end to end (~900 lines). Note: schema constants lines 47-53; `*Record` extern structs (`UserRecord` 81-137, `RoleRecord` 139-158, `PermissionRecord` 160-183); upsert helpers (`upsertUserNode`/`upsertRoleNode`/`createEntityNode` ~1050-1200); public write methods (`persistUser` ~452, `updateUser` ~470, `persistRole` ~786, `removeRole` ~804, `removeUser` ~646, `assignUserRole` ~587, `revokeUserRole` ~604, `persistPermission` ~826); and how `id`s are assigned to entities (monotonic counter? content hash?). Confirm `removeUser` deletes the `User` node + its `HAS_ROLE` edges. Find the existing list/scan reader used by hydration (something like `listUsers`/`listRoles` that enumerates nodes by label) — note its shape; you'll mirror it.
- [ ] **Step 2:** Add `pub const GRAPH_GRANT_LABEL = "GraphGrant";` next to the other label constants.
- [ ] **Step 3:** Add `GraphGrantRecord` extern struct (fixed-size buffers, same style as `RoleRecord`): `id: u64`, `user_id: u64`, `graph_name: [128]u8`, `graph_name_len: u16`, `action: u8` (reuse `PermissionRecord.action`'s encoding — check what it is and reuse; otherwise define `0=read, 1=write, 2=schema`), `granted_at: i64`, `granted_by: u64`. Add a node-mapping cache `graph_grant_nodes: std.AutoHashMap(u64, u64)` to `UserStorageBackend` alongside `user_nodes`/`role_nodes`; init it in the backend's init, deinit in deinit.
- [ ] **Step 4:** Add three methods, modeled on `persistRole`/`removeRole` + the list reader:
  - `pub fn persistGraphGrant(self: *Self, user_id: u64, graph_name: []const u8, action: u8) !u64` — derive a stable grant `id` (a hash of `user_id`/`graph_name`/`action`, or a monotonic id — match how `persistRole` gets its id; if `persistRole` takes the id from the caller, then `AuthGraphManager` will generate it — adjust signature so the caller passes the id, mirroring `persistRole`'s contract exactly). Upsert a `GraphGrant` node with the properties; return the id. Idempotent.
  - `pub fn revokeGraphGrant(self: *Self, user_id: u64, graph_name: []const u8, action: u8) !bool` — find the node for the triple; if found `store.deleteNode(...)` + remove from `graph_grant_nodes`; return whether removed.
  - `pub fn listGraphGrants(self: *Self, allocator: std.mem.Allocator) ![]GraphGrantRecord` — scan all `GraphGrant`-labeled nodes, return the records (caller frees). Mirror the existing list reader.
- [ ] **Step 5:** `zig build 2>&1 | tail -10` green; `zig build test 2>&1 | tail -15` no new failures (nothing calls these yet).
- [ ] **Step 6:** Commit: `git add src/storage/user_storage.zig && git commit -m "feat(security): add GraphGrant persistent record + UserStorageBackend grant methods"`

---

### Task P2: `AuthGraphManager` — write wrappers (HMAC-resealed) + global accessor

**Files:** `src/security/auth_graph_manager.zig`

- [ ] **Step 1:** Read the existing write methods (`createUser` ~709, `updateUserPassword` ~833, `assignUserRole` ~786, `revokeUserRole` ~800, `bootstrapDefaultAdmin` ~612, `sealChain` ~486, `upsertUserState` ~778, `verifyChain` ~351). Note the invariant: every mutating method takes `hmac_key: *const [32]u8`, mutates via `self.storage.*`, then `try self.sealChain(hmac_key)`; `self.hmac_key: [32]u8` holds the resolved key (set in `server_init` ~442). Note how `sealChain`/`verifyChain` enumerate the chained records (by which label list?).
- [ ] **Step 2:** Add a process-global accessor: `var g_instance: ?*Self = null; pub fn setGlobal(p: ?*Self) void { g_instance = p; } pub fn getGlobal() ?*Self { return g_instance; }`. (It's `null` in CLI/test contexts — all callers must handle that.)
- [ ] **Step 3:** Add these `pub fn`s, each delegating to `self.storage.*` then `try self.sealChain(hmac_key)` (and maintaining whatever id-tracking sets the existing methods maintain — mirror `createUser`/`assignUserRole`):
  - `removeUser(self, hmac_key, user_id: u64) !void` → `storage.removeUser(user_id)` + reseal.
  - `setUserActive(self, hmac_key, user_id: u64, active: bool) !u64` → `storage.updateUser(user_id, null, null, active, null, null)` then `storage.bumpUserAuthVersion(user_id)` (return new version) + reseal.
  - `createRole(self, hmac_key, name, description) !u64` → if `findRoleIdByName(name)` returns an id, return it (idempotent); else allocate a `role_id` the way `bootstrapDefaultAdmin` does for the admin role, `storage.persistRole(role_id, name, description, 0, 0, false)` + reseal, return `role_id`.
  - `removeRole(self, hmac_key, role_id: u64) !void` → `storage.removeRole(role_id)` + reseal.
  - `findRoleIdByName(self, name) !?u64` → scan `Role` nodes (reuse `storage.listRoles`-equivalent), return the id whose name matches case-insensitively.
  - `findUserIdByName(self, username) !?u64` → scan `User` nodes, return the id whose username matches.
  - `grantUserGraphPermission(self, hmac_key, user_id: u64, graph_name, action: u8) !void` → derive a grant id (consistent with P1's contract), `storage.persistGraphGrant(...)` + reseal.
  - `revokeUserGraphPermission(self, hmac_key, user_id: u64, graph_name, action: u8) !bool` → `storage.revokeGraphGrant(...)` + reseal; return whether removed.
  - `listGraphGrants(self, allocator) ![]…GraphGrantRecord` → `storage.listGraphGrants(allocator)` (no reseal). (Adjust the return-type spelling to the import path this file uses for `user_storage`.)
  - **HMAC chain:** if `sealChain`/`verifyChain` enumerate records by a fixed label list, add `GRAPH_GRANT_LABEL` to it so grant nodes are chained too. If they don't (e.g. chain only over User/Role) verify that adding `GraphGrant` nodes doesn't trip `verifyChain` (unexpected-label complaints); extend consistently if needed.
- [ ] **Step 4:** `zig build` green; `zig build test` no new failures.
- [ ] **Step 5:** Commit: `git add src/security/auth_graph_manager.zig && git commit -m "feat(security): AuthGraphManager write wrappers (user removal, active, roles, graph grants) + global accessor"`

---

### Task P3: `user_management.PersistentUserWriter` + `setUserActive`

**Files:** `src/security/user_management.zig`

- [ ] **Step 1:** Find `PersistentUserResolver`, `setPersistentUserResolver`, `persistentResolverEnabled`, the `persistent_resolver` global, and the locking convention they use. Mirror them.
- [ ] **Step 2:** Add:
  ```zig
  pub const PersistentUserWriter = struct {
      ctx: ?*anyopaque = null,
      create_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void = null,
      delete_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8) anyerror!void = null,
      update_password_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void = null,
      set_role_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, role: Role) anyerror!void = null,
      set_active_fn: ?*const fn (ctx: ?*anyopaque, username: []const u8, active: bool) anyerror!void = null,
  };
  var persistent_writer: ?PersistentUserWriter = null;
  pub fn setPersistentUserWriter(w: ?PersistentUserWriter) void { persistent_writer = w; }
  ```
- [ ] **Step 3:** Invoke the writer from each mutation *after* the in-memory mutation succeeds, best-effort (on writer error: `log.warn` + continue — don't fail the in-memory op; match how other best-effort persistence is handled here):
  - `createUser` (~356): after `store.putOrUpdate(user)`, call `create_fn(w.ctx, username, email, user.password_hash, role)`. Same in `createUserWithHash` (~393) (pass the supplied hash).
  - `deleteUser` (~474): after `store.remove(username)`, call `delete_fn(w.ctx, username)`.
  - `updateUserPassword` (~500): after replacing the hash, call `update_password_fn(w.ctx, username, user_ptr.user.password_hash)`.
  - `assignRole` (~528): after setting `user_ptr.user.role`, call `set_role_fn(w.ctx, username, role)`. Skip in the no-op (same-role) early return.
- [ ] **Step 4:** Add `pub fn setUserActive(allocator: std.mem.Allocator, username: []const u8, active: bool) !void` mirroring `updateUserPassword`'s structure: `ensureUserCached`, lock `user_store_mutex`, get `user_ptr`, `if (user_ptr.user.active == active) return;`, set `user_ptr.user.active = active`, `user_ptr.user.auth_version += 1`, then invoke `set_active_fn`. (`_ = allocator;` if unused, like `updateUserPassword`.)
- [ ] **Step 5:** `zig build` + `zig build test` — no regressions.
- [ ] **Step 6:** Commit: `git add src/security/user_management.zig && git commit -m "feat(security): add PersistentUserWriter write-through hooks + setUserActive"`

---

### Task P4: `auth_dispatch` write-throughs — enable/disable fix, role persistence, custom-role hydration hook

**Files:** `src/execution/auth_dispatch.zig`

- [ ] **Step 1:** Add `const auth_graph_manager = @import("../security/auth_graph_manager.zig");` (or the path this file uses for security modules).
- [ ] **Step 2:** `handleUserEnableDisable`: replace the no-op body — parse `username`, `const is_enable = std.mem.eql(u8, proc_name, "geode.auth.user_enable");`, then `user_mgmt.setUserActive(allocator, username, is_enable) catch |err| { ... return "error: {errname}" status row ... };`, then return the existing `"enabled {user}"` / `"disabled {user}"` two-column status row. (Persistence is automatic via `PersistentUserWriter.set_active_fn` once P7 wires it.)
- [ ] **Step 3:** `handleRoleCreate`: for the non-built-in branch, after `g_custom_roles.put(...)`, also `if (auth_graph_manager.getGlobal()) |agm| { _ = agm.createRole(&agm.hmac_key, role_name, desc) catch |e| log.warn("role_create persist failed", &.{Attr.string("error", @errorName(e))}); }`. (Built-in names still short-circuit with `"already exists … (built-in)"`, not persisted as custom — they're in the graph from bootstrap.)
- [ ] **Step 4:** `handleRoleDelete`: after `g_custom_roles.fetchRemove(role_name)`, also `if (auth_graph_manager.getGlobal()) |agm| { if (agm.findRoleIdByName(role_name) catch null) |rid| { agm.removeRole(&agm.hmac_key, rid) catch |e| log.warn(...); } }`.
- [ ] **Step 5:** Add `pub fn hydrateCustomRolesFromGraph(allocator: std.mem.Allocator) void` — if `getGlobal()` returns an AGM, enumerate `Role` nodes (via the AGM/storage list reader), and for each whose name is NOT `isBuiltinRoleName`, `g_custom_roles.put(dupe(name), dupe(description))`. Call `ensureRolesInit(allocator)` first; make it idempotent. (Called from `server_init` in P7.)
- [ ] **Step 6:** `zig build` + `zig build test` — no regressions.
- [ ] **Step 7:** Commit: `git add src/execution/auth_dispatch.zig && git commit -m "feat(auth): persist roles, fix enable/disable, add custom-role hydration hook"`

---

### Task P5: Persistent per-graph grants — `GraphRBACPolicy` grant set + `handleGrantRevoke`

**Files:** `src/security/multi_graph_security.zig`, `src/execution/auth_dispatch.zig`

- [ ] **Step 1:** Read `GraphRBACPolicy` (~84-280) — note `graph_user_roles`, `hasPermission(uid, graph, resource, action)`, the `getGlobal*`/`setGlobal*` singleton pattern used in `quic_connection_handler.zig:2928`, the `action` enum (`.read`/`.write`/`.schema`), and the resource-string convention (`"graph"`). Note the locking it uses for mutations.
- [ ] **Step 2:** Add a grant set distinct from `graph_user_roles` — `graph_user_grants: std.AutoHashMap(GraphGrantKey, void)` with `GraphGrantKey = struct { user_id: u64, graph_name_hash: u64, action: u8 }` (hash the graph name like other keyed maps here, or store owned strings — match the file's convention). Add (under the same lock as `graph_user_roles`):
  - `pub fn grantGraphPermission(self: *Self, user_id: u64, graph_name: []const u8, action: u8) !void`
  - `pub fn revokeGraphPermission(self: *Self, user_id: u64, graph_name: []const u8, action: u8) bool`
  - `pub fn hasGraphGrant(self: *Self, user_id: u64, graph_name: []const u8, action: u8) bool`
  - `pub fn loadGraphGrants(self: *Self, records: anytype) !void` — bulk-load (`records` is `[]const user_storage.GraphGrantRecord`; spell the type concretely if `anytype` is awkward). Clear-then-fill or additive (startup runs once; additive is fine).
- [ ] **Step 3:** Rewrite `handleGrantRevoke` in `auth_dispatch.zig` (currently formats `"Granted {perm} on {resource} to {target}"` and does nothing). New behavior:
  - Parse `perm` (`READ`/`WRITE`/`SCHEMA`/`ALL`), `target` (username), `resource` (graph name; may be empty).
  - If `resource == ""`: keep the old string-only status row but make it explicit: `"note: per-graph grant requires ON GRAPH; global privilege grants are governed by the user's role"` (do NOT pretend it persisted). Return.
  - Map `perm` → action code(s): `READ`→{0}, `WRITE`→{1}, `SCHEMA`→{2}, `ALL`→{0,1,2}.
  - Resolve `target` → `user_id`: `auth_graph_manager.getGlobal()` then `agm.findUserIdByName(target)`. If no AGM (CLI/test) or user not found in the graph → return a status row noting that (`"error: user not found"` or `"note: persistence unavailable in this context"`); still update the in-memory global RBAC if one exists.
  - For grant: for each action, `agm.grantUserGraphPermission(&agm.hmac_key, uid, resource, action)` AND `multi_graph_security.getGlobalRBAC().?.grantGraphPermission(uid, resource, action)`. For revoke: the `revoke*` counterparts.
  - Return a status row matching the wording the existing `geode_auth_ddl.yml` spec asserts (`"Granted READ on {graph} to {user}"` contains `Granted` + `READ`; `"Revoked READ …"` contains `Revoked` + `READ`).
- [ ] **Step 4:** Confirm `executeGrant` in `admin_ddl.zig` still routes `GrantSubject.role` → `geode.auth.user_assign_role` (which now persists via the `PersistentUserWriter.set_role_fn` after P7). No change there.
- [ ] **Step 5:** `zig build` + `zig build test` — no regressions.
- [ ] **Step 6:** Commit: `git add src/security/multi_graph_security.zig src/security/auth_graph_manager.zig src/execution/auth_dispatch.zig && git commit -m "feat(auth): persistent per-graph privilege grants (GraphRBACPolicy grant set + GRANT/REVOKE write-through)"`

---

### Task P6: Enforce per-graph grants (BIND-time + `checkPermission` fallback)

**Files:** `src/server/quic_connection_handler.zig`, `src/execution.zig`

- [ ] **Step 1:** `quic_connection_handler.zig` ~2920-2944 (BIND-time per-graph check). Today: if `graph_user_roles` has an explicit `(uid, graph)` entry lacking read → deny; else allow per global role. Extend the *allow* side only: also permit the bind if `rbac.hasGraphGrant(uid, graph, 0 /*read*/)` even when the prior logic would deny. Add a debug log when a grant is what permitted the bind. Do not add any new deny conditions.
- [ ] **Step 2:** `execution.zig` `checkPermission(context, permission)` (~790-807): currently `if (!user_mgmt.hasPermission(context.role.?, permission)) return error.Unauthorized;`. Change so that on global-role denial, before returning the error: resolve the bound graph name (`context.session_state.graph` or whatever field carries it — `grep -n "session_state\|graph" src/execution.zig` near `ExecutionContext`), and if `context.user != null` and a bound graph exists and `multi_graph_security.getGlobalRBAC()` returns a policy and `policy.hasGraphGrant(<user_id for context.user>, bound_graph, actionFor(permission))` → return (allow). Else `return error.Unauthorized`. **Widening-only** — only reached when the global check already failed, so existing behavior is unchanged. User-id resolution: if `ExecutionContext` carries a numeric user id or it can be cheaply fetched (this path is rare), use it; if not, it's acceptable to key the grant-check by username instead (have `GraphRBACPolicy` also accept a username-keyed lookup) — implementer's call based on what the context actually has. Add a CANARY here (see P9).
- [ ] **Step 3:** `zig build` green. Smoke: `timeout 3 ./zig-out/bin/geode --help >/dev/null 2>&1; echo $?` (0 or 124). `zig build test 2>&1 | tail -20` — no new failures.
- [ ] **Step 4:** Commit: `git add src/server/quic_connection_handler.zig src/execution.zig && git commit -m "feat(auth): enforce per-graph grants at BIND and as a checkPermission widening fallback"`

---

### Task P7: Startup wiring — install the writer, set the global AGM, hydrate

**Files:** `src/server/server_init.zig` (and/or `src/server/main.zig`)

- [ ] **Step 1:** Near where `graphPersistUserCreate`/`graphPersistPassword`/`graphPersistRoleMembership` are defined (~618-670 in `server_init.zig`), add the `user_mgmt.PersistentUserWriter` callbacks (ctx is `?*AuthGraphManager`; use `&agm.hmac_key`):
  - `writerCreateUser(ctx, username, email, password_hash, role)` → resolve admin↔`is_superuser`, `agm.createUser(&agm.hmac_key, username, email, password_hash, is_superuser)`; if `role` is non-admin, ensure the matching `Role` node exists (`agm.createRole` is idempotent) and `agm.assignUserRole` the edge — keep this consistent with how `bootstrapDefaultAdmin` represents the admin user's role. (Check `UserRecord` — if the effective role lives as a node property rather than a `HAS_ROLE` edge, set that instead/also.)
  - `writerDeleteUser(ctx, username)` → `agm.findUserIdByName(username)` then `agm.removeUser(&agm.hmac_key, uid)`.
  - `writerUpdatePassword(ctx, username, new_hash)` → `agm.findUserIdByName(username)` then `agm.updateUserPassword(&agm.hmac_key, uid, new_hash)`.
  - `writerSetRole(ctx, username, role)` → `agm.findUserIdByName(username)`; ensure the `Role` node for `role.toString()` exists; `agm.assignUserRole(&agm.hmac_key, uid, rid)` (revoke prior role edges first if the model is single-role); also update the role on the `User` node if that's where the effective role lives.
  - `writerSetActive(ctx, username, active)` → `agm.findUserIdByName(username)` then `agm.setUserActive(&agm.hmac_key, uid, active)`.
  Install: `user_mgmt.setPersistentUserWriter(.{ .ctx = @ptrCast(agm), .create_fn = &writerCreateUser, .delete_fn = &writerDeleteUser, .update_password_fn = &writerUpdatePassword, .set_role_fn = &writerSetRole, .set_active_fn = &writerSetActive });` — do this in the same place/condition the read resolver is installed (server only). (`findUserIdByName` must exist on `AuthGraphManager` — added in P2; if you find it's missing, add it here and note it.)
- [ ] **Step 2:** Where the AGM reaches its final memory location (after `fixupSelfPointers`, alongside `startPeriodicVerification` ~120), call `auth_graph_manager.setGlobal(agm)`.
- [ ] **Step 3:** After the AGM is verified/bootstrapped and before accepting connections: ensure the global `GraphRBACPolicy` is initialized; then `auth_dispatch.hydrateCustomRolesFromGraph(allocator)` and `{ const grants = try agm.listGraphGrants(allocator); defer allocator.free(grants); try multi_graph_security.getGlobalRBAC().?.loadGraphGrants(grants); }`. Wrap in best-effort logging — a hydration failure should warn, not crash startup.
- [ ] **Step 4:** `zig build` green. Smoke: `timeout 4 ./zig-out/bin/geode serve --listen 127.0.0.1:13199 >/tmp/p7boot.log 2>&1; echo "exit=$?"; tail -25 /tmp/p7boot.log` — clean start, no panic, no HMAC-chain error. `zig build test 2>&1 | tail -20` — no new failures.
- [ ] **Step 5:** Commit: `git add src/server/server_init.zig src/server/main.zig src/security/auth_graph_manager.zig && git commit -m "feat(server): wire PersistentUserWriter→AuthGraphManager; set global AGM; hydrate roles + graph grants on startup"`

---

### Task P8: Tests — unit + restart-survival geodetestlab spec

**Files:** `tests/test_auth_persistence.zig` (geode); `../geode-test-harness/geodetestlab-cli/specs/geode_auth_ddl_persistence.yml`

- [ ] **Step 1:** `tests/test_auth_persistence.zig` (model after `tests/test_user_management.zig` for state reset; register via a `test-auth-persistence` step in `build.zig` + `shardDep`, like `test-auth-ddl-parser`). Cover what's testable without a server:
  - Install a fake `PersistentUserWriter` (struct with counters + last-args) via `user_mgmt.setPersistentUserWriter`; call `user_mgmt.createUser`/`deleteUser`/`updateUserPassword`/`assignRole`/`setUserActive`; assert each fired the right callback with the right args; then `user_mgmt.setPersistentUserWriter(null)` to clean up.
  - `user_mgmt.setUserActive`: flips `active`, bumps `auth_version`, no-op on same value.
  - `GraphRBACPolicy.grantGraphPermission`/`hasGraphGrant`/`revokeGraphPermission` round-trip (construct a policy directly; assert grant absent → present after grant → absent after revoke; different action not granted).
  - If `UserStorageBackend` is easy to stand up against an in-memory `GraphStore` in a test, add `persistGraphGrant` → `listGraphGrants` round-trip; otherwise leave that to the geodetestlab spec.
- [ ] **Step 2:** `zig build test-auth-persistence 2>&1 | tail -5; echo $?` — exit 0.
- [ ] **Step 3:** `../geode-test-harness/geodetestlab-cli/specs/geode_auth_ddl_persistence.yml`. First determine the harness's restart mechanism: `grep -rln "restart\|cleanup: false\|data_dir:" ../geode-test-harness/geodetestlab-cli/specs/` and read the closest example + `../geode-test-harness/CLAUDE.md`. The `cli.server` block has `data_dir:` and `cleanup:` — a persistence test needs a *fixed* `data_dir` and `cleanup: false`; if the harness supports a `restart:` step or multiple server `phases`, use it; if not, write it as two specs (`..._phase1.yml` with `cleanup: false` + fixed `data_dir` that writes state; `..._phase2.yml` with the same `data_dir` that only reads/asserts) and document the run order, OR drive it from a shell test in the harness. The non-negotiable: prove that a created user/role/grant is visible after a real process restart against the same data dir. Sequence:
  - Phase 1 (fresh data dir): `CREATE GRAPH persgraph` (or use `default`); `CREATE USER perstest SET PASSWORD 'Persist3d!1' ROLE readwrite`; `CREATE ROLE perstrole SET DESCRIPTION 'survives restart'`; `CREATE USER persgrantee SET PASSWORD 'Persist3d!2' ROLE user`; `GRANT READ ON GRAPH persgraph TO persgrantee`; `ALTER USER perstest DISABLE`.
  - **Restart geode, same data dir.**
  - Phase 2: `SHOW USERS` → contains `perstest`, `persgrantee`; `SHOW ROLES` → contains `perstrole`; `SHOW PERMISSIONS FOR perstest` → readwrite perms; assert `perstest` is still disabled (via `SHOW USERS` output if it surfaces the active flag, or by attempting auth as `perstest` and expecting failure — pick what the harness can express); connect *as `persgrantee`* and bind to `persgraph` → succeeds (per-graph READ grant survived); `REVOKE READ ON GRAPH persgraph FROM persgrantee` → restart → reconnect as `persgrantee`, bind `persgraph` → denied **iff** the grant was actually load-bearing for that bind (if every user can bind every graph by default, this assertion is weak — then at least assert the grant appears in some introspection and the revoke status, and add a `# NOTE: enforcement coverage` comment). Cleanup (`DROP USER`, `DROP ROLE`, `DROP GRAPH`).
- [ ] **Step 4:** Run: `cd ../geode-test-harness && timeout 600 make test-spec SPEC=geodetestlab-cli/specs/geode_auth_ddl_persistence.yml GEODE_BINARY=/data/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode 2>&1 | tail -40`. Also re-run `geode_auth_ddl.yml` — no regression. Expectation mismatches → fix the spec to match real handler output (not the other way). A *real* failure (user/role/grant gone after restart, or HMAC chain verify error on restart) is a bug in P1-P7 — report it, don't paper over.
- [ ] **Step 5:** Commit (geode): `git add tests/test_auth_persistence.zig build.zig && git commit -m "test(auth): unit + restart-survival tests for auth DDL persistence"`. Commit (harness, current branch): `git add geodetestlab-cli/specs/geode_auth_ddl_persistence*.yml && git commit -m "test: restart-survival spec for auth DDL persistence"`.

---

### Task P9: Docs + CANARY

**Files:** `docs/GQL_AUTH_DDL.md`, `CLAUDE.md`, CANARY markers

- [ ] **Step 1:** `docs/GQL_AUTH_DDL.md`: remove the "Privilege grants not yet persistent" limitation; add a **Persistence** section — users, roles, password/role/active changes, and per-graph `GRANT … ON GRAPH … TO …` are persisted to the HMAC-chained `__geode_security` graph and survive restart (hydrated at startup). Document the per-graph grant model: `GRANT <action> ON GRAPH g TO u` records a `(u, g, action)` grant; grants are *additive* over the global role (widen, never restrict); enforced at BIND (a READ grant lets `u` access graph `g`) and at query time (a `checkPermission` fallback — a WRITE/SCHEMA grant lets `u` do that op on `g` even if their global role wouldn't). Residual limitations: a `GRANT <privilege>` *without* `ON GRAPH` is not persisted (global role governs that); custom-role *membership* is still only the built-in role field, not arbitrary role edges; RLS policy (`CREATE POLICY`) persistence is still TODO.
- [ ] **Step 2:** `CLAUDE.md`: update the "Privilege grants not yet persistent" Known-Limitations bullet to the new state; add to the auth-DDL feature entry: "all auth DDL writes persist to the HMAC-chained `__geode_security` graph and survive restart." Bump the date footer if present.
- [ ] **Step 3:** CANARY markers (match each file's format): `user_storage.zig` near `GraphGrantRecord`/`persistGraphGrant` — `REQ=REQ-AUTH-GRANT-PERSIST-001; ASPECT=Storage; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml`; `user_management.zig` near `PersistentUserWriter` — `...-002; ASPECT=WriteThrough; TEST=tests/test_auth_persistence.zig`; `execution.zig` near the `checkPermission` fallback — `...-003; ASPECT=Enforcement; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml`. Run `make status-generate` if it exists; include the regenerated status file in the commit.
- [ ] **Step 4:** `zig build && zig build test-auth-ddl-parser && zig build test-auth-persistence` — all exit 0.
- [ ] **Step 5:** Commit: `git add docs/GQL_AUTH_DDL.md CLAUDE.md src/storage/user_storage.zig src/security/user_management.zig src/execution.zig docs/status.csv && git commit -m "docs(auth): document auth DDL persistence + per-graph grant model; add CANARY markers"`.

---

## Self-Review

- **Spec coverage** — user asked to "ensure these are all properly persisted to the data files in the proper security graph as well" + chose "Also build persistent privilege grants". P1-P3: users + password/role/active changes write through to `__geode_security` via `PersistentUserWriter`→AGM. P4: custom roles persisted; the no-op `ALTER USER ENABLE/DISABLE` is fixed. P5-P6: persistent per-graph grants + enforcement (BIND + `checkPermission` widening). P7: startup wiring + hydration. P8: restart-survival proof. P9: docs. The one explicit residual (no model for a `GRANT <privilege>` without `ON GRAPH`) is documented, not silently dropped.
- **Risk** — all enforcement changes are *widening-only* (a grant can only add access), so existing authz is preserved; the QUIC hot path is untouched (only the existing BIND-time check is extended); persistence-write failures are best-effort + logged, never failing the in-memory op; HMAC chain stays consistent because every AGM write wrapper calls `sealChain` and `GraphGrant` nodes are added to the chained-record set (P2).
- **Type/name consistency** — `PersistentUserWriter` (P3) ↔ P7 install; `setUserActive` (P3) ↔ P4 `handleUserEnableDisable`; `GraphGrantRecord`/`persistGraphGrant`/`listGraphGrants` (P1) ↔ P2 AGM wrappers ↔ P7 hydration ↔ P8 tests; `auth_graph_manager.{setGlobal,getGlobal,findRoleIdByName,findUserIdByName,createRole,removeRole,removeUser,setUserActive,grantUserGraphPermission,revokeUserGraphPermission,listGraphGrants}` (P2) ↔ P4/P5/P7; `GraphRBACPolicy.{grantGraphPermission,revokeGraphPermission,hasGraphGrant,loadGraphGrants}` (P5) ↔ P5/P6/P7. Open implementation choices flagged inline (role-as-edge vs role-as-property on the `User` node — check `UserRecord` + `bootstrapDefaultAdmin`; user_id resolution in `checkPermission`; grant-id derivation matching `persistRole`'s contract; harness restart mechanism).

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-12-auth-ddl-persistence.md`. Execute via **superpowers:subagent-driven-development**: fresh subagent per task P1→P9, verify each before the next. Commit directly onto `main`.
