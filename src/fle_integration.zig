const std = @import("std");
const build_options = @import("build_options");
const fle_catalog = @import("schema/fle_catalog.zig");
const fle_annotations = @import("schema/annotations.zig");
const fle_aead = @import("fle_aead");
const key_manager_mod = @import("fle_key_manager");
const master_key_check = @import("keys/master_key_check.zig");
const key_types = @import("fle_key_types");
const blind_index_mod = @import("fle_blind_index");

// Field-Level Encryption Integration Layer
// CANARY: REQ=REQ-FLE-INTEGRATION-001; FEATURE="FieldLevelEncryption"; ASPECT=INTEGRATION; STATUS=TESTED; TEST=test-gap0852; OWNER=security; UPDATED=2026-11-12

// Re-export modules for external access
pub const catalog_mod = fle_catalog;
pub const fle_aead_mod = fle_aead;

/// Integration layer for field-level encryption
/// This module provides high-level encryption/decryption operations
/// that integrate with the schema catalog, key manager, and blind index

// Global singletons for key management and blind index
//
// SONNY-2656: both live for the process, so they are created on
// `singleton_allocator`, never on the allocator of the call that happens to
// create them. That call can be a WHERE evaluating on a per-node scratch arena
// (node_scan_stream.zig `predicateAllocator`), or any other request-scoped
// arena; a singleton created there would be freed by the arena's reset and
// left dangling. The schema catalog (schema/fle_catalog.zig) does the same.
pub const singleton_allocator = std.heap.smp_allocator;
var global_key_manager_instance: ?*key_manager_mod.KeyManager = null;
var global_blind_index_instance: ?*blind_index_mod.BlindIndex = null;
var global_mutex: std.Io.Mutex = std.Io.Mutex.init;

// GAP-0203: Global flag to fast-path skip FLE when no encryption is configured
// CANARY: REQ=REQ-PERF-FLE-SKIP-001; FEATURE="FLESkipOptimization"; ASPECT=GlobalDisable; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
// SONNY-6327: atomics (they were plain bools read without the mutex), and
// the catalog's own lock-free `globalHasFields` is consulted first, so a
// field configured by any path (not only `CALL geode.fle.configureField`,
// which sets this flag) is seen.
var fle_has_encrypted_fields: std.atomic.Value(bool) = .init(false);
var fle_catalog_state_checked: std.atomic.Value(bool) = .init(false);

/// Check if FLE has any encrypted fields configured. Returns false when no encryption is active,
/// allowing callers to skip all FLE processing for non-encrypted deployments.
/// Lock-free once the catalog has been loaded.
pub fn hasEncryptedFields() bool {
    if (fle_has_encrypted_fields.load(.acquire)) return true;
    if (fle_catalog.globalHasFields()) return true;
    if (!fle_catalog_state_checked.load(.acquire)) {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (!fle_has_encrypted_fields.load(.acquire) and !fle_catalog_state_checked.load(.acquire)) {
            // CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=UnknownMeansEncrypted; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-6324: a catalog that cannot be loaded means "which fields
            // are encrypted is unknown", not "none are": answer true (and
            // remember nothing), so callers take the FLE path, which asks
            // the catalog and refuses. It answered false and cached it, so
            // every write skipped FLE and went to disk in plaintext.
            const catalog = fle_catalog.globalCatalog(std.heap.c_allocator) catch {
                return true;
            };
            fle_has_encrypted_fields.store(catalog.count() > 0, .release);
            fle_catalog_state_checked.store(true, .release);
        }
    }
    return fle_has_encrypted_fields.load(.acquire) or fle_catalog.globalHasFields();
}

/// Mark that encrypted fields exist (called when encryption is configured)
pub fn setHasEncryptedFields(has_fields: bool) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    fle_has_encrypted_fields.store(has_fields, .release);
    fle_catalog_state_checked.store(has_fields, .release);
}

// GAP-0285/S3: Per-thread user role map replaces process-global variable.
// Previous implementation used a single `global_current_user_role` variable
// protected by a mutex, which caused TOCTOU race conditions: concurrent
// connections would overwrite each other's role, enabling cross-tenant FLE
// decryption (CVSS 8.5). Now keyed by thread ID so each connection handler
// thread maintains its own independent role state.
//
// GAP-0844 (deferred secondary): binding tenant/role to the request/execution
// context (`execution.ExecutionContext`) instead of the OS thread would make
// FLE isolation survive a future async / work-stealing executor that moves a
// request across threads mid-flight. We DEFER that here, deliberately, because:
//   (1) Under the current synchronous one-thread-per-connection executor this
//       per-thread model is correct — it is fragility, not a live bug.
//   (2) `execution.g_active_context` (the obvious place to read role/tenant
//       from) is ITSELF a `threadlocal` (execution.zig:521), so merely moving
//       the FLE role/tenant onto it would add churn WITHOUT removing the
//       OS-thread coupling. The fragility only truly disappears when the
//       executor stops being one-thread-per-connection AND the context is
//       passed explicitly (not via a threadlocal) into every FLE consumer
//       (~12 getCurrentUserRole/getCurrentTenantId call sites across
//       graph_store.zig, value_utilities.zig, fle_hooks.zig, rewrite.zig) and
//       the request boundaries in quic_connection_handler.zig / grpc_server.zig
//       set an `fle_user_role: ?[]const u8` on the context. That is a
//       cross-cutting execution-model refactor, out of scope for this gap.
// The PRIMARY GAP-0844 fix (removing the GEODE_CURRENT_ROLE process-global env
// override from getCurrentUserRole) IS applied — see that function below.
// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-001; FEATURE="FLERoleIsolation"; ASPECT=PerThreadRole; STATUS=TESTED; OWNER=security; UPDATED=2026-06-08
var per_thread_roles: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(std.heap.c_allocator);

/// Set the current user role for RBAC checks (per-thread, safe for concurrent connections).
/// This should be called at the start of a session/transaction.
pub fn setCurrentUserRole(role: ?[]const u8) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    if (role) |r| {
        per_thread_roles.put(tid, r) catch {
            // On allocation failure, remove any stale entry (fail-secure: no role = deny)
            _ = per_thread_roles.remove(tid);
        };
    } else {
        _ = per_thread_roles.remove(tid);
    }
}

// GAP-0281: Per-thread tenant_id map for FLE encryption namespace isolation.
// Same pattern as per_thread_roles (GAP-0285/S3): keyed by thread ID so each
// connection handler thread maintains its own tenant_id state.
// CANARY: REQ=REQ-MULTI-TENANT-FLE-002; FEATURE="FLE Multi-Tenancy"; ASPECT=PerThreadTenant; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
var per_thread_tenants: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(std.heap.c_allocator);

/// Set the current tenant_id for FLE encryption namespace (per-thread, safe for concurrent connections).
/// Should be called at the start of query execution when session has a tenant_id.
pub fn setCurrentTenantId(tenant_id: ?[]const u8) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    if (tenant_id) |t| {
        per_thread_tenants.put(tid, t) catch {
            _ = per_thread_tenants.remove(tid);
        };
    } else {
        _ = per_thread_tenants.remove(tid);
    }
}

/// Get the current tenant_id for FLE operations.
/// Returns the per-thread tenant_id if set, otherwise "default".
pub fn getCurrentTenantId() []const u8 {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_tenants.get(std.Thread.getCurrentId()) orelse "default";
}

/// Get the current user role for FLE RBAC checks.
///
/// GAP-0844: the per-thread role map is the SINGLE source of truth. The old
/// implementation read the process-global env var `GEODE_CURRENT_ROLE` BEFORE
/// the per-thread map, which let one process-wide env var silently override the
/// authenticated role of EVERY connection in a shared multi-tenant process —
/// a cross-tenant FLE isolation hole that bypassed the per-thread isolation
/// GAP-0285 established. The env var was only ever a crutch for the old
/// subprocess-spawning CLI test path (eliminated by the unified-binary
/// architecture); tests that need to set a role out-of-band use the per-thread
/// `setCurrentUserRole` setter directly. The override is removed entirely.
pub fn getCurrentUserRole() ?[]const u8 {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_roles.get(std.Thread.getCurrentId());
}

/// GAP-0844 (secondary): context-preferring FLE role reader.
///
/// Prefers the request-scoped `ctx.fle_role` (set at the request boundary
/// alongside `setCurrentUserRole`), falling back to the per-thread map via
/// `getCurrentUserRole()` when the context carries no role. This makes the
/// EXECUTION CONTEXT — not the OS thread — authoritative wherever a context is
/// threaded, so FLE role isolation survives a future async / work-stealing
/// executor that moves a request across threads mid-flight.
///
/// `ctx` is `anytype` (rather than the concrete `execution.ExecutionContext`)
/// purely to avoid a fle_integration ↔ execution import cycle; the only field it
/// reads is `fle_role`. `getCurrentUserRole()` (the per-thread reader) is left
/// untouched so the ~12 existing per-thread call sites keep their behavior.
pub fn getCurrentUserRoleCtx(ctx: anytype) ?[]const u8 {
    const T = @TypeOf(ctx);
    if (comptime @typeInfo(T) == .pointer) {
        if (comptime @hasField(@typeInfo(T).pointer.child, "fle_role")) {
            if (ctx.fle_role) |r| return r;
        }
    } else if (comptime @hasField(T, "fle_role")) {
        if (ctx.fle_role) |r| return r;
    }
    return getCurrentUserRole();
}

/// GAP-0852: context-preferring FLE tenant reader (analog of `getCurrentUserRoleCtx`).
///
/// Prefers the request-scoped `ctx.tenant_id` (set at the request boundary
/// alongside `setCurrentTenantId`) over the per-thread tenant map. This makes
/// the EXECUTION CONTEXT — not the OS thread — authoritative for the FLE
/// encryption namespace wherever a context is threaded, so tenant isolation
/// survives a future async / work-stealing executor that moves a request across
/// threads mid-flight.
///
/// SECURITY (GAP-0852): when a context is present and carries a non-null
/// `tenant_id`, that tenant is used verbatim — the value NEVER silently
/// collapses to the `"default"` namespace. Only a genuinely contextless caller
/// (no context, or a context whose `tenant_id` is null) falls through to the
/// per-thread map (and its documented `"default"` fallback) — that path serves
/// internal/startup callers that legitimately have no tenant. Mixing a wrong
/// tenant into the AAD/key-id namespace causes decryption to fail closed, so a
/// stale per-thread tenant can never expose another tenant's plaintext.
///
/// `ctx` is `anytype` (rather than the concrete `execution.ExecutionContext`)
/// purely to avoid a fle_integration ↔ execution import cycle; the only field it
/// reads is `tenant_id`. `getCurrentTenantId()` (the per-thread reader) is left
/// untouched so the legacy per-thread call sites keep their behavior.
/// CANARY: REQ=REQ-MULTI-TENANT-FLE-003; FEATURE="FLE Multi-Tenancy"; ASPECT=ContextTenant; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn getCurrentTenantIdCtx(ctx: anytype) []const u8 {
    const T = @TypeOf(ctx);
    if (comptime @typeInfo(T) == .pointer) {
        if (comptime @hasField(@typeInfo(T).pointer.child, "tenant_id")) {
            if (ctx.tenant_id) |t| return t;
        }
    } else if (comptime @hasField(T, "tenant_id")) {
        if (ctx.tenant_id) |t| return t;
    }
    return getCurrentTenantId();
}

/// GAP-0852 follow-up: single source of truth for "resolve the FLE role,
/// preferring the active ExecutionContext's request-scoped role over the
/// per-thread map." Previously this 5-line body was copy-pasted into
/// `src/execution/fle_hooks.zig`, `src/execution/value_utilities.zig`,
/// `src/graph_store.zig`, and `src/planner/rewrite.zig` (each with its own lazy
/// `@import("execution.zig")` to dodge the cycle). Consolidated here next to
/// `getCurrentUserRoleCtx` — `checkPropertyAccess` already proves the lazy
/// function-body import of execution works inside this module, so every migrated
/// site now calls this instead. Wherever a request context is pushed (the request
/// boundary), the context becomes authoritative; contextless internal/legacy
/// callers keep the per-thread behavior. Fail-secure: with neither a context role
/// nor a per-thread role, returns null so plaintext access is denied.
/// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-003; FEATURE="FLERoleIsolation"; ASPECT=ContextRole; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn rolePreferringActiveContext() ?[]const u8 {
    const exec_mod = @import("execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        return getCurrentUserRoleCtx(ctx_ptr);
    }
    return getCurrentUserRole();
}

/// GAP-0852 follow-up: single source of truth for "resolve the FLE tenant,
/// preferring the active ExecutionContext's request-scoped tenant over the
/// per-thread map" (analog of `rolePreferringActiveContext`). Consolidates the
/// `currentTenantIdPreferringContext` copies from `src/execution/fle_hooks.zig`
/// and `src/execution/value_utilities.zig`. When a context is present and carries
/// a tenant, that tenant is used verbatim; the per-thread map (and its documented
/// `"default"`) is reached ONLY for genuinely contextless internal callers
/// (startup hydration, legacy paths). Fail-secure: a wrong tenant in the
/// AAD/key-id namespace makes decryption fail rather than expose another tenant's
/// plaintext.
/// CANARY: REQ=REQ-MULTI-TENANT-FLE-004; FEATURE="FLE Multi-Tenancy"; ASPECT=ContextTenant; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn tenantPreferringActiveContext() []const u8 {
    const exec_mod = @import("execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        return getCurrentTenantIdCtx(ctx_ptr);
    }
    return getCurrentTenantId();
}

/// Clear all per-thread FLE state (tenant_id and role) for the current thread.
/// MUST be called in the connection handler's defer block to prevent stale
/// state from leaking into a subsequent connection that reuses the same thread.
/// GAP-0285: Prevents cross-tenant FLE decryption when threads are reused.
/// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-002; FEATURE="FLERoleIsolation"; ASPECT=ThreadCleanup; STATUS=TESTED; OWNER=security; UPDATED=2026-04-05
pub fn clearCurrentThreadState() void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    _ = per_thread_roles.remove(tid);
    _ = per_thread_tenants.remove(tid);
    _ = per_thread_plaintext_gates.remove(tid);
}

// CANARY: REQ=REQ-SONNY-6334-FLE-PLAINTEXT-GATE; FEATURE="FieldLevelEncryption"; ASPECT=GpsDecryptFieldGate; STATUS=TESTED; TEST=tests/test_sonny6334_fle_authorization.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6334: the GPS `decrypt_field` half of the plaintext decision. A
/// read of an encrypted field returns plaintext only when the request's FLE
/// role is in the field's visibility roles AND this gate allows (GPS
/// `decide(decrypt_field)` for the authenticated principal: the Admin
/// builtin, or an ALLOW DECRYPT_FIELD policy; a DENY DECRYPT_FIELD refuses).
/// It is asked once per encrypted value the role may read (the decision
/// cache answers repeats), never for fields that are not encrypted.
pub const PlaintextGate = struct {
    ctx: ?*const anyopaque,
    allows: *const fn (ctx: ?*const anyopaque) bool,
};

/// The request's gate on its thread, for reads made outside the executor's
/// active context (the transports encode result rows after the executor
/// returns). Set and cleared with the request's role and tenant
/// (`ServerState.installRequestThreadState`); `clearCurrentThreadState`
/// clears it.
var per_thread_plaintext_gates: std.AutoHashMap(std.Thread.Id, PlaintextGate) = std.AutoHashMap(std.Thread.Id, PlaintextGate).init(std.heap.c_allocator);

pub fn setCurrentPlaintextGate(gate: ?PlaintextGate) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    if (gate) |g| {
        // A gate that cannot be recorded: the thread's FLE role goes too,
        // so the request reads no plaintext (fail closed).
        per_thread_plaintext_gates.put(tid, g) catch {
            _ = per_thread_plaintext_gates.remove(tid);
            _ = per_thread_roles.remove(tid);
        };
    } else {
        _ = per_thread_plaintext_gates.remove(tid);
    }
}

fn currentThreadPlaintextGate() ?PlaintextGate {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_plaintext_gates.get(std.Thread.getCurrentId());
}

/// GPS `decide(decrypt_field)` for the active executor context's principal,
/// on the session's graph. Anything but allow (deny, unauthorized, an
/// error) refuses.
fn activeContextAllowsDecrypt(ctx_opaque: ?*const anyopaque) bool {
    const exec_mod = @import("execution.zig");
    const ctx: *const exec_mod.ExecutionContext = @ptrCast(@alignCast(ctx_opaque orelse return false));
    const princ = ctx.principal orelse return false;
    const graph = blk: {
        if (ctx.session_state) |sess| if (sess.graph) |g| break :blk g;
        break :blk "default";
    };
    return decryptAllowedFor(princ, graph);
}

/// GPS `decide(decrypt_field)` for a principal (`*const Principal`) on
/// `graph`. Installed by the executor (`execution.installDecryptDecider`,
/// on every statement and at server start): this module cannot name GPS
/// itself without pulling the security modules into every binary that
/// reads a stored string.
pub const DecryptDecider = *const fn (principal: *const anyopaque, graph: []const u8) bool;
var decrypt_decider: std.atomic.Value(?DecryptDecider) = .init(null);

pub fn setDecryptDecider(decider: DecryptDecider) void {
    decrypt_decider.store(decider, .release);
}

/// GPS `decide(decrypt_field)` for `principal` on `graph` (SONNY-6334).
/// Both the executor's gate and the transports' thread gate ask here. No
/// decider installed: refused (fail closed).
pub fn decryptAllowedFor(principal: *const anyopaque, graph: []const u8) bool {
    const decide = decrypt_decider.load(.acquire) orelse return false;
    return decide(principal, graph);
}

/// The plaintext gate for a read on this thread now. With authentication
/// off none: every caller is an implicit admin, as before. With it on: the
/// active executor context's principal; else the request's thread gate
/// (both transports install one with the request's FLE role). A caller
/// with neither is not a request (an in-process embedder, background
/// work): no gate, and the role list alone decides, as the old hook did;
/// such a caller has no FLE role unless it set one itself, and no role
/// reads no plaintext.
pub fn currentPlaintextGate() ?PlaintextGate {
    const user_mgmt = @import("security/user_management.zig");
    if (!user_mgmt.isAuthEnabled()) return null;
    const exec_mod = @import("execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        if (ctx_ptr.principal != null) return .{ .ctx = ctx_ptr, .allows = activeContextAllowsDecrypt };
    }
    return currentThreadPlaintextGate();
}

/// SONNY-6334: the FLE role a HELLO named, as both transports accept it:
/// non-empty, `[A-Za-z0-9_-]` only (GAP-0271); anything else is no role.
pub fn helloFleRole(requested: ?[]const u8) ?[]const u8 {
    const r = requested orelse return null;
    if (r.len == 0) return null;
    for (r) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return null;
    }
    return r;
}

pub const EncryptionContext = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    allocator: std.mem.Allocator,
    current_user_role: ?[]const u8 = null, // User's current role for RBAC checks
    /// SONNY-6334: the GPS decrypt_field gate (`currentPlaintextGate`);
    /// null: none (authentication off, or an internal caller).
    plaintext_gate: ?PlaintextGate = null,
};

// CANARY: REQ=REQ-SONNY-2670-FLE-SINGLETONS-PROCESS-ALLOCATOR; FEATURE="FieldLevelEncryption"; ASPECT=SingletonsOnProcessAllocator; STATUS=TESTED; TEST=tests/test_sonny2670_fle_singletons_process_allocator.zig; OWNER=security; UPDATED=2026-11-13
/// Get or create global key manager, on `singleton_allocator` (SONNY-2656,
/// SONNY-2670). `allocator` is used only for the duration of the call.
fn getGlobalKeyManager(allocator: std.mem.Allocator) !*key_manager_mod.KeyManager {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_key_manager_instance) |km| {
        return km;
    }

    // SONNY-6442: refuse a GEODE_MASTER_KEY other than the one this data
    // directory's encrypted fields were written with (as `geode serve` does
    // at startup), and record it where none is.
    if (try master_key_check.fleDataDir(allocator)) |dir| {
        defer allocator.free(dir);
        try master_key_check.verifyOrRecord(allocator, dir, .in_process);
    }
    const km = try key_manager_mod.initFromEnv(singleton_allocator);
    global_key_manager_instance = km;
    return km;
}

/// Get or create global blind index (SONNY-2670: on `singleton_allocator`).
fn getGlobalBlindIndex() !*blind_index_mod.BlindIndex {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_blind_index_instance) |bi| {
        return bi;
    }

    const bi = try singleton_allocator.create(blind_index_mod.BlindIndex);
    bi.* = blind_index_mod.BlindIndex.init(singleton_allocator);
    global_blind_index_instance = bi;
    return bi;
}

/// Tear down the process-global FLE key manager and blind index, freeing all
/// memory they own and clearing the singletons so the next access re-initializes
/// from the environment. Production never calls this (the singletons live for the
/// process lifetime); tests use it to start from no key state (the next use
/// reads GEODE_MASTER_KEY again). Safe to call when no
/// global has been created — it is a no-op in that case.
pub fn resetGlobalKeyStateForTesting() void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_key_manager_instance) |km| {
        km.deinit();
        global_key_manager_instance = null;
    }
    if (global_blind_index_instance) |bi| {
        const alloc = bi.allocator;
        bi.deinit();
        alloc.destroy(bi);
        global_blind_index_instance = null;
    }
}

// GAP-0083: Key rotation support
// CANARY: REQ=REQ-FLE-ROTATION-002; FEATURE="FLEKeyRotation"; ASPECT=KeyManagement; STATUS=TESTED; TEST=geodetestlab/specs/fle_rotation.yml; OWNER=security; UPDATED=2026-01-10

/// Get the current key version for a field
/// Returns 1 if no rotation has occurred, otherwise returns the current version
pub fn getCurrentKeyVersion(ctx: EncryptionContext, field_name: []const u8) !u16 {
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_path = try std.fmt.allocPrint(ctx.allocator, "{s}:{s}:{s}", .{
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
    });
    defer ctx.allocator.free(key_path);

    // Get version from key manager (defaults to 1 if not set)
    return key_manager_mod.currentKeyVersion(key_manager, key_path);
}

/// Rotate the FLE key for a field to a new version
/// New encryptions will use the new version; old versions remain readable
/// Returns the new key version
pub fn rotateFieldKey(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema_name: []const u8,
    field_name: []const u8,
) !u16 {
    const key_manager = try getGlobalKeyManager(allocator);
    return key_manager.rotateFEK(tenant_id, schema_name, field_name);
}

/// Re-encrypt a single field value from old version to current version
/// Used during key rotation migration
pub fn reEncryptField(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    encrypted_data: []const u8,
    record_id: []const u8,
) ![]const u8 {
    // Decrypt with old key version (embedded in envelope)
    const plaintext = try decryptFieldIfNeeded(ctx, type_name, field_name, encrypted_data, record_id, false);
    defer if (!std.mem.eql(u8, plaintext.ptr, encrypted_data.ptr)) {
        // Only free if we allocated new memory (decryption happened)
        ctx.allocator.free(plaintext);
    };

    // Re-encrypt with current version
    return encryptFieldIfNeeded(ctx, type_name, field_name, plaintext, record_id);
}

/// Get key rotation status for a field
pub const RotationStatus = struct {
    current_version: u16,
    records_at_current: u64,
    records_at_older: u64,
    fully_rotated: bool,
};

/// Check rotation status - in real implementation would scan encrypted data versions
pub fn getRotationStatus(
    ctx: EncryptionContext,
    field_name: []const u8,
) !RotationStatus {
    const current_version = try getCurrentKeyVersion(ctx, field_name);

    // In a real implementation, this would scan the storage to count
    // records at each key version. For now, return conservative estimate.
    return RotationStatus{
        .current_version = current_version,
        .records_at_current = 0, // Would be populated by storage scan
        .records_at_older = if (current_version > 1) 1 else 0, // Conservative
        .fully_rotated = current_version == 1, // Only true if never rotated
    };
}

// CANARY: REQ=REQ-SONNY-6347-FLE-INDEX-DDL-SERIALIZED; FEATURE="FieldLevelEncryption"; ASPECT=IndexDdlAndConfigureFieldSerialized; STATUS=TESTED; TEST=tests/test_sonny6347_fle_envelope_identity.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6347 item 3: CREATE INDEX and CREATE CONSTRAINT UNIQUE / NODE KEY
/// check that no field they cover is encrypted, then build and record their
/// catalog row; `geode.fle.configureField` checks that no index or such
/// constraint covers the field, then encrypts it. Nothing was held between
/// either check and its write, so a configureField could pass while an index
/// DDL was between its check and its row (and the other way round), leaving
/// an index over an encrypted field. An index DDL now reserves its fields
/// (`reserveIndexFields`, refused when one is encrypted) until its row is in
/// the catalog, and configureField checks the rows and the reservations and
/// configures the field with `index_ddl_mutex` held (`lockIndexDdl`).
///
/// Lock order: after any graph lock (index DDL runs under the graph's write
/// lock), before the schema catalog lock and the FLE catalog and key-state
/// mutexes, which are taken while it is held. No graph lock is ever taken
/// while it is held.
var index_ddl_mutex: std.Io.Mutex = std.Io.Mutex.init;
var index_ddl_reservations: std.ArrayList(IndexFieldReservation) = .empty;
var index_ddl_next_id: u64 = 1;

const IndexFieldReservation = struct {
    id: u64,
    type_name: []const u8,
    fields: []const []const u8,
};

/// A reservation `reserveIndexFields` made; `releaseIndexFields` ends it.
pub const IndexFieldsHold = struct { id: u64 };

/// SONNY-6347: reserve `type_name`'s `fields` for an index DDL, refused
/// (`IndexOnEncryptedField`, 0A000) when one is encrypted. The slices are
/// borrowed: they must outlive the reservation.
pub fn reserveIndexFields(type_name: []const u8, fields: []const []const u8) error{ IndexOnEncryptedField, OutOfMemory }!IndexFieldsHold {
    const io = std.Io.Threaded.global_single_threaded.io();
    index_ddl_mutex.lockUncancelable(io);
    defer index_ddl_mutex.unlock(io);
    for (fields) |field| {
        if (fieldRequiresEncryption(type_name, field)) return error.IndexOnEncryptedField;
    }
    const id = index_ddl_next_id;
    index_ddl_next_id += 1;
    try index_ddl_reservations.append(std.heap.smp_allocator, .{ .id = id, .type_name = type_name, .fields = fields });
    return .{ .id = id };
}

pub fn releaseIndexFields(hold: IndexFieldsHold) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    index_ddl_mutex.lockUncancelable(io);
    defer index_ddl_mutex.unlock(io);
    for (index_ddl_reservations.items, 0..) |r, i| {
        if (r.id != hold.id) continue;
        _ = index_ddl_reservations.swapRemove(i);
        return;
    }
}

/// SONNY-6347: held by configureField from its index check to its write.
pub fn lockIndexDdl() void {
    index_ddl_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
}

pub fn unlockIndexDdl() void {
    index_ddl_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

/// SONNY-6347: does an index DDL in flight cover `type_name`.`field_name`?
/// Call with `lockIndexDdl` held.
pub fn indexFieldReservedLocked(type_name: []const u8, field_name: []const u8) bool {
    for (index_ddl_reservations.items) |r| {
        if (!std.mem.eql(u8, r.type_name, type_name)) continue;
        for (r.fields) |f| {
            if (std.mem.eql(u8, f, field_name)) return true;
        }
    }
    return false;
}

/// SONNY-6362: is `field_name` FLE-encrypted in any type? A stored value is
/// encrypted under the first label of its node (or its edge type), so a
/// pattern naming another label, or none, can still meet one. Fail-secure:
/// true when the catalog cannot be read.
pub fn fieldEncryptedInAnyType(field_name: []const u8) bool {
    if (!hasEncryptedFields()) return false;
    const catalog = fle_catalog.globalCatalog(std.heap.c_allocator) catch return true;
    return catalog.isFieldEncryptedInAnyType(field_name);
}

/// Check if a field requires encryption according to the FLE catalog
/// This is used by fail-secure logic to determine if encryption failure should abort writes
/// CANARY: REQ=REQ-FLE-FAILSECURE-004; FEATURE="FLEFailSecure"; ASPECT=EncryptionCheck; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
pub fn fieldRequiresEncryption(type_name: []const u8, field_name: []const u8) bool {
    // Fast path - if no encrypted fields are configured globally, nothing requires encryption
    if (!hasEncryptedFields()) {
        return false;
    }

    // Use c_allocator for catalog lookup to avoid page_allocator usage in runtime paths.
    const allocator = std.heap.c_allocator;

    // Get global catalog - FAIL-SECURE: if we can't access catalog, assume encryption IS required
    // This prevents bypassing encryption by causing catalog errors
    const catalog = fle_catalog.globalCatalog(allocator) catch {
        std.log.warn("SECURITY: Cannot access FLE catalog - assuming field {s}.{s} requires encryption (fail-secure)", .{ type_name, field_name });
        return true; // FAIL-SECURE: Assume encryption required on catalog error
    };

    // SONNY-6327: answered under the catalog mutex (a type or field not in
    // the catalog is not configured for encryption).
    return catalog.isFieldEncrypted(type_name, field_name);
}

/// Encrypt a field value if encryption is enabled for this field
/// Returns the original value if encryption is not configured
pub fn encryptFieldIfNeeded(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    plaintext: []const u8,
    record_id: []const u8,
) ![]const u8 {
    // GAP-0203: Fast path - skip all FLE processing when no encryption is configured
    if (!hasEncryptedFields()) {
        return plaintext;
    }

    // 1. Get global catalog
    const catalog = try fle_catalog.globalCatalog(ctx.allocator);

    // 2-3. The field's policy, by value (SONNY-6327: it read the catalog's
    // type pointer after unlocking).
    const policy = catalog.fieldPolicy(type_name, field_name) orelse return plaintext;
    if (!policy.encrypted) {
        return plaintext;
    }

    // 4. Get FEK from key manager using current version
    // GAP-0083: Support key rotation - use getCurrentKeyVersion to get latest
    // CANARY: REQ=REQ-FLE-ROTATION-001; FEATURE="FLEKeyRotation"; ASPECT=Encryption; STATUS=TESTED; TEST=geodetestlab/specs/fle_rotation.yml; OWNER=security; UPDATED=2026-01-10
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const current_version = try getCurrentKeyVersion(ctx, field_name);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = current_version,
    };
    const fek = try key_manager.getFEK(key_ids);

    // 5. Construct AAD
    const aad = try fle_aead.makeAAD(
        ctx.allocator,
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
        record_id,
        key_ids.version,
    );
    defer ctx.allocator.free(aad);

    // 6. Encrypt using AEAD
    // FIPS fail-close: ChaCha20-Poly1305 is not an approved AEAD under FIPS 140-3.
    // AES-256-GCM is the only permitted path. Reject ChaCha selection at runtime.
    // CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncrypt; STATUS=IMPL; OWNER=security; UPDATED=2026-06-24
    if (build_options.fips and policy.algorithm == .chacha20_poly1305) {
        return error.FipsUnsupported;
    }
    const alg = switch (policy.algorithm) {
        .aes256_gcm => fle_aead.Alg.aes256_gcm,
        .chacha20_poly1305 => fle_aead.Alg.chacha20_poly1305,
    };

    var envelope = try fle_aead.encryptField(
        ctx.allocator,
        alg,
        &fek,
        aad,
        plaintext,
        key_ids.version,
    );
    defer envelope.deinit(ctx.allocator);

    // 7. If searchable, update blind index
    if (policy.searchable) {
        const blind_index = try getGlobalBlindIndex();
        const bik = try key_manager.getBIK(key_ids);

        try blind_index.put(
            ctx.schema_name,
            field_name,
            bik,
            plaintext,
            record_id,
        );
    }

    // 8. Serialize envelope to bytes and return
    const serialized = try envelope.serialize(ctx.allocator);
    return serialized;
}

/// Decrypt a field value if it's encrypted
/// Returns the original value if it's not an encrypted envelope
pub fn decryptFieldIfNeeded(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    data: []const u8,
    record_id: []const u8,
    check_rbac: bool,
) ![]const u8 {
    // GAP-0203: Fast path - skip all FLE processing when no encryption is configured
    // CANARY: REQ=REQ-PERF-FLE-SKIP-002; FEATURE="FLESkipOptimization"; ASPECT=DecryptFastPath; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
    if (!hasEncryptedFields()) {
        return data;
    }

    // 1. Get global catalog
    const catalog = try fle_catalog.globalCatalog(ctx.allocator);

    // 2. Check if field is encrypted, and (3) whether the role may read it,
    // in one decision under the catalog mutex (SONNY-6327).
    const decision = catalog.readDecision(type_name, field_name, ctx.current_user_role orelse getCurrentUserRole());
    if (!decision.encrypted) {
        return data;
    }

    // 3. If RBAC check required, verify access: the role list, then
    // (SONNY-6334) GPS decrypt_field. A GPS refusal reads as a role not in
    // the list: "[REDACTED]", or SearchNotPermitted for a searchable field.
    const plaintext_allowed = decision.plaintext_allowed and
        (if (ctx.plaintext_gate) |gate| gate.allows(gate.ctx) else true);
    if (check_rbac and !plaintext_allowed) {
        // If field is searchable, throw error (search operations require privilege)
        // If field is not searchable, return redacted placeholder (projection only)
        if (decision.searchable) {
            // fle v0.1.7 (98dd8af) dropped the never-raised SearchNotPermitted
            // from its aead.Error set; this is geode's own authz semantic
            // (see value_types / execution / eval EvalError.SearchNotPermitted).
            return error.SearchNotPermitted;
        }
        // Return redacted placeholder for non-searchable fields
        return try ctx.allocator.dupe(u8, "[REDACTED]");
    }

    // Check if data looks like an encrypted envelope (minimum size check)
    if (data.len < 35) {
        // Not an encrypted envelope, return as-is
        return data;
    }

    // 4. Try to parse envelope
    var envelope = fle_aead.EnvelopeV1.deserialize(ctx.allocator, data) catch |err| {
        // If deserialization fails, assume it's plaintext (not yet encrypted)
        if (err == fle_aead.Error.InvalidEnvelope) {
            return data;
        }
        return err;
    };
    defer envelope.deinit(ctx.allocator);

    // FIPS fail-close: reject decryption of ChaCha20-Poly1305 ciphertext under FIPS.
    // alg_id=2 corresponds to chacha20_poly1305 in the fle envelope format.
    // AES-256-GCM (alg_id=1) is the only approved AEAD path.
    // CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-002; FEATURE="FIPSFailClose"; ASPECT=FLEDecrypt; STATUS=IMPL; OWNER=security; UPDATED=2026-06-24
    if (build_options.fips and envelope.alg_id == @intFromEnum(fle_aead.Alg.chacha20_poly1305)) {
        return error.FipsUnsupported;
    }

    // 5. Get FEK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = envelope.key_version,
    };
    const fek = try key_manager.getFEK(key_ids);

    // 6. Construct AAD (must match encryption)
    const aad = try fle_aead.makeAAD(
        ctx.allocator,
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
        record_id,
        envelope.key_version,
    );
    defer ctx.allocator.free(aad);

    // 7. Decrypt
    const plaintext = try fle_aead.decryptField(
        ctx.allocator,
        &fek,
        aad,
        envelope,
    );

    // 8. Return plaintext
    return plaintext;
}

// SONNY-6348: lookupEncryptedField / matchesEncryptedField (blind-index
// equality lookups) were removed: no query path called them, and no field
// can be made searchable (geode.fle.configureField refuses `searchable`).

/// Helper to construct AAD (Additional Authenticated Data) for AEAD
fn makeAAD(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema_name: []const u8,
    field_name: []const u8,
    record_id: []const u8,
    version: u16,
) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}",
        .{ tenant_id, schema_name, field_name, record_id, version },
    );
}

/// Check RBAC permission to read plaintext for a field
/// SECURITY FIX: Fail-secure on catalog errors (deny access instead of grant)
/// CANARY: REQ=REQ-FLE-FAILSECURE-005; FEATURE="FLEFailSecure"; ASPECT=CatalogErrorDenyAccess; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
fn canReadPlaintext(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
) bool {
    // Get global catalog
    // SECURITY FIX: On catalog error, DENY access (fail-secure)
    // Previous behavior returned true, allowing access on catalog errors - INSECURE!
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch {
        std.log.warn("SECURITY: Cannot access FLE catalog for {s}.{s} - denying plaintext access (fail-secure)", .{ type_name, field_name });
        return false; // FAIL-SECURE: Deny access on catalog error
    };

    // SONNY-6327: decided under the catalog mutex (it walked the role list
    // after unlocking, and a grant, revoke or reconfigure frees that list).
    // A type/field not in the catalog is not FLE-protected (allowed); an
    // encrypted field with no visibility roles is locked to nobody; no role
    // reads nothing that lists roles.
    if (!catalog.canReadPlaintext(type_name, field_name, ctx.current_user_role orelse getCurrentUserRole())) return false;
    // SONNY-6334: and GPS decrypt_field.
    if (ctx.plaintext_gate) |gate| return gate.allows(gate.ctx);
    return true;
}

/// SONNY-6327: what a read of a stored string property can fail with.
/// `FleDecryptionFailed` (58030): the field is encrypted, the principal may
/// read it, and the stored bytes do not decrypt (damaged, written under
/// another key or record identity). The stored bytes are never presented
/// as the value.
pub const FleReadError = error{ SearchNotPermitted, FleCatalogUnavailable, FleDecryptionFailed, OutOfMemory };

/// Whose property a stored string is: the record identity in the AAD the
/// executor's FLE hooks encrypt with (`fle_hooks.encryptPropertyIfNeeded`:
/// "<id>", `encryptEdgePropertyIfNeeded`: "edge_<id>").
pub const EntityKind = enum { node, edge };

// CANARY: REQ=REQ-SONNY-6335-FLE-ONE-IDENTITY; FEATURE="FieldLevelEncryption"; ASPECT=OneEncryptionIdentity; STATUS=TESTED; TEST=tests/test_sonny6335_fle_identity_and_indexes.zig; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-SONNY-6347-FLE-RECORD-TENANT; FEATURE="FieldLevelEncryption"; ASPECT=RecordTenantIdentity; STATUS=TESTED; TEST=tests/test_sonny6347_fle_envelope_identity.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6335: the ONE encryption identity of a stored string property (what
/// goes into the key ids and the AAD): the record's stored tenant
/// (SONNY-6347), the node's first label or the edge's type as the schema,
/// and the record id "<id>" for a node, "edge_<id>" for an edge. Every
/// writer (the executor hook and the graph-store primitives, which encrypt a
/// value that reaches them in plaintext: raft apply, internal callers) and
/// every reader uses it. SONNY-6347: the tenant was the request's (the
/// active context's, else the thread's), so a parent tenant reading its
/// child tenant's row (GAP-0846) could not decrypt it; readers still try
/// the request tenant (`requestTenantIdentity`) for values written that
/// way. The graph-store writers used tenant/schema "default"/"default" and
/// "node_<id>" before SONNY-6335: see `legacyStoreIdentity`.
pub const Identity = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    record_id: []const u8,
};

pub fn recordIdentity(buf: *[32]u8, kind: EntityKind, type_name: []const u8, id: u64, record_tenant: []const u8) Identity {
    return .{
        .tenant_id = record_tenant,
        .schema_name = type_name,
        .record_id = switch (kind) {
            .node => std.fmt.bufPrint(buf, "{d}", .{id}),
            .edge => std.fmt.bufPrint(buf, "edge_{d}", .{id}),
        } catch unreachable, // error-policy: D — "edge_" + a u64 fits 32 bytes.
    };
}

/// SONNY-6347: the identity values were written under before SONNY-6347
/// (`recordIdentity` with the writer's request tenant: GAP-0852's active
/// context, else the thread's). Null when it is `recordIdentity` itself.
pub fn requestTenantIdentity(buf: *[32]u8, kind: EntityKind, type_name: []const u8, id: u64, record_tenant: []const u8) ?Identity {
    const request_tenant = tenantPreferringActiveContext();
    if (std.mem.eql(u8, request_tenant, record_tenant)) return null;
    return recordIdentity(buf, kind, type_name, id, request_tenant);
}

/// SONNY-6335: the identity the graph-store write sites used before
/// SONNY-6335 (store tenant and schema "default", "node_<id>" /
/// "edge_<id>"). Readers try it after `recordIdentity`, so values written
/// that way (raft apply, internal callers) decrypt.
pub fn legacyStoreIdentity(buf: *[32]u8, kind: EntityKind, id: u64) Identity {
    return .{
        .tenant_id = "default",
        .schema_name = "default",
        .record_id = switch (kind) {
            .node => std.fmt.bufPrint(buf, "node_{d}", .{id}),
            .edge => std.fmt.bufPrint(buf, "edge_{d}", .{id}),
        } catch unreachable, // error-policy: D — "node_" + a u64 fits 32 bytes.
    };
}

/// SONNY-6335: encrypt a stored string property under `recordIdentity` (or
/// return `plaintext` when the field is not encrypted). Memory from
/// `allocator` when it differs from `plaintext`.
pub fn encryptStoredString(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    plaintext: []const u8,
    id: u64,
    record_tenant: []const u8,
) ![]const u8 {
    var buf: [32]u8 = undefined;
    const ident = recordIdentity(&buf, kind, type_name, id, record_tenant);
    return encryptFieldIfNeeded(.{
        .tenant_id = ident.tenant_id,
        .schema_name = ident.schema_name,
        .allocator = allocator,
    }, type_name, field_name, plaintext, ident.record_id);
}

// CANARY: REQ=REQ-SONNY-6347-FLE-AUTHENTIC-ENVELOPE; FEATURE="FieldLevelEncryption"; ASPECT=StoreEnvelopeAuthenticated; STATUS=TESTED; TEST=tests/test_sonny6347_fle_envelope_identity.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6347: the bytes a graph-store write primitive stores for a string
/// property of an FLE-encrypted field: `value` itself when it is this
/// record's field envelope already (the executor hook encrypted it, or an
/// undo or replay writes stored bytes back), proved by authenticating it
/// (AEAD under the field key and an identity a reader tries); otherwise
/// `value` encrypted under `recordIdentity`. The primitives used a shape
/// test (algorithm byte, length field), so a crafted plaintext of that
/// shape reaching one outside the executor (a raft payload, an internal
/// caller) was stored in the clear. Memory from `allocator` when the result
/// differs from `value`.
pub fn sealStoredString(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    value: []const u8,
    id: u64,
    record_tenant: []const u8,
) ![]const u8 {
    if (try isStoredEnvelopeOf(allocator, kind, type_name, field_name, value, id, record_tenant)) return value;
    return encryptStoredString(allocator, kind, type_name, field_name, value, id, record_tenant);
}

/// SONNY-6688: is `value` already this record's sealed `field_name` value
/// (`isStoredEnvelopeOf`: authenticated, not judged by shape)? For the
/// migration of a field's existing plaintext.
pub fn storedStringIsEnvelope(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    value: []const u8,
    id: u64,
    record_tenant: []const u8,
) error{OutOfMemory}!bool {
    return isStoredEnvelopeOf(allocator, kind, type_name, field_name, value, id, record_tenant);
}

/// SONNY-6347: does `data` decrypt as this record's `field_name` envelope
/// under an identity a reader tries (`recordIdentity`, the request tenant's,
/// `legacyStoreIdentity`)? No role check: this is the writer's question, and
/// the plaintext is wiped and freed at once.
fn isStoredEnvelopeOf(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    data: []const u8,
    id: u64,
    record_tenant: []const u8,
) error{OutOfMemory}!bool {
    var bufs: [3][32]u8 = undefined;
    var idents: [3]Identity = undefined;
    var n: usize = 0;
    idents[n] = recordIdentity(&bufs[n], kind, type_name, id, record_tenant);
    n += 1;
    if (requestTenantIdentity(&bufs[n], kind, type_name, id, record_tenant)) |ident| {
        idents[n] = ident;
        n += 1;
    }
    idents[n] = legacyStoreIdentity(&bufs[n], kind, id);
    n += 1;
    for (idents[0..n]) |ident| {
        const ctx = EncryptionContext{ .tenant_id = ident.tenant_id, .schema_name = ident.schema_name, .allocator = allocator };
        const plain = decryptFieldIfNeeded(ctx, type_name, field_name, data, ident.record_id, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        // Not an envelope at all (too short, or not one by its encoding).
        if (plain.ptr == data.ptr and plain.len == data.len) return false;
        std.crypto.secureZero(u8, @constCast(plain));
        allocator.free(plain);
        return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-6327-FLE-READ-POLICY; FEATURE="FieldLevelEncryption"; ASPECT=OneReadPolicyForNodesAndEdges; STATUS=TESTED; TEST=tests/test_sonny6327_fle_read_gaps.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6327: the ONE read policy for a stored string property of a node
/// (`type_name` its first label) or an edge (`type_name` its type). Every
/// read surface (member access, `properties()`, map projection, the JSON
/// and wire encodings of a whole node, edge or path) calls this:
///   * no FLE field configured anywhere: the stored bytes, lock-free;
///   * a field that is not encrypted: the stored bytes;
///   * encrypted, and the principal's role may read plaintext: the
///     decrypted value; bytes that do not decrypt are
///     `error.FleDecryptionFailed`, never the stored bytes;
///   * encrypted, and it may not: "[REDACTED]" for a field without a blind
///     index, `error.SearchNotPermitted` (42501) for a searchable one;
///   * the FLE catalog cannot be loaded: `error.FleCatalogUnavailable`.
/// The role is the active request context's, else the thread's (GAP-0852);
/// `record_tenant` is the record's stored tenant (SONNY-6347). Returns
/// `stored` itself or memory from `allocator`.
pub fn readStoredString(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    stored: []const u8,
    id: u64,
    record_tenant: []const u8,
) FleReadError![]const u8 {
    if (!hasEncryptedFields()) return stored;

    // SONNY-6335: the one identity (`recordIdentity`), then (SONNY-6347) the
    // writer's request tenant's, then the legacy graph-store one.
    var id_buf: [32]u8 = undefined;
    const ident = recordIdentity(&id_buf, kind, type_name, id, record_tenant);
    const ctx = EncryptionContext{
        .tenant_id = ident.tenant_id,
        .schema_name = ident.schema_name,
        .allocator = allocator,
        .current_user_role = rolePreferringActiveContext(),
        .plaintext_gate = currentPlaintextGate(),
    };

    return decryptFieldIfNeeded(ctx, type_name, field_name, stored, ident.record_id, true) catch |err| switch (err) {
        error.SearchNotPermitted => error.SearchNotPermitted,
        error.FleCatalogUnavailable => error.FleCatalogUnavailable,
        error.OutOfMemory => error.OutOfMemory,
        else => {
            // The principal may read it (the RBAC check passed before any
            // decrypt): try the identities values were written under before.
            var request_buf: [32]u8 = undefined;
            if (requestTenantIdentity(&request_buf, kind, type_name, id, record_tenant)) |request| {
                var request_ctx = ctx;
                request_ctx.tenant_id = request.tenant_id;
                if (decryptFieldIfNeeded(request_ctx, type_name, field_name, stored, request.record_id, true)) |v| return v else |_| {}
            }
            var legacy_buf: [32]u8 = undefined;
            const legacy = legacyStoreIdentity(&legacy_buf, kind, id);
            var legacy_ctx = ctx;
            legacy_ctx.tenant_id = legacy.tenant_id;
            legacy_ctx.schema_name = legacy.schema_name;
            if (decryptFieldIfNeeded(legacy_ctx, type_name, field_name, stored, legacy.record_id, true)) |v| return v else |_| {}
            std.log.warn("SECURITY: FLE field {s}.{s} could not be decrypted ({s}); the read is refused", .{ type_name, field_name, @errorName(err) });
            return error.FleDecryptionFailed;
        },
    };
}

/// SONNY-6327: `readStoredString`, always as a copy `allocator` owns.
pub fn readStoredStringOwned(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    stored: []const u8,
    id: u64,
    record_tenant: []const u8,
) FleReadError![]u8 {
    const v = try readStoredString(allocator, kind, type_name, field_name, stored, id, record_tenant);
    if (v.ptr == stored.ptr and v.len == stored.len) return allocator.dupe(u8, stored);
    return @constCast(v);
}

/// SONNY-6327: `readStoredString` for a whole-entity encoding (RETURN n,
/// RETURN r, a path, `properties()`, map projection, JSON): a field the
/// principal may not read is "[REDACTED]" there, searchable or not (as the
/// node JSON encoding always did); every other refusal stands.
pub fn readStoredStringForEntity(
    allocator: std.mem.Allocator,
    kind: EntityKind,
    type_name: []const u8,
    field_name: []const u8,
    stored: []const u8,
    id: u64,
    record_tenant: []const u8,
) FleReadError![]u8 {
    return readStoredStringOwned(allocator, kind, type_name, field_name, stored, id, record_tenant) catch |err| switch (err) {
        error.SearchNotPermitted => allocator.dupe(u8, "[REDACTED]"),
        else => err,
    };
}

/// Check property access permissions during evaluation
/// This should be called when accessing node properties during WHERE clause evaluation
/// For searchable encrypted fields, it enforces RBAC by throwing SearchNotPermitted
/// Returns the value (decrypted if necessary and permitted)
/// SONNY-6327: a node's property through `readStoredString` (a decrypt
/// failure is an error, and no FLE field means no lock). Without the node
/// this has no stored tenant: it reads as the request tenant's record.
pub fn checkPropertyAccess(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    field_name: []const u8,
    value_str: []const u8,
    node_id: u64,
) FleReadError![]const u8 {
    return readStoredString(allocator, .node, type_name, field_name, value_str, node_id, tenantPreferringActiveContext());
}

/// SONNY-6327: an edge's property through the same policy as a node's.
pub fn checkEdgePropertyAccess(
    allocator: std.mem.Allocator,
    edge_type: []const u8,
    field_name: []const u8,
    value_str: []const u8,
    edge_id: u64,
) FleReadError![]const u8 {
    return readStoredString(allocator, .edge, edge_type, field_name, value_str, edge_id, tenantPreferringActiveContext());
}

// CANARY: REQ=REQ-FLE-PREDICATE-HELPERS-001; FEATURE="FLE Predicate Rewriting"; ASPECT=Helpers; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2026-01-09
/// Check if a field is encrypted according to the FLE catalog
pub fn isFieldEncrypted(ctx: EncryptionContext, type_name: []const u8, field_name: []const u8) bool {
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch return false;
    return catalog.isFieldEncrypted(type_name, field_name);
}

/// Check if an encrypted field is searchable (has blind index)
pub fn isFieldSearchable(ctx: EncryptionContext, type_name: []const u8, field_name: []const u8) bool {
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch return false;
    return catalog.isFieldSearchable(type_name, field_name);
}

test "FLE integration placeholder" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer fle_catalog.resetGlobalCatalog(allocator);

    const ctx = EncryptionContext{
        .tenant_id = "tenant1",
        .schema_name = "myschema",
        .allocator = allocator,
    };

    // Test that placeholder functions don't crash
    const result = try encryptFieldIfNeeded(ctx, "Person", "ssn", "123-45-6789", "node_1");
    try testing.expectEqualStrings("123-45-6789", result);

    const decrypt_result = try decryptFieldIfNeeded(ctx, "Person", "ssn", "123-45-6789", "node_1", false);
    try testing.expectEqualStrings("123-45-6789", decrypt_result);
}

// GAP-0285: Verify that clearCurrentThreadState removes stale per-thread role and tenant entries.
// SONNY-2656: the process-wide FLE key manager and blind index outlive the
// allocator of the call that creates them. A WHERE on the node scan evaluates
// on a per-node scratch arena that is reset after each node; a decrypt there
// can be the first FLE call in the process. Before this, both singletons were
// created on that arena and left dangling by its reset.
// CANARY: REQ=REQ-SONNY-2656-EXTENDED-VALUE-LEAKS; FEATURE="EngineDirectExtendedValueOwnership"; ASPECT=FleSingletonsProcessAllocator; STATUS=TESTED; TEST=src/fle_integration.zig; OWNER=security; UPDATED=2026-10-27
test "SONNY-2656: FLE singletons are created on the process allocator, not the caller's arena" {
    const testing = std.testing;
    resetGlobalKeyStateForTesting();
    defer resetGlobalKeyStateForTesting();
    try testing.expectEqual(@as(c_int, 0), setenvForTest("GEODE_MASTER_KEY", "sonny2656-singleton-allocator-test-master-key"));
    defer _ = unsetenvForTest("GEODE_MASTER_KEY");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const km = try getGlobalKeyManager(arena.allocator());
    const bi = try getGlobalBlindIndex();
    arena.deinit();

    try testing.expect(km.allocator.vtable == singleton_allocator.vtable);
    try testing.expect(bi.allocator.vtable == singleton_allocator.vtable);
    // Both still work after the caller's arena is gone.
    const ids = key_types.KeyIds{ .tenant = "t", .schema = "s", .field = "f", .version = 1 };
    const fek = try km.getFEK(ids);
    try testing.expectEqual(fek, try (try getGlobalKeyManager(testing.allocator)).getFEK(ids));
    try bi.put("s", "f", try km.getBIK(ids), "value", "rec_1");
    const hits = (try bi.lookup("s", "f", try km.getBIK(ids), "value")).?;
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("rec_1", hits[0]);
}

test "clearCurrentThreadState removes per-thread role and tenant" {
    const testing = std.testing;

    // Set per-thread state (simulates a connection handler setting FLE context)
    setCurrentUserRole("admin");
    setCurrentTenantId("acme-corp");

    // Verify state is set
    try testing.expectEqualStrings("acme-corp", getCurrentTenantId());
    // getCurrentUserRole may read env var first; check per_thread_roles directly
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(std.Thread.getCurrentId()) != null);
    }

    // Simulate connection handler defer block calling clearCurrentThreadState
    clearCurrentThreadState();

    // After cleanup: tenant should fall back to "default", role should be null
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(std.Thread.getCurrentId()) == null);
        try testing.expect(per_thread_tenants.get(std.Thread.getCurrentId()) == null);
    }
}

// GAP-0844: The process-global env var GEODE_CURRENT_ROLE must NOT override the
// per-thread role in the production getCurrentUserRole() path. Previously
// getCurrentUserRole() read GEODE_CURRENT_ROLE *before* the per-thread map, so a
// single process-wide env var could mask every connection's authenticated role
// — a cross-tenant FLE isolation hole in a shared multi-tenant process. The
// per-thread map (set on HELLO, cleared on close) is now the single source of
// truth. This test sets the env var to a different value than the per-thread
// role and asserts the per-thread role wins.
// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-003; FEATURE="FLERoleIsolation"; ASPECT=NoEnvOverride; STATUS=TESTED; OWNER=security; UPDATED=2026-06-08
test "GAP-0844: GEODE_CURRENT_ROLE env does not override per-thread role" {
    const testing = std.testing;

    // Set the dangerous process-global override to a value that, under the old
    // behavior, would mask whatever the per-thread map says.
    const set_rc = setenvForTest("GEODE_CURRENT_ROLE", "env_admin");
    try testing.expectEqual(@as(c_int, 0), set_rc);
    defer _ = unsetenvForTest("GEODE_CURRENT_ROLE");

    // Authenticated connection role established via the per-thread setter
    // (the same API the QUIC HELLO path uses).
    setCurrentUserRole("tenant_user");
    defer clearCurrentThreadState();

    // The per-thread role MUST win. The env var must be ignored entirely in the
    // production path.
    const role = getCurrentUserRole() orelse return error.RoleNotSet;
    try testing.expectEqualStrings("tenant_user", role);

    // And with NO per-thread role set, the env var must NOT resurrect a role:
    // getCurrentUserRole() falls through to the (empty) per-thread map and
    // returns null, NOT "env_admin". Fail-secure: no role = deny.
    clearCurrentThreadState();
    try testing.expect(getCurrentUserRole() == null);
}

// libc setenv/unsetenv shims for the GAP-0844 env-override test. std.posix.setenv
// was removed in Zig 0.16; std.c provides the non-allocating libc entry points.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
fn setenvForTest(name: [*:0]const u8, value: [*:0]const u8) c_int {
    return setenv(name, value, 1);
}
fn unsetenvForTest(name: [*:0]const u8) c_int {
    return unsetenv(name);
}

// #813 / GAP-0886a: REQ-FLE-ENFORCE-030 — the fle_has_encrypted_fields
// fast-path flag MUST read true once the schema has encrypted fields;
// otherwise encryptFieldIfNeeded() silently skips encryption (fail-open).
// Two mechanisms guarantee the invariant:
//   1. Explicit set: the `CALL geode.fle.configureField` dispatch calls
//      setHasEncryptedFields(true) right after catalog.configureField
//      (src/execution/storage_dispatch.zig).
//   2. Lazy self-heal: hasEncryptedFields() consults catalog.count() > 0 when
//      the flag is unset and unchecked — covering any path that populates the
//      catalog WITHOUT the explicit setter (e.g. persisted-catalog boot load).
// This test exercises mechanism 2 (the one a code reviewer can't see at the
// dispatch call site) plus the explicit-setter round-trip.
// CANARY: REQ=REQ-FLE-ENFORCE-030; FEATURE="FLEEnforcement"; ASPECT=GlobalFlagSkipDisabled; STATUS=TESTED; TEST=src/fle_integration.zig; OWNER=security; UPDATED=2026-06-10
test "GAP-0886: hasEncryptedFields reflects catalog state (flag self-heal + setter)" {
    const testing = std.testing;

    // Isolate catalog persistence: point the catalog at a tmp dir so
    // configureField's saveCatalog never touches a real data dir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // std.Io.Dir has no realpath in Zig 0.16; TmpDir.sub_path is relative to
    // `.zig-cache/tmp`, so reconstruct the absolute path from getcwd (same
    // pattern as tests/test_gap0854_fle_chain.zig).
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    while (cwd_len > 0 and cwd_buf[cwd_len - 1] == 0) : (cwd_len -= 1) {}
    const data_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/.zig-cache/tmp/{s}",
        .{ cwd_buf[0..cwd_len], &tmp.sub_path },
    );
    defer testing.allocator.free(data_dir);
    // SONNY-6336: the catalog's data-directory override wins over
    // GEODE_DATA_DIR and is process-global, and an earlier test in this
    // binary may have left one naming a directory it removed: set this
    // test's own, and restore the previous one on exit.
    const saved_override = fle_catalog.saveDataDirOverride();
    defer saved_override.restore();
    fle_catalog.setDataDirOverride(data_dir);

    // Clean global FLE state; restore it for sibling tests in this binary.
    fle_catalog.resetGlobalCatalog(testing.allocator);
    setHasEncryptedFields(false);
    defer {
        fle_catalog.resetGlobalCatalog(testing.allocator);
        setHasEncryptedFields(false);
    }

    // Explicit-setter round-trip while the catalog is still empty
    // (mirrors the storage_dispatch configureField call site).
    setHasEncryptedFields(true);
    try testing.expect(hasEncryptedFields());
    setHasEncryptedFields(false);
    try testing.expect(!hasEncryptedFields()); // empty catalog → lazy check stays false

    // Populate the catalog WITHOUT calling setHasEncryptedFields — simulating
    // a path that configures encryption while bypassing the dispatch setter.
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    try catalog.configureField("Gap0886Type", .{
        .field_name = "ssn",
        .encryption = .{ .enabled = true },
    });

    // Force the "never explicitly set" state: unset AND unchecked.
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        fle_has_encrypted_fields.store(false, .release);
        fle_catalog_state_checked.store(false, .release);
    }

    // INVARIANT under test: the lazy self-heal must observe the configured
    // field and flip the flag — no silent encryption skip.
    try testing.expect(hasEncryptedFields());
}

// GAP-0515: Thread reuse isolation regression test.
//
// The earlier test covers the single direction (set → clear → empty). The
// attack surface GAP-0515 flagged is specifically the thread-pool reuse
// case: connection handler thread T runs for tenant A, cleanup fires,
// then the same thread T is immediately reused for tenant B. Nothing
// from tenant A's FLE context must survive into tenant B's execution
// — including after B's own cleanup, a hypothetical C must likewise
// see a clean slate. Also verifies that a redundant second clear is
// idempotent (defer blocks can fire twice in some error paths).
test "GAP-0515: thread reuse isolates FLE context across connections" {
    const testing = std.testing;
    const tid = std.Thread.getCurrentId();

    // --- Connection 1 (tenant "alpha", role "admin") ---
    setCurrentUserRole("admin");
    setCurrentTenantId("alpha");
    try testing.expectEqualStrings("alpha", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const r = per_thread_roles.get(tid) orelse return error.RoleNotSet;
        try testing.expectEqualStrings("admin", r);
    }

    // Simulated defer block: clear state on connection close.
    clearCurrentThreadState();

    // --- Connection 2 reuses the same thread (tenant "beta", role "user") ---
    // On entry the state MUST be clean — no leak from connection 1.
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(tid) == null);
    }

    setCurrentUserRole("user");
    setCurrentTenantId("beta");

    // Reading back must return connection 2's values, not connection 1's.
    try testing.expectEqualStrings("beta", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const r = per_thread_roles.get(tid) orelse return error.RoleNotSet;
        try testing.expectEqualStrings("user", r);
        // And crucially: the old "admin" / "alpha" values are gone.
        try testing.expect(!std.mem.eql(u8, r, "admin"));
    }

    // --- Connection 2 cleanup ---
    clearCurrentThreadState();

    // Idempotency: double-clear must not panic or leave state in a bad
    // shape. The QUIC handler's errdefer path can fire in addition to the
    // defer, so the function must tolerate being called twice.
    clearCurrentThreadState();

    // After the double-clear, state is empty. A fresh connection 3 on
    // the same thread starts from the same clean slate.
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(tid) == null);
        try testing.expect(per_thread_tenants.get(tid) == null);
    }
}

// =============================================================================
// FIPS FAIL-CLOSE TESTS (Task 8)
//
// These tests assert the fail-close invariant for ChaCha20-Poly1305 under FIPS:
//   - Under -Dfips=true:  selecting ChaCha20-Poly1305 returns error.FipsUnsupported
//   - Under -Dfips=false: ChaCha20-Poly1305 compiles and is reachable (no gate)
//   - AES-256-GCM works in both modes
//
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLETests; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
// =============================================================================

// Helper: configure a field with the given algorithm in an isolated catalog, set up a
// minimal key-manager env, and call encryptFieldIfNeeded. Returns the error (or void on
// success). Caller owns cleanup of catalog state.
fn configureAndEncrypt(
    allocator: std.mem.Allocator,
    alg: fle_annotations.EncryptionConfig.Algorithm,
) !void {
    // Point to a tmp data dir to avoid polluting the real catalog on disk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    while (cwd_len > 0 and cwd_buf[cwd_len - 1] == 0) : (cwd_len -= 1) {}
    const data_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/tmp/{s}",
        .{ cwd_buf[0..cwd_len], &tmp.sub_path },
    );
    defer allocator.free(data_dir);
    // SONNY-6336: the catalog's data-directory override wins over
    // GEODE_DATA_DIR and is process-global, and an earlier test in this
    // binary may have left one naming a directory it removed: set this
    // test's own, and restore the previous one on exit.
    const saved_override = fle_catalog.saveDataDirOverride();
    defer saved_override.restore();
    fle_catalog.setDataDirOverride(data_dir);

    // Reset global catalog + key-manager state for isolation.
    fle_catalog.resetGlobalCatalog(allocator);
    setHasEncryptedFields(false);
    resetGlobalKeyStateForTesting();
    defer {
        fle_catalog.resetGlobalCatalog(allocator);
        setHasEncryptedFields(false);
        resetGlobalKeyStateForTesting();
    }

    // Configure the catalog with the requested algorithm.
    const catalog = try fle_catalog.globalCatalog(allocator);
    try catalog.configureField("FipsTestType", .{
        .field_name = "secret",
        .encryption = .{ .enabled = true, .algorithm = alg },
    });
    setHasEncryptedFields(true);

    // Point key manager at a dummy env (no real KMS needed — we expect
    // failure before the key-fetch for the ChaCha path under FIPS).
    _ = setenvForTest("GEODE_MASTER_KEY", "deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb");
    defer _ = unsetenvForTest("GEODE_MASTER_KEY");

    const ctx = EncryptionContext{
        .tenant_id = "test_tenant",
        .schema_name = "FipsTestType",
        .allocator = allocator,
    };

    // encryptFieldIfNeeded will fail-close with FipsUnsupported before key fetch.
    const result = encryptFieldIfNeeded(ctx, "FipsTestType", "secret", "plaintext_value", "rec_1");
    if (result) |ciphertext| {
        // On success (non-FIPS path), free the allocated ciphertext.
        // encryptFieldIfNeeded returns the original plaintext slice (no alloc)
        // when the field is not in the catalog, but returns an allocated envelope
        // when encryption succeeds. Free only if it differs from the input.
        if (ciphertext.ptr != "plaintext_value".ptr) {
            allocator.free(ciphertext);
        }
    } else |err| {
        return err;
    }
}

// Task 8: Under FIPS, selecting ChaCha20-Poly1305 for FLE must return FipsUnsupported.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptRejectChaCha; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: ChaCha20-Poly1305 FLE encrypt returns FipsUnsupported under FIPS" {
    if (!build_options.fips) return error.SkipZigTest; // FIPS gate: only runs under -Dfips=true

    const err = configureAndEncrypt(std.testing.allocator, .chacha20_poly1305);
    try std.testing.expectError(error.FipsUnsupported, err);
}

// Task 8: Under FIPS, AES-256-GCM FLE must still be reachable (no false positive).
// The key-manager env is minimal (dummy key), so the test will fail at key fetch —
// but NOT at the FIPS gate. The absence of FipsUnsupported confirms AES-GCM is
// approved and passes the FIPS check.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptAesGcmAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: AES-256-GCM FLE encrypt is NOT blocked by FIPS gate" {
    if (!build_options.fips) return error.SkipZigTest; // FIPS gate: only runs under -Dfips=true

    const err = configureAndEncrypt(std.testing.allocator, .aes256_gcm);
    // AES-GCM must NOT produce FipsUnsupported. It may produce other errors
    // (key-fetch, catalog) but the FIPS fail-close must NOT trigger.
    if (err) |_| {
        // Succeeded without error — fine.
    } else |e| {
        try std.testing.expect(e != error.FipsUnsupported);
    }
}

// Task 8: Under non-FIPS (-Dfips=false), ChaCha20-Poly1305 path is reachable and
// must NOT be blocked by the FIPS gate.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptChaChaAllowedNonFips; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: ChaCha20-Poly1305 FLE is NOT gated under non-FIPS build" {
    if (build_options.fips) return error.SkipZigTest; // Non-FIPS gate: only runs under -Dfips=false

    const err = configureAndEncrypt(std.testing.allocator, .chacha20_poly1305);
    // Under non-FIPS, ChaCha20 must NOT be blocked. It may produce other errors
    // (key-fetch) but the FIPS gate must not fire.
    if (err) |_| {
        // Succeeded without error — fine.
    } else |e| {
        // Must not be FipsUnsupported.
        try std.testing.expect(e != error.FipsUnsupported);
    }
}
