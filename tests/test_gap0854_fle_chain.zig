// GAP-0854 — FLE `configureField` must not corrupt the auth/audit HMAC chain.
//
// ============================================================================
// ROOT CAUSE (investigated 2026-06-09)
// ============================================================================
// Geode persists auth users/roles/permissions/policies/grants as nodes in an
// internal HMAC-chained graph named `__geode_security`. User nodes carry a
// `User` label and plaintext properties (`username`, `email`,
// `password_hash`, …) plus an `hmac` property. `verifyChain` (run at every
// boot, src/server/server_init.zig:412-436) recomputes each record's HMAC from
// the *plaintext* property values and compares it against the stored `hmac`.
//
// Field-Level Encryption keys solely on a node's PRIMARY LABEL + property key
// (src/graph_store.zig setNodeProperty / applyFleEncryption / getNodeProperty).
// It did NOT consider which graph the node lives in. So the moment an operator
// runs:
//
//     CALL geode.fle.configureField('User','email',{algorithm:'AES-256-GCM'})
//
// every subsequent write of an `email` property on ANY node whose first label
// is `User` — INCLUDING the `__geode_security` graph's own admin User node —
// gets FLE-encrypted on disk. The stored `hmac` was computed over the
// plaintext `email`; after a flush/restart the on-disk `email` is an FLE
// envelope. On reload `loadUserRecordFromNode` reads that property back through
// `getNodeProperty` (which, during boot, has no authorized FLE role, so the
// RBAC-gated decrypt returns the raw envelope), and `verifyChain`'s recomputed
// HMAC no longer matches the stored `hmac` → `error.AuthChainTampered` and the
// process exits 1. A server with any FLE field configured could never restart.
// (Reproduced by CaaST across geode 0.6.13–0.6.18; docs/CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md.)
//
// ============================================================================
// FIX
// ============================================================================
// The `__geode_security` graph is internal infrastructure (already protected
// at rest by TDE) and must never be subject to user-configured FLE. All three
// node FLE sites in src/graph_store.zig (setNodeProperty encrypt,
// applyFleEncryption encrypt, getNodeProperty decrypt) now short-circuit when
// the node lives in the `__geode_security` graph, via `isSecurityGraphName`.
//
// ============================================================================
// TEST STRATEGY
// ============================================================================
// 1. Bootstrap an admin user into `__geode_security` (HMAC sealed over
//    plaintext). Assert `verifyChain` passes.
// 2. Configure FLE for ('User','email') through the REAL production dispatch
//    (geode.storage_dispatch.executeFle), which flips the global
//    has-encrypted-fields flag and configures the same global FLE catalog the
//    storage layer consults.
// 3. Re-persist the security-graph User node's `email` (the server flushes the
//    security graph after FLE config) and then re-hydrate a FRESH
//    AuthGraphManager on the same store — the in-process equivalent of a server
//    restart's `loadCache`.
// 4. `verifyChain` must still pass. Before the fix this fails with an
//    AuthChainTampered-family error (RecordHmacMismatch / ChainHashMismatch).

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const fle_integration = geode.fle_integration;
const storage_dispatch = geode.storage_dispatch;
const ast = geode.gql.ast;

const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const testing = std.testing;

const HMAC_KEY = [_]u8{0x5a} ** 32;
const SECURITY_GRAPH_NAME = "__geode_security";

// Drive the real `CALL geode.fle.configureField('User','email')` dispatch so
// the SAME global FLE catalog/state the storage layer reads is configured.
fn configureFleField(arena: std.mem.Allocator, type_name: []const u8, field_name: []const u8) !void {
    var type_expr = ast.Expr{ .String = type_name };
    var field_expr = ast.Expr{ .String = field_name };
    var args = [_]*ast.Expr{ &type_expr, &field_expr };

    var callee = ast.Expr{ .String = "geode.fle.configureField" };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = &args } };

    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };

    const result = try storage_dispatch.executeFle(arena, "geode.fle.configurefield", call_stmt);
    try testing.expect(result != null);
}

// CANARY: REQ=REQ-FLE-AUTHCHAIN-001; FEATURE="FLE AuthChain Integrity"; ASPECT=ConfigureFieldRestart; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09

test "GAP-0854: configureField on a colliding label does not corrupt the auth HMAC chain across restart" {
    const allocator = testing.allocator;

    // Isolated FLE state: ensure no leftover global encryption flag/catalog
    // from another test in the same binary. Restore afterwards.
    const had_fields_before = fle_integration.hasEncryptedFields();
    defer fle_integration.setHasEncryptedFields(had_fields_before);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // 1. Bootstrap admin into __geode_security and seal the chain.
    {
        var mgr = try AuthGraphManager.init(allocator, &store);
        defer mgr.deinit();
        const boot = try mgr.bootstrapDefaultAdmin(&HMAC_KEY);
        // bootstrapDefaultAdmin returns owned username/password strings.
        allocator.free(boot.username);
        allocator.free(boot.password);
        // Sanity: a freshly bootstrapped chain verifies.
        try mgr.verifyChain(&HMAC_KEY);
    }

    // 2. Configure FLE for ('User','email') via the real dispatch path.
    {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        try configureFleField(arena_state.allocator(), "User", "email");
    }
    // The dispatch sets this, but assert it so the test fails loudly if the
    // production path stops flipping the flag.
    try testing.expect(fle_integration.hasEncryptedFields());
    try testing.expect(fle_integration.fieldRequiresEncryption("User", "email"));

    // 3. Re-persist the security-graph User node's `email` exactly as the
    //    server would when it flushes __geode_security after FLE config, then
    //    re-hydrate a fresh manager (= restart).
    {
        const nodes = store.getNodesByLabel(SECURITY_GRAPH_NAME, "User") orelse &[_]u64{};
        try testing.expect(nodes.len >= 1);
        for (nodes) |node_id| {
            // Read the current (plaintext) email and write it straight back.
            const email_val = store.getNodeProperty(node_id, "email") orelse continue;
            if (email_val == .String) {
                try store.setNodeProperty(node_id, "email", .{ .String = email_val.String });
            }
        }
    }

    // 4. Restart: fresh manager re-hydrates cache from the graph and verifies.
    {
        var mgr2 = try AuthGraphManager.init(allocator, &store);
        defer mgr2.deinit();
        // Before the GAP-0854 fix this returns an AuthChainTampered-family
        // error (RecordHmacMismatch / ChainHashMismatch) because the
        // security-graph User node's `email` was FLE-rewritten.
        mgr2.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("GAP-0854 reproduction: verifyChain failed with {s}\n", .{@errorName(err)});
            return err;
        };
    }

    // Also assert the stored email is still plaintext on disk (no FLE envelope
    // leaked into the security graph).
    {
        const nodes = store.getNodesByLabel(SECURITY_GRAPH_NAME, "User") orelse &[_]u64{};
        for (nodes) |node_id| {
            const email_val = store.getNodeProperty(node_id, "email") orelse continue;
            if (email_val == .String) {
                try testing.expectEqualStrings("admin@localhost", email_val.String);
            }
        }
    }
}
