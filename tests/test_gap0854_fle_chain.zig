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

// libc setenv shim: the FLE key manager reads GEODE_MASTER_KEY via std.c.getenv
// and refuses to operate without it. The test module links libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// 32-byte secret (hex) for the FLE master key — test-only, never a real secret.
const TEST_MASTER_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

// Local mirror of graph_store.isLikelyFleEnvelope (private). Used only to
// assert — positively — that a value stored in a NORMAL graph really did get
// turned into an FLE envelope (alg id 1-3 + matching length-prefix), so the
// GAP-0854 security-graph guard cannot regress into disabling FLE everywhere.
fn looksLikeFleEnvelope(data: []const u8) bool {
    if (data.len < 35) return false;
    const alg_id = data[0];
    if (alg_id < 1 or alg_id > 3) return false;
    const ciphertext_len = std.mem.readInt(u32, data[31..35], .little);
    return data.len == 35 + ciphertext_len;
}

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

    // The FLE key manager refuses to derive a FEK without a master key.
    // Install a deterministic test key so the positive-encryption assertion
    // (step 5) can produce a real envelope. (The security-graph guard is
    // independent of whether a master key is present.)
    _ = setenv("GEODE_MASTER_KEY", TEST_MASTER_KEY_HEX, 1);

    // Isolated FLE state: ensure no leftover global encryption flag/catalog
    // from another test in the same binary. Restore afterwards.
    const had_fields_before = fle_integration.hasEncryptedFields();
    defer fle_integration.setHasEncryptedFields(had_fields_before);

    // Step 5 exercises the real encrypt path, which lazily instantiates the
    // process-global FLE key manager + blind index on the test allocator. Tear
    // them down so the leak checker stays clean (production keeps them for the
    // process lifetime).
    defer fle_integration.resetGlobalKeyStateForTesting();

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

    // 5. POSITIVE counter-assertion (the guard must NOT disable FLE generally):
    //    a `User` node in a NORMAL (non-security) graph, with the exact same
    //    ('User','email') field configured above, MUST get FLE-encrypted — the
    //    raw stored value is an FLE envelope, not the plaintext we wrote. This
    //    locks in that the GAP-0854 security-graph short-circuit only suppresses
    //    FLE for `__geode_security`, never anywhere else.
    {
        const plaintext_email = "alice@example.com";
        const labels = [_][]const u8{"User"};
        const node_id = try store.createNodeWithGraph(&labels, "app");
        try store.setNodeProperty(node_id, "email", .{ .String = plaintext_email });

        // Read the RAW stored value (no FLE decrypt) — it must be an envelope.
        const raw = try store.getNodePropertyValue(node_id, "email");
        try testing.expect(raw == .String);
        try testing.expect(!std.mem.eql(u8, raw.String, plaintext_email));
        try testing.expect(looksLikeFleEnvelope(raw.String));
    }
}
