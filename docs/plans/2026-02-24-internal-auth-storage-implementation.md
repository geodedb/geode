# Internal Auth Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move auth credentials from the external flat file (`auth_state.db`) into the `__geode_security` graph with HMAC chain tamper detection and unified Argon2id hashing.

**Architecture:** Auth records stored as graph nodes in `__geode_security` within `graph_store.dat`, protected by TDE. HMAC-SHA256 chain verifies integrity on every startup. SecurityManager becomes a read cache hydrated from the graph store. CLI commands work offline (direct graph access) or online (QUIC to server).

**Tech Stack:** Zig 0.15.1, `std.crypto.auth.hmac.sha2.HmacSha256`, `std.crypto.pwhash.argon2`, existing GraphStore API

**Design Doc:** `docs/plans/2026-02-24-internal-auth-storage-design.md`

---

## Task 1: Create HMAC Chain Module

**Files:**

- Create: `src/security/auth_hmac.zig`
- Test: inline `test` blocks in `src/security/auth_hmac.zig`

This module handles all HMAC computation: per-record HMACs, chain hash, key resolution, and verification. It has no dependency on SecurityManager or CLI — pure crypto + serialization.

**Step 1: Write failing tests for HMAC key resolution**

```zig
const std = @import("std");
const auth_hmac = @This();

// ... (implementation will go above tests)

test "resolveHmacKey returns env var key when set" {
    // This test verifies GEODE_AUTH_HMAC_KEY env var takes priority.
    // Since we can't reliably set env vars in tests, test the HKDF path instead.
    const tde_key_hex = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    var tde_key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&tde_key, tde_key_hex) catch unreachable;
    const hmac_key = deriveHmacKeyFromTde(&tde_key);
    // HKDF output should be deterministic
    const hmac_key2 = deriveHmacKeyFromTde(&tde_key);
    try std.testing.expectEqualSlices(u8, &hmac_key, &hmac_key2);
    // Should NOT equal the raw TDE key
    try std.testing.expect(!std.mem.eql(u8, &hmac_key, &tde_key));
}
```

**Step 2: Write failing tests for per-record HMAC**

```zig
test "computeRecordHmac is deterministic for same input" {
    const key = [_]u8{0x42} ** 32;
    const props = [_]KeyValue{
        .{ .key = "email", .value = "admin@test.com" },
        .{ .key = "username", .value = "admin" },
    };
    const hmac1 = computeRecordHmac(&key, &props);
    const hmac2 = computeRecordHmac(&key, &props);
    try std.testing.expectEqualSlices(u8, &hmac1, &hmac2);
}

test "computeRecordHmac differs for different input" {
    const key = [_]u8{0x42} ** 32;
    const props1 = [_]KeyValue{
        .{ .key = "username", .value = "admin" },
    };
    const props2 = [_]KeyValue{
        .{ .key = "username", .value = "other" },
    };
    const hmac1 = computeRecordHmac(&key, &props1);
    const hmac2 = computeRecordHmac(&key, &props2);
    try std.testing.expect(!std.mem.eql(u8, &hmac1, &hmac2));
}

test "computeRecordHmac sorts keys deterministically" {
    const key = [_]u8{0x42} ** 32;
    // Same properties, different order — should produce same HMAC
    const props_a = [_]KeyValue{
        .{ .key = "username", .value = "admin" },
        .{ .key = "email", .value = "a@b.com" },
    };
    const props_b = [_]KeyValue{
        .{ .key = "email", .value = "a@b.com" },
        .{ .key = "username", .value = "admin" },
    };
    const hmac_a = computeRecordHmac(&key, &props_a);
    const hmac_b = computeRecordHmac(&key, &props_b);
    try std.testing.expectEqualSlices(u8, &hmac_a, &hmac_b);
}
```

**Step 3: Write failing tests for chain hash**

```zig
test "computeChainHash is deterministic" {
    const key = [_]u8{0x42} ** 32;
    var record_hmacs: [2][32]u8 = undefined;
    record_hmacs[0] = [_]u8{0x01} ** 32;
    record_hmacs[1] = [_]u8{0x02} ** 32;
    const chain1 = computeChainHash(&key, &record_hmacs, 2);
    const chain2 = computeChainHash(&key, &record_hmacs, 2);
    try std.testing.expectEqualSlices(u8, &chain1, &chain2);
}

test "computeChainHash detects count mismatch" {
    const key = [_]u8{0x42} ** 32;
    var record_hmacs: [2][32]u8 = undefined;
    record_hmacs[0] = [_]u8{0x01} ** 32;
    record_hmacs[1] = [_]u8{0x02} ** 32;
    const chain_2 = computeChainHash(&key, &record_hmacs, 2);
    const chain_3 = computeChainHash(&key, &record_hmacs, 3);
    try std.testing.expect(!std.mem.eql(u8, &chain_2, &chain_3));
}
```

**Step 4: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "auth_hmac|error"`
Expected: Compilation errors (file doesn't exist yet or functions not defined)

**Step 5: Implement auth_hmac.zig**

```zig
const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const HMAC_LEN = 32;
pub const KEY_LEN = 32;

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Derive HMAC key from TDE key using HKDF.
/// Context string ensures the derived key is domain-separated from TDE usage.
pub fn deriveHmacKeyFromTde(tde_key: *const [32]u8) [KEY_LEN]u8 {
    const salt = "geode-auth-hmac-v1";
    const info = "auth-chain-integrity";
    var out: [KEY_LEN]u8 = undefined;
    Hkdf.expand(&out, info, Hkdf.extract(salt, tde_key));
    return out;
}

/// Compute HMAC-SHA256 over a set of key-value properties.
/// Properties are sorted by key name for deterministic output.
/// Input format per property: key_len(u32 LE) || key || value_len(u32 LE) || value
pub fn computeRecordHmac(key: *const [KEY_LEN]u8, props: []const KeyValue) [HMAC_LEN]u8 {
    // Sort by key. We need indices since we can't sort a const slice.
    var indices: [64]usize = undefined;
    for (0..props.len) |i| indices[i] = i;
    const idx_slice = indices[0..props.len];
    std.mem.sortUnstable(usize, idx_slice, props, struct {
        pub fn lessThan(kv: []const KeyValue, a: usize, b: usize) bool {
            return std.mem.order(u8, kv[a].key, kv[b].key) == .lt;
        }
    }.lessThan);

    var mac = HmacSha256.init(key);
    for (idx_slice) |i| {
        const klen: u32 = @intCast(props[i].key.len);
        mac.update(std.mem.asBytes(&klen));
        mac.update(props[i].key);
        const vlen: u32 = @intCast(props[i].value.len);
        mac.update(std.mem.asBytes(&vlen));
        mac.update(props[i].value);
    }
    var out: [HMAC_LEN]u8 = undefined;
    mac.final(&out);
    return out;
}

/// Compute chain hash over all record HMACs.
/// Input: concat(all record HMACs in node-ID order) || record_count(u64 LE)
pub fn computeChainHash(key: *const [KEY_LEN]u8, record_hmacs: []const [HMAC_LEN]u8, record_count: u64) [HMAC_LEN]u8 {
    var mac = HmacSha256.init(key);
    for (record_hmacs) |*h| {
        mac.update(h);
    }
    mac.update(std.mem.asBytes(&record_count));
    var out: [HMAC_LEN]u8 = undefined;
    mac.final(&out);
    return out;
}

/// Constant-time HMAC comparison.
pub fn verifyHmac(expected: *const [HMAC_LEN]u8, actual: *const [HMAC_LEN]u8) bool {
    return std.crypto.timing_safe.eql([HMAC_LEN]u8, expected.*, actual.*);
}

/// Encode a 32-byte HMAC as a 64-char lowercase hex string.
pub fn hmacToHex(hmac: *const [HMAC_LEN]u8) [64]u8 {
    return std.fmt.bytesToHex(hmac.*, .lower);
}

/// Decode a 64-char hex string into a 32-byte HMAC.
pub fn hexToHmac(hex: *const [64]u8) ![HMAC_LEN]u8 {
    var out: [HMAC_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}
```

**Step 6: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -E "auth_hmac|PASS|FAIL"`
Expected: All auth_hmac tests PASS

**Step 7: Register module in build system**

Add `auth_hmac` to `src/lib.zig` public exports so it's accessible as `geode.auth_hmac`.

**Step 8: Commit**

```bash
git add src/security/auth_hmac.zig src/lib.zig
git commit -m "feat(security): add HMAC chain module for auth record integrity"
```

---

## Task 2: Extend UserStorageBackend with HMAC Properties

**Files:**

- Modify: `src/storage/user_storage.zig`
- Test: inline `test` blocks in `src/storage/user_storage.zig`

Add `hmac` and `hash_algorithm` properties to UserRecord, and new fields (`is_default_user`, `password_reset_required`, `password_changed_at`) needed by the design. Add `AuthChainRoot` node label. Wire HMAC computation into persist/load operations.

**Step 1: Write failing test for HMAC-aware user persist + verify round-trip**

```zig
test "persistUser stores hmac property and loadCache retrieves it" {
    // Uses test GraphStore instance
    var store = try graph_store.GraphStore.initTest(std.testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(std.testing.allocator, &store);
    defer backend.deinit();

    const hmac_key = [_]u8{0x42} ** 32;
    try backend.persistUserWithHmac(1, "admin", "admin@test.com", "$argon2id$v=19$test", "", &hmac_key);

    // Reload and check hmac property is present
    const record = backend.getUser(1) orelse return error.TestFailed;
    try std.testing.expect(record.getUsername().len > 0);
    // The hmac field on the graph node should be non-empty
    const node_id = backend.user_nodes.get(1) orelse return error.TestFailed;
    const hmac_val = getStringProp(&store, node_id, "hmac", "");
    try std.testing.expect(hmac_val.len == 64); // 32 bytes = 64 hex chars
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "persistUserWithHmac"`
Expected: FAIL — function doesn't exist

**Step 3: Add new fields to UserRecord**

Add to `UserRecord` struct in `user_storage.zig`:

- `hash_algorithm: [16]u8` + `hash_algorithm_len: u16`
- `is_default_user: bool`
- `password_reset_required: bool`
- `password_changed_at: i64`

Update `blankUserRecord()` to initialize these.
Update `loadUsersFromGraph()` to read these properties.
Update `upsertUserNode()` to write these properties.

**Step 4: Add `AuthChainRoot` label constant**

```zig
const AUTH_CHAIN_ROOT_LABEL = "AuthChainRoot";
```

**Step 5: Add `persistUserWithHmac` function**

This wraps `persistUser` and also computes + stores the per-record HMAC as a node property.

```zig
pub fn persistUserWithHmac(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8, hmac_key: *const [32]u8) !void {
    try self.persistUser(user_id, username, email, password_hash, salt);
    // Compute HMAC over user properties
    const auth_hmac = @import("geode").auth_hmac;
    const record = self.user_cache.get(user_id) orelse return error.UserNotFound;
    const props = [_]auth_hmac.KeyValue{
        .{ .key = "username", .value = record.getUsername() },
        .{ .key = "email", .value = record.getEmail() },
        .{ .key = "password_hash", .value = record.getPasswordHash() },
        .{ .key = "is_active", .value = if (record.is_active) "true" else "false" },
        .{ .key = "is_superuser", .value = if (record.is_superuser) "true" else "false" },
        // ... all fields
    };
    const hmac = auth_hmac.computeRecordHmac(hmac_key, &props);
    const hex = auth_hmac.hmacToHex(&hmac);
    const node_id = self.user_nodes.get(user_id) orelse return error.UserNotFound;
    try self.store.setNodeProperty(node_id, "hmac", .{ .String = &hex });
    self.store.saveIfDirty();
}
```

**Step 6: Add chain root read/write functions**

```zig
pub fn loadChainRoot(self: *Self) ?ChainRootRecord { ... }
pub fn persistChainRoot(self: *Self, chain_hash: []const u8, record_count: u64, hmac_key_id: []const u8) !void { ... }
```

**Step 7: Run tests**

Run: `zig build test 2>&1 | grep -E "user_storage|PASS|FAIL"`
Expected: All tests PASS

**Step 8: Commit**

```bash
git add src/storage/user_storage.zig
git commit -m "feat(security): extend UserStorageBackend with HMAC properties and chain root"
```

---

## Task 3: Create Auth Graph Manager (Orchestration Layer)

**Files:**

- Create: `src/security/auth_graph_manager.zig`
- Test: inline `test` blocks

This is the orchestration layer that ties together `auth_hmac.zig` (crypto), `user_storage.zig` (persistence), and later `geode_auth_lib.zig` (SecurityManager). It handles:

- Loading all auth records from graph + verifying HMAC chain
- Creating/updating auth records with HMAC computation
- Bootstrapping the default admin user
- HMAC key resolution (env var, HKDF from TDE, file)

**Step 1: Write failing test for HMAC key resolution**

```zig
test "resolveHmacKey loads from file when env vars not set" {
    // Create a temp .geode_hmac_key file, verify it's read
    const allocator = std.testing.allocator;
    var mgr = try AuthGraphManager.initForTest(allocator);
    defer mgr.deinit();
    // Should fail if no key source exists
    try std.testing.expectError(error.NoHmacKeyAvailable, mgr.resolveHmacKey());
}
```

**Step 2: Write failing test for full chain verification**

```zig
test "verifyChain passes for correctly sealed auth records" {
    var mgr = try AuthGraphManager.initForTest(std.testing.allocator);
    defer mgr.deinit();
    const key = [_]u8{0x42} ** 32;
    // Bootstrap creates admin + seals chain
    try mgr.bootstrapDefaultAdmin(&key);
    // Verification should pass
    try mgr.verifyChain(&key);
}

test "verifyChain fails when record tampered" {
    var mgr = try AuthGraphManager.initForTest(std.testing.allocator);
    defer mgr.deinit();
    const key = [_]u8{0x42} ** 32;
    try mgr.bootstrapDefaultAdmin(&key);
    // Tamper: change username directly in graph store bypassing HMAC
    // ... modify node property directly ...
    try std.testing.expectError(error.HmacVerificationFailed, mgr.verifyChain(&key));
}

test "verifyChain fails when record count mismatched" {
    var mgr = try AuthGraphManager.initForTest(std.testing.allocator);
    defer mgr.deinit();
    const key = [_]u8{0x42} ** 32;
    try mgr.bootstrapDefaultAdmin(&key);
    // Add a user node directly without updating chain root
    // ... create node bypassing manager ...
    try std.testing.expectError(error.RecordCountMismatch, mgr.verifyChain(&key));
}
```

**Step 3: Run tests to verify they fail**

Run: `zig build test`
Expected: Compilation errors

**Step 4: Implement AuthGraphManager**

```zig
pub const AuthGraphManager = struct {
    allocator: Allocator,
    storage: UserStorageBackend,

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !Self { ... }
    pub fn deinit(self: *Self) void { ... }

    /// Resolve HMAC key from environment or file.
    pub fn resolveHmacKey(self: *Self) ![32]u8 { ... }

    /// Verify the entire HMAC chain. Returns error on any mismatch.
    pub fn verifyChain(self: *Self, hmac_key: *const [32]u8) !void { ... }

    /// Seal (recompute) the entire HMAC chain.
    pub fn sealChain(self: *Self, hmac_key: *const [32]u8) !void { ... }

    /// Bootstrap default admin user + seal chain. For first-boot only.
    pub fn bootstrapDefaultAdmin(self: *Self, hmac_key: *const [32]u8) !BootstrapResult { ... }

    /// Create a new user with Argon2id hash + HMAC. Returns user ID.
    pub fn createUser(self: *Self, hmac_key: *const [32]u8, username: []const u8, email: []const u8, password: []const u8, is_superuser: bool) !u64 { ... }

    /// Hydrate a SecurityManager from verified graph data.
    pub fn hydrateSecurityManager(self: *Self, sm: *geode_auth.SecurityManager) !void { ... }
};
```

**Step 5: Run tests**

Run: `zig build test`
Expected: All auth_graph_manager tests PASS

**Step 6: Commit**

```bash
git add src/security/auth_graph_manager.zig src/lib.zig
git commit -m "feat(security): add AuthGraphManager orchestration layer"
```

---

## Task 4: Wire AuthGraphManager into Server Startup

**Files:**

- Modify: `src/server/server_init.zig`
- Modify: `src/security/geode_auth_lib.zig` (add `hydrateFromStorage` method to SecurityManager)

**Step 1: Add `hydrateFromStorage` to SecurityManager**

Currently `SecurityManager.init()` calls `initializeDefaultUser()` to create an in-memory default user. Add a new method that populates from external data instead:

```zig
/// Populate SecurityManager users/roles from externally loaded auth records.
/// Called after AuthGraphManager verifies the HMAC chain.
pub fn hydrateFromStorage(self: *Self, users: []const StorageUser, roles: []const StorageRole) !void {
    for (users) |u| {
        const user_id = self.next_user_id;
        self.next_user_id += 1;
        try self.users.put(user_id, User{
            .username = u.username,
            .password_hash = u.password_hash,
            .is_active = u.is_active,
            .is_superuser = u.is_superuser,
            .password_reset_required = u.password_reset_required,
            // ...
        });
    }
    // Similar for roles
}
```

**Step 2: Modify `server_init.initialize()` startup sequence**

After WAL init (line ~210), before SecurityManager init (line ~259):

```zig
// Load and verify auth from graph store
const auth_mgr = try auth_graph_manager.AuthGraphManager.init(allocator, store);
const hmac_key = auth_mgr.resolveHmacKey() catch |err| {
    log.err("Cannot resolve HMAC key for auth verification", .{Attr.string("error", @errorName(err))});
    return err; // Server refuses to start
};

if (auth_mgr.hasAuthRecords()) {
    auth_mgr.verifyChain(&hmac_key) catch |err| {
        log.err("AUTH TAMPER DETECTED - HMAC chain verification failed", .{Attr.string("error", @errorName(err))});
        return err; // Server refuses to start
    };
    log.info("Auth HMAC chain verified successfully", .{});
} else {
    // First boot: bootstrap admin
    const result = try auth_mgr.bootstrapDefaultAdmin(&hmac_key);
    std.debug.print("\n*** GENERATED ADMIN PASSWORD (change immediately): {s} ***\n", .{result.password});
}
```

Then modify SecurityManager init to hydrate from verified data:

```zig
if (env_config.abac_enabled) {
    var sm = try geode_auth.SecurityManager.initEmpty(allocator);
    try auth_mgr.hydrateSecurityManager(&sm);
    ctx.security_manager_storage = sm;
}
```

**Step 3: Add InitContext field for AuthGraphManager**

The `AuthGraphManager` needs to persist for runtime mutations:

```zig
auth_graph_manager: ?*auth_graph_manager.AuthGraphManager = null,
auth_graph_manager_storage: ?auth_graph_manager.AuthGraphManager = null,
```

**Step 4: Run build**

Run: `zig build test`
Expected: Compiles and passes (existing tests don't exercise server startup directly)

**Step 5: Commit**

```bash
git add src/server/server_init.zig src/security/geode_auth_lib.zig
git commit -m "feat(security): wire auth graph manager into server startup with HMAC verification"
```

---

## Task 5: Wire Runtime Auth Mutations Through Graph Store

**Files:**

- Modify: `src/security/geode_auth_lib.zig`
- Modify: `src/security/auth_graph_manager.zig`

Currently SecurityManager's `createUserDetailed`, `authenticateUser` (for login attempt tracking), and other mutation functions only modify in-memory state. They need to also write to the graph store and update the HMAC chain.

**Step 1: Add graph_manager reference to SecurityManager**

```zig
// In SecurityManager struct:
auth_graph_mgr: ?*AuthGraphManager = null,
hmac_key: ?[32]u8 = null,
```

**Step 2: Modify `createUserDetailed` to persist**

After creating the in-memory user, also persist to graph store:

```zig
// After successful in-memory creation:
if (self.auth_graph_mgr) |mgr| {
    try mgr.createUser(&self.hmac_key.?, username, email, password, is_superuser);
}
```

**Step 3: Modify `authenticateUser` to persist failed_login_attempts and lockout_until**

After updating in-memory counters, write to graph:

```zig
if (self.auth_graph_mgr) |mgr| {
    try mgr.updateUserLoginState(user_id, failed_attempts, lockout_until);
}
```

**Step 4: Modify password change/reset to persist**

After rehashing + updating in-memory:

```zig
if (self.auth_graph_mgr) |mgr| {
    try mgr.updateUserPassword(user_id, new_hash);
}
```

**Step 5: Run tests**

Run: `zig build test`
Expected: PASS — existing SecurityManager tests don't inject a graph manager, so `auth_graph_mgr` is null and the new code paths are skipped

**Step 6: Commit**

```bash
git add src/security/geode_auth_lib.zig src/security/auth_graph_manager.zig
git commit -m "feat(security): route SecurityManager mutations through graph store with HMAC updates"
```

---

## Task 6: Remove auth_state.zig and Update CLI Commands

**Files:**

- Delete: `src/security/auth_state.zig`
- Modify: `src/lib.zig` (remove `auth_state` export)
- Modify: `src/cli/user_mgmt_cli.zig`
- Modify: `src/cli/auth_cli.zig`
- Modify: `src/cli/authn_cli.zig`
- Modify: `src/cli/session_cli.zig`
- Modify: `src/cli/apikey_cli.zig`
- Modify: `src/cli/mtls_cli.zig`
- Modify: `src/cli/main.zig`
- Modify: `src/security/user_management.zig`

**Step 1: Remove `auth_state` from `src/lib.zig` exports**

Remove the public declaration that exposes `auth_state`.

**Step 2: Update CLI commands to use graph store backend**

Each CLI file that currently does `var state = try auth_state.State.load(allocator)` needs to be rewritten to:

1. Try connecting to running server over QUIC (online path)
2. If offline: open graph store directly, load HMAC key, verify chain
3. Perform the operation through `AuthGraphManager`

The general pattern for each CLI command:

```zig
// Replace:
//   var state = try auth_state.State.load(allocator);
//   defer state.deinit();
// With:
var mgr = try getAuthManager(allocator, data_dir);
defer mgr.deinit();
```

Where `getAuthManager` opens graph store directly (offline mode).

**Step 3: For `authn_cli.zig`** — this uses `auth_state.resolveStatePath` for `geode_authn_state.db`. This is a separate file for authentication provider config, not user credentials. Keep the path resolution utility but move it out of auth_state.zig into a general utility, or inline it.

**Step 4: Delete `src/security/auth_state.zig`**

**Step 5: Run build to find all remaining references**

Run: `zig build test 2>&1 | grep "auth_state"`
Expected: No references remain (all resolved)

**Step 6: Run full test suite**

Run: `zig build test`
Expected: PASS

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor(security): remove auth_state.zig, unify CLI commands on graph store backend"
```

---

## Task 7: Add New CLI Auth Commands

**Files:**

- Create: `src/cli/auth_init_cli.zig`
- Modify: `src/cli/main.zig` (register new subcommands)

**Step 1: Implement `geode auth init`**

```zig
/// Bootstrap admin user into graph store (offline).
pub fn cmdAuthInit(allocator: Allocator, argv: [][:0]u8, start_idx: usize) !void {
    const data_dir = parseDataDirFlag(argv, start_idx);
    graph_store.setDataDirOverride(allocator, data_dir);
    const store = graph_store.getGlobalStore(allocator);
    var mgr = try AuthGraphManager.init(allocator, store);
    defer mgr.deinit();

    const hmac_key = try mgr.resolveHmacKey();
    if (mgr.hasAuthRecords()) {
        std.debug.print("Error: auth records already exist. Use 'geode auth reseal' to recompute chain.\n", .{});
        std.process.exit(1);
    }
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    std.debug.print("Admin user created: {s}\nGenerated password: {s}\n", .{ result.username, result.password });
    std.debug.print("WARNING: Change this password immediately after first login.\n", .{});
}
```

**Step 2: Implement `geode auth reseal`**

```zig
pub fn cmdAuthReseal(allocator: Allocator, argv: [][:0]u8, start_idx: usize) !void {
    const data_dir = parseDataDirFlag(argv, start_idx);
    // Open graph store, resolve key, recompute entire chain
    // ...
    std.debug.print("HMAC chain resealed successfully ({d} records).\n", .{count});
}
```

**Step 3: Implement `geode auth verify`**

```zig
pub fn cmdAuthVerify(allocator: Allocator, argv: [][:0]u8, start_idx: usize) !void {
    const data_dir = parseDataDirFlag(argv, start_idx);
    // Open graph store, resolve key, verify chain
    // ...
    std.debug.print("HMAC chain verified: {d} records, integrity OK.\n", .{count});
}
```

**Step 4: Register in `src/cli/main.zig`**

Add `"auth"` subcommand dispatching to `init`, `reseal`, `verify`.

**Step 5: Run build**

Run: `zig build test`
Expected: PASS

**Step 6: Commit**

```bash
git add src/cli/auth_init_cli.zig src/cli/main.zig
git commit -m "feat(cli): add geode auth init/reseal/verify commands for offline auth management"
```

---

## Task 8: Consolidate Argon2id Implementation

**Files:**

- Modify: `src/security/user_management.zig`
- Modify: `src/security/geode_auth_lib.zig`

**Step 1: Identify the two Argon2id implementations**

- `geode_auth_lib.zig:703-761`: t=2, m=19456, p=1 (OWASP minimum)
- `user_management.zig:115-175`: t=3, m=65536, p=4

**Step 2: Remove duplicate from user_management.zig**

Make `user_management.zig` call `geode_auth_lib.hashPassword()` instead of having its own implementation. If `user_management.zig` has callers that depend on the different parameters, update them.

**Step 3: Run tests**

Run: `zig build test`
Expected: PASS

**Step 4: Commit**

```bash
git add src/security/user_management.zig src/security/geode_auth_lib.zig
git commit -m "refactor(security): consolidate Argon2id into single implementation in geode_auth_lib"
```

---

## Task 9: Periodic HMAC Verification Background Thread

**Files:**

- Modify: `src/security/auth_graph_manager.zig`
- Modify: `src/server/server_init.zig`

**Step 1: Add background verification thread**

```zig
pub fn startPeriodicVerification(self: *Self, hmac_key: *const [32]u8, interval_minutes: u32) void {
    self.verify_thread = std.Thread.spawn(.{}, periodicVerifyLoop, .{ self, hmac_key, interval_minutes }) catch |err| {
        log.err("Failed to start HMAC verification thread", .{Attr.string("error", @errorName(err))});
        return;
    };
}

fn periodicVerifyLoop(self: *Self, hmac_key: *const [32]u8, interval_minutes: u32) void {
    while (!self.shutdown.load(.acquire)) {
        std.Thread.sleep(interval_minutes * 60 * std.time.ns_per_s);
        if (self.shutdown.load(.acquire)) break;
        self.verifyChain(hmac_key) catch |err| {
            log.err("PERIODIC HMAC CHECK FAILED - POSSIBLE TAMPERING", .{Attr.string("error", @errorName(err))});
        };
    }
}
```

**Step 2: Start thread after successful startup verification**

In `server_init.zig`, after HMAC chain verified:

```zig
auth_mgr.startPeriodicVerification(&hmac_key, 5); // every 5 minutes
```

**Step 3: Add shutdown signal to deinit**

**Step 4: Run tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/security/auth_graph_manager.zig src/server/server_init.zig
git commit -m "feat(security): add periodic HMAC chain verification background thread"
```

---

## Task 10: HMAC Key File Generation

**Files:**

- Modify: `src/security/auth_graph_manager.zig`

When neither `GEODE_AUTH_HMAC_KEY` env var nor `GEODE_TDE_KEY` is available, generate a random HMAC key and write it to `.geode_hmac_key` in the data directory with 0o600 permissions.

**Step 1: Write failing test**

```zig
test "resolveHmacKey generates key file when no env vars set" {
    // Create temp data dir, verify .geode_hmac_key is created
    // ...
}
```

**Step 2: Implement key file generation in resolveHmacKey**

```zig
pub fn resolveHmacKey(self: *Self, data_dir: []const u8) ![32]u8 {
    // 1. Check GEODE_AUTH_HMAC_KEY env
    // 2. Check GEODE_TDE_KEY env → HKDF derive
    // 3. Check .geode_hmac_key file → read
    // 4. Generate random key → write to .geode_hmac_key
    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);
    // Write to file with 0o600 permissions
    // ...
    return key;
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: PASS

**Step 4: Commit**

```bash
git add src/security/auth_graph_manager.zig
git commit -m "feat(security): auto-generate HMAC key file when no key source available"
```

---

## Task 11: Update Existing Tests

**Files:**

- Modify: any test files that reference `auth_state`
- Modify: geodetestlab specs that rely on `auth_state.db` setup

**Step 1: Search for test files referencing auth_state**

Run: `grep -r "auth_state" src/ --include="*.zig" -l`

**Step 2: Update each test to use the new AuthGraphManager/graph store path**

**Step 3: Update geodetestlab test harness if it creates auth_state.db for test setup**

The test harness likely needs to:

- Let the server auto-bootstrap admin on first start
- Use the generated admin password for test authentication
- OR use `geode auth init` before starting the test server

**Step 4: Run full test suite**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A
git commit -m "test(security): update tests for internal auth storage migration"
```

---

## Task 12: Final Verification & Cleanup

**Files:**

- Verify: no remaining references to `auth_state.db`, `geode_auth_state`, or the old state directory
- Verify: `zig build test` passes
- Verify: cross-compilation succeeds

**Step 1: Search for stale references**

Run:

```bash
grep -r "auth_state" src/ --include="*.zig"
grep -r "geode_auth_state" src/ --include="*.zig"
grep -r "AUTH_STATE_FILE" src/ --include="*.zig"
grep -r "resolveStateDir" src/ --include="*.zig"  # only authn_cli should remain
```

**Step 2: Run full test suite**

Run: `zig build test`
Expected: PASS with zero auth_state references

**Step 3: Run cross-compilation check**

Run: `make cross-compile` (if available) or `zig build -Dtarget=x86_64-linux`
Expected: PASS

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore(security): final cleanup of internal auth storage migration"
```

---

## Summary of File Changes

| Action | File | Task |
|--------|------|------|
| Create | `src/security/auth_hmac.zig` | 1 |
| Create | `src/security/auth_graph_manager.zig` | 3 |
| Create | `src/cli/auth_init_cli.zig` | 7 |
| Modify | `src/storage/user_storage.zig` | 2 |
| Modify | `src/server/server_init.zig` | 4, 9 |
| Modify | `src/security/geode_auth_lib.zig` | 4, 5, 8 |
| Modify | `src/security/user_management.zig` | 6, 8 |
| Modify | `src/lib.zig` | 1, 3, 6 |
| Modify | `src/cli/main.zig` | 6, 7 |
| Modify | `src/cli/user_mgmt_cli.zig` | 6 |
| Modify | `src/cli/auth_cli.zig` | 6 |
| Modify | `src/cli/authn_cli.zig` | 6 |
| Modify | `src/cli/session_cli.zig` | 6 |
| Modify | `src/cli/apikey_cli.zig` | 6 |
| Modify | `src/cli/mtls_cli.zig` | 6 |
| Delete | `src/security/auth_state.zig` | 6 |

## Dependency Order

```
Task 1 (HMAC module) ─────────────┐
                                   ├──> Task 3 (AuthGraphManager) ──> Task 4 (server startup) ──> Task 5 (runtime mutations)
Task 2 (UserStorage HMAC fields) ──┘                                                              │
                                                                                                   ├──> Task 9 (periodic verify)
Task 8 (consolidate Argon2id) ── independent, can run in parallel                                  │
                                                                                                   ├──> Task 6 (remove auth_state + CLI)
Task 10 (HMAC key file) ── after Task 3                                                            │
                                                                                                   ├──> Task 7 (new CLI commands)
                                                                                                   │
                                                                                                   └──> Task 11 (update tests) ──> Task 12 (final cleanup)
```
