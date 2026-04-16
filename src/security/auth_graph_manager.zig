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

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        _ = std.c.getrandom(buf.ptr, buf.len, 0);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const Allocator = std.mem.Allocator;
const geode = @import("geode");
const graph_store = geode.graph_store;
const audit_mod = geode.security.audit;
const auth_hmac = @import("auth_lib").hmac;
const geode_auth = @import("geode_auth");
const user_storage = @import("user_storage");
const pooled = @import("transport/thread_pool");
const UserStorageBackend = user_storage.UserStorageBackend;
const logging = @import("logging");
const log = logging.scoped("auth_graph_manager");
const Attr = logging.Attr;

const SECURITY_GRAPH_NAME = "__geode_security";
const HAS_ROLE_EDGE = "HAS_ROLE";
const geode_hkdf_config = auth_hmac.HkdfConfig{
    .salt = "geode-auth-hmac-v1",
    .info = "auth-chain-integrity",
};

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
    // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-001; FEATURE="PeriodicHmacVerification"; ASPECT=BackgroundThread; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
    shutdown: std.atomic.Value(bool),
    verify_pool: ?*pooled.ThreadPool = null,
    /// Owned copy of the HMAC key for the periodic verification thread.
    /// Stored in-struct so the thread can reference it without dangling pointers
    /// (the struct is moved by value during server initialization).
    hmac_key: [32]u8 = [_]u8{0} ** 32,
    verify_interval_minutes: u32 = 0,

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
            .shutdown = std.atomic.Value(bool).init(false),
            .verify_pool = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.requestShutdown();
        self.storage.deinit();
    }

    // -- Periodic HMAC Verification --

    // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-002; FEATURE="PeriodicHmacVerification"; ASPECT=BackgroundThread; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
    /// Spawn a background thread that periodically re-verifies the HMAC chain
    /// to detect runtime tampering.
    ///
    /// IMPORTANT: `self` must be at its FINAL memory location before calling
    /// this method. The spawned thread captures `self` by pointer — if the
    /// struct is moved after the thread starts, the pointer becomes dangling
    /// and the server will GPF when the thread wakes up.
    pub fn startPeriodicVerification(self: *Self, hmac_key: *const [32]u8, interval_minutes: u32) void {
        // Copy the key into the struct so the thread references owned memory
        // instead of a caller-provided pointer that may go out of scope.
        self.hmac_key = hmac_key.*;
        self.verify_interval_minutes = interval_minutes;
        const pool = pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 1,
            .queue_capacity = 4,
        }) catch |err| {
            log.err("Failed to initialize periodic HMAC verification pool", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };
        errdefer pool.deinit();
        pool.submitBlocking(.{
            .context = @ptrCast(self),
            .callback = runPeriodicVerifyLoop,
        }) catch |err| {
            pool.deinit();
            log.err("Failed to spawn periodic HMAC verification thread", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };
        self.verify_pool = pool;
        log.info("Periodic HMAC verification thread started", &.{
            Attr.uint("interval_minutes", @intCast(interval_minutes)),
        });
    }

    fn periodicVerifyLoop(self: *Self) void {
        while (!self.shutdown.load(.acquire)) {
            // Sleep in small increments so we can check shutdown flag
            var elapsed: u64 = 0;
            const target_ns = @as(u64, self.verify_interval_minutes) * 60 * std.time.ns_per_s;
            while (elapsed < target_ns and !self.shutdown.load(.acquire)) {
                {
                    const req = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
                    var rem: std.os.linux.timespec = undefined;
                    _ = std.os.linux.nanosleep(&req, &rem);
                }
                elapsed += std.time.ns_per_s;
            }
            if (self.shutdown.load(.acquire)) break;
            // Acquire the EXCLUSIVE write lock before reading graph data.
            //
            // verifyChain reads label_index (via getNodesByLabel) and node
            // properties (via getNodeProperty).  QUIC query handlers hold the
            // SHARED lock (lockShared) while executing MERGE statements that
            // call addNodeLabel → label_index.getOrPut(), which may rehash
            // and free the old backing array.
            //
            // Using acquireStoreLock() (shared / lockShared) was insufficient:
            // multiple shared-lock holders run concurrently, so the verify
            // thread and a query handler could still race on label_index.
            //
            // The exclusive write lock (lock()) blocks until all shared-lock
            // holders have released, and prevents new shared locks from being
            // acquired while it is held.  This fully serialises the verify
            // read against any concurrent MERGE writes.
            graph_store.acquireStoreWriteLock();
            const verify_result = self.verifyChain(&self.hmac_key);
            graph_store.releaseStoreWriteLock();
            verify_result catch |err| {
                log.err("PERIODIC HMAC CHECK FAILED - POSSIBLE TAMPERING", &.{Attr.string("error", @errorName(err))});
                continue;
            };
            log.debug("Periodic HMAC chain verification passed", &.{});
        }
    }

    /// Signal the periodic verification thread to stop and wait for it to finish.
    pub fn requestShutdown(self: *Self) void {
        self.shutdown.store(true, .release);
        if (self.verify_pool) |pool| {
            pool.deinit();
            self.verify_pool = null;
        }
    }

    fn runPeriodicVerifyLoop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.periodicVerifyLoop();
    }

    // -- HMAC Key Resolution --

    /// Resolve HMAC signing key from available sources.
    ///
    /// Resolution order:
    /// 1. `GEODE_AUTH_HMAC_KEY` env var (64-char hex -> 32 bytes)
    /// 2. `GEODE_TDE_KEY` env var -> derive via auth_hmac.deriveHmacKey
    /// 3. `.geode_hmac_key` file in data directory (64 hex chars or 32 raw bytes)
    /// 4. Auto-generate random 256-bit key -> write to `.geode_hmac_key` (0o600)
    /// 5. error.NoHmacKeyAvailable (only if no data_dir provided)
    pub fn resolveHmacKey(allocator: Allocator, data_dir: ?[]const u8) !HmacKeyResult {
        // 1. Try GEODE_AUTH_HMAC_KEY env var
        if (getEnvVarOwned(allocator, "GEODE_AUTH_HMAC_KEY")) |env_val| {
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
        if (getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |tde_val| {
            defer allocator.free(tde_val);
            if (tde_val.len == 64) {
                var tde_key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&tde_key, tde_val) catch {
                    log.warn("GEODE_TDE_KEY contains invalid hex", &.{});
                    return error.NoHmacKeyAvailable;
                };
                const derived = auth_hmac.deriveHmacKey(&tde_key, geode_hkdf_config);
                return HmacKeyResult{ .key = derived, .key_id = "tde-derived" };
            }
        } else |_| {}

        // 3. Try .geode_hmac_key file in data directory
        if (data_dir) |dir| {
            const path = std.fmt.allocPrint(allocator, "{s}/.geode_hmac_key", .{dir}) catch
                return error.NoHmacKeyAvailable;
            defer allocator.free(path);

            const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        // 4. Auto-generate a random 256-bit HMAC key and write to file
                        return autoGenerateHmacKeyFile(path);
                    },
                    else => {
                        log.warn("Failed to open HMAC key file", &.{
                            Attr.string("path", path),
                        });
                        return error.NoHmacKeyAvailable;
                    },
                }
            };
            const io_hr = std.Io.Threaded.global_single_threaded.io();
            defer file.close(io_hr);

            // Read hex-encoded key (64 hex chars = 32 bytes)
            var hex_buf: [64]u8 = undefined;
            const bytes_read = file.readPositionalAll(io_hr, &hex_buf, 0) catch {
                log.warn("Failed to read HMAC key file", &.{});
                return error.NoHmacKeyAvailable;
            };
            if (bytes_read == 64) {
                // Hex-encoded key file (64 hex chars -> 32 bytes)
                var key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key, &hex_buf) catch {
                    log.warn("HMAC key file contains invalid hex", &.{
                        Attr.string("path", path),
                    });
                    return error.NoHmacKeyAvailable;
                };
                return HmacKeyResult{ .key = key, .key_id = "file" };
            } else if (bytes_read == 32) {
                // Legacy raw-bytes key file (32 raw bytes)
                var key: [32]u8 = undefined;
                @memcpy(&key, hex_buf[0..32]);
                return HmacKeyResult{ .key = key, .key_id = "file" };
            } else {
                log.warn("HMAC key file must be exactly 64 hex chars or 32 raw bytes", &.{
                    Attr.uint("actual", @intCast(bytes_read)),
                });
                return error.NoHmacKeyAvailable;
            }
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
        const computed_chain_hash = computeChainHashChecked(hmac_key, hmac_list.items, total_records);
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
        const chain_hash = computeChainHashChecked(hmac_key, hmac_list.items, total_records);
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
        const username = if (getEnvVarOwned(self.allocator, "GEODE_ADMIN_USERNAME")) |name| name else |_| try self.allocator.dupe(u8, "geode");

        // 2. Use GEODE_ADMIN_PASSWORD from env if set, otherwise generate random 32-char hex password
        var password_from_env = false;
        const password = if (getEnvVarOwned(self.allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| pw_blk: {
            password_from_env = true;
            break :pw_blk env_pw;
        } else |_| blk: {
            var random_bytes: [16]u8 = undefined;
            compat_fillRandom(&random_bytes);
            const pw = try self.allocator.alloc(u8, 32);
            const hex_chars = "0123456789abcdef";
            for (random_bytes, 0..) |byte, i| {
                pw[i * 2] = hex_chars[byte >> 4];
                pw[i * 2 + 1] = hex_chars[byte & 0xf];
            }
            break :blk pw;
        };

        // 3. Hash password with Argon2id (canonical implementation)
        const password_hash = try geode_auth.hashPasswordArgon2id(self.allocator, password);
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
        record.password_reset_required = !password_from_env;
        record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
        record.password_changed_at = compat_milliTimestamp();
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

    pub fn countAuthRecords(self: *Self) u64 {
        // Cast each count() to u64 before summing. HashMap.count() returns u32
        // (HashMap.Size), so four-operand u32 addition can overflow when the
        // total exceeds ~4 billion records. Casting first lifts the arithmetic
        // to u64, preventing the panic in safe/debug builds.
        return @as(u64, self.storage.user_cache.count()) +
            @as(u64, self.storage.role_cache.count()) +
            @as(u64, self.storage.permission_cache.count()) +
            @as(u64, self.storage.policy_cache.count());
    }

    fn recomputeAndStoreUserHmac(self: *Self, user_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.user_cache.get(user_id) orelse return error.UserNotFound;
        const computed = computeUserHmac(hmac_key, &record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        const node_id = self.storage.user_nodes.get(user_id) orelse return error.UserNotFound;
        try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
    }

    fn recomputeAndStoreRoleHmac(self: *Self, role_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.role_cache.get(role_id) orelse return error.RoleNotFound;
        const computed = computeRoleHmac(hmac_key, &record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        const node_id = self.storage.role_nodes.get(role_id) orelse return error.RoleNotFound;
        try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
    }

    fn logSecurityGraphMutation(self: *Self, event_type: audit_mod.AuditEventType, action: []const u8, user_id: u64, username: []const u8, details: ?[]const u8) void {
        audit_mod.logSecurityGraphEvent(self.allocator, .{
            .event_type = event_type,
            .action = action,
            .user_id = user_id,
            .username = username,
            .details = details,
        });
    }

    pub fn upsertUserState(self: *Self, hmac_key: *const [32]u8, opts: UserStorageBackend.ManagedUserUpsert) !u64 {
        const version = try self.storage.upsertManagedUser(opts);
        try self.recomputeAndStoreUserHmac(opts.user_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "UPSERT_USER_STATE", opts.user_id, opts.username, null);
        return version;
    }

    pub fn assignUserRole(self: *Self, hmac_key: *const [32]u8, user_id: u64, role_id: u64) !u64 {
        const changed = try self.storage.assignUserRole(user_id, role_id);
        if (!changed) {
            const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
            return record.auth_version;
        }
        const version = try self.storage.bumpUserAuthVersion(user_id);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
        const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
        self.logSecurityGraphMutation(.configuration_change, "ASSIGN_ROLE", user_id, record.getUsername(), null);
        return version;
    }

    pub fn revokeUserRole(self: *Self, hmac_key: *const [32]u8, user_id: u64, role_id: u64) !u64 {
        const changed = try self.storage.revokeUserRole(user_id, role_id);
        if (!changed) {
            const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
            return record.auth_version;
        }
        const version = try self.storage.bumpUserAuthVersion(user_id);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
        const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
        self.logSecurityGraphMutation(.configuration_change, "REVOKE_ROLE", user_id, record.getUsername(), null);
        return version;
    }

    // -- Runtime Mutation Persistence (called via SecurityManager callbacks) --

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-006; FEATURE="Runtime Auth Graph Persistence"; ASPECT=LoginState; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
    /// Update a user record's login state (failed_attempts, lockout_until) in the graph store.
    /// Recomputes the record HMAC and reseals the chain.
    pub fn updateUserLoginState(self: *Self, hmac_key: *const [32]u8, user_id: u64, failed_attempts: u16, lockout_until: i64) !void {
        var record = self.storage.user_cache.get(user_id) orelse return error.UserNotFound;
        record.failed_login_attempts = failed_attempts;
        record.lockout_until = lockout_until;
        record.updated_at = compat_milliTimestamp();
        try self.storage.user_cache.put(user_id, record);
        try self.storage.upsertUserNode(record);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-007; FEATURE="Runtime Auth Graph Persistence"; ASPECT=PasswordChange; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
    /// Update a user record's password hash in the graph store.
    /// Recomputes the record HMAC and reseals the chain.
    pub fn updateUserPassword(self: *Self, hmac_key: *const [32]u8, user_id: u64, new_password_hash: []const u8) !u64 {
        var record = self.storage.user_cache.get(user_id) orelse return error.UserNotFound;
        record.password_hash_len = UserStorageBackend.copyIntoField(&record.password_hash, new_password_hash);
        record.password_changed_at = compat_milliTimestamp();
        record.updated_at = compat_milliTimestamp();
        record.auth_version += 1;
        try self.storage.user_cache.put(user_id, record);
        try self.storage.upsertUserNode(record);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "UPDATE_PASSWORD", user_id, record.getUsername(), null);
        return record.auth_version;
    }
};

// -- HMAC Key Auto-Generation (module-level) --

// CANARY: REQ=REQ-AUTH-HMAC-KEYGEN-001; FEATURE="HmacKeyAutoGeneration"; ASPECT=KeyFile; STATUS=TESTED; OWNER=security; UPDATED=2026-02-24
/// Auto-generate a random 256-bit HMAC key and write it to the given file path
/// as 64 hex characters with restricted permissions (0o600).
fn autoGenerateHmacKeyFile(path: []const u8) !HmacKeyResult {
    // Generate cryptographically random 32-byte key
    var key: [32]u8 = undefined;
    compat_fillRandom(&key);

    // Convert to hex for human-readable file format
    const hex = auth_hmac.hmacToHex(&key);

    // Write to file with restricted permissions
    const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) }) catch |err| {
        log.warn("Failed to create HMAC key file", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return error.NoHmacKeyAvailable;
    };
    const io_hk = std.Io.Threaded.global_single_threaded.io();
    defer file.close(io_hk);

    file.writeStreamingAll(io_hk, &hex) catch |err| {
        log.warn("Failed to write HMAC key file", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return error.NoHmacKeyAvailable;
    };

    log.info("Auto-generated HMAC key file", &.{Attr.string("path", path)});
    return HmacKeyResult{ .key = key, .key_id = "generated" };
}

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
    var auth_version_buf: [20]u8 = undefined;
    const auth_version_str = std.fmt.bufPrint(&auth_version_buf, "{d}", .{record.auth_version}) catch "0";

    const mfa_secret = record.getMFASecret() orelse "";
    const attributes_json = record.getAttributesJson() orelse "";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "attributes_json", .value = attributes_json },
        .{ .key = "auth_version", .value = auth_version_str },
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

    return computeRecordHmacChecked(hmac_key, &props);
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

    return computeRecordHmacChecked(hmac_key, &props);
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

    return computeRecordHmacChecked(hmac_key, &props);
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

    return computeRecordHmacChecked(hmac_key, &props);
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

fn computeChainHashChecked(hmac_key: *const [32]u8, record_hmacs: []const [32]u8, record_count: u64) [32]u8 {
    return auth_hmac.computeChainHash(hmac_key, record_hmacs, record_count) catch unreachable;
}

fn computeRecordHmacChecked(hmac_key: *const [32]u8, props: []const auth_hmac.KeyValue) [32]u8 {
    return auth_hmac.computeRecordHmac(hmac_key, props) catch unreachable;
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

test "resolveHmacKey auto-generates key file when data_dir exists but key file missing" {
    // Use a temporary directory for the data_dir
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = tmp_dir.dir.realpathAlloc(testing.allocator, ".") catch unreachable;
    defer testing.allocator.free(dir_path);

    // First call should auto-generate the key file
    const result1 = try AuthGraphManager.resolveHmacKey(testing.allocator, dir_path);
    try testing.expect(std.mem.eql(u8, result1.key_id, "generated"));

    // Verify the key is non-zero (random)
    const zero_key = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &result1.key, &zero_key));

    // Second call should read the file back and return "file" source
    const result2 = try AuthGraphManager.resolveHmacKey(testing.allocator, dir_path);
    try testing.expect(std.mem.eql(u8, result2.key_id, "file"));

    // Both calls should return the same key
    try testing.expect(std.mem.eql(u8, &result1.key, &result2.key));
}

test "hasAuthRecords returns false on empty store" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    try testing.expect(!mgr.hasAuthRecords());
}

test "bootstrapDefaultAdmin creates user + role + chain root with valid HMAC chain" {
    var store = try graph_store.GraphStore.init(testing.allocator);
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
    var store = try graph_store.GraphStore.init(testing.allocator);
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
    var store = try graph_store.GraphStore.init(testing.allocator);
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
    var store = try graph_store.GraphStore.init(testing.allocator);
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
    var store = try graph_store.GraphStore.init(testing.allocator);
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
    const pw_hash = try geode_auth.hashPasswordArgon2id(testing.allocator, "testpassword123");
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
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    // Should not error - empty chain is valid
    try mgr.verifyChain(&hmac_key);
}

// CANARY: REQ=REQ-AUTH-GRAPH-MGR-002; FEATURE="AuthGraphManagerTests"; ASPECT=ChainIntegrity; STATUS=TESTED; TEST=test_bootstrapDefaultAdmin_creates_user; OWNER=security; UPDATED=2026-02-24
