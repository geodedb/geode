// CANARY: REQ=REQ-AUTH-GRAPH-MGR-001; FEATURE="AuthGraphManager"; ASPECT=Orchestration; STATUS=TESTED; OWNER=security; UPDATED=2026-02-24
//! Orchestration layer for the HMAC-authenticated security graph.
//!
//! Ties together `auth_hmac` (crypto), `UserStorageBackend` (persistence), and
//! Argon2id password hashing into a single manager that handles:
//!
//! - HMAC key resolution (env var / TDE derivation / key-file)
//! - Chain verification and sealing
//! - Default admin bootstrap
//! - HMAC-aware user creation

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_store = @import("geode").graph_store;
const auth_hmac = @import("geode").auth_hmac;
const user_storage = @import("user_storage");
const UserStorageBackend = user_storage.UserStorageBackend;
const logging = @import("logging");
const log = logging.scoped("auth_graph_manager");
const Attr = logging.Attr;

const SECURITY_GRAPH_NAME = "__geode_security";
const HAS_ROLE_EDGE = "HAS_ROLE";

/// Result of HMAC key resolution.
pub const HmacKeyResult = struct {
    key: [32]u8,
    key_id: []const u8, // "env", "tde-derived", or "file"
};

/// Result of bootstrapping the default admin user.
pub const BootstrapResult = struct {
    username: []const u8,
    password: []const u8, // generated plain text password (caller prints to stderr)
    user_id: u64,
};

pub const AuthGraphManager = struct {
    allocator: Allocator,
    storage: UserStorageBackend,
    next_user_id: u64, // track next available user ID

    const Self = @This();

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !Self {
        var storage = try UserStorageBackend.init(allocator, store);

        // Scan existing users to find max ID
        var max_id: u64 = 0;
        var it = storage.userIterator();
        while (it.next()) |record| {
            if (record.id > max_id) max_id = record.id;
        }

        return Self{
            .allocator = allocator,
            .storage = storage,
            .next_user_id = max_id + 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.storage.deinit();
    }

    // -- HMAC Key Resolution --

    /// Resolve HMAC signing key from available sources.
    ///
    /// Resolution order:
    /// 1. `GEODE_AUTH_HMAC_KEY` env var (64-char hex -> 32 bytes)
    /// 2. `GEODE_TDE_KEY` env var -> derive via auth_hmac.deriveHmacKeyFromTde
    /// 3. `.geode_hmac_key` file in data directory (32 raw bytes, 0o600)
    /// 4. error.NoHmacKeyAvailable
    pub fn resolveHmacKey(allocator: Allocator, data_dir: ?[]const u8) !HmacKeyResult {
        // 1. Try GEODE_AUTH_HMAC_KEY env var
        if (std.process.getEnvVarOwned(allocator, "GEODE_AUTH_HMAC_KEY")) |env_val| {
            defer allocator.free(env_val);
            if (env_val.len == 64) {
                var key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key, env_val) catch {
                    log.warn("GEODE_AUTH_HMAC_KEY contains invalid hex", &.{});
                    return error.NoHmacKeyAvailable;
                };
                return HmacKeyResult{ .key = key, .key_id = "env" };
            } else {
                log.warn("GEODE_AUTH_HMAC_KEY must be exactly 64 hex characters", &.{
                    Attr.uint("actual_len", @intCast(env_val.len)),
                });
            }
        } else |_| {}

        // 2. Try GEODE_TDE_KEY env var -> HKDF derivation
        if (std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |tde_val| {
            defer allocator.free(tde_val);
            if (tde_val.len == 64) {
                var tde_key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&tde_key, tde_val) catch {
                    log.warn("GEODE_TDE_KEY contains invalid hex", &.{});
                    return error.NoHmacKeyAvailable;
                };
                const derived = auth_hmac.deriveHmacKeyFromTde(&tde_key);
                return HmacKeyResult{ .key = derived, .key_id = "tde-derived" };
            }
        } else |_| {}

        // 3. Try .geode_hmac_key file in data directory
        if (data_dir) |dir| {
            const path = std.fmt.allocPrint(allocator, "{s}/.geode_hmac_key", .{dir}) catch
                return error.NoHmacKeyAvailable;
            defer allocator.free(path);

            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {},
                    else => {
                        log.warn("Failed to open HMAC key file", &.{
                            Attr.string("path", path),
                        });
                    },
                }
                return error.NoHmacKeyAvailable;
            };
            defer file.close();

            var key: [32]u8 = undefined;
            const bytes_read = file.readAll(&key) catch {
                log.warn("Failed to read HMAC key file", &.{});
                return error.NoHmacKeyAvailable;
            };
            if (bytes_read != 32) {
                log.warn("HMAC key file must be exactly 32 bytes", &.{
                    Attr.uint("actual", @intCast(bytes_read)),
                });
                return error.NoHmacKeyAvailable;
            }
            return HmacKeyResult{ .key = key, .key_id = "file" };
        }

        return error.NoHmacKeyAvailable;
    }

    // -- Chain Verification --

    /// Verify the integrity of the entire auth chain.
    ///
    /// 1. Load AuthChainRoot
    /// 2. If no root but records exist -> error.MissingChainRoot
    /// 3. Verify record count
    /// 4. Recompute per-record HMACs and compare
    /// 5. Recompute chain hash and compare
    pub fn verifyChain(self: *Self, hmac_key: *const [32]u8) !void {
        const total_records = self.countAuthRecords();

        const chain_root = self.storage.loadChainRoot();

        if (chain_root == null) {
            if (total_records > 0) {
                return error.MissingChainRoot;
            }
            // No records, no root -> valid empty chain
            return;
        }

        const root = chain_root.?;

        // Verify record count
        if (root.record_count != total_records) {
            return error.RecordCountMismatch;
        }

        // Collect all record HMACs and verify each one
        var hmac_list: std.ArrayList([32]u8) = .empty;
        defer hmac_list.deinit(self.allocator);

        // Verify user records
        try self.verifyUserRecords(hmac_key, &hmac_list);

        // Verify role records
        try self.verifyRoleRecords(hmac_key, &hmac_list);

        // Verify permission records
        try self.verifyPermissionRecords(hmac_key, &hmac_list);

        // Verify policy records
        try self.verifyPolicyRecords(hmac_key, &hmac_list);

        // Sort HMACs by their byte representation for deterministic ordering
        sortHmacs(hmac_list.items);

        // Recompute chain hash
        const computed_chain_hash = auth_hmac.computeChainHash(hmac_key, hmac_list.items, total_records);
        const computed_hex = auth_hmac.hmacToHex(&computed_chain_hash);

        // Compare with stored chain hash
        const stored_hash = root.chain_hash[0..root.chain_hash_len];
        if (!std.mem.eql(u8, &computed_hex, stored_hash)) {
            return error.ChainHashMismatch;
        }
    }

    fn verifyUserRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.userIterator();
        while (it.next()) |record| {
            const computed = computeUserHmac(hmac_key, record);

            // Get stored HMAC from graph node
            const node_id = self.storage.user_nodes.get(record.id) orelse continue;
            const stored_hmac_prop = self.storage.store.getNodeProperty(node_id, "hmac");
            if (stored_hmac_prop == null or stored_hmac_prop.? != .String) {
                return error.RecordHmacMismatch;
            }
            const stored_hex = stored_hmac_prop.?.String;
            const computed_hex = auth_hmac.hmacToHex(&computed);
            if (!std.mem.eql(u8, &computed_hex, stored_hex)) {
                return error.RecordHmacMismatch;
            }

            try hmac_list.append(self.allocator, computed);
        }
    }

    fn verifyRoleRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.roleIterator();
        while (it.next()) |record| {
            const computed = computeRoleHmac(hmac_key, record);

            const node_id = self.storage.role_nodes.get(record.id) orelse continue;
            const stored_hmac_prop = self.storage.store.getNodeProperty(node_id, "hmac");
            if (stored_hmac_prop == null or stored_hmac_prop.? != .String) {
                return error.RecordHmacMismatch;
            }
            const stored_hex = stored_hmac_prop.?.String;
            const computed_hex = auth_hmac.hmacToHex(&computed);
            if (!std.mem.eql(u8, &computed_hex, stored_hex)) {
                return error.RecordHmacMismatch;
            }

            try hmac_list.append(self.allocator, computed);
        }
    }

    fn verifyPermissionRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.permissionIterator();
        while (it.next()) |record| {
            const computed = computePermissionHmac(hmac_key, record);

            const node_id = self.storage.permission_nodes.get(record.id) orelse continue;
            const stored_hmac_prop = self.storage.store.getNodeProperty(node_id, "hmac");
            if (stored_hmac_prop == null or stored_hmac_prop.? != .String) {
                return error.RecordHmacMismatch;
            }
            const stored_hex = stored_hmac_prop.?.String;
            const computed_hex = auth_hmac.hmacToHex(&computed);
            if (!std.mem.eql(u8, &computed_hex, stored_hex)) {
                return error.RecordHmacMismatch;
            }

            try hmac_list.append(self.allocator, computed);
        }
    }

    fn verifyPolicyRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.policyIterator();
        while (it.next()) |record| {
            const computed = computePolicyHmac(hmac_key, record);

            const node_id = self.storage.policy_nodes.get(record.id) orelse continue;
            const stored_hmac_prop = self.storage.store.getNodeProperty(node_id, "hmac");
            if (stored_hmac_prop == null or stored_hmac_prop.? != .String) {
                return error.RecordHmacMismatch;
            }
            const stored_hex = stored_hmac_prop.?.String;
            const computed_hex = auth_hmac.hmacToHex(&computed);
            if (!std.mem.eql(u8, &computed_hex, stored_hex)) {
                return error.RecordHmacMismatch;
            }

            try hmac_list.append(self.allocator, computed);
        }
    }

    // -- Chain Sealing --

    /// Recompute all per-record HMACs and chain hash.
    /// Used after mutations or by `geode auth reseal`.
    pub fn sealChain(self: *Self, hmac_key: *const [32]u8) !void {
        var hmac_list: std.ArrayList([32]u8) = .empty;
        defer hmac_list.deinit(self.allocator);

        // Seal user records
        try self.sealUserRecords(hmac_key, &hmac_list);

        // Seal role records
        try self.sealRoleRecords(hmac_key, &hmac_list);

        // Seal permission records
        try self.sealPermissionRecords(hmac_key, &hmac_list);

        // Seal policy records
        try self.sealPolicyRecords(hmac_key, &hmac_list);

        // Sort HMACs for deterministic chain hash
        sortHmacs(hmac_list.items);

        const total_records = self.countAuthRecords();
        const chain_hash = auth_hmac.computeChainHash(hmac_key, hmac_list.items, total_records);
        const chain_hash_hex = auth_hmac.hmacToHex(&chain_hash);

        try self.storage.persistChainRoot(&chain_hash_hex, total_records, "sealed");
    }

    fn sealUserRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        // Collect user IDs first to avoid iterator invalidation
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.user_cache.keyIterator();
            while (it.next()) |key| {
                try ids.append(self.allocator, key.*);
            }
        }

        for (ids.items) |user_id| {
            const record = self.storage.user_cache.get(user_id) orelse continue;
            const computed = computeUserHmac(hmac_key, &record);
            const computed_hex = auth_hmac.hmacToHex(&computed);

            // Store HMAC on graph node
            const node_id = self.storage.user_nodes.get(user_id) orelse continue;
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });

            try hmac_list.append(self.allocator, computed);
        }
        self.storage.store.saveIfDirty();
    }

    fn sealRoleRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.role_cache.keyIterator();
            while (it.next()) |key| {
                try ids.append(self.allocator, key.*);
            }
        }

        for (ids.items) |role_id| {
            const record = self.storage.role_cache.get(role_id) orelse continue;
            const computed = computeRoleHmac(hmac_key, &record);
            const computed_hex = auth_hmac.hmacToHex(&computed);

            const node_id = self.storage.role_nodes.get(role_id) orelse continue;
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });

            try hmac_list.append(self.allocator, computed);
        }
        self.storage.store.saveIfDirty();
    }

    fn sealPermissionRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.permission_cache.keyIterator();
            while (it.next()) |key| {
                try ids.append(self.allocator, key.*);
            }
        }

        for (ids.items) |perm_id| {
            const record = self.storage.permission_cache.get(perm_id) orelse continue;
            const computed = computePermissionHmac(hmac_key, &record);
            const computed_hex = auth_hmac.hmacToHex(&computed);

            const node_id = self.storage.permission_nodes.get(perm_id) orelse continue;
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });

            try hmac_list.append(self.allocator, computed);
        }
        self.storage.store.saveIfDirty();
    }

    fn sealPolicyRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.policy_cache.keyIterator();
            while (it.next()) |key| {
                try ids.append(self.allocator, key.*);
            }
        }

        for (ids.items) |policy_id| {
            const record = self.storage.policy_cache.get(policy_id) orelse continue;
            const computed = computePolicyHmac(hmac_key, &record);
            const computed_hex = auth_hmac.hmacToHex(&computed);

            const node_id = self.storage.policy_nodes.get(policy_id) orelse continue;
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });

            try hmac_list.append(self.allocator, computed);
        }
        self.storage.store.saveIfDirty();
    }

    // -- Bootstrap Default Admin --

    /// Create the initial admin user with a random password.
    ///
    /// 1. Check `GEODE_ADMIN_USERNAME` env (default: "geode")
    /// 2. Generate random 32-char hex password
    /// 3. Hash with Argon2id
    /// 4. Persist user + "admin" role + HAS_ROLE edge
    /// 5. Seal chain
    /// 6. Return BootstrapResult (caller prints password to stderr)
    pub fn bootstrapDefaultAdmin(self: *Self, hmac_key: *const [32]u8) !BootstrapResult {
        // 1. Resolve admin username
        const username = if (std.process.getEnvVarOwned(self.allocator, "GEODE_ADMIN_USERNAME")) |name| name else |_| try self.allocator.dupe(u8, "geode");

        // 2. Generate random 32-char hex password
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const password = try self.allocator.alloc(u8, 32);
        const hex_chars = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            password[i * 2] = hex_chars[byte >> 4];
            password[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        // 3. Hash password with Argon2id
        const password_hash = try hashPasswordArgon2id(self.allocator, password);
        defer self.allocator.free(password_hash);

        // 4. Create User node with HMAC
        const user_id = self.next_user_id;
        self.next_user_id += 1;

        // Set extra fields before persisting
        try self.storage.persistUserWithHmac(user_id, username, "admin@localhost", password_hash, "", hmac_key);

        // Update the user record with additional flags
        var record = self.storage.getUser(user_id) orelse return error.UserNotFound;
        record.is_superuser = true;
        record.is_default_user = true;
        record.password_reset_required = true;
        record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
        record.password_changed_at = std.time.milliTimestamp();
        try self.storage.user_cache.put(user_id, record);
        try self.storage.upsertUserNode(record);

        // Re-persist HMAC with updated fields
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);

        // 5. Create "admin" Role + HAS_ROLE edge
        const role_id: u64 = 1;
        try self.storage.persistRole(role_id, "admin", "Default administrator role", 0, 100, true);
        try self.recomputeAndStoreRoleHmac(role_id, hmac_key);

        // Create HAS_ROLE edge
        const user_node_id = self.storage.user_nodes.get(user_id) orelse return error.UserNotFound;
        const role_node_id = self.storage.role_nodes.get(role_id) orelse return error.RoleNotFound;
        _ = self.storage.store.createEdgeWithGraph(user_node_id, role_node_id, HAS_ROLE_EDGE, SECURITY_GRAPH_NAME) catch |err| {
            log.warn("Failed to create HAS_ROLE edge", &.{
                Attr.string("error", @errorName(err)),
            });
            return err;
        };

        // 6. Seal chain
        try self.sealChain(hmac_key);

        return BootstrapResult{
            .username = username,
            .password = password,
            .user_id = user_id,
        };
    }

    // -- User Creation --

    /// Create a new user with HMAC and reseal the chain.
    pub fn createUser(self: *Self, hmac_key: *const [32]u8, username: []const u8, email: []const u8, password_hash: []const u8, is_superuser: bool) !u64 {
        const user_id = self.next_user_id;
        self.next_user_id += 1;

        // Persist with HMAC
        try self.storage.persistUserWithHmac(user_id, username, email, password_hash, "", hmac_key);

        // Set is_superuser if needed
        if (is_superuser) {
            var record = self.storage.getUser(user_id) orelse return error.UserNotFound;
            record.is_superuser = true;
            record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
            try self.storage.user_cache.put(user_id, record);
            try self.storage.upsertUserNode(record);
            try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        }

        // Reseal chain
        try self.sealChain(hmac_key);

        return user_id;
    }

    // -- Has Auth Records Check --

    /// Returns true if any User nodes exist in __geode_security.
    pub fn hasAuthRecords(self: *Self) bool {
        return self.storage.user_cache.count() > 0;
    }

    // -- Internal Helpers --

    fn countAuthRecords(self: *Self) u64 {
        return self.storage.user_cache.count() +
            self.storage.role_cache.count() +
            self.storage.permission_cache.count() +
            self.storage.policy_cache.count();
    }

    fn recomputeAndStoreUserHmac(self: *Self, user_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.user_cache.get(user_id) orelse return error.UserNotFound;
        const computed = computeUserHmac(hmac_key, &record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        const node_id = self.storage.user_nodes.get(user_id) orelse return error.UserNotFound;
        try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
        self.storage.store.saveIfDirty();
    }

    fn recomputeAndStoreRoleHmac(self: *Self, role_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.role_cache.get(role_id) orelse return error.RoleNotFound;
        const computed = computeRoleHmac(hmac_key, &record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        const node_id = self.storage.role_nodes.get(role_id) orelse return error.RoleNotFound;
        try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
        self.storage.store.saveIfDirty();
    }
};

// -- HMAC Computation Helpers (module-level) --

fn computeUserHmac(hmac_key: *const [32]u8, record: *const UserStorageBackend.UserRecord) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{record.id}) catch "0";
    var created_buf: [20]u8 = undefined;
    const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
    var updated_buf: [20]u8 = undefined;
    const updated_str = std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) catch "0";
    var pwd_changed_buf: [20]u8 = undefined;
    const pwd_changed_str = std.fmt.bufPrint(&pwd_changed_buf, "{d}", .{record.password_changed_at}) catch "0";
    var lockout_buf: [20]u8 = undefined;
    const lockout_str = std.fmt.bufPrint(&lockout_buf, "{d}", .{record.lockout_until}) catch "0";
    var last_login_buf: [20]u8 = undefined;
    const last_login_str = std.fmt.bufPrint(&last_login_buf, "{d}", .{record.last_login}) catch "0";
    var failed_buf: [10]u8 = undefined;
    const failed_str = std.fmt.bufPrint(&failed_buf, "{d}", .{record.failed_login_attempts}) catch "0";

    const mfa_secret = record.getMFASecret() orelse "";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "created_at", .value = created_str },
        .{ .key = "email", .value = record.getEmail() },
        .{ .key = "failed_login_attempts", .value = failed_str },
        .{ .key = "hash_algorithm", .value = record.getHashAlgorithm() },
        .{ .key = "id", .value = id_str },
        .{ .key = "is_active", .value = if (record.is_active) "true" else "false" },
        .{ .key = "is_default_user", .value = if (record.is_default_user) "true" else "false" },
        .{ .key = "is_superuser", .value = if (record.is_superuser) "true" else "false" },
        .{ .key = "last_login", .value = last_login_str },
        .{ .key = "lockout_until", .value = lockout_str },
        .{ .key = "mfa_enabled", .value = if (record.mfa_enabled) "true" else "false" },
        .{ .key = "mfa_secret", .value = mfa_secret },
        .{ .key = "password_changed_at", .value = pwd_changed_str },
        .{ .key = "password_hash", .value = record.getPasswordHash() },
        .{ .key = "password_reset_required", .value = if (record.password_reset_required) "true" else "false" },
        .{ .key = "salt", .value = if (sliceUntilZero(&record.salt)) |s| s else "" },
        .{ .key = "updated_at", .value = updated_str },
        .{ .key = "username", .value = record.getUsername() },
    };

    return auth_hmac.computeRecordHmac(hmac_key, &props);
}

fn computeRoleHmac(hmac_key: *const [32]u8, record: *const UserStorageBackend.RoleRecord) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{record.id}) catch "0";
    var created_buf: [20]u8 = undefined;
    const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
    var updated_buf: [20]u8 = undefined;
    const updated_str = std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) catch "0";
    var parent_buf: [20]u8 = undefined;
    const parent_str = std.fmt.bufPrint(&parent_buf, "{d}", .{record.parent_role}) catch "0";
    var priority_buf: [10]u8 = undefined;
    const priority_str = std.fmt.bufPrint(&priority_buf, "{d}", .{record.priority}) catch "0";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "created_at", .value = created_str },
        .{ .key = "description", .value = record.getDescription() },
        .{ .key = "id", .value = id_str },
        .{ .key = "is_system", .value = if (record.is_system) "true" else "false" },
        .{ .key = "name", .value = record.getName() },
        .{ .key = "parent_role", .value = parent_str },
        .{ .key = "priority", .value = priority_str },
        .{ .key = "updated_at", .value = updated_str },
    };

    return auth_hmac.computeRecordHmac(hmac_key, &props);
}

fn computePermissionHmac(hmac_key: *const [32]u8, record: *const UserStorageBackend.PermissionRecord) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{record.id}) catch "0";
    var created_buf: [20]u8 = undefined;
    const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
    var action_buf: [10]u8 = undefined;
    const action_str = std.fmt.bufPrint(&action_buf, "{d}", .{record.action}) catch "0";

    const conditions = record.getConditions() orelse "";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "action", .value = action_str },
        .{ .key = "conditions", .value = conditions },
        .{ .key = "created_at", .value = created_str },
        .{ .key = "id", .value = id_str },
        .{ .key = "name", .value = record.getName() },
        .{ .key = "resource", .value = record.getResource() },
    };

    return auth_hmac.computeRecordHmac(hmac_key, &props);
}

fn computePolicyHmac(hmac_key: *const [32]u8, record: *const UserStorageBackend.PolicyRecord) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{record.id}) catch "0";
    var created_buf: [20]u8 = undefined;
    const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
    var updated_buf: [20]u8 = undefined;
    const updated_str = std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) catch "0";
    var operation_buf: [10]u8 = undefined;
    const operation_str = std.fmt.bufPrint(&operation_buf, "{d}", .{record.operation}) catch "0";
    var audit_buf: [10]u8 = undefined;
    const audit_str = std.fmt.bufPrint(&audit_buf, "{d}", .{record.audit_level}) catch "0";
    var created_by_buf: [20]u8 = undefined;
    const created_by_str = std.fmt.bufPrint(&created_by_buf, "{d}", .{record.created_by}) catch "0";

    const using_clause = record.getUsingClause() orelse "";
    const check_clause = record.getCheckClause() orelse "";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "audit_level", .value = audit_str },
        .{ .key = "check_clause", .value = check_clause },
        .{ .key = "created_at", .value = created_str },
        .{ .key = "created_by", .value = created_by_str },
        .{ .key = "description", .value = record.getDescription() },
        .{ .key = "enabled", .value = if (record.enabled) "true" else "false" },
        .{ .key = "graph", .value = record.getGraph() },
        .{ .key = "id", .value = id_str },
        .{ .key = "name", .value = record.getName() },
        .{ .key = "operation", .value = operation_str },
        .{ .key = "permissive", .value = if (record.permissive) "true" else "false" },
        .{ .key = "table", .value = record.getTable() },
        .{ .key = "updated_at", .value = updated_str },
        .{ .key = "using_clause", .value = using_clause },
    };

    return auth_hmac.computeRecordHmac(hmac_key, &props);
}

/// Sort HMACs by their byte representation for deterministic chain hash ordering.
fn sortHmacs(hmacs: [][32]u8) void {
    const Ctx = struct {
        pub fn lessThan(_: @This(), a: [32]u8, b: [32]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    };
    std.mem.sortUnstable([32]u8, hmacs, Ctx{}, Ctx.lessThan);
}

/// Hash a password using Argon2id with standard parameters.
/// Returns a PHC format string: $argon2id$v=19$m=19456,t=2,p=1$salt_hex$hash_hex
fn hashPasswordArgon2id(allocator: Allocator, password: []const u8) ![]const u8 {
    // Generate random 16-byte salt
    var salt: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);

    // OWASP recommended Argon2id parameters
    const argon2_params = std.crypto.pwhash.argon2.Params{
        .t = 2, // 2 iterations
        .m = 19456, // 19 MiB memory
        .p = 1, // 1 parallel lane
    };

    var hash: [32]u8 = undefined;
    std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        &salt,
        argon2_params,
        .argon2id,
    ) catch return error.HashingFailed;

    // Encode as hex strings
    const hex_chars = "0123456789abcdef";

    var salt_hex: [32]u8 = undefined;
    for (salt, 0..) |byte, i| {
        salt_hex[i * 2] = hex_chars[byte >> 4];
        salt_hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    // Compact format: "argon2id:<salt_hex>:<hash_hex>" (106 chars, fits in 127-char field)
    return std.fmt.allocPrint(
        allocator,
        "argon2id:{s}:{s}",
        .{ &salt_hex, &hash_hex },
    );
}

fn sliceUntilZero(bytes: []const u8) ?[]const u8 {
    var len: usize = 0;
    while (len < bytes.len) : (len += 1) {
        if (bytes[len] == 0) break;
    }
    if (len == 0) return null;
    return bytes[0..len];
}

// -- Tests --

const testing = std.testing;

test "resolveHmacKey returns NoHmacKeyAvailable when no source available" {
    // With no env vars set and no data dir, should fail
    const result = AuthGraphManager.resolveHmacKey(testing.allocator, null);
    try testing.expectError(error.NoHmacKeyAvailable, result);
}

test "hasAuthRecords returns false on empty store" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    try testing.expect(!mgr.hasAuthRecords());
}

test "bootstrapDefaultAdmin creates user + role + chain root with valid HMAC chain" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(result.username);
        testing.allocator.free(result.password);
    }

    // Verify user was created
    try testing.expect(mgr.hasAuthRecords());
    try testing.expect(std.mem.eql(u8, result.username, "geode"));
    try testing.expectEqual(@as(usize, 32), result.password.len);

    // Verify user is superuser and default
    const user = mgr.storage.getUser(result.user_id);
    try testing.expect(user != null);
    try testing.expect(user.?.is_superuser);
    try testing.expect(user.?.is_default_user);
    try testing.expect(user.?.password_reset_required);

    // Verify role was created
    const role = mgr.storage.getRole(1);
    try testing.expect(role != null);
    try testing.expect(std.mem.eql(u8, role.?.getName(), "admin"));

    // Verify chain root exists
    const chain_root = mgr.storage.loadChainRoot();
    try testing.expect(chain_root != null);
    try testing.expectEqual(@as(u64, 2), chain_root.?.record_count); // 1 user + 1 role
}

test "verifyChain passes after bootstrap" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(result.username);
        testing.allocator.free(result.password);
    }

    // Chain should verify successfully
    try mgr.verifyChain(&hmac_key);
}

test "verifyChain fails after tampering with a user property" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(result.username);
        testing.allocator.free(result.password);
    }

    // Tamper with user record: change is_superuser in cache
    var record = mgr.storage.getUser(result.user_id).?;
    record.is_superuser = false;
    try mgr.storage.user_cache.put(result.user_id, record);

    // Verify should fail
    try testing.expectError(error.RecordHmacMismatch, mgr.verifyChain(&hmac_key));
}

test "sealChain fixes a tampered chain" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(result.username);
        testing.allocator.free(result.password);
    }

    // Tamper with user record
    var record = mgr.storage.getUser(result.user_id).?;
    record.is_superuser = false;
    try mgr.storage.user_cache.put(result.user_id, record);
    try mgr.storage.upsertUserNode(record);

    // Verify should fail
    try testing.expectError(error.RecordHmacMismatch, mgr.verifyChain(&hmac_key));

    // Reseal should fix it
    try mgr.sealChain(&hmac_key);

    // Verify should pass now
    try mgr.verifyChain(&hmac_key);
}

test "createUser adds user and maintains valid chain" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;

    // Bootstrap first
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(bootstrap.username);
        testing.allocator.free(bootstrap.password);
    }

    // Create another user
    const pw_hash = try hashPasswordArgon2id(testing.allocator, "testpassword123");
    defer testing.allocator.free(pw_hash);

    const new_id = try mgr.createUser(&hmac_key, "alice", "alice@example.com", pw_hash, false);

    // Verify user exists
    const alice = mgr.storage.getUser(new_id);
    try testing.expect(alice != null);
    try testing.expect(std.mem.eql(u8, alice.?.getUsername(), "alice"));

    // Verify chain root count updated (admin user + admin role + alice)
    const chain_root = mgr.storage.loadChainRoot();
    try testing.expect(chain_root != null);
    try testing.expectEqual(@as(u64, 3), chain_root.?.record_count);

    // Verify chain integrity
    try mgr.verifyChain(&hmac_key);
}

test "verifyChain on empty store passes" {
    var store = graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    // Should not error - empty chain is valid
    try mgr.verifyChain(&hmac_key);
}

// CANARY: REQ=REQ-AUTH-GRAPH-MGR-002; FEATURE="AuthGraphManagerTests"; ASPECT=ChainIntegrity; STATUS=TESTED; TEST=test_bootstrapDefaultAdmin_creates_user; OWNER=security; UPDATED=2026-02-24
