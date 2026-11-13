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
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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

/// Review-0016 Important-1: shared fail-closed mapping for the engine-level
/// persisted-admin check. ONLY `error.GraphNotFound` (the security graph has
/// never been registered — a genuine first boot) maps to "zero persisted
/// records". Every OTHER engine error (corrupt shard manifest, EACCES, fd
/// exhaustion, torn registry, I/O failure while opening a REGISTERED graph)
/// is exactly the degraded-security-storage class the bootstrap guard exists
/// to defend against, so it REFUSES bootstrap (fail closed) with a loud log
/// naming the error, instead of reading as "first boot" and letting
/// GEODE_ADMIN_PASSWORD re-seed the persisted credential.
pub fn failClosedPersistedUserCount(count_result: anyerror!u64) error{PersistedAdminExists}!u64 {
    return count_result catch |err| switch (err) {
        error.GraphNotFound => 0,
        else => {
            log.err("ADMIN BOOTSTRAP REFUSED (fail-closed): storage engine error while checking __geode_security for persisted admin records — cannot distinguish first boot from degraded security storage, so GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD seeding is BLOCKED. Repair the security graph storage and restart.", &.{
                Attr.string("error", @errorName(err)),
            });
            return error.PersistedAdminExists;
        },
    };
}

/// Engine-direct persisted-admin probe shared by `bootstrapDefaultAdmin` and
/// the server's no-AGM fallback (main.zig, review-0016 Important-3): the
/// number of :User records the storage ENGINE reports for __geode_security,
/// independent of any in-memory load. Returns 0 when no global adapter is
/// installed (pure in-memory stores / unit tests) or the security graph was
/// never registered; fails CLOSED (`error.PersistedAdminExists`) on any other
/// engine error via `failClosedPersistedUserCount`.
pub fn persistedSecurityUserCountOnDisk() error{PersistedAdminExists}!u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return 0;
    return failClosedPersistedUserCount(
        adapter.countNodesByLabel(SECURITY_GRAPH_NAME, user_storage.USER_LABEL),
    );
}

/// Count persisted :User nodes that actually carry a credential (non-empty
/// `password_hash`), reading engine-direct (slot ids from the per-shard label
/// index, properties straight from the property chains — no dependency on the
/// GraphStore in-memory load). Used by the bootstrap guard to distinguish a
/// real persisted admin (refuse re-seed) from the half-bootstrap crash
/// artifact (a :User node committed without any properties — treat as first
/// boot). Errors propagate so the caller can fail CLOSED.
fn countCredentialBearingPersistedUsers(allocator: Allocator, adapter: anytype) !u64 {
    const slots = try adapter.getNodesByLabel(SECURITY_GRAPH_NAME, user_storage.USER_LABEL, allocator);
    defer allocator.free(slots);

    var credentialed: u64 = 0;
    for (slots) |slot| {
        const maybe_val = adapter.getNodeProperty(SECURITY_GRAPH_NAME, slot, "password_hash", allocator) catch |err| switch (err) {
            // Slot disappeared between the label scan and the property read —
            // not a credential-bearing record; keep scanning.
            error.NodeNotFound => continue,
            else => return err,
        };
        const val = maybe_val orelse continue;
        switch (val) {
            .string => |s| {
                defer allocator.free(s);
                if (s.len > 0) credentialed += 1;
            },
            else => {},
        }
    }
    return credentialed;
}

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
                    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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
    // CANARY: REQ=REQ-SONNY-6352-AUTH-READERS-LOCKED; FEATURE="GQL Auth DDL Persistence"; ASPECT=VerifyRoundHoldsAuthDdlLock; STATUS=TESTED; TEST=tests/test_sonny6352_auth_verify_locking.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-6352: `verifyChain` reads the role, policy and permission caches
    /// and `graph_grant_nodes`, which the auth DDL changes under
    /// `auth_ddl_lock` (SONNY-6329). The round holds that lock too, taken
    /// BEFORE the store lock (the lock order: `auth_ddl_lock` is never taken
    /// while holding a graph lock). Without it a round racing a GRANT, REVOKE
    /// or role / policy change read the maps mid-change: a rehash under the
    /// iteration, or a count that did not match the records it then read.
    pub fn runVerifyRound(self: *Self) void {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
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
    ///
    /// SONNY-6339: a source that is present but unusable is
    /// error.HmacKeyInvalid, never "no key": a non-empty GEODE_AUTH_HMAC_KEY
    /// that is not 64 hex characters (it was skipped, and the file key used
    /// instead), a non-empty GEODE_TDE_KEY that is not 64 hex characters
    /// (SONNY-6386: a wrong length was skipped too), and a
    /// `.geode_hmac_key` that cannot be opened or read or is not 64 hex
    /// characters / 32 bytes. The server refuses to start on it; it used to
    /// run with the auth graph disabled.
    pub fn resolveHmacKey(allocator: Allocator, data_dir: ?[]const u8) !HmacKeyResult {
        return resolveHmacKeyEx(allocator, data_dir, true);
    }

    // CANARY: REQ=REQ-SONNY-3035-OFFLINE-CHAIN-ROOT; FEATURE="OfflineAuthStoreSafety"; ASPECT=NoKeyBeforeVerify; STATUS=TESTED; TEST=tests/test_sonny3035_offline_chain_root.zig; OWNER=security; UPDATED=2026-09-27
    /// SONNY-3035: `resolveHmacKey` that writes nothing: with no key in the
    /// environment and no `.geode_hmac_key` file, `NoHmacKeyAvailable`, where
    /// `resolveHmacKey` generates the file. For verifying an existing chain:
    /// a key made up now cannot verify it, and generating it wrote key
    /// material into a store the command then refused to change.
    pub fn resolveExistingHmacKey(allocator: Allocator, data_dir: ?[]const u8) !HmacKeyResult {
        return resolveHmacKeyEx(allocator, data_dir, false);
    }

    fn resolveHmacKeyEx(allocator: Allocator, data_dir: ?[]const u8, create_missing: bool) !HmacKeyResult {
        // 1. Try GEODE_AUTH_HMAC_KEY env var
        if (getEnvVarOwned(allocator, "GEODE_AUTH_HMAC_KEY")) |env_val| {
            defer allocator.free(env_val);
            if (env_val.len == 64) {
                var key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key, env_val) catch {
                    log.warn("GEODE_AUTH_HMAC_KEY contains invalid hex", &.{});
                    return error.HmacKeyInvalid;
                };
                return HmacKeyResult{ .key = key, .key_id = "env" };
            } else if (env_val.len > 0) {
                log.warn("GEODE_AUTH_HMAC_KEY must be exactly 64 hex characters", &.{
                    Attr.uint("actual_len", @intCast(env_val.len)),
                });
                return error.HmacKeyInvalid;
            }
        } else |_| {}

        // 2. Try GEODE_TDE_KEY env var -> HKDF derivation
        if (getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |tde_val| {
            defer allocator.free(tde_val);
            if (tde_val.len == 64) {
                var tde_key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&tde_key, tde_val) catch {
                    log.warn("GEODE_TDE_KEY contains invalid hex", &.{});
                    return error.HmacKeyInvalid;
                };
                const derived = auth_hmac.deriveHmacKey(&tde_key, geode_hkdf_config);
                return HmacKeyResult{ .key = derived, .key_id = "tde-derived" };
            } else if (tde_val.len > 0) {
                // SONNY-6386: a set GEODE_TDE_KEY of the wrong length was
                // skipped and the chain sealed with the file key instead.
                log.warn("GEODE_TDE_KEY must be exactly 64 hex characters", &.{
                    Attr.uint("actual_len", @intCast(tde_val.len)),
                });
                return error.HmacKeyInvalid;
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
                        if (!create_missing) return error.NoHmacKeyAvailable;
                        return autoGenerateHmacKeyFile(path);
                    },
                    else => {
                        log.warn("Failed to open HMAC key file", &.{
                            Attr.string("path", path),
                            Attr.string("error", @errorName(err)),
                        });
                        return error.HmacKeyInvalid;
                    },
                }
            };
            const io_hr = std.Io.Threaded.global_single_threaded.io();
            defer file.close(io_hr);

            // Read hex-encoded key (64 hex chars = 32 bytes)
            var hex_buf: [64]u8 = undefined;
            const bytes_read = file.readPositionalAll(io_hr, &hex_buf, 0) catch {
                log.warn("Failed to read HMAC key file", &.{});
                return error.HmacKeyInvalid;
            };
            if (bytes_read == 64) {
                // Hex-encoded key file (64 hex chars -> 32 bytes)
                var key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key, &hex_buf) catch {
                    log.warn("HMAC key file contains invalid hex", &.{
                        Attr.string("path", path),
                    });
                    return error.HmacKeyInvalid;
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
                return error.HmacKeyInvalid;
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

        // SONNY-6341: FLE role grant records
        try self.verifyFleRoleGrantRecords(hmac_key, &hmac_list);

        // SONNY-6352: the records read must be the records counted. A
        // mismatch (the maps changed between the count and the reads) fails
        // the verification; it reached `computeChainHashChecked`'s
        // `catch unreachable` and crashed the verifying thread.
        if (hmac_list.items.len != total_records) return error.RecordCountMismatch;

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
        // SONNY-6329: ids under the cache's lock; the loop reads graph nodes.
        const ids = try self.storage.cachedUserIds(self.allocator);
        defer self.allocator.free(ids);
        for (ids) |user_id| {
            const user_copy = self.storage.getUser(user_id) orelse continue;
            const record = &user_copy;
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

    /// SONNY-2791: does the HMAC stored on `record`'s node match the one
    /// `hmac_key` gives it?
    fn policyHmacVerifies(self: *Self, hmac_key: *const [32]u8, record: *const UserStorageBackend.PolicyRecord) bool {
        const node_id = self.storage.policy_nodes.get(record.id) orelse return false;
        const stored = self.storage.store.getNodeProperty(node_id, "hmac") orelse return false;
        if (stored != .String) return false;
        const computed = computePolicyHmac(hmac_key, record);
        const computed_hex = auth_hmac.hmacToHex(&computed);
        return std.mem.eql(u8, &computed_hex, stored.String);
    }

    /// SONNY-2791: the operator's decisions, by record id, for the policy
    /// records no seal signs on its own (`refuseUnsignedLegacy`).
    pub const LegacyPolicyDecisions = struct {
        /// Sign each one, stored explicitly as what its shape makes it.
        accept: []const u64 = &.{},
        /// Delete each one.
        drop: []const u64 = &.{},

        fn decided(self: LegacyPolicyDecisions, id: u64) bool {
            return std.mem.indexOfScalar(u64, self.accept, id) != null or
                std.mem.indexOfScalar(u64, self.drop, id) != null;
        }
    };

    // CANARY: REQ=REQ-SONNY-2791-RESEAL-LEGACY; FEATURE="AuthDDLPersistence"; ASPECT=SealRefusesUnsignedLegacy; STATUS=TESTED; TEST=tests/test_sonny2791_internal_graphs_reseal.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2791: refuse (error.UnsignedLegacyPolicyRecord, logging each
    /// record) while a policy record has no kind, its stored HMAC does not
    /// verify under `hmac_key`, and `decisions` has nothing for it.
    ///
    /// A record without a kind was written before SONNY-2750. GPS loads it by
    /// its shape, and with no USING text it grants unconditionally. One this
    /// key never signed may have been planted in that shape, so no seal signs
    /// it: not the recovery reseal, and not the seal after every auth change.
    /// An offline CLI command loads the security graph as it is and seals
    /// after its change, so it used to sign such a record. A record without a
    /// kind whose HMAC verifies was signed by this key before the upgrade.
    fn refuseUnsignedLegacy(self: *Self, hmac_key: *const [32]u8, decisions: LegacyPolicyDecisions) error{UnsignedLegacyPolicyRecord}!void {
        var refused: usize = 0;
        var it = self.storage.policyIterator();
        while (it.next()) |record| {
            if (record.kind != .legacy or decisions.decided(record.id)) continue;
            if (self.policyHmacVerifies(hmac_key, record)) continue;
            log.err("refusing to sign a policy record without a kind whose HMAC does not verify (it may have been planted); decide it with geode auth reseal --accept-legacy-policy <id> or --drop-legacy-policy <id>", &.{
                Attr.uint("policy_id", record.id),
                Attr.string("name", record.getName()),
                Attr.string("shape", @tagName(record.effectiveKind())),
            });
            refused += 1;
        }
        if (refused > 0) return error.UnsignedLegacyPolicyRecord;
    }

    // CANARY: REQ=REQ-SONNY-2791-RESEAL-LEGACY; FEATURE="AuthDDLPersistence"; ASPECT=ResealRefusesUnsignedLegacy; STATUS=TESTED; TEST=tests/test_sonny2791_internal_graphs_reseal.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2791: the recovery reseal (`geode auth reseal`, and
    /// GEODE_AUTH_RESEAL_CHAIN=1 at startup). It is `sealChain`, after the
    /// operator's decision for each policy record that has no kind and does
    /// not verify (`refuseUnsignedLegacy`):
    /// - a dropped record is deleted;
    /// - an accepted record is rewritten as what it now is, explicitly: its
    ///   kind and, for GPS, its USING text ("true" when it had none), so
    ///   nothing is "true by absence". A malformed one is signed as it is and
    ///   still loads nowhere.
    /// Without a decision for each one it refuses and changes nothing. An id
    /// both accepted and dropped is error.ConflictingLegacyPolicyDecision. A
    /// decision for any other record is ignored.
    pub fn resealChain(self: *Self, hmac_key: *const [32]u8, decisions: LegacyPolicyDecisions) !void {
        for (decisions.accept) |id| {
            if (std.mem.indexOfScalar(u64, decisions.drop, id) == null) continue;
            log.err("reseal refused: a policy record is both accepted and dropped", &.{
                Attr.uint("policy_id", id),
            });
            return error.ConflictingLegacyPolicyDecision;
        }
        try self.refuseUnsignedLegacy(hmac_key, decisions);

        // Collected first: the changes below change the cache.
        var unverified: std.ArrayList(u64) = .empty;
        defer unverified.deinit(self.allocator);
        var it = self.storage.policyIterator();
        while (it.next()) |record| {
            if (record.kind != .legacy) continue;
            if (self.policyHmacVerifies(hmac_key, record)) continue;
            try unverified.append(self.allocator, record.id);
        }
        for (unverified.items) |id| {
            const record = self.storage.getPolicy(id) orelse continue;
            if (std.mem.indexOfScalar(u64, decisions.drop, id) != null) {
                log.warn("reseal: the operator dropped a policy record without a kind that did not verify", &.{
                    Attr.uint("policy_id", id),
                    Attr.string("name", record.getName()),
                });
                try self.storage.removePolicy(id);
                continue;
            }
            const kind = record.effectiveKind();
            if (record.malformed or (kind != .gps and kind != .rls)) continue;
            log.warn("reseal: the operator accepted a policy record without a kind; storing its kind and USING text", &.{
                Attr.uint("policy_id", id),
                Attr.string("name", record.getName()),
                Attr.string("kind", @tagName(kind)),
            });
            try self.storage.persistPolicy(.{
                .policy_id = id,
                .name = record.getName(),
                .description = record.getDescription(),
                .graph = record.getGraph(),
                .table = record.getTable(),
                .operation = record.operation,
                .permissive = record.permissive,
                .enabled = record.enabled,
                .using_clause = if (kind == .gps) (record.getUsingClause() orelse "true") else record.getUsingClause(),
                .check_clause = record.getCheckClause(),
                .audit_level = record.audit_level,
                .created_by = record.created_by,
                .created_at = record.created_at,
                .kind = kind,
                .mode = .replace,
            });
        }
        // A malformed accepted record keeps no kind and still does not verify.
        try self.sealChainWith(hmac_key, .{ .accept = decisions.accept });
    }

    /// Recompute all per-record HMACs and the chain hash, after every auth
    /// change. SONNY-2791: while a policy record without a kind does not
    /// verify, it refuses and signs nothing (`refuseUnsignedLegacy`). Only
    /// the recovery reseal (`resealChain`) signs one, on the operator's
    /// decision.
    pub fn sealChain(self: *Self, hmac_key: *const [32]u8) !void {
        return self.sealChainWith(hmac_key, .{});
    }

    fn sealChainWith(self: *Self, hmac_key: *const [32]u8, decisions: LegacyPolicyDecisions) !void {
        // #834: hold seal_mutex across the entire compute-and-persist window
        // so concurrent ALTER USER calls don't interleave their hmac_list
        // construction with another writer's persistChainRoot.
        self.seal_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.seal_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const seal = try self.computeSealLocked(hmac_key, decisions, &.{});
        try self.persistSealLocked(seal);
    }

    /// A chain seal computed but not yet stored (SONNY-6273).
    const ChainSeal = struct {
        chain_hash: [32]u8,
        record_count: u64,
    };

    /// Everything of a seal that can fail with this manager's memory: the
    /// legacy-record check, each record's HMAC (stored on its node) and the
    /// chain hash. `leaving`: policy records about to be removed, which the
    /// seal leaves out (SONNY-6273, `dropPolicy`); they are not refused as
    /// unsigned legacy records either, as the drop used to remove them
    /// before sealing. Caller holds `seal_mutex`.
    fn computeSealLocked(self: *Self, hmac_key: *const [32]u8, decisions: LegacyPolicyDecisions, leaving: []const u64) !ChainSeal {
        if (leaving.len == 0) {
            try self.refuseUnsignedLegacy(hmac_key, decisions);
        } else {
            // Only dropPolicy passes `leaving`, with no decisions of its own.
            std.debug.assert(decisions.accept.len == 0 and decisions.drop.len == 0);
            try self.refuseUnsignedLegacy(hmac_key, .{ .drop = leaving });
        }

        var hmac_list: std.ArrayList([32]u8) = .empty;
        defer hmac_list.deinit(self.allocator);

        // Seal user records
        try self.sealUserRecords(hmac_key, &hmac_list);

        // Seal role records
        try self.sealRoleRecords(hmac_key, &hmac_list);

        // Seal permission records
        try self.sealPermissionRecords(hmac_key, &hmac_list);

        // Seal policy records
        try self.sealPolicyRecords(hmac_key, &hmac_list, leaving);

        // Seal graph grant records
        try self.sealGraphGrantRecords(hmac_key, &hmac_list);

        // SONNY-6341: FLE role grant records
        try self.sealFleRoleGrantRecords(hmac_key, &hmac_list);

        // Sort HMACs for deterministic chain hash
        sortHmacs(hmac_list.items);

        const total_records = self.countAuthRecords() - leaving.len;
        return .{
            .chain_hash = computeChainHashChecked(hmac_key, hmac_list.items, total_records),
            .record_count = total_records,
        };
    }

    fn persistSealLocked(self: *Self, seal: ChainSeal) !void {
        const chain_hash_hex = auth_hmac.hmacToHex(&seal.chain_hash);
        try self.storage.persistChainRoot(&chain_hash_hex, seal.record_count, "sealed");
    }

    fn sealUserRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        // Collect user IDs first to avoid iterator invalidation
        // SONNY-6329: the ids copied under the cache's lock, each record
        // copied out by `getUser` (the loop writes graph nodes).
        const ids = try self.storage.cachedUserIds(self.allocator);
        defer self.allocator.free(ids);

        for (ids) |user_id| {
            const record = self.storage.getUser(user_id) orelse continue;
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

    fn sealPolicyRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8), leaving: []const u64) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.policy_cache.keyIterator();
            while (it.next()) |key| {
                if (std.mem.indexOfScalar(u64, leaving, key.*) != null) continue;
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
        // 0. Persisted-credential precedence guard (2026-07-01 live incident:
        //    restart with a changed GEODE_ADMIN_PASSWORD silently rotated the
        //    persisted admin credential to the env value).
        //
        //    Callers gate bootstrap on `hasAuthRecords()`, which reflects only
        //    the IN-MEMORY user_cache populated by `loadUsersFromGraph`. Any
        //    boot where that load comes up empty while persisted records still
        //    exist on disk (lazy-hydration failure, storage-layout drift,
        //    partial crash recovery) looks exactly like a first boot, so the
        //    caller re-runs bootstrap and re-seeds the admin from the env —
        //    destroying the persisted credential with no warning.
        //
        //    Ask the storage ENGINE directly (per-shard label index, on-disk
        //    truth, independent of the GraphStore in-memory load) whether any
        //    :User records are persisted for __geode_security. If yes, REFUSE:
        //    the persisted credential wins; env seeding is first-boot only.
        //    Only `error.GraphNotFound` (the security graph was never
        //    registered — a genuine first boot) and the no-adapter case (pure
        //    in-memory store, unit tests) count as zero; every OTHER engine
        //    error fails CLOSED (review-0016 Important-1: an open/IO failure
        //    on a REGISTERED security graph is precisely the degraded-storage
        //    class this guard defends against, so it must never read as
        //    "first boot").
        //
        //    Engine-index dependency (review-0016 Minor-1): the zero-count
        //    signal is only sound because the pinned graph-storage release
        //    (v0.2.23) populates the per-shard derived label index
        //    SYNCHRONOUSLY at engine open (engine.zig tryLoadDerivedIndexes /
        //    rebuildDerivedIndexes) — a registered graph with persisted :User
        //    nodes can never read 0 here. If a future gs pin defers the
        //    derived-index build past open (the cold-open work does exactly
        //    that on a dev branch), a lazily-built index could read 0 and
        //    SILENTLY bypass this guard. Before bumping the gs pin to such a
        //    release, add a second signal for the count==0-on-registered-graph
        //    case (e.g. the registry entry's node_count).
        if (graph_store.getGlobalAdapter()) |adapter| {
            const persisted_users = try failClosedPersistedUserCount(
                adapter.countNodesByLabel(SECURITY_GRAPH_NAME, user_storage.USER_LABEL),
            );
            if (persisted_users > 0) {
                // Review-0016 Important-2: distinguish REAL credential-bearing
                // records (refuse — the persisted credential wins) from the
                // half-bootstrap crash artifact. Bootstrap is not atomic:
                // `createEntityNode(USER_LABEL)` commits the :User node in its
                // own engine txn BEFORE `setNodePropertiesBatch` writes any
                // credential property, so a crash in that window leaves a
                // :User node with NO properties and NO recoverable credential.
                // Refusing forever on that artifact would brick the store with
                // no working credential and no escape route. Counting only
                // credential-bearing nodes (non-empty password_hash, read
                // engine-direct) turns the artifact back into a first boot —
                // recoverable via a normal restart — while any error during
                // the property inspection still fails CLOSED.
                const credentialed = countCredentialBearingPersistedUsers(self.allocator, adapter) catch |err| {
                    log.err("ADMIN BOOTSTRAP REFUSED (fail-closed): storage engine error while inspecting persisted :User records for credentials; refusing to re-seed the admin credential (GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD are IGNORED). Repair __geode_security storage and restart.", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("persisted_user_records", persisted_users),
                    });
                    return error.PersistedAdminExists;
                };
                if (credentialed > 0) {
                    // Attr key deliberately avoids "credential"/"password"
                    // substrings — the logging layer redacts values for such
                    // keys and the operator needs to SEE this count.
                    log.err("ADMIN BOOTSTRAP REFUSED: persisted admin user records exist on disk but none were loaded into memory; refusing to re-seed the admin credential (GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD are IGNORED — a persisted credential always wins). Investigate __geode_security storage health.", &.{
                        Attr.uint("persisted_user_records", persisted_users),
                        Attr.uint("usable_admin_records", credentialed),
                    });
                    return error.PersistedAdminExists;
                }
                log.warn("half-bootstrapped security graph detected: :User node(s) exist on disk but NONE carries a credential (crash between node create and property write); treating as first boot and seeding the admin credential normally", &.{
                    Attr.uint("persisted_user_records", persisted_users),
                });
            }
        }

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
        //    notice the drift.  Falls back to a random policy-compliant
        //    passphrase (SONNY-6331) when neither env var is present.
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

            // SONNY-6331: a generated password meets the policy (it was 32
            // hex characters, which the policy refuses).
            var pw_buf: [geode_auth.max_password_length]u8 = undefined;
            break :blk try self.allocator.dupe(u8, try geode_auth.PasswordPolicy.geodeSecure().generate(&pw_buf));
        };

        // CANARY: REQ=REQ-AUTH-POLICY-005; FEATURE="Unified Password Policy Validation"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_bug731_password_policy.zig; OWNER=security; UPDATED=2026-07-31
        // CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=FirstBootSeedForcedReset; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
        // The env seed path historically enforced NO password policy at all,
        // while `ALTER USER ... SET PASSWORD` over the wire enforced a 20-char
        // 3-word passphrase. See docs/@BUGS_731.md bug 4.
        //
        // SONNY-6331: a seed that does not meet the policy is taken (refusing
        // to boot would brick a deployment whose seed predates the check) with
        // a forced reset, as docs/USER_AUTH.md "Reset Triggers" states: it
        // logs the admin in only to set a policy-compliant password. It was
        // taken with no reset and only a warning.
        var seed_violation: ?geode_auth.PasswordPolicy.Violation = null;
        if (password_from_env) {
            const policy = geode_auth.PasswordPolicy.geodeSecure();
            seed_violation = policy.check(password);
            if (seed_violation) |v| {
                log.warn("GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD does not meet the server's password policy. The seed is accepted with a FORCED RESET: the admin must set a policy-compliant passphrase at first login. Seed a compliant passphrase to avoid the reset.", &.{
                    Attr.string("reason", policy.message(v)),
                });
            }
        }

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
        record.password_reset_required = !password_from_env or seed_violation != null;
        record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
        record.password_changed_at = compat_milliTimestamp();
        try self.storage.putCachedUser(user_id, record);
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
        // NEW-8 residual (#860): Defense-in-depth guard.  All current call sites reach
        // this function through guarded wrappers (user_management.createUser ->
        // persistent_writer.create_fn -> writerCreateUser), but this is a public
        // function on a public struct.  A future direct call site would re-open the
        // graph-persistence half of the bypass without this check at the function level.
        for (geode.user_management.RESERVED_USERNAMES) |reserved| {
            if (std.mem.eql(u8, username, reserved)) {
                return error.ReservedUsername;
            }
        }

        const user_id = self.next_user_id;
        self.next_user_id += 1;
        // SONNY-1333: a user whose save failed part way is taken out again,
        // so the CREATE USER that reports the failure can be retried.
        errdefer {
            self.storage.removeUser(user_id) catch {};
            self.sealChain(hmac_key) catch |err| {
                log.err("SONNY-1333: the security chain could not be sealed after a failed CREATE USER", &.{Attr.string("error", @errorName(err))});
            };
        }

        // Persist with HMAC
        try self.storage.persistUserWithHmac(user_id, username, email, password_hash, "", hmac_key);

        // Set is_superuser if needed
        if (is_superuser) {
            var record = self.storage.getUser(user_id) orelse return error.UserNotFound;
            record.is_superuser = true;
            record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
            try self.storage.putCachedUser(user_id, record);
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
        return self.storage.cachedUserCount() > 0;
    }

    // -- Internal Helpers --

    pub fn countAuthRecords(self: *Self) u64 {
        // Cast each count() to u64 before summing. HashMap.count() returns u32
        // (HashMap.Size), so four-operand u32 addition can overflow when the
        // total exceeds ~4 billion records. Casting first lifts the arithmetic
        // to u64, preventing the panic in safe/debug builds.
        return @as(u64, self.storage.cachedUserCount()) +
            @as(u64, self.storage.role_cache.count()) +
            @as(u64, self.storage.permission_cache.count()) +
            @as(u64, self.storage.policy_cache.count()) +
            @as(u64, self.storage.graph_grant_nodes.count()) +
            @as(u64, self.storage.fle_role_grant_nodes.count());
    }

    fn recomputeAndStoreUserHmac(self: *Self, user_id: u64, hmac_key: *const [32]u8) !void {
        const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
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
        const old = self.storage.getUser(user_id) orelse return error.UserNotFound;
        const changed = try self.storage.assignUserRole(user_id, role_id);
        if (!changed) return old.auth_version;
        // SONNY-3038: the edge and the record, or neither.
        errdefer {
            _ = self.storage.revokeUserRole(user_id, role_id) catch |err| logRestoreFailure("HAS_ROLE edge", err);
            self.restoreUserRecord(hmac_key, old);
        }
        const version = try self.storage.bumpUserAuthVersion(user_id);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
        const record = self.storage.getUser(user_id) orelse return error.UserNotFound;
        self.logSecurityGraphMutation(.configuration_change, "ASSIGN_ROLE", user_id, record.getUsername(), null);
        return version;
    }

    pub fn revokeUserRole(self: *Self, hmac_key: *const [32]u8, user_id: u64, role_id: u64) !u64 {
        const old = self.storage.getUser(user_id) orelse return error.UserNotFound;
        const changed = try self.storage.revokeUserRole(user_id, role_id);
        if (!changed) return old.auth_version;
        // SONNY-3038: the edge and the record, or neither.
        errdefer {
            _ = self.storage.assignUserRole(user_id, role_id) catch |err| logRestoreFailure("HAS_ROLE edge", err);
            self.restoreUserRecord(hmac_key, old);
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
        var record = self.storage.getUser(user_id) orelse return error.UserNotFound;
        record.failed_login_attempts = failed_attempts;
        record.lockout_until = lockout_until;
        record.updated_at = compat_milliTimestamp();
        try self.storage.putCachedUser(user_id, record);
        try self.storage.upsertUserNode(record);
        try self.recomputeAndStoreUserHmac(user_id, hmac_key);
        try self.sealChain(hmac_key);
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-007; FEATURE="Runtime Auth Graph Persistence"; ASPECT=PasswordChange; STATUS=TESTED; TEST=tests/test_bug731_password_reset.zig; OWNER=security; UPDATED=2026-07-31
    /// Update a user record's password hash in the graph store.
    /// Recomputes the record HMAC and reseals the chain.
    ///
    /// Bug 731-4a: changing the password satisfies a pending forced reset, so
    /// the DURABLE `password_reset_required` flag is cleared here — for this
    /// user only. Every password-change path (the wire `ALTER USER ... SET
    /// PASSWORD` intercept via the user_management persistent writer, the
    /// SecurityManager graph-persist callback, `geode.auth.user_*_password`,
    /// and the offline `geode user reset-password` CLI) funnels through this
    /// one seam, so clearing it here is what makes them agree. Leaving it set
    /// used to bounce the account back through the reset gate on the very next
    /// query with the NEW password — with no self-service escape.
    /// The flag is part of the record HMAC input (`recomputeAndStoreUserHmac`),
    /// so the reseal below is mandatory: a bare property write would fail
    /// `verifyChain` and brick the next startup.
    pub fn updateUserPassword(self: *Self, hmac_key: *const [32]u8, user_id: u64, new_password_hash: []const u8) !u64 {
        const old = self.storage.getUser(user_id) orelse return error.UserNotFound;
        // SONNY-3038: all of it or none of it.
        errdefer self.restoreUserRecord(hmac_key, old);
        var record = old;
        record.password_hash_len = UserStorageBackend.copyIntoField(&record.password_hash, new_password_hash);
        record.password_reset_required = false;
        record.password_changed_at = compat_milliTimestamp();
        record.updated_at = compat_milliTimestamp();
        record.auth_version += 1;
        try self.storage.putCachedUser(user_id, record);
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
        // SONNY-3038: the record is gone; a seal that failed is tried again
        // (as a revoke's is), so a saved removal is not reported as failed.
        self.sealChain(hmac_key) catch try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REMOVE_USER", user_id, "", null);
    }

    // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=UserRecordUndo; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-3038: put a user record back as it was before a change that
    /// failed part way (its cached record, its node, its HMAC) and seal the
    /// chain again. A password, active-flag or role change used to leave
    /// whatever it had written: a record whose node or chain no longer
    /// matched (the next start's verification failed), or a change that was
    /// in force after the restart although the statement failed.
    fn restoreUserRecord(self: *Self, hmac_key: *const [32]u8, old: UserStorageBackend.UserRecord) void {
        self.storage.putCachedUser(old.id, old) catch |err| logRestoreFailure("user record", err);
        self.storage.upsertUserNode(old) catch |err| logRestoreFailure("user node", err);
        self.recomputeAndStoreUserHmac(old.id, hmac_key) catch |err| logRestoreFailure("user HMAC", err);
        self.sealChain(hmac_key) catch |err| logRestoreFailure("chain seal", err);
    }

    fn logRestoreFailure(what: []const u8, err: anyerror) void {
        log.err("SONNY-3038: a security-graph change that failed could not be undone; the next start may load it or fail chain verification", &.{
            Attr.string("part", what),
            Attr.string("error", @errorName(err)),
        });
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-011; FEATURE="AuthDDLPersistence"; ASPECT=SetUserActive; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
    /// Set a user's active state. Bumps auth_version so existing sessions are
    /// invalidated when a user is disabled. Reseals the chain.
    pub fn setUserActive(self: *Self, hmac_key: *const [32]u8, user_id: u64, active: bool) !u64 {
        const old = self.storage.getUser(user_id) orelse return error.UserNotFound;
        // SONNY-3038: all of it or none of it.
        errdefer self.restoreUserRecord(hmac_key, old);
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
    /// SONNY-6329: under the user cache's lock, copying the id alone.
    pub fn findUserIdByName(self: *Self, username: []const u8) !?u64 {
        return self.storage.findUserIdByUsername(username);
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

        // SONNY-3038: a role whose save failed part way is taken out again
        // (as a user is, SONNY-1333): CREATE ROLE reports the failure, and a
        // role left stored would come back at the next start.
        errdefer {
            self.storage.removeRole(role_id) catch |err| logRestoreFailure("role record", err);
            self.sealChain(hmac_key) catch |err| logRestoreFailure("chain seal", err);
        }
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
        // SONNY-3038: as removeUser.
        self.sealChain(hmac_key) catch try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REMOVE_ROLE", role_id, "", null);
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=FindPolicyIdByName; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    /// Look up a GPS policy's id by name. Returns null if not found.
    /// SONNY-2750: GPS records only; an RLS record of the same name (the
    /// geode-auth CLI writes the same record type) is not a GPS policy, and
    /// CREATE, ALTER and DROP POLICY must not reach it.
    pub fn findPolicyIdByName(self: *Self, name: []const u8) ?u64 {
        var it = self.storage.policyIterator();
        while (it.next()) |record| {
            if (record.effectiveKind() == .gps and std.mem.eql(u8, record.getName(), name)) return record.id;
        }
        return null;
    }

    /// SONNY-2750: audit a :Policy record that GPS hydration refused to load
    /// (it is not a GPS policy, or it is malformed). `reason` says why.
    pub fn auditRefusedPolicyRecord(self: *Self, record: *const UserStorageBackend.PolicyRecord, reason: []const u8) void {
        self.logSecurityGraphMutation(.policy_violation, "REFUSE_POLICY_RECORD", record.id, record.getName(), reason);
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

        // SONNY-2777: the policy id sequence every policy writer shares.
        const policy_id = self.storage.nextPolicyId();
        // SONNY-3038: a policy whose save failed part way is taken out again.
        // CREATE POLICY took it out of the catalog and failed, and the stored
        // record came back at the next start.
        errdefer {
            self.storage.removePolicy(policy_id) catch |err| logRestoreFailure("policy record", err);
            self.sealChain(hmac_key) catch |err| logRestoreFailure("chain seal", err);
        }

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
            .kind = .gps,
            .mode = .create,
        });
        try self.recomputeAndStorePolicyHmac(policy_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "CREATE_POLICY", policy_id, name, null);
        return policy_id;
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropPolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-SONNY-6273-DROP-POLICY-ATOMIC; FEATURE="GPS Policy Persistence"; ASPECT=DropPolicySealBeforeRemove; STATUS=TESTED; TEST=tests/test_sonny6273_drop_policy_atomic.zig; OWNER=security; UPDATED=2026-11-11
    /// Remove a policy by name from the security graph and reseal the chain.
    /// Returns error.PolicyNotFound if no matching policy exists.
    ///
    /// SONNY-3038: every GPS record of that name goes. Two could be stored
    /// (a store written before names were unique, or by another writer); the
    /// drop removed the first only, and the other was loaded at the next
    /// start, so the dropped policy came back.
    ///
    /// SONNY-6273: removal and seal are one step. The records were removed
    /// first and the chain sealed after; a seal that failed twice left them
    /// gone with the chain still counting them (RecordCountMismatch: the next
    /// start refused to load the security graph) while DROP POLICY failed and
    /// the catalog kept the policy. Now the ids and the new seal (every
    /// allocation of it) are computed while the records are still there; a
    /// failure there changes nothing. Then the records go and the computed
    /// seal is stored, which allocates nothing of this manager's. Only if
    /// the graph store fails that write is the chain sealed again (twice),
    /// as before.
    pub fn dropPolicy(self: *Self, hmac_key: *const [32]u8, name: []const u8) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.policyIterator();
            while (it.next()) |record| {
                if (record.effectiveKind() == .gps and std.mem.eql(u8, record.getName(), name)) try ids.append(self.allocator, record.id);
            }
        }
        if (ids.items.len == 0) return error.PolicyNotFound;

        var removal_failure: ?anyerror = null;
        var sealed = false;
        {
            self.seal_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.seal_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const seal = try self.computeSealLocked(hmac_key, .{}, ids.items);
            for (ids.items) |policy_id| {
                self.storage.removePolicy(policy_id) catch |err| {
                    removal_failure = err;
                    break;
                };
            }
            if (removal_failure == null) {
                if (self.persistSealLocked(seal)) |_| {
                    sealed = true;
                } else |err| log.warn("DROP POLICY: the graph store did not take the chain seal; sealing again", &.{Attr.string("error", @errorName(err))});
            }
        }
        // A removal that stopped part way, or a seal the graph store did not
        // take: seal what is there now (a retry, as a revoke's), so the
        // chain matches the records whatever is answered.
        if (!sealed) self.sealChain(hmac_key) catch try self.sealChain(hmac_key);
        if (removal_failure) |err| return err;
        for (ids.items) |policy_id| self.logSecurityGraphMutation(.configuration_change, "DROP_POLICY", policy_id, name, null);
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
        // SONNY-2750: a record with a missing or mistyped property was not
        // loaded, and is not rewritten either: the rewrite would store the
        // defaults that stood in for what is missing as its values.
        if (existing.malformed) return error.PolicyNotFound;

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

        // SONNY-3038: all of it or none of it. A change that failed part way
        // was left stored (or stored with a stale HMAC or seal), while ALTER
        // POLICY put the catalog back and failed.
        errdefer {
            self.storage.restorePolicyRecord(existing) catch |err| logRestoreFailure("policy record", err);
            self.recomputeAndStorePolicyHmac(policy_id, hmac_key) catch |err| logRestoreFailure("policy HMAC", err);
            self.sealChain(hmac_key) catch |err| logRestoreFailure("chain seal", err);
        }

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
            // SONNY-2750: a legacy GPS record stored no USING text for "true"
            // (a well-formed `kind = gps` record always has one); the rewrite
            // stores it, as a GPS record without one is malformed.
            .using_clause = existing.getUsingClause() orelse "true",
            .check_clause = existing.getCheckClause(),
            .audit_level = existing.audit_level,
            .created_by = existing.created_by,
            .created_at = existing.created_at,
            // SONNY-2750: `findPolicyIdByName` found a GPS record (a legacy one
            // included), which this re-persist records as such.
            .kind = .gps,
            .mode = .replace,
        });
        try self.recomputeAndStorePolicyHmac(policy_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "ALTER_POLICY", policy_id, new_name, null);
    }

    // -- geode.rls.* restrictions (SONNY-3034) --

    /// SONNY-3034: a restriction `geode.rls.*` adds, as stored: a label deny
    /// (`kind = .rls_deny`; `subject` is the user, empty for every user) or
    /// an attribute policy (`kind = .rls_attribute`; `subject` is the row
    /// property, `attribute` the ABAC attribute key).
    pub const RlsRestriction = struct {
        kind: UserStorageBackend.PolicyKind,
        graph: []const u8,
        label: []const u8,
        subject: []const u8,
        attribute: []const u8 = "",
    };

    fn rlsRestrictionMatches(record: *const UserStorageBackend.PolicyRecord, r: RlsRestriction) bool {
        return record.kind == r.kind and
            std.mem.eql(u8, record.getGraph(), r.graph) and
            std.mem.eql(u8, record.getTable(), r.label) and
            std.mem.eql(u8, record.getUsingClause() orelse "", r.subject) and
            std.mem.eql(u8, record.getCheckClause() orelse "", r.attribute);
    }

    // CANARY: REQ=REQ-SONNY-3034-RLS-RESTRICTIONS-DURABLE; FEATURE="RLS deny-policy procedure"; ASPECT=PersistRestriction; STATUS=TESTED; TEST=tests/test_sonny3034_rls_restrictions_durable.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-3034: store `r` in the security graph, signed and sealed: all of
    /// it or none of it. Already stored: nothing to do. The restrictions
    /// lived in the RLS engines only and were lost at every restart.
    pub fn persistRlsRestriction(self: *Self, hmac_key: *const [32]u8, r: RlsRestriction) !void {
        if (r.kind != .rls_deny and r.kind != .rls_attribute) return error.InvalidPolicyKind;
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        {
            var it = self.storage.policyIterator();
            while (it.next()) |record| {
                if (rlsRestrictionMatches(record, r)) return;
            }
        }
        const policy_id = self.storage.nextPolicyId();
        errdefer {
            self.storage.removePolicy(policy_id) catch |err| logRestoreFailure("policy record", err);
            self.sealChain(hmac_key) catch |err| logRestoreFailure("chain seal", err);
        }
        try self.storage.persistPolicy(.{
            .policy_id = policy_id,
            .name = r.kind.property().?,
            .description = "",
            .graph = r.graph,
            .table = r.label,
            .operation = 0,
            .permissive = false,
            .enabled = true,
            .using_clause = if (r.subject.len > 0) r.subject else null,
            .check_clause = if (r.attribute.len > 0) r.attribute else null,
            .audit_level = 0,
            .created_by = 0,
            .kind = r.kind,
            .mode = .create,
        });
        try self.recomputeAndStorePolicyHmac(policy_id, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "ADD_RLS_RESTRICTION", policy_id, r.kind.property().?, null);
    }

    /// SONNY-3034: remove every stored record of `r` and reseal (one step,
    /// as `dropPolicy`). Nothing stored: nothing to do. An error means the
    /// records are still stored.
    pub fn removeRlsRestriction(self: *Self, hmac_key: *const [32]u8, r: RlsRestriction) !void {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.policyIterator();
            while (it.next()) |record| {
                if (rlsRestrictionMatches(record, r)) try ids.append(self.allocator, record.id);
            }
        }
        if (ids.items.len == 0) return;

        var removal_failure: ?anyerror = null;
        var sealed = false;
        {
            self.seal_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.seal_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const seal = try self.computeSealLocked(hmac_key, .{}, ids.items);
            for (ids.items) |policy_id| {
                self.storage.removePolicy(policy_id) catch |err| {
                    removal_failure = err;
                    break;
                };
            }
            if (removal_failure == null) {
                if (self.persistSealLocked(seal)) |_| {
                    sealed = true;
                } else |err| log.warn("geode.rls remove: the graph store did not take the chain seal; sealing again", &.{Attr.string("error", @errorName(err))});
            }
        }
        if (!sealed) self.sealChain(hmac_key) catch try self.sealChain(hmac_key);
        if (removal_failure) |err| return err;
        for (ids.items) |policy_id| self.logSecurityGraphMutation(.configuration_change, "REMOVE_RLS_RESTRICTION", policy_id, r.kind.property().?, null);
    }

    /// SONNY-3034: every stored restriction, for startup hydration, copied
    /// with `allocator` (free with `freeRlsRestrictions`). A malformed
    /// record is left out, and logged.
    pub fn listRlsRestrictions(self: *Self, allocator: std.mem.Allocator) ![]RlsRestriction {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        var out: std.ArrayList(RlsRestriction) = .empty;
        errdefer {
            freeRlsRestrictionItems(allocator, out.items);
            out.deinit(allocator);
        }
        var it = self.storage.policyIterator();
        while (it.next()) |record| {
            if (record.kind != .rls_deny and record.kind != .rls_attribute) continue;
            if (record.malformed) {
                log.err("a stored geode.rls restriction is malformed and is not loaded", &.{
                    Attr.uint("policy_id", record.id),
                    Attr.string("kind", @tagName(record.kind)),
                });
                continue;
            }
            const graph = try allocator.dupe(u8, record.getGraph());
            errdefer allocator.free(graph);
            const label = try allocator.dupe(u8, record.getTable());
            errdefer allocator.free(label);
            const subject = try allocator.dupe(u8, record.getUsingClause() orelse "");
            errdefer allocator.free(subject);
            const attribute = try allocator.dupe(u8, record.getCheckClause() orelse "");
            errdefer allocator.free(attribute);
            try out.append(allocator, .{ .kind = record.kind, .graph = graph, .label = label, .subject = subject, .attribute = attribute });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn freeRlsRestrictions(allocator: std.mem.Allocator, items: []RlsRestriction) void {
        freeRlsRestrictionItems(allocator, items);
        allocator.free(items);
    }

    fn freeRlsRestrictionItems(allocator: std.mem.Allocator, items: []const RlsRestriction) void {
        for (items) |r| {
            allocator.free(r.graph);
            allocator.free(r.label);
            allocator.free(r.subject);
            allocator.free(r.attribute);
        }
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

    // CANARY: REQ=REQ-SONNY-6341-FLE-ROLE-GRANT-STORE; FEATURE="FieldLevelEncryption"; ASPECT=SealedFleRoleGrants; STATUS=TESTED; TEST=tests/test_sonny6341_fle_role_binding.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-6341: let `user_id` act under FLE role `role`. Stored and the
    /// chain resealed, or nothing: a reseal that fails takes the record out
    /// again, so the caller can refuse the grant (fail closed).
    pub fn grantUserFleRole(self: *Self, hmac_key: *const [32]u8, user_id: u64, role: []const u8) !void {
        const was_there = self.storage.fle_role_grant_nodes.contains(UserStorageBackend.fleRoleGrantId(user_id, role));
        _ = try self.storage.persistFleRoleGrant(user_id, role);
        self.sealChain(hmac_key) catch |err| {
            if (!was_there) {
                _ = self.storage.revokeFleRoleGrant(user_id, role);
                self.sealChain(hmac_key) catch {};
            }
            return err;
        };
        self.logSecurityGraphMutation(.configuration_change, "GRANT_FLE_ROLE", user_id, role, null);
    }

    /// SONNY-6341: take FLE role `role` from `user_id`; false when it was
    /// not granted. An error means the revoke may not be saved.
    pub fn revokeUserFleRole(self: *Self, hmac_key: *const [32]u8, user_id: u64, role: []const u8) !bool {
        if (!self.storage.revokeFleRoleGrant(user_id, role)) return false;
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REVOKE_FLE_ROLE", user_id, role, null);
        return true;
    }

    /// SONNY-6341: every FLE role grant of a user being dropped.
    pub fn revokeAllUserFleRoles(self: *Self, hmac_key: *const [32]u8, user_id: u64) !void {
        if (try self.storage.revokeAllFleRoleGrants(user_id) > 0) try self.sealChain(hmac_key);
    }

    /// SONNY-6341: every stored FLE role grant (roles borrow from the store).
    pub fn listFleRoleGrants(self: *Self, allocator: std.mem.Allocator) ![]UserStorageBackend.FleRoleGrantRecord {
        return self.storage.listFleRoleGrants(allocator);
    }

    // CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=GrantWriteThrough; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-1333: GRANT `actions` ON GRAPH `graph_name` for the user: each
    /// grant stored in __geode_security and added to the live grant table
    /// `pol`, or none of them. If any step fails, every grant this call added,
    /// to the store or to `pol`, is taken out again and the error returned: a
    /// failed GRANT confers nothing now and nothing at the next start. A grant
    /// held before the call is left as it was.
    pub fn grantGraphPermissionsWriteThrough(
        self: *Self,
        hmac_key: *const [32]u8,
        pol: ?*geode.multi_graph_security.GraphRBACPolicy,
        user_id: u64,
        graph_name: []const u8,
        actions: []const u8,
    ) !void {
        const max_actions = 8;
        if (actions.len > max_actions) return error.TooManyGrantActions;
        // SONNY-6359: the grant records change under auth_ddl_lock (the auth
        // DDL holds it already; re-entrant), before any graph lock.
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        var stored_new: [max_actions]bool = undefined;
        var live_new: [max_actions]bool = undefined;
        var touched: usize = 0;
        errdefer self.undoGraphGrants(hmac_key, pol, user_id, graph_name, actions[0..touched], stored_new[0..touched], live_new[0..touched]);
        for (actions, 0..) |action, i| {
            stored_new[i] = !self.storage.hasGraphGrant(user_id, graph_name, action);
            live_new[i] = if (pol) |p| !p.hasGraphGrant(user_id, graph_name, action) else false;
            touched = i + 1;
            try self.grantUserGraphPermission(hmac_key, user_id, graph_name, action);
            if (pol) |p| try p.grantGraphPermission(user_id, graph_name, action);
        }
    }

    /// SONNY-1333: the write-throughs above are their own unit of undo. The
    /// statement undo (SONNY-3348) replays a failed statement's store writes
    /// but not this manager's record maps or the HMAC chain, so it would undo
    /// the security graph behind their back (and a statement that recorded a
    /// limit fences, silently, the writes that undo a failed save). They run
    /// with capture and the fence suspended, as the transaction undo does.
    fn suspendStatementUndo() void {
        geode.statement_undo.suspendCapture();
    }

    /// The undo of a failed `grantGraphPermissionsWriteThrough`. The chain is
    /// sealed again whatever was undone: a failed seal, or a re-stored grant
    /// held before, left it stale.
    fn undoGraphGrants(
        self: *Self,
        hmac_key: *const [32]u8,
        pol: ?*geode.multi_graph_security.GraphRBACPolicy,
        user_id: u64,
        graph_name: []const u8,
        actions: []const u8,
        stored_new: []const bool,
        live_new: []const bool,
    ) void {
        for (actions, stored_new, live_new) |action, s, l| {
            if (l) if (pol) |p| {
                _ = p.revokeGraphPermission(user_id, graph_name, action);
            };
            if (s) self.storage.discardGraphGrant(user_id, graph_name, action) catch |err| {
                log.err("SONNY-1333: a failed GRANT left its record stored; it is loaded at the next start unless revoked", &.{
                    Attr.uint("user_id", user_id),
                    Attr.string("graph", graph_name),
                    Attr.uint("action", @as(u64, action)),
                    Attr.string("error", @errorName(err)),
                });
            };
        }
        self.sealChain(hmac_key) catch |err| {
            log.err("SONNY-1333: the security chain could not be sealed after a failed GRANT", &.{Attr.string("error", @errorName(err))});
        };
    }

    // CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=RevokeWriteThrough; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-1333: REVOKE `action` ON GRAPH `graph_name` from the user. The
    /// live grant table `pol` first, so the privilege stops at once whatever
    /// the save does (fail closed), then the stored record. An error means the
    /// record could not be removed: the grant is gone until the next start,
    /// when it is loaded again unless the REVOKE is retried. Returns whether
    /// the grant was held, live or stored.
    pub fn revokeGraphPermissionWriteThrough(
        self: *Self,
        hmac_key: *const [32]u8,
        pol: ?*geode.multi_graph_security.GraphRBACPolicy,
        user_id: u64,
        graph_name: []const u8,
        action: u8,
    ) !bool {
        // SONNY-6359: as grantGraphPermissionsWriteThrough.
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const live_removed = if (pol) |p| p.revokeGraphPermission(user_id, graph_name, action) else false;
        const stored_removed = self.revokeUserGraphPermission(hmac_key, user_id, graph_name, action) catch |err| {
            // The record may be gone with only the seal failed. Seal again:
            // if that holds, the revoke is saved. Otherwise the chain stays
            // stale (a retry that finds no record would not seal it).
            if (self.storage.hasGraphGrant(user_id, graph_name, action)) return err;
            self.sealChain(hmac_key) catch return err;
            return true;
        };
        return live_removed or stored_removed;
    }

    // CANARY: REQ=REQ-SONNY-6359-GRANT-READERS-LOCKED; FEATURE="GQL Auth DDL Persistence"; ASPECT=GrantListingsLocked; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-1333: the stored grants of one user, for SHOW GRANTS. Caller owns
    /// the returned slice. SONNY-6359: under `auth_ddl_lock`, as GRANT /
    /// REVOKE change the grant records under it; it read them unlocked.
    /// Callers hold no graph lock but their session graph's.
    pub fn listGraphGrantsForUser(self: *Self, allocator: std.mem.Allocator, user_id: u64) ![]user_storage.UserStorageBackend.GraphGrantRecord {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        const all = try self.storage.listGraphGrants(allocator);
        defer allocator.free(all);
        var out: std.ArrayList(user_storage.UserStorageBackend.GraphGrantRecord) = .empty;
        errdefer out.deinit(allocator);
        for (all) |g| {
            if (g.user_id == user_id) try out.append(allocator, g);
        }
        return out.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-SONNY-1333-GRANT-PERSIST-FAIL-CLOSED; FEATURE="GQL Auth DDL Persistence"; ASPECT=CreateUserWriteThrough; STATUS=TESTED; TEST=tests/test_sonny1333_grant_persist_show_grants.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-1333: CREATE USER's write-through: the User node and, with
    /// `role_name`, the role node and its HAS_ROLE edge, or none of it. A user
    /// stored without its role was left behind by a failed CREATE USER; the
    /// retry then failed as a duplicate.
    pub fn createUserWithRole(
        self: *Self,
        hmac_key: *const [32]u8,
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        is_superuser: bool,
        role_name: ?[]const u8,
    ) !u64 {
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const uid = try self.createUser(hmac_key, username, email, password_hash, is_superuser);
        errdefer self.removeUser(hmac_key, uid) catch |err| {
            log.err("SONNY-1333: a failed CREATE USER left its user stored", &.{
                Attr.string("user", username),
                Attr.string("error", @errorName(err)),
            });
        };
        if (role_name) |rn| {
            // createRole is idempotent.
            _ = try self.createRole(hmac_key, rn, "");
            if (try self.findRoleIdByName(rn)) |rid| {
                _ = try self.assignUserRole(hmac_key, uid, rid);
            }
        }
        return uid;
    }

    // CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=UserWriteThroughs; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-3038: DROP USER's write-through (`server_init.writerDeleteUser`).
    /// An error means the user is still stored. No such stored user: nothing
    /// to do.
    pub fn deleteUserWriteThrough(self: *Self, hmac_key: *const [32]u8, username: []const u8) !void {
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        // Not stored: a removal whose seals failed may have left the chain
        // unsealed (removeUser); seal it, so the retry that reports success
        // leaves a chain that verifies.
        const uid = (try self.findUserIdByName(username)) orelse return self.sealChain(hmac_key);
        // SONNY-6341: a dropped user's FLE role grants go with it (a user made
        // later under the name holds none).
        try self.revokeAllUserFleRoles(hmac_key, uid);
        try self.removeUser(hmac_key, uid);
    }

    /// SONNY-3038: a password change's write-through
    /// (`server_init.writerUpdatePassword`): stored, or an error and the
    /// stored record as it was.
    pub fn updatePasswordWriteThrough(self: *Self, hmac_key: *const [32]u8, username: []const u8, new_password_hash: []const u8) !void {
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const uid = (try self.findUserIdByName(username)) orelse return;
        _ = try self.updateUserPassword(hmac_key, uid, new_password_hash);
    }

    // CANARY: REQ=REQ-SONNY-6369-LEGACY-HASH-UPGRADE; FEATURE="SecurePasswordVerify"; ASPECT=StoreUpgradedHash; STATUS=TESTED; TEST=tests/test_sonny6369_query_exit_and_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-6369: the login upgrade's write-through
    /// (`user_management.upgradeLegacyHash`, `server_init.writerRehashPassword`):
    /// replace `username`'s stored legacy hash `old_hash` with the Argon2id
    /// hash `new_hash` of the same password. The password is not changed, so
    /// unlike `updateUserPassword` the auth version (the user's sessions), the
    /// reset flag and `password_changed_at` stay. `error.PasswordHashChanged`
    /// when the stored hash is no longer `old_hash` (a concurrent change wins).
    /// All of it or none of it.
    pub fn replaceLegacyPasswordHashWriteThrough(self: *Self, hmac_key: *const [32]u8, username: []const u8, old_hash: []const u8, new_hash: []const u8) !void {
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const uid = (try self.findUserIdByName(username)) orelse return error.UserNotFound;
        const old = self.storage.getUser(uid) orelse return error.UserNotFound;
        if (!std.mem.eql(u8, old.getPasswordHash(), old_hash)) return error.PasswordHashChanged;
        errdefer self.restoreUserRecord(hmac_key, old);
        var record = old;
        record.password_hash_len = UserStorageBackend.copyIntoField(&record.password_hash, new_hash);
        record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
        record.updated_at = compat_milliTimestamp();
        try self.storage.putCachedUser(uid, record);
        try self.storage.upsertUserNode(record);
        try self.recomputeAndStoreUserHmac(uid, hmac_key);
        try self.sealChain(hmac_key);
        self.logSecurityGraphMutation(.configuration_change, "REHASH_PASSWORD", uid, record.getUsername(), null);
    }

    /// SONNY-3038: ALTER USER ... ENABLE / DISABLE's write-through
    /// (`server_init.writerSetActive`): stored, or an error and the stored
    /// record as it was.
    pub fn setActiveWriteThrough(self: *Self, hmac_key: *const [32]u8, username: []const u8, active: bool) !void {
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const uid = (try self.findUserIdByName(username)) orelse return;
        _ = try self.setUserActive(hmac_key, uid, active);
    }

    /// SONNY-3038: a built-in role change's write-through
    /// (`server_init.writerSetRole`): the user's HAS_ROLE edges to the other
    /// built-in roles (`builtin_names`) are revoked and one to `role_name`
    /// assigned (its role node created if missing), all of it or none of it.
    /// Done step by step, a failure part way left the user stored with no
    /// built-in role, or with two. Custom-role edges are not touched.
    pub fn setBuiltinRoleWriteThrough(self: *Self, hmac_key: *const [32]u8, username: []const u8, role_name: []const u8, builtin_names: []const []const u8) !void {
        const max_roles = 8;
        if (builtin_names.len > max_roles) return error.TooManyBuiltinRoles;
        suspendStatementUndo();
        defer geode.statement_undo.resumeCapture();
        const uid = (try self.findUserIdByName(username)) orelse return;
        const old = self.storage.getUser(uid) orelse return error.UserNotFound;

        var revoked: [max_roles]u64 = undefined;
        var revoked_count: usize = 0;
        var created_role: ?u64 = null;
        var assigned_role: ?u64 = null;
        errdefer {
            if (assigned_role) |rid| _ = self.storage.revokeUserRole(uid, rid) catch |err| logRestoreFailure("HAS_ROLE edge", err);
            for (revoked[0..revoked_count]) |rid| _ = self.storage.assignUserRole(uid, rid) catch |err| logRestoreFailure("HAS_ROLE edge", err);
            if (created_role) |rid| self.storage.removeRole(rid) catch |err| logRestoreFailure("role record", err);
            self.restoreUserRecord(hmac_key, old);
        }

        // A user has exactly one built-in role at a time (see writerSetRole).
        for (builtin_names) |other| {
            if (std.mem.eql(u8, other, role_name)) continue;
            const rid = (try self.findRoleIdByName(other)) orelse continue;
            const before = self.authVersionOf(uid);
            // The version moves only when an edge was removed.
            if (try self.revokeUserRole(hmac_key, uid, rid) != before) {
                revoked[revoked_count] = rid;
                revoked_count += 1;
            }
        }

        const existed = (try self.findRoleIdByName(role_name)) != null;
        const rid = try self.createRole(hmac_key, role_name, "");
        if (!existed) created_role = rid;
        const before = self.authVersionOf(uid);
        if (try self.assignUserRole(hmac_key, uid, rid) != before) assigned_role = rid;
    }

    fn authVersionOf(self: *Self, user_id: u64) u64 {
        const record = self.storage.getUser(user_id) orelse return 0;
        return record.auth_version;
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-018; FEATURE="AuthDDLPersistence"; ASPECT=ListGraphGrants; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    /// List all persisted graph grants. Caller owns the returned slice.
    /// SONNY-6359: under `auth_ddl_lock` (see `listGraphGrantsForUser`).
    pub fn listGraphGrants(self: *Self, allocator: std.mem.Allocator) ![]user_storage.UserStorageBackend.GraphGrantRecord {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();
        return self.storage.listGraphGrants(allocator);
    }

    // CANARY: REQ=REQ-SONNY-6352-AUTH-READERS-LOCKED; FEATURE="GQL Auth DDL Persistence"; ASPECT=CanUserAccessGraphLocked; STATUS=TESTED; TEST=tests/test_sonny6352_auth_verify_locking.zig; OWNER=security; UPDATED=2026-11-12
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
    /// Locking (SONNY-6352): holds `auth_ddl_lock` for the scan, as GRANT /
    /// REVOKE hold it while they change `graph_grant_nodes`; it iterated
    /// the map unlocked. Callers (LSP / schema introspection) hold no
    /// graph lock here, as the lock order requires.
    pub fn canUserAccessGraph(self: *Self, user: []const u8, graph_name: []const u8) bool {
        const ddl_guard = geode.security.auth_ddl_lock.acquire();
        defer ddl_guard.release();

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
            // Gap 0034 discipline: hydrate-on-miss so an evicted/not-yet-resident
            // grant body still resolves from the engine (the getNodeProperty
            // reads below already hydrate; the body read must match).
            const node = self.storage.store.getNodePtrHydrated(node_id) orelse continue;
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

    // -- FleRoleGrant HMAC chain support (SONNY-6341) --

    fn sealFleRoleGrantRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.storage.fle_role_grant_nodes.keyIterator();
            while (it.next()) |key| try ids.append(self.allocator, key.*);
        }
        for (ids.items) |grant_id| {
            const node_id = self.storage.fle_role_grant_nodes.get(grant_id) orelse continue;
            const computed = computeFleRoleGrantHmacFromNode(hmac_key, self.storage.store, node_id, grant_id);
            const computed_hex = auth_hmac.hmacToHex(&computed);
            try self.storage.store.setNodeProperty(node_id, "hmac", .{ .String = &computed_hex });
            try hmac_list.append(self.allocator, computed);
        }
    }

    fn verifyFleRoleGrantRecords(self: *Self, hmac_key: *const [32]u8, hmac_list: *std.ArrayList([32]u8)) !void {
        var it = self.storage.fle_role_grant_nodes.iterator();
        while (it.next()) |e| {
            const computed = computeFleRoleGrantHmacFromNode(hmac_key, self.storage.store, e.value_ptr.*, e.key_ptr.*);
            const stored = self.storage.store.getNodeProperty(e.value_ptr.*, "hmac") orelse return error.RecordHmacMismatch;
            if (stored != .String) return error.RecordHmacMismatch;
            const computed_hex = auth_hmac.hmacToHex(&computed);
            if (!std.mem.eql(u8, &computed_hex, stored.String)) return error.RecordHmacMismatch;
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

/// SONNY-6484: one definition, shared with the writer
/// (`UserStorageBackend.persistUserWithHmac`).
fn computeUserHmac(hmac_key: *const [32]u8, record: *const UserStorageBackend.UserRecord) [32]u8 {
    return user_storage.userRecordHmac(hmac_key, record);
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

/// SONNY-2750: the kind is covered once a record has one. A legacy record
/// (no `kind` property) is hashed exactly as before, so its stored HMAC still
/// verifies.
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

    const kind_value: ?[]const u8 = switch (record.kind) {
        .legacy => null,
        .gps, .rls, .rls_deny, .rls_attribute => record.kind.property().?,
        // Not a value any writer stores: it can only match a record signed
        // with it, and no loader uses an `.invalid` record anyway.
        .invalid => "<invalid>",
    };
    const kv = kind_value orelse return computeRecordHmacChecked(hmac_key, &props);
    var with_kind: [props.len + 1]auth_hmac.KeyValue = undefined;
    @memcpy(with_kind[0..props.len], &props);
    with_kind[props.len] = .{ .key = "kind", .value = kv };
    return computeRecordHmacChecked(hmac_key, &with_kind);
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
    return UserStorageBackend.graphGrantId(user_id, graph_name, action);
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

/// SONNY-6341: the HMAC of a FleRoleGrant node, from its stored fields.
fn computeFleRoleGrantHmacFromNode(hmac_key: *const [32]u8, store: *graph_store.GraphStore, node_id: u64, grant_id: u64) [32]u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{grant_id}) catch "0";
    const user_id_val = if (store.getNodeProperty(node_id, "user_id")) |v| if (v == .Int) v.Int else 0 else 0;
    var uid_buf: [20]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{user_id_val}) catch "0";
    const role = if (store.getNodeProperty(node_id, "role")) |v| if (v == .String) v.String else "" else "";
    const granted_at_val = if (store.getNodeProperty(node_id, "granted_at")) |v| if (v == .Int) v.Int else 0 else 0;
    var granted_at_buf: [20]u8 = undefined;
    const granted_at_str = std.fmt.bufPrint(&granted_at_buf, "{d}", .{granted_at_val}) catch "0";
    const props = [_]auth_hmac.KeyValue{
        .{ .key = "fle_role", .value = role },
        .{ .key = "grant_id", .value = id_str },
        .{ .key = "granted_at", .value = granted_at_str },
        .{ .key = "kind", .value = "FleRoleGrant" },
        .{ .key = "user_id", .value = uid_str },
    };
    return computeRecordHmacChecked(hmac_key, &props);
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
    // SONNY-6331: a generated password meets the password policy.
    try testing.expectEqual(@as(?[]const u8, null), geode_auth.PasswordPolicy.geodeSecure().validate(result.password));

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
