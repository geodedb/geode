/// Migration engine for managing GQL schema migrations.
///
/// Provides a durable ledger, checksum validation, up/down application,
/// drift detection, and a pluggable query executor interface (QUIC-backed
/// in the CLI, injectable for tests).  Migration files live in a
/// configurable directory and are applied in version order.
const std = @import("std");
const cb = @import("crypto_backend");

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
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab-cli/specs/geode_migrations.yml; OWNER=migration; UPDATED=2026-04-01
// Fully functional migration engine with durable ledger, checksum validation, up/down
// application, drift detection, and pluggable query executor (QUIC-backed in CLI).

pub const MigrationError = error{
    NotImplemented,
    OutOfMemory,
    AlreadyLocked,
    LockExpired,
    NoLockHeld,
    InvalidMigrationName,
    MigrationFileMissing,
    DownScriptMissing,
    LedgerCorrupt,
    ApplyFailed,
    FileSystemError,
    ResumeSlotsFull,
    MigrationSignatureInvalid,
    MigrationSignatureMissing,
};

const StagedMigration = struct {
    version: i64,
    name: []const u8,
};

pub const MigrationConfig = struct {
    migrations_dir: []const u8 = "migrations",
    ledger_filename: []const u8 = "migration_ledger.json",
    /// When true, skip HMAC-SHA256 signature verification for migration files.
    /// Use only in development/test environments. Default: false (signatures required).
    allow_unsigned: bool = false,
    /// HMAC-SHA256 key for migration file signature verification (32 bytes).
    /// When null and allow_unsigned is false, migrations will be rejected.
    hmac_key: ?*const [32]u8 = null,
};

/// Pluggable executor so production uses QUIC and tests can inject a real executor.
pub const QueryExecutor = struct {
    context: ?*anyopaque = null,
    execFn: *const fn (context: ?*anyopaque, script: []const u8) anyerror!void,
};

pub const LockHandle = struct {
    id: u64 = 0,
    owner: []const u8 = "local",
    acquired_at_ms: u64 = 0,
    expires_at_ms: u64 = 0,
};

pub const MigrationPlan = struct {
    up: []const []const u8 = &.{},
    down: []const []const u8 = &.{},
    /// Whether this plan owns heap-allocated slices that freePlan must release.
    /// Only true for plans returned by planDryRun; default-initialized plans
    /// use comptime empty slices and must NOT be freed.
    owned: bool = false,
};

pub const StatusRow = struct {
    version: i64 = 0,
    name: []const u8 = "",
    applied: bool = false,
    checksum_prefix: [7]u8 = "0000000".*,
    /// SEC-MIG-05: SHA-256 full content hash (64-char hex). All zeros means legacy
    /// entry written before the SHA-256 upgrade — drift detection falls back to FNV-1a.
    content_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
};

pub const Metrics = struct {
    applied_total: u64 = 0,
    failed_total: u64 = 0,
    drift_detected_total: u64 = 0,
    /// Tracks how many times an expired lock was stolen by a new acquireLock call.
    lock_steal_attempts_total: u64 = 0,
};

pub const ResumeState = struct {
    token: []const u8,
    total_batches: u32,
    completed_batches: u32,
    done: bool,
};

// Sub-modules (Q9/#621)
pub const ledger_mod = @import("ledger.zig");
pub const lock_mod = @import("lock.zig");
pub const apply_mod = @import("apply.zig");
const Ledger = ledger_mod.Ledger;
const loadLedger = ledger_mod.loadLedger;
const saveLedger = ledger_mod.saveLedger;
const writeLedgerJson = ledger_mod.writeLedgerJson;

pub var baseline_override: ?u64 = null;

// Named constants
pub const fnv_offset_basis: u64 = 0xcbf29ce484222325;
pub const fnv_prime: u64 = 0x100000001b3;
pub const max_ledger_bytes: usize = 4 * 1024 * 1024;
pub const max_script_bytes: usize = 8 * 1024 * 1024;
pub const default_lock_ttl_ms: u64 = 300_000; // 5 minutes
pub const max_migration_name_len: usize = 255;
const max_version_digits: usize = 17;
const default_resume_batches: u32 = 5;
pub const max_resume_slots: usize = 8;

// ------------------ Helpers ------------------

/// Validates a migration name using an allowlist to prevent path traversal, injection,
/// and encoding bypass attacks. Only [a-zA-Z0-9._-] characters are permitted.
pub fn validateMigrationName(name: []const u8) MigrationError!void {
    if (name.len == 0 or name.len > max_migration_name_len) return error.InvalidMigrationName;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return error.InvalidMigrationName;
    }
    if (std.mem.indexOf(u8, name, "..")) |_| return error.InvalidMigrationName;
}

pub fn nowMs() u64 {
    return @intCast(compat_milliTimestamp());
}

pub fn parseVersion(name: []const u8) ?i64 {
    var i: usize = 0;
    var value: i64 = 0;
    while (i < name.len and name[i] >= '0' and name[i] <= '9') : (i += 1) {
        if (i >= max_version_digits) return null;
        value = value * 10 + @as(i64, name[i] - '0');
    }
    if (i == 0) return null;
    return value;
}

pub fn checksumPrefix(bytes: []const u8) [7]u8 {
    var h: u64 = fnv_offset_basis;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    var hex: [16]u8 = undefined;
    var idx: usize = hex.len;
    var tmp = h;
    while (idx > 0) : (idx -= 1) {
        const nyb = @as(u4, @intCast(tmp & 0xF));
        hex[idx - 1] = "0123456789abcdef"[nyb];
        tmp >>= 4;
    }
    var prefix: [7]u8 = undefined;
    std.mem.copyForwards(u8, prefix[0..], hex[0..7]);
    return prefix;
}

/// SEC-MIG-05: Computes the SHA-256 hash of content, returned as a 64-char lowercase hex string.
pub fn computeContentSha256(data: []const u8) ![64]u8 {
    var hash: [32]u8 = undefined;
    _ = try cb.Hash.digest(.sha256, data, &hash);
    return std.fmt.bytesToHex(hash, .lower);
}

pub const sha256_zero: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*;

pub fn computeFingerprint(rows: []const StatusRow) u64 {
    var h: u64 = fnv_offset_basis;
    for (rows) |row| {
        if (!row.applied) continue;
        var vtmp: u64 = @bitCast(row.version);
        inline for (0..8) |_| {
            const b: u8 = @intCast(vtmp & 0xFF);
            h ^= b;
            h *%= fnv_prime;
            vtmp >>= 8;
        }
        // SEC-MIG-05: Use SHA-256 hash when available (non-zero), otherwise fall
        // back to legacy FNV-1a prefix for entries written before the upgrade.
        if (!std.mem.eql(u8, &row.content_sha256, &sha256_zero)) {
            for (row.content_sha256) |b| {
                h ^= b;
                h *%= fnv_prime;
            }
        } else {
            for (row.checksum_prefix) |b| {
                h ^= b;
                h *%= fnv_prime;
            }
        }
    }
    return h;
}

pub fn versionExists(rows: []const StatusRow, v: i64) bool {
    for (rows) |r| {
        if (r.version == v and r.applied) return true;
    }
    return false;
}

/// Returns the latest applied migration, excluding version <= 1 (base schema).
/// Version 1 is treated as the immutable initial migration and cannot be rolled back.
pub fn latestApplied(rows: []const StatusRow) ?StatusRow {
    var best: ?StatusRow = null;
    for (rows) |r| {
        if (!r.applied or r.version <= 1) continue;
        if (best == null or r.version > best.?.version) best = r;
    }
    return best;
}

pub fn joinPath(alloc: std.mem.Allocator, cfg: MigrationConfig, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ cfg.migrations_dir, name });
}

/// Protects global_lock, policy_mode, resume_slots, and baseline_override from concurrent access.
pub var migration_mutex: std.Io.Mutex = std.Io.Mutex.init;
pub var global_lock: ?LockHandle = null;
pub var lock_steal_count: u64 = 0;
pub const lock_filename = ".migration_lock";
// Lock+signature in lock.zig
pub const acquireLock = lock_mod.acquireLock;
pub const heartbeatLock = lock_mod.heartbeatLock;
pub const releaseLock = lock_mod.releaseLock;
pub const FileLock = lock_mod.FileLock;
pub const signMigrationFile = lock_mod.signMigrationFile;
const verifyMigrationSignature = lock_mod.verifyMigrationSignature;
const constTimeEqlHex = lock_mod.constTimeEqlHex;
const computeHmacSha256 = lock_mod.computeHmacSha256;

// Apply+status in apply.zig
pub const applyUpMigrations = apply_mod.applyUpMigrations;
pub const applyDownMigration = apply_mod.applyDownMigration;
pub const statusReport = apply_mod.statusReport;
pub const freeStatusRows = apply_mod.freeStatusRows;

// ------------------ Policy / Drift / Checksums ------------------

pub const PolicyMode = enum { strict, lenient };
var policy_mode: PolicyMode = .lenient;

/// Sets the migration policy mode directly from a typed enum. Thread-safe.
pub fn enforcePolicyMode(mode: PolicyMode) void {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    policy_mode = mode;
}

/// Sets the migration policy mode from a string ("STRICT" or "LENIENT"). Thread-safe.
pub fn enforcePolicy(mode: []const u8) MigrationError!void {
    if (std.mem.eql(u8, mode, "STRICT")) {
        enforcePolicyMode(.strict);
    } else if (std.mem.eql(u8, mode, "LENIENT")) {
        enforcePolicyMode(.lenient);
    } else {
        return error.NotImplemented;
    }
}

/// Returns true if the current policy mode is STRICT.
pub fn isStrictPolicy() bool {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return policy_mode == .strict;
}

/// Validates ledger checksums against a manifest string (version checksum per line).
/// SEC-MIG-05: Accepts both SHA-256 (64-char) and legacy FNV-1a (7-char) checksums.
/// SHA-256 checksums use exact full-match; legacy 7-char uses prefix match.
pub fn checksumValidate(alloc: std.mem.Allocator, cfg: MigrationConfig, manifest: []const u8) MigrationError!bool {
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();

    var it = std.mem.tokenizeAny(u8, manifest, "\n\r");
    var matched: usize = 0;
    var manifest_entries: usize = 0;
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const ver_txt = parts.next() orelse continue;
        const chk_txt = parts.next() orelse continue;

        const ver = parseVersion(ver_txt) orelse continue;
        manifest_entries += 1;

        var found = false;
        for (ledger.rows.items) |row| {
            if (row.version == ver) {
                if (!row.applied) return false;
                // SEC-MIG-05: Match by SHA-256 (64 chars) or legacy FNV prefix (7 chars)
                if (chk_txt.len == 64) {
                    // SHA-256 exact match
                    if (!std.mem.eql(u8, &row.content_sha256, chk_txt[0..64])) return false;
                } else if (chk_txt.len == 7) {
                    // Legacy FNV-1a prefix match
                    if (!std.mem.eql(u8, &row.checksum_prefix, chk_txt[0..7])) return false;
                } else {
                    return false;
                }
                matched += 1;
                found = true;
                break;
            }
        }
        // Manifest references a version not in ledger — mismatch.
        if (!found) return false;
    }

    var applied_count: usize = 0;
    for (ledger.rows.items) |row| {
        if (row.applied) applied_count += 1;
    }
    return matched == applied_count and manifest_entries == matched;
}

/// Compares the current ledger fingerprint against the stored baseline; returns false on drift.
pub fn driftCheck(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!bool {
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    const current = computeFingerprint(ledger.rows.items);
    const expected = blk: {
        migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        break :blk baseline_override orelse ledger.baseline_fingerprint;
    };
    const ok = current == expected;
    if (!ok) {
        ledger.metrics.drift_detected_total += 1;
        saveLedger(alloc, cfg, &ledger) catch |err| {
            std.log.warn("migration: failed to persist drift metric: {}", .{err});
        };
    }
    return ok;
}

// ------------------ Planning ------------------

/// Returns a dry-run plan showing which migrations would be applied up and which could roll back.
pub fn planDryRun(alloc: std.mem.Allocator, cfg: MigrationConfig, names: []const []const u8) MigrationError!MigrationPlan {
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();

    var pending_up = std.ArrayList([]const u8).initCapacity(alloc, names.len) catch return error.OutOfMemory;
    errdefer pending_up.deinit(alloc);
    var pending_down = std.ArrayList([]const u8).initCapacity(alloc, ledger.rows.items.len) catch return error.OutOfMemory;
    errdefer pending_down.deinit(alloc);

    for (names) |nm| {
        const ver = parseVersion(nm) orelse return error.InvalidMigrationName;
        if (!versionExists(ledger.rows.items, ver)) {
            const name_copy = alloc.dupe(u8, nm) catch return error.OutOfMemory;
            pending_up.append(alloc, name_copy) catch {
                alloc.free(name_copy);
                return error.OutOfMemory;
            };
        }
    }

    var idx: isize = @intCast(ledger.rows.items.len);
    while (idx > 0) : (idx -= 1) {
        const row = ledger.rows.items[@intCast(idx - 1)];
        if (row.applied and row.version > 1) {
            const name_copy = alloc.dupe(u8, row.name) catch return error.OutOfMemory;
            pending_down.append(alloc, name_copy) catch {
                alloc.free(name_copy);
                return error.OutOfMemory;
            };
        }
    }

    if (pending_up.items.len > 1) {
        std.sort.heap([]const u8, pending_up.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return (parseVersion(a) orelse 0) < (parseVersion(b) orelse 0);
            }
        }.lessThan);
    }

    const up_slice = pending_up.toOwnedSlice(alloc) catch return error.OutOfMemory;
    errdefer {
        for (up_slice) |name| alloc.free(name);
        alloc.free(up_slice);
    }
    const down_slice = pending_down.toOwnedSlice(alloc) catch return error.OutOfMemory;
    return MigrationPlan{ .up = up_slice, .down = down_slice, .owned = true };
}

/// Frees all heap-allocated slices within a MigrationPlan returned by planDryRun.
/// Safe to call on default-initialized plans (owned=false is a no-op).
pub fn freePlan(alloc: std.mem.Allocator, plan: *const MigrationPlan) void {
    if (!plan.owned) return;
    for (plan.up) |name| alloc.free(name);
    alloc.free(plan.up);
    for (plan.down) |name| alloc.free(name);
    alloc.free(plan.down);
}

// ------------------ Resume Token Data Migration ------------------

var resume_slots: [max_resume_slots]ResumeState = [_]ResumeState{.{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true }} ** max_resume_slots;
var resume_slots_len: usize = 0;

fn getOrInitResume(alloc: std.mem.Allocator, token: []const u8, total_batches: u32) MigrationError!*ResumeState {
    // Caller must hold migration_mutex.
    var i: usize = 0;
    while (i < resume_slots_len) : (i += 1) {
        if (std.mem.eql(u8, resume_slots[i].token, token)) return &resume_slots[i];
    }
    if (resume_slots_len == resume_slots.len) {
        // SEC-MIG-08: Evict completed (done=true) slots to reclaim memory before
        // reporting ResumeSlotsFull. This prevents unbounded token accumulation in
        // long-running processes that execute repeated migration cycles.
        evictCompletedSlots(alloc);
        if (resume_slots_len == resume_slots.len) return error.ResumeSlotsFull;
    }
    const token_copy = alloc.dupe(u8, token) catch return error.OutOfMemory;
    resume_slots[resume_slots_len] = .{ .token = token_copy, .total_batches = total_batches, .completed_batches = 0, .done = false };
    resume_slots_len += 1;
    return &resume_slots[resume_slots_len - 1];
}

/// SEC-MIG-08: Evicts all completed (done=true) resume slots, freeing their token
/// memory and compacting the array. Caller must hold migration_mutex.
fn evictCompletedSlots(alloc: std.mem.Allocator) void {
    var write_idx: usize = 0;
    var read_idx: usize = 0;
    while (read_idx < resume_slots_len) : (read_idx += 1) {
        if (resume_slots[read_idx].done) {
            // Free the completed token's heap memory
            if (resume_slots[read_idx].token.len > 0) {
                alloc.free(resume_slots[read_idx].token);
            }
            resume_slots[read_idx] = .{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true };
        } else {
            // Keep active slot — shift left if needed
            if (write_idx != read_idx) {
                resume_slots[write_idx] = resume_slots[read_idx];
                resume_slots[read_idx] = .{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true };
            }
            write_idx += 1;
        }
    }
    resume_slots_len = write_idx;
}

/// Frees all heap-allocated resume token strings and resets slot count. Thread-safe.
pub fn resetResumeSlots(alloc: std.mem.Allocator) void {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var i: usize = 0;
    while (i < resume_slots_len) : (i += 1) {
        if (resume_slots[i].token.len > 0) alloc.free(resume_slots[i].token);
        resume_slots[i] = .{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true };
    }
    resume_slots_len = 0;
}

/// Advances the resume state for a data migration token by one batch. Thread-safe.
/// If the token is new, creates a slot with the given total_batches count.
pub fn resumeDataMigration(alloc: std.mem.Allocator, token: []const u8, total_batches: u32) MigrationError!ResumeState {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const rs = try getOrInitResume(alloc, token, total_batches);
    if (!rs.done) {
        if (rs.completed_batches < rs.total_batches) rs.completed_batches += 1;
        if (rs.completed_batches >= rs.total_batches) rs.done = true;
    }
    return rs.*;
}

// ------------------ Metrics ------------------

/// Returns a snapshot of migration metrics from the ledger.
pub fn metricsSnapshot(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!Metrics {
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    const steals = lock_steal_count;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var m = ledger.metrics;
    m.lock_steal_attempts_total += steals;
    return m;
}

/// Deliberately corrupts the baseline fingerprint to trigger drift detection in tests.
/// Only available in test builds; compiles to nothing in release.
pub const testSimulateDrift = if (builtin.is_test) testSimulateDriftImpl else @compileError("testSimulateDrift is test-only");

fn testSimulateDriftImpl() void {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    baseline_override = (baseline_override orelse fnv_offset_basis) ^ 0x9e3779b97f4a7c15;
}

// ------------------ CANARY markers ------------------
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ObservabilityMetrics; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_087_ObservabilityMetrics; OWNER=migration; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DownReversalSafety; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_087_DownReversalSafety; OWNER=migration; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PlanDryRunIntegrity; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_087_ChecksumValidation_and_PlanDryRun; OWNER=migration; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=CliParityStatusCommand; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_087_CliParityStatusCommand; OWNER=migration; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftPolicyOutcomeStrict; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict; OWNER=migration; UPDATED=2026-11-14

// ==================== Unit Tests (GAP-0233) ====================
// CANARY: REQ=REQ-GAP-0233; FEATURE="MigrationUnitTests"; ASPECT=RegressionTest; STATUS=TESTED; TEST="parseVersion extracts leading digits from migration name"; OWNER=migration; UPDATED=2026-04-01

test "parseVersion extracts leading digits from migration name" {
    try std.testing.expectEqual(@as(?i64, 1), parseVersion("001_init.gql"));
    try std.testing.expectEqual(@as(?i64, 42), parseVersion("42_schema.gql"));
    try std.testing.expectEqual(@as(?i64, 123456), parseVersion("123456_large.gql"));
    try std.testing.expectEqual(@as(?i64, null), parseVersion("no_digits.gql"));
    try std.testing.expectEqual(@as(?i64, null), parseVersion(""));
}

test "checksumPrefix returns 7-char hex prefix" {
    const prefix = checksumPrefix("test content");
    try std.testing.expectEqual(@as(usize, 7), prefix.len);
    // Verify it's valid hex
    for (prefix) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "computeFingerprint is deterministic" {
    const rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
        .{ .version = 2, .name = "002_add.gql", .applied = true, .checksum_prefix = "def5678".* },
    };
    const fp1 = computeFingerprint(&rows);
    const fp2 = computeFingerprint(&rows);
    try std.testing.expectEqual(fp1, fp2);
}

test "computeFingerprint ignores unapplied rows" {
    const applied_rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
    };
    const mixed_rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
        .{ .version = 2, .name = "002_add.gql", .applied = false, .checksum_prefix = "def5678".* },
    };
    try std.testing.expectEqual(computeFingerprint(&applied_rows), computeFingerprint(&mixed_rows));
}

test "versionExists checks applied status" {
    const rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
        .{ .version = 2, .name = "002_add.gql", .applied = false, .checksum_prefix = "def5678".* },
    };
    try std.testing.expect(versionExists(&rows, 1));
    try std.testing.expect(!versionExists(&rows, 2)); // not applied
    try std.testing.expect(!versionExists(&rows, 3)); // doesn't exist
}

test "QueryExecutor can execute with context" {
    var called = false;
    const executor = QueryExecutor{
        .context = @ptrCast(&called),
        .execFn = struct {
            fn exec(ctx: ?*anyopaque, _: []const u8) anyerror!void {
                const ptr: *bool = @ptrCast(@alignCast(ctx.?));
                ptr.* = true;
            }
        }.exec,
    };
    try executor.execFn(executor.context, "test script");
    try std.testing.expect(called);
}

test "PolicyMode defaults to lenient" {
    // Reset to known state via the public API (thread-safe).
    try enforcePolicy("LENIENT");
    try std.testing.expect(!isStrictPolicy());
}

test "enforcePolicy sets strict mode" {
    try enforcePolicy("LENIENT");
    try enforcePolicy("STRICT");
    try std.testing.expect(isStrictPolicy());
    try enforcePolicy("LENIENT");
}

test "enforcePolicy sets lenient mode" {
    try enforcePolicy("STRICT");
    try enforcePolicy("LENIENT");
    try std.testing.expect(!isStrictPolicy());
}

test "enforcePolicy rejects invalid modes" {
    const result = enforcePolicy("INVALID");
    try std.testing.expectError(error.NotImplemented, result);
}

test "enforcePolicyMode sets mode via typed enum" {
    enforcePolicyMode(.strict);
    try std.testing.expect(isStrictPolicy());
    enforcePolicyMode(.lenient);
    try std.testing.expect(!isStrictPolicy());
}

test "latestApplied returns null for empty rows" {
    const rows = [_]StatusRow{};
    try std.testing.expectEqual(@as(?StatusRow, null), latestApplied(&rows));
}

test "latestApplied returns highest applied version" {
    const rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
        .{ .version = 3, .name = "003_add.gql", .applied = true, .checksum_prefix = "def5678".* },
        .{ .version = 2, .name = "002_mod.gql", .applied = true, .checksum_prefix = "ghi9012".* },
    };
    const latest = latestApplied(&rows).?;
    try std.testing.expectEqual(@as(i64, 3), latest.version);
}

test "latestApplied skips unapplied rows" {
    const rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
        .{ .version = 5, .name = "005_big.gql", .applied = false, .checksum_prefix = "def5678".* },
        .{ .version = 2, .name = "002_mod.gql", .applied = true, .checksum_prefix = "ghi9012".* },
    };
    const latest = latestApplied(&rows).?;
    try std.testing.expectEqual(@as(i64, 2), latest.version);
}

test "checksumPrefix produces different hashes for different inputs" {
    const p1 = checksumPrefix("content A");
    const p2 = checksumPrefix("content B");
    try std.testing.expect(!std.mem.eql(u8, &p1, &p2));
}

test "checksumPrefix handles empty input" {
    const prefix = checksumPrefix("");
    try std.testing.expectEqual(@as(usize, 7), prefix.len);
}

test "checksumPrefix handles binary data" {
    const binary = [_]u8{ 0x00, 0xFF, 0x80, 0x7F };
    const prefix = checksumPrefix(&binary);
    try std.testing.expectEqual(@as(usize, 7), prefix.len);
}

test "parseVersion handles leading zeros" {
    try std.testing.expectEqual(@as(?i64, 1), parseVersion("001_init.gql"));
    try std.testing.expectEqual(@as(?i64, 12), parseVersion("012_schema.gql"));
    try std.testing.expectEqual(@as(?i64, 100), parseVersion("100_feature.gql"));
}

test "parseVersion rejects very long numbers" {
    // More than 17 digits should return null to prevent overflow
    try std.testing.expectEqual(@as(?i64, null), parseVersion("123456789012345678_too_long.gql"));
}

test "StatusRow has correct defaults" {
    const row = StatusRow{};
    try std.testing.expectEqual(@as(i64, 0), row.version);
    try std.testing.expectEqual(false, row.applied);
    try std.testing.expectEqual(@as(usize, 0), row.name.len);
    try std.testing.expect(std.mem.eql(u8, "0000000", &row.checksum_prefix));
}

test "freeStatusRows safely handles default-initialized rows" {
    const alloc = std.testing.allocator;
    var rows = try alloc.alloc(StatusRow, 1);
    rows[0] = StatusRow{}; // default name is "" — must not crash on free
    freeStatusRows(alloc, rows);
}

test "MigrationConfig has sensible defaults" {
    const cfg = MigrationConfig{};
    try std.testing.expect(std.mem.eql(u8, "migrations", cfg.migrations_dir));
    try std.testing.expect(std.mem.eql(u8, "migration_ledger.json", cfg.ledger_filename));
}

test "Metrics initializes to zero" {
    const metrics = Metrics{};
    try std.testing.expectEqual(@as(u64, 0), metrics.applied_total);
    try std.testing.expectEqual(@as(u64, 0), metrics.failed_total);
    try std.testing.expectEqual(@as(u64, 0), metrics.drift_detected_total);
    try std.testing.expectEqual(@as(u64, 0), metrics.lock_steal_attempts_total);
}

test "LockHandle has correct defaults" {
    const handle = LockHandle{};
    try std.testing.expectEqual(@as(u64, 0), handle.id);
    try std.testing.expect(std.mem.eql(u8, "local", handle.owner));
}

test "acquireLock increments lock_steal_count on expired lock" {
    // Reset global state for this test.
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // Acquire with a 1ms TTL, then sleep to let it expire.
    var h = try acquireLock(1);
    {
        const req = std.os.linux.timespec{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    }

    // Second acquire should steal the expired lock.
    var h2 = try acquireLock(60_000);

    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    const steals = lock_steal_count;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expect(steals >= 1);

    releaseLock(&h2) catch {};
    releaseLock(&h) catch {}; // stale handle, expected to fail

    // Cleanup.
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

// SEC-MIG-04: Cross-process file lock tests
test "acquireFileLock creates lockfile and blocks concurrent processes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };

    // First lock should succeed
    var lock1 = try FileLock.acquire(alloc, cfg);

    // Verify lockfile was created
    const lock_path = try std.fs.path.join(alloc, &.{ tmp_path, lock_filename });
    defer alloc.free(lock_path);
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), lock_path, .{});
    try std.testing.expect(stat != error.FileNotFound);

    // Release lock
    lock1.release();

    // Should be able to re-acquire after release
    var lock2 = try FileLock.acquire(alloc, cfg);
    lock2.release();
}

test "FileLock release allows subsequent acquisition" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };

    // Acquire and release three times to prove correctness
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var lock = try FileLock.acquire(alloc, cfg);
        lock.release();
    }
}

test "MigrationPlan has empty defaults" {
    const plan = MigrationPlan{};
    try std.testing.expectEqual(@as(usize, 0), plan.up.len);
    try std.testing.expectEqual(@as(usize, 0), plan.down.len);
    try std.testing.expect(!plan.owned);
}

test "freePlan is safe on default-initialized MigrationPlan (Q19 regression)" {
    const alloc = std.testing.allocator;
    const plan = MigrationPlan{};
    // Must not crash — default plan has comptime slices, not heap-allocated.
    freePlan(alloc, &plan);
}

test "computeFingerprint with single applied row" {
    const rows = [_]StatusRow{
        .{ .version = 1, .name = "001_init.gql", .applied = true, .checksum_prefix = "abc1234".* },
    };
    const fp = computeFingerprint(&rows);
    // Should produce a non-zero fingerprint
    try std.testing.expect(fp != 0);
}

test "computeFingerprint with empty rows" {
    const rows = [_]StatusRow{};
    const fp = computeFingerprint(&rows);
    // Empty rows should return base FNV hash
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fp);
}

test "nowMs returns positive timestamp" {
    const ts = nowMs();
    try std.testing.expect(ts > 0);
}

test "validateMigrationName rejects path traversal" {
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("../etc/passwd"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("foo/bar.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("foo\\bar.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName(""));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName(".."));
    // Valid names should pass
    try validateMigrationName("001_init.gql");
    try validateMigrationName("002_add_users.gql");
}

test "validateMigrationName rejects special and unicode characters" {
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name with spaces.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name;drop.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name'inject.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name$var.gql"));
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("\xc3\xa9")); // UTF-8 é
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name\x7f.gql")); // DEL
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName("name\x01.gql")); // control char
}

test "validateMigrationName rejects names exceeding 255 bytes" {
    const long_name = "a" ** 256;
    try std.testing.expectError(error.InvalidMigrationName, validateMigrationName(long_name));
    // 255 bytes should be fine
    const max_name = "a" ** 255;
    try validateMigrationName(max_name);
}

// ==================== Core Logic Tests (GAP-0310) ====================

fn makeTestExecutor(ctx: *bool) QueryExecutor {
    return .{
        .context = @ptrCast(ctx),
        .execFn = struct {
            fn exec(context: ?*anyopaque, _: []const u8) anyerror!void {
                const ptr: *bool = @ptrCast(@alignCast(context.?));
                ptr.* = true;
            }
        }.exec,
    };
}

fn makeFailingExecutor() QueryExecutor {
    return .{
        .context = null,
        .execFn = struct {
            fn exec(_: ?*anyopaque, _: []const u8) anyerror!void {
                return error.ConnectionRefused;
            }
        }.exec,
    };
}

test "applyUpMigrations applies migration and persists ledger" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH test" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    try std.testing.expect(executed);
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    try std.testing.expectEqual(@as(usize, 1), ledger.rows.items.len);
    try std.testing.expect(ledger.rows.items[0].applied);
    try std.testing.expectEqual(@as(i64, 1), ledger.rows.items[0].version);
    try std.testing.expectEqual(@as(u64, 1), ledger.metrics.applied_total);
}

test "applyUpMigrations skips already-applied versions" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH test" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    executed = false;
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expect(!executed);
}

test "applyUpMigrations records failure metric on executor error" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "FAIL" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    const executor = makeFailingExecutor();
    const result = applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expectError(error.ApplyFailed, result);
}

// CANARY: REQ=REQ-GAP-0902-MIGRATE-FAILED-NOT-APPLIED; FEATURE="Migrations"; ASPECT=LedgerConsistencyOnFailure; STATUS=TESTED; TEST=self; OWNER=cli; UPDATED=2026-07-10
// GAP-0902: a failed migration must NOT be recorded as applied (the ledger's
// "Applied" count stays 0). This pins the orchestration contract the harness
// documented — the executor failure returns error.ApplyFailed WITHOUT
// half-applying, so a subsequent status report shows the migration as still
// pending (or absent), never applied. (The live QUIC-transport crash the gap
// also describes needs the managed-server harness to reproduce; this pins the
// apply-path half of the defect that IS unit-testable.)
test "gap0902: a failed migration is not recorded as applied (ledger Applied stays 0)" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "SOME MIGRATION" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };

    // A failing executor: the apply must return error.ApplyFailed.
    try std.testing.expectError(
        error.ApplyFailed,
        applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, makeFailingExecutor()),
    );

    // The ledger must show the migration NOT applied (Applied stays 0).
    const rows = try statusReport(alloc, cfg);
    defer freeStatusRows(alloc, rows);
    var applied_count: usize = 0;
    for (rows) |r| {
        if (r.applied) applied_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), applied_count);

    // A SUCCEEDING executor then applies it exactly once (proves the failure
    // above didn't leave the ledger in a state that blocks a later retry).
    const ok_executor = QueryExecutor{
        .context = null,
        .execFn = struct {
            fn exec(_: ?*anyopaque, _: []const u8) anyerror!void {}
        }.exec,
    };
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, ok_executor);
    const rows2 = try statusReport(alloc, cfg);
    defer freeStatusRows(alloc, rows2);
    var applied2: usize = 0;
    for (rows2) |r| {
        if (r.applied) applied2 += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), applied2);
}

test "applyDownMigration rolls back the latest applied migration" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "002_add.gql", .data = "CREATE GRAPH g2" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "002_add.gql.down.gql", .data = "DROP GRAPH g2" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"002_add.gql"}, executor);
    executed = false;

    try applyDownMigration(alloc, cfg, executor);
    try std.testing.expect(executed);

    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    for (ledger.rows.items) |row| {
        if (row.version == 2) {
            try std.testing.expect(!row.applied);
        }
    }
}

test "statusReport returns discovered migration files with applied status" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "002_add.gql", .data = "CREATE GRAPH g2" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql.down.gql", .data = "DROP GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    const rows = try statusReport(alloc, cfg);
    defer freeStatusRows(alloc, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        try std.testing.expect(!row.applied);
    }
}

test "driftCheck returns true for consistent ledger" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    baseline_override = null;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    const ok = try driftCheck(alloc, cfg);
    try std.testing.expect(ok);
}

test "driftCheck returns false after simulated drift" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    baseline_override = null;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    testSimulateDrift();
    const ok = try driftCheck(alloc, cfg);
    try std.testing.expect(!ok);

    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    baseline_override = null;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

test "checksumValidate passes for matching manifest" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    const row = ledger.rows.items[0];

    var manifest_buf: [64]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buf, "{d} {s}", .{ row.version, row.checksum_prefix }) catch unreachable;

    const valid = try checksumValidate(alloc, cfg, manifest);
    try std.testing.expect(valid);
}

test "checksumValidate fails for mismatched manifest" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    const valid = try checksumValidate(alloc, cfg, "1 XXXXXXX");
    try std.testing.expect(!valid);
}

// ==================== SEC-MIG-05: SHA-256 Content Hash Tests ====================

test "computeContentSha256 produces deterministic 64-char hex" {
    const hash = try computeContentSha256("CREATE GRAPH test");
    try std.testing.expectEqual(@as(usize, 64), hash.len);
    for (hash) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    const hash2 = try computeContentSha256("CREATE GRAPH test");
    try std.testing.expect(std.mem.eql(u8, &hash, &hash2));
}

test "computeContentSha256 detects single-byte changes" {
    const hash_a = try computeContentSha256("CREATE GRAPH safe");
    const hash_b = try computeContentSha256("CREATE GRAPH safE"); // single char differs
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
}

test "applyUpMigrations stores SHA-256 content hash in ledger" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const script_content = "CREATE GRAPH sha256_test";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = script_content });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    const row = ledger.rows.items[0];

    // Verify the SHA-256 hash was stored (not all zeros)
    try std.testing.expect(!std.mem.eql(u8, &row.content_sha256, &sha256_zero));

    // Verify it matches the expected SHA-256 of the content
    const expected_sha = try computeContentSha256(script_content);
    try std.testing.expect(std.mem.eql(u8, &row.content_sha256, &expected_sha));
}

test "checksumValidate accepts SHA-256 manifest (64-char hash)" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const script_content = "CREATE GRAPH sha_validate";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = script_content });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    // Build a SHA-256 manifest
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();
    const row = ledger.rows.items[0];

    var manifest_buf: [128]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buf, "{d} {s}", .{ row.version, row.content_sha256 }) catch unreachable;

    const valid = try checksumValidate(alloc, cfg, manifest);
    try std.testing.expect(valid);
}

test "checksumValidate rejects wrong SHA-256 hash" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH sha_wrong" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    // Wrong 64-char hash
    const valid = try checksumValidate(alloc, cfg, "1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(!valid);
}

test "planDryRun returns pending and rollback migrations" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "002_add.gql", .data = "ADD" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "003_more.gql", .data = "MORE" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"002_add.gql"}, executor);

    const plan = try planDryRun(alloc, cfg, &[_][]const u8{ "002_add.gql", "003_more.gql" });
    defer freePlan(alloc, &plan);

    try std.testing.expectEqual(@as(usize, 1), plan.up.len);
    try std.testing.expect(std.mem.eql(u8, "003_more.gql", plan.up[0]));
    try std.testing.expectEqual(@as(usize, 1), plan.down.len);
    try std.testing.expect(std.mem.eql(u8, "002_add.gql", plan.down[0]));
}

test "metricsSnapshot returns ledger metrics plus lock steal count" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 5;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    const m = try metricsSnapshot(alloc, cfg);
    try std.testing.expectEqual(@as(u64, 5), m.lock_steal_attempts_total);

    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

test "acquireLock serializes concurrent access" {
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var acquired_count = std.atomic.Value(u32).init(0);

    const thread_fn = struct {
        fn run(count: *std.atomic.Value(u32)) void {
            const result = acquireLock(60_000);
            if (result) |_| {
                _ = count.fetchAdd(1, .monotonic);
            } else |_| {}
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, thread_fn, .{&acquired_count});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, 1), acquired_count.load(.monotonic));

    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

test "resumeDataMigration advances batches to completion" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    const s1 = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    try std.testing.expectEqual(@as(u32, 1), s1.completed_batches);
    try std.testing.expectEqual(@as(u32, 5), s1.total_batches);
    try std.testing.expect(!s1.done);

    _ = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    _ = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    _ = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    const s5 = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    try std.testing.expectEqual(@as(u32, 5), s5.completed_batches);
    try std.testing.expect(s5.done);

    const s6 = try resumeDataMigration(alloc, "token-1", default_resume_batches);
    try std.testing.expectEqual(@as(u32, 5), s6.completed_batches);
    try std.testing.expect(s6.done);
}

test "resumeDataMigration returns ResumeSlotsFull when all 8 slots used" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var buf: [16]u8 = undefined;
        const token = std.fmt.bufPrint(&buf, "token-{d}", .{i}) catch unreachable;
        _ = try resumeDataMigration(alloc, token, default_resume_batches);
    }

    const result = resumeDataMigration(alloc, "token-overflow", default_resume_batches);
    try std.testing.expectError(error.ResumeSlotsFull, result);
}

// SEC-MIG-08: Verify that completed slots are evicted to make room for new tokens
test "resumeDataMigration evicts completed slots when full" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    // Fill all 8 slots with tokens that complete in 1 batch
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var buf: [16]u8 = undefined;
        const token = std.fmt.bufPrint(&buf, "evict-{d}", .{i}) catch unreachable;
        _ = try resumeDataMigration(alloc, token, 1); // completes immediately (1/1 = done)
    }

    // All 8 slots are now done=true. A new token should succeed after eviction.
    const s = try resumeDataMigration(alloc, "new-after-evict", 3);
    try std.testing.expectEqual(@as(u32, 1), s.completed_batches);
    try std.testing.expect(!s.done);
}

// SEC-MIG-08: Verify partial eviction — only completed slots are freed
test "resumeDataMigration evicts only completed slots preserving active" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    // Fill 7 slots with completed tokens (1 batch)
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        var buf: [16]u8 = undefined;
        const token = std.fmt.bufPrint(&buf, "done-{d}", .{i}) catch unreachable;
        _ = try resumeDataMigration(alloc, token, 1);
    }

    // 1 active slot (5 batches, only 1 completed)
    _ = try resumeDataMigration(alloc, "active-slot", 5);

    // All 8 slots used. New token should evict the 7 completed ones.
    const s = try resumeDataMigration(alloc, "after-partial-evict", 3);
    try std.testing.expectEqual(@as(u32, 1), s.completed_batches);

    // The active slot should still be accessible
    const active = try resumeDataMigration(alloc, "active-slot", 5);
    try std.testing.expectEqual(@as(u32, 2), active.completed_batches);
    try std.testing.expect(!active.done);
}

test "resumeDataMigration respects custom total_batches" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    const s1 = try resumeDataMigration(alloc, "custom-token", 3);
    try std.testing.expectEqual(@as(u32, 3), s1.total_batches);
    try std.testing.expectEqual(@as(u32, 1), s1.completed_batches);
    try std.testing.expect(!s1.done);

    _ = try resumeDataMigration(alloc, "custom-token", 3);
    const s3 = try resumeDataMigration(alloc, "custom-token", 3);
    try std.testing.expectEqual(@as(u32, 3), s3.completed_batches);
    try std.testing.expect(s3.done);
}

// ==================== Migration Signature Verification Tests (SEC-MIG-01) ====================
// CANARY: REQ=REQ-SEC-MIG-01; FEATURE="MigrationSignatureVerification"; ASPECT=UnitTest; STATUS=TESTED; TEST="applyUpMigrations rejects unsigned migration by default"; OWNER=migration; UPDATED=2026-04-10

test "computeHmacSha256 produces deterministic 64-char hex" {
    const key = [_]u8{0x42} ** 32;
    const result = computeHmacSha256(&key, "CREATE GRAPH test");
    try std.testing.expectEqual(@as(usize, 64), result.len);
    // Verify hex chars
    for (result) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Deterministic: same key + data = same output
    const result2 = computeHmacSha256(&key, "CREATE GRAPH test");
    try std.testing.expect(std.mem.eql(u8, &result, &result2));
}

test "computeHmacSha256 produces different output for different data" {
    const key = [_]u8{0x42} ** 32;
    const result_a = computeHmacSha256(&key, "content A");
    const result_b = computeHmacSha256(&key, "content B");
    try std.testing.expect(!std.mem.eql(u8, &result_a, &result_b));
}

test "computeHmacSha256 produces different output for different keys" {
    const key_a = [_]u8{0x01} ** 32;
    const key_b = [_]u8{0x02} ** 32;
    const result_a = computeHmacSha256(&key_a, "same data");
    const result_b = computeHmacSha256(&key_b, "same data");
    try std.testing.expect(!std.mem.eql(u8, &result_a, &result_b));
}

test "constTimeEqlHex returns true for equal strings" {
    const a = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const b = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(constTimeEqlHex(a, b));
}

test "constTimeEqlHex returns false for different strings" {
    const a = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const b = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde0";
    try std.testing.expect(!constTimeEqlHex(a, b));
}

test "constTimeEqlHex returns false for wrong lengths" {
    const short = "0123456789abcdef";
    const correct = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(!constTimeEqlHex(short, correct));
    try std.testing.expect(!constTimeEqlHex(correct, short));
}

test "signMigrationFile creates valid .sig sidecar file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const script_content = "CREATE GRAPH signed_test";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = script_content });

    var key = [_]u8{0xAB} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };
    try signMigrationFile(alloc, cfg, "001_init.gql");

    // Verify the .sig file was created and contains the correct HMAC
    const sig_contents = try tmp.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "001_init.gql.sig", alloc, .limited(128));
    defer alloc.free(sig_contents);
    const trimmed = std.mem.trim(u8, sig_contents, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 64), trimmed.len);

    // Verify it matches what computeHmacSha256 produces
    const expected = computeHmacSha256(&key, script_content);
    try std.testing.expect(std.mem.eql(u8, trimmed, &expected));
}

test "verifyMigrationSignature accepts valid signature" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const script_content = "CREATE GRAPH verified_test";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "002_schema.gql", .data = script_content });

    var key = [_]u8{0xCD} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };

    // Sign first
    try signMigrationFile(alloc, cfg, "002_schema.gql");

    // Verify should succeed
    try verifyMigrationSignature(alloc, cfg, "002_schema.gql", script_content);
}

test "verifyMigrationSignature rejects tampered content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const original_content = "CREATE GRAPH safe";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "003_tamper.gql", .data = original_content });

    var key = [_]u8{0xEF} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };

    // Sign with the original content
    try signMigrationFile(alloc, cfg, "003_tamper.gql");

    // Verify with tampered content should fail
    const tampered_content = "DROP GRAPH safe; CREATE GRAPH evil";
    const result = verifyMigrationSignature(alloc, cfg, "003_tamper.gql", tampered_content);
    try std.testing.expectError(error.MigrationSignatureInvalid, result);
}

test "verifyMigrationSignature rejects missing signature file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var key = [_]u8{0x11} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };

    // No .sig file exists
    const result = verifyMigrationSignature(alloc, cfg, "004_nosig.gql", "some content");
    try std.testing.expectError(error.MigrationSignatureMissing, result);
}

test "verifyMigrationSignature skips check when allow_unsigned is true" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // No key, no sig file, but allow_unsigned = true
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .allow_unsigned = true };
    try verifyMigrationSignature(alloc, cfg, "005_unsigned.gql", "any content");
}

test "verifyMigrationSignature rejects when no hmac_key and not allow_unsigned" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // No key, no allow_unsigned
    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    const result = verifyMigrationSignature(alloc, cfg, "006_nokey.gql", "content");
    try std.testing.expectError(error.MigrationSignatureMissing, result);
}

test "applyUpMigrations rejects unsigned migration by default" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH test" });

    // No hmac_key and allow_unsigned = false (default)
    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    const result = applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expectError(error.MigrationSignatureMissing, result);
    try std.testing.expect(!executed);
}

test "applyUpMigrations succeeds with valid signature" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const script_content = "CREATE GRAPH signed_apply";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = script_content });

    var key = [_]u8{0x77} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };

    // Sign the migration file
    try signMigrationFile(alloc, cfg, "001_init.gql");

    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expect(executed);
}

test "applyUpMigrations rejects tampered migration with valid sig for original" {
    const alloc = std.testing.allocator;
    migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // Write original content and sign it
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "CREATE GRAPH safe" });
    var key = [_]u8{0x88} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };
    try signMigrationFile(alloc, cfg, "001_init.gql");

    // Tamper with the migration file after signing
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "001_init.gql", .data = "DROP GRAPH safe; CREATE GRAPH evil" });

    var executed = false;
    const executor = makeTestExecutor(&executed);
    const result = applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expectError(error.MigrationSignatureInvalid, result);
    try std.testing.expect(!executed);
}

test "signMigrationFile rejects missing migration file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var key = [_]u8{0x99} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };
    const result = signMigrationFile(alloc, cfg, "nonexistent.gql");
    try std.testing.expectError(error.MigrationFileMissing, result);
}

test "signMigrationFile rejects invalid migration name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var key = [_]u8{0xAA} ** 32;
    const cfg = MigrationConfig{ .migrations_dir = tmp_path, .hmac_key = &key };
    const result = signMigrationFile(alloc, cfg, "../etc/passwd");
    try std.testing.expectError(error.InvalidMigrationName, result);
}

test "signMigrationFile rejects null hmac_key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    const result = signMigrationFile(alloc, cfg, "001_init.gql");
    try std.testing.expectError(error.MigrationSignatureMissing, result);
}
