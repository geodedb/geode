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
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
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

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const log = logging.scoped("auth_graph_manager");
const Attr = logging.Attr;

// GAP-0854 follow-up: single source of truth for the internal security graph
// name lives at the lowest layer (graph_store). Aliasing here prevents drift
// between the FLE exclusion guard and the auth/HMAC machinery.
const SECURITY_GRAPH_NAME = graph_store.SECURITY_GRAPH_NAME;
const HAS_ROLE_EDGE = "HAS_ROLE";

// gap0900-read-write-deadlock: upper bound on how long the periodic HMAC
// verify loop will spend trying to acquire the GLOBAL store EXCLUSIVE lock
// before it gives up and retries on the next interval. The acquire uses
// `acquireStoreWriteLockCancelable` (spins on tryLock, never registers a
// pending writer), so exceeding this bound means the store is continuously
// busy under shared load (heavy bulk ingest + checkpoint); skipping this
// round keeps the loop from ever becoming a blocking writer that could wedge
// the server. 2 s is generous for the brief windows the store lock is free
// between shared acquires, yet bounded enough that a stuck verify is visible
// in logs promptly.
const VERIFY_LOCK_ACQUIRE_BOUND_NS: u64 = 2 * std.time.ns_per_s;
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
    // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-001; FEATURE="PeriodicHmacVerification"; ASPECT=BackgroundThread; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
    shutdown: std.atomic.Value(bool),
    verify_pool: ?*pooled.ThreadPool = null,
    /// Owned copy of the HMAC key for the periodic verification thread.
    /// Stored in-struct so the thread can reference it without dangling pointers
    /// (the struct is moved by value during server initialization).
    hmac_key: [32]u8 = [_]u8{0} ** 32,
    verify_interval_minutes: u32 = 0,
    /// #834: serialize sealChain across concurrent auth mutations. Without
    /// this lock two concurrent ALTER USER calls could each (a) compute their
    /// HMAC list, (b) race to persist the chain root, leaving the chain_root
    /// inconsistent with the per-record hmac on disk -- subsequent restart's
    /// verifyChain then fails with AuthChainTampered even though no real
    /// tamper occurred.
    seal_mutex: std.Io.Mutex = std.Io.Mutex.init,

    const Self = @This();

    // CANARY: REQ=REQ-AUTH-GRAPH-GLOBAL-001; FEATURE="AuthGraphManagerGlobal"; ASPECT=GlobalAccessor; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
    /// Global singleton. Null in CLI/test contexts — every caller must handle null.
    var g_instance: ?*Self = null;
    pub fn setGlobal(p: ?*Self) void {
        g_instance = p;
    }
    pub fn getGlobal() ?*Self {
        return g_instance;
    }

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

    // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-002; FEATURE="PeriodicHmacVerification"; ASPECT=BackgroundThread; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
    /// Spawn a background thread that periodically re-verifies the HMAC chain
    /// to detect runtime tampering.
    ///
    /// IMPORTANT: `self` must be at its FINAL memory location before calling
    /// this method. The spawned thread captures `self` by pointer — if the
    /// struct is moved after the thread starts, the pointer becomes dangling
    /// and the server will GPF when the thread wakes up.
    pub fn startPeriodicVerification(self: *Self, hmac_key: *const [32]u8, interval_minutes: u32) void {
        // gap0900-read-write-deadlock: interval 0 means DISABLED. The loop's
        // sleep is gated by `elapsed < target_ns` where target_ns = interval *
        // 60s; with interval 0 that inner sleep never runs, so the loop would
        // busy-acquire the GLOBAL store EXCLUSIVE lock in a tight spin —
        // continuously stalling every reader/writer and pinning a CPU. The
        // documented intent (struct default is 0) is that 0 = off, so do not
        // spawn the thread at all.
        if (interval_minutes == 0) {
            self.verify_interval_minutes = 0;
            log.info("Periodic HMAC verification disabled (interval=0)", &.{});
            return;
        }
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
            self.runVerifyRound();
        }
    }

    /// Run one periodic-verification round: acquire the global store lock,
    /// verify the HMAC chain, release.  Factored out of `periodicVerifyLoop`
    /// so the deadlock regression test can drive a single round deterministically
    /// (the loop's real cadence is in MINUTES).  Returns nothing — failures are
    /// logged, matching the loop's fire-and-continue contract.
    ///
    /// Acquire the EXCLUSIVE write lock before reading graph data.
    ///
    /// verifyChain reads label_index (via getNodesByLabel) and node properties
    /// (via getNodeProperty).  QUIC query handlers hold the SHARED lock
    /// (lockShared) while executing MERGE statements that call addNodeLabel →
    /// label_index.getOrPut(), which may rehash and free the old backing array.
    /// Using acquireStoreLock() (shared) was insufficient: multiple shared-lock
    /// holders run concurrently, so the verify thread and a query handler could
    /// still race on label_index.  The exclusive write lock excludes all
    /// shared-lock holders for the duration of the scan, which fully serialises
    /// the verify read against any concurrent MERGE writes — preserving the
    /// tamper detection guarantee.
    ///
    /// gap0900-read-write-deadlock: we MUST NOT use the blocking
    /// `acquireStoreWriteLock()` here.  That primitive registers a pending writer
    /// (Io.RwLock adds the `writer` count BEFORE parking), and
    /// `lockSharedUncancelable` then refuses every NEW shared acquire until the
    /// writer wins (writer-fair).  Under a heavy bulk ingest, an ingest worker
    /// holding a PER-GRAPH shared lock can be blocked here trying to take the
    /// global store lock SHARED, which prevents it releasing the per-graph lock,
    /// which prevents the persistence-loop checkpoint (holding the global store
    /// lock SHARED) from taking the per-graph EXCLUSIVE lock, which keeps the
    /// global store lock SHARED held forever — so this exclusive acquire never
    /// completes.  Classic three-actor lock-ordering deadlock that wedges the
    /// whole server.
    ///
    /// `acquireStoreWriteLockCancelable` instead spins on `tryLock`, which only
    /// succeeds when the lock is fully free and NEVER registers a pending writer.
    /// A failed attempt leaves the lock state untouched, so concurrent shared
    /// acquires (ingest + checkpoint) keep flowing and the cycle can never form.
    /// If we can't grab the exclusive lock within the bound, we skip this verify
    /// round and retry next interval (logged, never silent) rather than becoming
    /// a blocking writer.
    pub fn runVerifyRound(self: *Self) void {
        const deadline_ns = graph_store.monoNanosNowPub() + VERIFY_LOCK_ACQUIRE_BOUND_NS;
        graph_store.acquireStoreWriteLockCancelable(deadline_ns) catch |lock_err| {
            log.warn("Periodic HMAC verification skipped this round: could not acquire exclusive store lock within bound (retrying next interval)", &.{
                Attr.string("error", @errorName(lock_err)),
            });
            return;
        };
        const verify_result = self.verifyChain(&self.hmac_key);
        graph_store.releaseStoreWriteLock();
        verify_result catch |err| {
            log.err("PERIODIC HMAC CHECK FAILED - POSSIBLE TAMPERING", &.{Attr.string("error", @errorName(err))});
            return;
        };
        log.debug("Periodic HMAC chain verification passed", &.{});
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

        // Verify graph grant records
        try self.verifyGraphGrantRecords(hmac_key, &hmac_list);

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
        // #834: hold seal_mutex across the entire compute-and-persist window
        // so concurrent ALTER USER calls don't interleave their hmac_list
        // construction with another writer's persistChainRoot.
        self.seal_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.seal_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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

        // Seal graph grant records
        try self.sealGraphGrantRecords(hmac_key, &hmac_list);

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

        // NEW-8 residual (#860): Reject reserved usernames.  If GEODE_ADMIN_USERNAME
        // is misconfigured to a reserved name (e.g. "geode-cluster"), the bootstrap
        // would silently persist the federation-node identity as a real admin, re-
        // enabling the envelope-trust bypass on every subsequent restart.  Failing
        // explicitly here surfaces the misconfiguration loudly at startup time.
        // We return error.ReservedUsername (not a silent fallback) because a fallback
        // would obscure the operator mistake; the default username "geode" is already
        // safe, so there is no valid reason to set this env var to a reserved name.
        for (geode.user_management.RESERVED_USERNAMES) |reserved| {
            if (std.mem.eql(u8, username, reserved)) {
                self.allocator.free(username);
                return error.ReservedUsername;
            }
        }

        // 2. Resolve seed password from env (widened to honour both the
        //    historical `GEODE_ADMIN_PASSWORD` and the documented
        //    `GEODE_DEFAULT_PASSWORD`).  Precedence: when both are set,
        //    `GEODE_ADMIN_PASSWORD` wins for backward compatibility with
        //    deployments already pinning that name; a deprecation warning is
        //    emitted when both are set with different values so operators
        //    notice the drift.  Falls back to a random 32-char hex password
        //    when neither env var is present.
        var password_from_env = false;
        const password = blk: {
            const admin_env = getEnvVarOwned(self.allocator, "GEODE_ADMIN_PASSWORD") catch null;
            const default_env = getEnvVarOwned(self.allocator, "GEODE_DEFAULT_PASSWORD") catch null;

            if (admin_env != null and default_env != null) {
                if (!std.mem.eql(u8, admin_env.?, default_env.?)) {
                    log.warn("Both GEODE_ADMIN_PASSWORD and GEODE_DEFAULT_PASSWORD are set with different values; using GEODE_ADMIN_PASSWORD (precedence)", &.{});
                }
                self.allocator.free(default_env.?);
                password_from_env = true;
                break :blk admin_env.?;
            }
            if (admin_env) |env_pw| {
                password_from_env = true;
                break :blk env_pw;
            }
            if (default_env) |env_pw| {
                password_from_env = true;
                break :blk env_pw;
            }

            var random_bytes: [16]u8 = undefined;
            try cb.Csprng.bytes(&random_bytes);
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
            @as(u64, self.storage.policy_cache.count()) +
            @as(u64, self.storage.graph_grant_nodes.count());
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

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-006; FEATURE="Runtime Auth Graph Persistence"; ASPECT=LoginState; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
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

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-007; FEATURE="Runtime Auth Graph Persistence"; ASPECT=PasswordChange; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
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

    // -- P2 Write Wrappers --

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-010; FEATURE="AuthDDLPersistence"; ASPECT=RemoveUser; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Remove a user from the security graph and reseal the chain.
    pub fn removeUser(self: *Self, hmac_key: *const [32]u8, user_id: u64) !void {
        try self.storage.removeUser(user_id);
        // next_user_id is monotonically increasing; no need to decrement.
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REMOVE_USER", user_id, "", null);
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-011; FEATURE="AuthDDLPersistence"; ASPECT=SetUserActive; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Set a user's active state. Bumps auth_version so existing sessions are
    /// invalidated when a user is disabled. Reseals the chain.
    pub fn setUserActive(self: *Self, hmac_key: *const [32]u8, user_id: u64, active: bool) !u64 {
        try self.storage.updateUser(user_id, null, null, active, null, null);
        const v = try self.storage.bumpUserAuthVersion(user_id);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, if (active) "ENABLE_USER" else "DISABLE_USER", user_id, "", null);
        return v;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-023; FEATURE="AuthDDLPersistence"; ASPECT=ListRoles; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    /// Return a slice of all persisted roles. Each entry holds slices into the
    /// in-memory fixed-size arrays (no heap allocation per record beyond the
    /// outer slice). Caller must free the returned slice with `allocator.free`.
    pub const RoleEntry = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
    };
    pub fn listRoles(self: *Self, allocator: Allocator) ![]RoleEntry {
        const count = self.storage.role_cache.count();
        const entries = try allocator.alloc(RoleEntry, count);
        var i: usize = 0;
        var it = self.storage.role_cache.valueIterator();
        while (it.next()) |record| {
            entries[i] = .{
                .id = record.id,
                .name = record.getName(),
                .description = record.getDescription(),
            };
            i += 1;
        }
        return entries[0..i];
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-012; FEATURE="AuthDDLPersistence"; ASPECT=FindRoleIdByName; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Look up a role id by name (case-sensitive). Returns null if not found.
    pub fn findRoleIdByName(self: *Self, name: []const u8) !?u64 {
        const record = self.storage.getRoleByName(name) orelse return null;
        return record.id;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-013; FEATURE="AuthDDLPersistence"; ASPECT=FindUserIdByName; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Look up a user id by username. Returns null if not found.
    pub fn findUserIdByName(self: *Self, username: []const u8) !?u64 {
        const record = self.storage.getUserByUsername(username) orelse return null;
        return record.id;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-014; FEATURE="AuthDDLPersistence"; ASPECT=CreateRole; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    /// Create a named role, persisting it to the security graph. Idempotent —
    /// if a role with the same name already exists, return its id without
    /// writing or resealing.
    pub fn createRole(self: *Self, hmac_key: *const [32]u8, name: []const u8, description: []const u8) !u64 {
        // Idempotency check: return existing role id without a write.
        if (try self.findRoleIdByName(name)) |existing_id| {
            return existing_id;
        }

        // Derive next role id by scanning the cache for the current max,
        // mirroring how `init` scans users for next_user_id.
        var max_id: u64 = 0;
        var it = self.storage.role_cache.keyIterator();
        while (it.next()) |key| {
            if (key.* > max_id) max_id = key.*;
        }
        const role_id = max_id + 1;

        try self.storage.persistRole(role_id, name, description, 0, 0, false);
        try self.recomputeAndStoreRoleHmac(role_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "CREATE_ROLE", role_id, name, null);
        return role_id;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-015; FEATURE="AuthDDLPersistence"; ASPECT=RemoveRole; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Remove a role from the security graph and reseal the chain.
    pub fn removeRole(self: *Self, hmac_key: *const [32]u8, role_id: u64) !void {
        try self.storage.removeRole(role_id);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REMOVE_ROLE", role_id, "", null);
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=FindPolicyIdByName; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    /// Look up a policy id by name. Returns null if not found.
    pub fn findPolicyIdByName(self: *Self, name: []const u8) ?u64 {
        const record = self.storage.getPolicyByName(name) orelse return null;
        return record.id;
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=CreatePolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    /// Persist a GPS policy to the security graph and reseal the HMAC chain.
    /// Idempotent: if a policy with the same name already exists, returns its id
    /// without writing a duplicate node or resealing.
    pub fn createPolicy(
        self: *Self,
        hmac_key: *const [32]u8,
        name: []const u8,
        scope_graph: []const u8,
        operation: u8,
        permissive: bool,
        using_clause: ?[]const u8,
        enabled: bool,
    ) !u64 {
        if (self.findPolicyIdByName(name)) |existing_id| return existing_id;

        // Derive next policy id: max across the cache + 1.
        var max_id: u64 = 0;
        var it = self.storage.policy_cache.keyIterator();
        while (it.next()) |key| {
            if (key.* > max_id) max_id = key.*;
        }
        const policy_id = max_id + 1;

        try self.storage.persistPolicy(.{
            .policy_id = policy_id,
            .name = name,
            .description = "",
            .graph = scope_graph,
            .table = "",
            .operation = operation,
            .permissive = permissive,
            .enabled = enabled,
            .using_clause = using_clause,
            .check_clause = null,
            .audit_level = 0,
            .created_by = 0,
        });
        try self.recomputeAndStorePolicyHmac(policy_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "CREATE_POLICY", policy_id, name, null);
        return policy_id;
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropPolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    /// Remove a policy by name from the security graph and reseal the chain.
    /// Returns error.PolicyNotFound if no matching policy exists.
    pub fn dropPolicy(self: *Self, hmac_key: *const [32]u8, name: []const u8) !void {
        const policy_id = self.findPolicyIdByName(name) orelse return error.PolicyNotFound;
        try self.storage.removePolicy(policy_id);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "DROP_POLICY", policy_id, name, null);
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=AlterPolicy; STATUS=TESTED; TEST=tests/test_gap0858_alter_policy_persist.zig; OWNER=security; UPDATED=2026-06-09
    /// GAP-0858: durable ALTER POLICY write-through. Locates the policy by its
    /// current name, applies the enable/disable and/or rename mutation by
    /// re-persisting the record under the SAME policy id (an in-place update of
    /// the existing :Policy node — no stale node remains under the old name),
    /// recomputes the record HMAC, and reseals the chain.
    /// Returns error.PolicyNotFound when no matching policy exists.
    pub fn alterPolicy(
        self: *Self,
        hmac_key: *const [32]u8,
        name: []const u8,
        set_enabled: ?bool,
        rename_to: ?[]const u8,
    ) !void {
        const policy_id = self.findPolicyIdByName(name) orelse return error.PolicyNotFound;
        const existing = self.storage.getPolicy(policy_id) orelse return error.PolicyNotFound;

        // GAP-0858 (follow-up): durable rename-collision guard. If the rename
        // target is already held by a DIFFERENT policy id, reject — otherwise
        // the re-persist under our own id would leave two :Policy nodes sharing
        // a name (the in-memory PolicyCatalog already rejects this; the durable
        // path must too).
        if (rename_to) |target| {
            if (self.findPolicyIdByName(target)) |other_id| {
                if (other_id != policy_id) return error.PolicyAlreadyExists;
            }
        }

        // Resolve the post-mutation field values, defaulting to the durable
        // record's current values so an unspecified mutation is preserved.
        const new_enabled = set_enabled orelse existing.enabled;
        const new_name = rename_to orelse existing.getName();

        // Re-persist under the SAME id so upsertPolicyNode reuses the existing
        // node (in-place rename/toggle — no duplicate, no stale old-name node).
        // created_at is carried over from the existing record so the ALTER does
        // not falsify the original creation timestamp.
        try self.storage.persistPolicy(.{
            .policy_id = policy_id,
            .name = new_name,
            .description = existing.getDescription(),
            .graph = existing.getGraph(),
            .table = existing.getTable(),
            .operation = existing.operation,
            .permissive = existing.permissive,
            .enabled = new_enabled,
            .using_clause = existing.getUsingClause(),
            .check_clause = existing.getCheckClause(),
            .audit_level = existing.audit_level,
            .created_by = existing.created_by,
            .created_at = existing.created_at,
        });
        try self.recomputeAndStorePolicyHmac(policy_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "ALTER_POLICY", policy_id, new_name, null);
    }

    fn recomputeAndStorePolicyHmac(self: *Self, policy_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.getPolicy(policy_id) orelse return error.PolicyNotFound;
        const computed = computePolicyHmac(hmac_key, &record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        const node_id = self.storage.policy_nodes.get(policy_id) orelse return error.PolicyNotFound;
        try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-016; FEATURE="AuthDDLPersistence"; ASPECT=GrantUserGraphPermission; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Persist a graph-level permission grant for a user. The grant_id is
    /// derived deterministically from the (user_id, graph_name, action) triple
    /// using Wyhash so duplicate calls are idempotent at the storage level.
    pub fn grantUserGraphPermission(self: *Self, hmac_key: *const [32]u8, user_id: u64, graph_name: []const u8, action: u8) !void {
        const grant_id = graphGrantId(user_id, graph_name, action);
        try self.storage.persistGraphGrant(grant_id, user_id, graph_name, action);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "GRANT_GRAPH_PERMISSION", user_id, graph_name, null);
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-017; FEATURE="AuthDDLPersistence"; ASPECT=RevokeUserGraphPermission; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Revoke a graph-level permission grant for a user. Returns true if a
    /// matching grant was found and removed.
    pub fn revokeUserGraphPermission(self: *Self, hmac_key: *const [32]u8, user_id: u64, graph_name: []const u8, action: u8) !bool {
        const removed = try self.storage.revokeGraphGrant(user_id, graph_name, action);
        if (removed) {
            try self.sealChain(hmac_key);
            self.logSecurityGraphMutation(.configuration_change, "REVOKE_GRAPH_PERMISSION", user_id, graph_name, null);
        }
        return removed;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-018; FEATURE="AuthDDLPersistence"; ASPECT=ListGraphGrants; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    /// List all persisted graph grants. Caller owns the returned slice.
    pub fn listGraphGrants(self: *Self, allocator: std.mem.Allocator) ![]user_storage.UserStorageBackend.GraphGrantRecord {
        return self.storage.listGraphGrants(allocator);
    }

    // CANARY: REQ=REQ-LSP-PERM-GRAPH-VISIBILITY-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=CoarseGraphVisibilityGate; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
    /// Returns true if `user` is a superuser (admin) or holds at least one
    /// persisted grant of any action on `graph_name`. Intended as a COARSE
    /// visibility gate for the LSP schema completion path — it answers
    /// "should this graph appear in this user's autocomplete?" and nothing
    /// more.
    ///
    /// NOT a substitute for action-level permission enforcement. Callers
    /// that need to distinguish READ vs WRITE vs SCHEMA must layer their
    /// own check (e.g. via the multi_graph_security policy). The query
    /// executor remains the source of truth for actual access decisions.
    ///
    /// Complexity: O(grants) — scans the in-memory `graph_grant_nodes`
    /// map and reads per-node properties from the security graph. A
    /// dedicated (user_id, graph_name) index can be added later if this
    /// becomes a hot path.
    ///
    /// Locking: takes no AuthGraphManager-level lock (the manager has
    /// none on the grant path). The underlying GraphStore reads are
    /// safe under the global store rwlock convention used elsewhere in
    /// this file — `revokeGraphGrant` scans the same data the same way.
    pub fn canUserAccessGraph(self: *Self, user: []const u8, graph_name: []const u8) bool {
        // Resolve username -> user_id and short-circuit if the user is a
        // superuser. getUserByUsername is itself a thin wrapper over the
        // cache, so the cost is a single hashmap scan.
        const user_record = self.storage.getUserByUsername(user) orelse return false;
        if (user_record.is_superuser) return true;

        const user_id = user_record.id;

        // Enumerate the in-memory grant id set and resolve each grant's
        // backing node properties. We deliberately mirror the lookup
        // structure used by `revokeGraphGrant` so any future refactor
        // (e.g. caching grants in-memory like users/roles) only has to
        // touch one shape.
        var it = self.storage.graph_grant_nodes.iterator();
        while (it.next()) |entry| {
            const node_id = entry.value_ptr.*;
            const node = self.storage.store.getNodePtr(node_id) orelse continue;
            // SECURITY_GRAPH_NAME is duplicated as a file-local const in this
            // module (and in user_storage.zig). Use the local copy so we don't
            // rely on a cross-module reference.
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const uid_prop = self.storage.store.getNodeProperty(node_id, "user_id") orelse continue;
            const stored_uid: u64 = switch (uid_prop) {
                .Int => |v| if (v < 0) continue else @intCast(v),
                else => continue,
            };
            if (stored_uid != user_id) continue;

            const gname_prop = self.storage.store.getNodeProperty(node_id, "graph_name") orelse continue;
            const stored_gname: []const u8 = switch (gname_prop) {
                .String => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, stored_gname, graph_name)) continue;

            return true;
        }
        return false;
    }

    // -- GraphGrant HMAC chain support --

    fn sealGraphGrantRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        // GraphGrants use graph_grant_nodes (id -> node_id) but have no in-memory cache.
        // Collect grant ids from the node map first to avoid iterator invalidation.
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.graph_grant_nodes.keyIterator();
            while (it.next()) |key| {
                try ids.append(self.allocator, key.*);
            }
        }

        for (ids.items) |grant_id| {
            const node_id = self.storage.graph_grant_nodes.get(grant_id) orelse continue;
            // Read properties from graph to build a stable HMAC input.
            const computed = computeGraphGrantHmacFromNode(hmac_key, self.storage.store, node_id, grant_id);
            const computed_hex = auth_hmac.hmacToHex(&computed);
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
            try hmac_list.append(self.allocator, computed);
        }
    }

    fn verifyGraphGrantRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.graph_grant_nodes.keyIterator();
        while (it.next()) |key| {
            const grant_id = key.*;
            const node_id = self.storage.graph_grant_nodes.get(grant_id) orelse continue;
            const computed = computeGraphGrantHmacFromNode(hmac_key, self.storage.store, node_id, grant_id);
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
};

// -- HMAC Key Auto-Generation (module-level) --

// CANARY: REQ=REQ-AUTH-HMAC-KEYGEN-001; FEATURE="HmacKeyAutoGeneration"; ASPECT=KeyFile; STATUS=TESTED; OWNER=security; UPDATED=2026-02-24
/// Auto-generate a random 256-bit HMAC key and write it to the given file path
/// as 64 hex characters with restricted permissions (0o600).
fn autoGenerateHmacKeyFile(path: []const u8) !HmacKeyResult {
    // Generate cryptographically random 32-byte key
    var key: [32]u8 = undefined;
    try cb.Csprng.bytes(&key);

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
    // error-policy: D — computeChainHash's only error is RecordCountMismatch;
    // every call site passes record_count == record_hmacs.len by construction.
    return auth_hmac.computeChainHash(hmac_key, record_hmacs, record_count) catch unreachable;
}

fn computeRecordHmacChecked(hmac_key: *const [32]u8, props: []const auth_hmac.KeyValue) [32]u8 {
    // error-policy: D — computeRecordHmac's only error is TooManyProperties
    // (>128 props); every call site passes a fixed-size props array well under that.
    return auth_hmac.computeRecordHmac(hmac_key, props) catch unreachable;
}

/// Derive a stable, deterministic grant id from the (user_id, graph_name, action) triple.
/// Uses Wyhash for speed; collisions are astronomically unlikely for realistic input sets.
fn graphGrantId(user_id: u64, graph_name: []const u8, action: u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&user_id));
    h.update(graph_name);
    h.update(&[_]u8{action});
    return h.final();
}

/// Compute the HMAC for a GraphGrant node by reading its properties from the store.
fn computeGraphGrantHmacFromNode(hmac_key: *const [32]u8, store: *graph_store.GraphStore, node_id: u64, grant_id: u64) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{grant_id}) catch "0";

    // Read properties directly from the graph node (grants have no in-memory cache).
    const user_id_val = if (store.getNodeProperty(node_id, "user_id")) |v| if (v == .Int) v.Int else 0 else 0;
    var uid_buf: [20]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{user_id_val}) catch "0";

    const graph_name = if (store.getNodeProperty(node_id, "graph_name")) |v| if (v == .String) v.String else "" else "";

    const action_val = if (store.getNodeProperty(node_id, "action")) |v| if (v == .Int) v.Int else 0 else 0;
    var action_buf: [10]u8 = undefined;
    const action_str = std.fmt.bufPrint(&action_buf, "{d}", .{action_val}) catch "0";

    const granted_at_val = if (store.getNodeProperty(node_id, "granted_at")) |v| if (v == .Int) v.Int else 0 else 0;
    var granted_at_buf: [20]u8 = undefined;
    const granted_at_str = std.fmt.bufPrint(&granted_at_buf, "{d}", .{granted_at_val}) catch "0";

    const granted_by_val = if (store.getNodeProperty(node_id, "granted_by")) |v| if (v == .Int) v.Int else 0 else 0;
    var granted_by_buf: [20]u8 = undefined;
    const granted_by_str = std.fmt.bufPrint(&granted_by_buf, "{d}", .{granted_by_val}) catch "0";

    const props = [_]auth_hmac.KeyValue{
        .{ .key = "action", .value = action_str },
        .{ .key = "grant_id", .value = id_str },
        .{ .key = "granted_at", .value = granted_at_str },
        .{ .key = "granted_by", .value = granted_by_str },
        .{ .key = "graph_name", .value = graph_name },
        .{ .key = "user_id", .value = uid_str },
    };

    return computeRecordHmacChecked(hmac_key, &props);
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

    // error-policy: A — test setup; a failure here crashes the test, which is the desired signal.
    const dir_path = tmpDirRealpathAlloc(testing.allocator, &tmp_dir.sub_path) catch unreachable;
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

// gap0900-read-write-deadlock: the deadlock fix moved verifyChain behind the
// non-blocking `acquireStoreWriteLockCancelable` in `runVerifyRound`. The
// tamper-detection guarantee MUST survive that change: when runVerifyRound
// acquires the lock (the uncontended test case always does) it must still run
// verifyChain and observe tampering. runVerifyRound itself logs-and-returns on
// failure (fire-and-continue, matching the loop), so we assert the underlying
// verifyChain still rejects the tampered chain — which is what runVerifyRound
// invokes under the lock.
test "runVerifyRound path: verifyChain still detects tampering after deadlock fix" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xcd} ** 32;
    const result = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(result.username);
        testing.allocator.free(result.password);
    }
    mgr.hmac_key = hmac_key; // runVerifyRound reads self.hmac_key

    // Clean chain verifies (the bound is generous and the lock is uncontended,
    // so the cancelable acquire always succeeds here).
    try mgr.verifyChain(&hmac_key);
    mgr.runVerifyRound(); // exercises the real acquire→verify→release body

    // Tamper, then confirm verifyChain (the function runVerifyRound calls under
    // the exclusive lock) still detects it.
    var record = mgr.storage.getUser(result.user_id).?;
    record.is_superuser = false;
    try mgr.storage.user_cache.put(result.user_id, record);
    try testing.expectError(error.RecordHmacMismatch, mgr.verifyChain(&hmac_key));
}

// gap0900-read-write-deadlock: interval 0 must mean DISABLED, not a tight
// busy-acquire loop on the global exclusive store lock.
test "startPeriodicVerification with interval 0 is disabled (no thread spawned)" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xef} ** 32;
    mgr.startPeriodicVerification(&hmac_key, 0);

    // No verification thread/pool must be created for the disabled interval.
    try testing.expect(mgr.verify_pool == null);
    try testing.expectEqual(@as(u32, 0), mgr.verify_interval_minutes);

    // requestShutdown must be a clean no-op (nothing to join).
    mgr.requestShutdown();
    try testing.expect(mgr.verify_pool == null);
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

// CANARY: REQ=REQ-LSP-PERM-GRAPH-VISIBILITY-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=CoarseGraphVisibilityGate; STATUS=TESTED; TEST=test_canUserAccessGraph_grant_revoke_round_trip; OWNER=security; UPDATED=2026-05-14
test "canUserAccessGraph returns true after grant and false after revoke" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;

    // Bootstrap so the chain root exists and seals don't fail on first grant.
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(bootstrap.username);
        testing.allocator.free(bootstrap.password);
    }

    // Create a non-superuser "alice" to exercise the grant path (admins
    // would short-circuit and trivially pass).
    const pw_hash = try geode_auth.hashPasswordArgon2id(testing.allocator, "testpassword123");
    defer testing.allocator.free(pw_hash);
    const alice_id = try mgr.createUser(&hmac_key, "alice", "alice@example.com", pw_hash, false);

    // Pre-grant: alice cannot see the "trade" graph.
    try testing.expect(!mgr.canUserAccessGraph("alice", "trade"));

    // Action byte 0 == Read per GraphGrantRecord.action encoding.
    try mgr.grantUserGraphPermission(&hmac_key, alice_id, "trade", 0);

    // Post-grant: alice sees "trade".
    try testing.expect(mgr.canUserAccessGraph("alice", "trade"));
    // Other graphs remain hidden.
    try testing.expect(!mgr.canUserAccessGraph("alice", "other"));
    // Other users still don't see "trade".
    try testing.expect(!mgr.canUserAccessGraph("nobody", "trade"));

    // Revoke the same action and verify visibility drops back to false.
    const removed = try mgr.revokeUserGraphPermission(&hmac_key, alice_id, "trade", 0);
    try testing.expect(removed);
    try testing.expect(!mgr.canUserAccessGraph("alice", "trade"));
}

// CANARY: REQ=REQ-LSP-PERM-GRAPH-VISIBILITY-002; FEATURE="LspPermissionAwareCompletion"; ASPECT=AdminShortcut; STATUS=TESTED; TEST=test_canUserAccessGraph_admin_shortcut; OWNER=security; UPDATED=2026-05-14
test "canUserAccessGraph short-circuits true for superusers without any grant" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    const bootstrap = try mgr.bootstrapDefaultAdmin(&hmac_key);
    defer {
        testing.allocator.free(bootstrap.username);
        testing.allocator.free(bootstrap.password);
    }

    // bootstrapDefaultAdmin creates a superuser named "geode" with no
    // graph grants. The admin shortcut must still return true for any
    // graph name.
    try testing.expect(mgr.canUserAccessGraph(bootstrap.username, "any_graph_name"));
    try testing.expect(mgr.canUserAccessGraph(bootstrap.username, "another"));
    // And an unknown user remains false.
    try testing.expect(!mgr.canUserAccessGraph("ghost", "any"));
}

// CANARY: REQ=REQ-AUTH-GRAPH-MGR-002; FEATURE="AuthGraphManagerTests"; ASPECT=ChainIntegrity; STATUS=TESTED; TEST=test_bootstrapDefaultAdmin_creates_user; OWNER=security; UPDATED=2026-02-24
