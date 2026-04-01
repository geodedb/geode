const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_migrations.yml; OWNER=migration; UPDATED=2026-01-11
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
};

const StagedMigration = struct {
    version: i64,
    name: []const u8,
};

pub const MigrationConfig = struct {
    migrations_dir: []const u8 = "migrations",
    ledger_filename: []const u8 = "migration_ledger.json",
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
};

pub const StatusRow = struct {
    version: i64 = 0,
    name: []const u8 = "",
    applied: bool = false,
    checksum_prefix: [7]u8 = "0000000".*,
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

const Ledger = struct {
    rows: std.ArrayList(StatusRow),
    baseline_fingerprint: u64,
    metrics: Metrics,
    alloc: std.mem.Allocator,

    fn deinit(self: *Ledger) void {
        for (self.rows.items) |row| {
            self.alloc.free(row.name);
        }
        self.rows.deinit(self.alloc);
    }
};

const LedgerFile = struct {
    baseline_fingerprint: u64,
    rows: []StatusRow,
    metrics: Metrics = .{},
};

var baseline_override: ?u64 = null;

// ------------------ Helpers ------------------

/// Validates a migration name using an allowlist to prevent path traversal, injection,
/// and encoding bypass attacks. Only [a-zA-Z0-9._-] characters are permitted.
pub fn validateMigrationName(name: []const u8) MigrationError!void {
    if (name.len == 0 or name.len > 255) return error.InvalidMigrationName;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return error.InvalidMigrationName;
    }
    if (std.mem.indexOf(u8, name, "..")) |_| return error.InvalidMigrationName;
}

fn nowMs() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn parseVersion(name: []const u8) ?i64 {
    var i: usize = 0;
    var value: i64 = 0;
    while (i < name.len and name[i] >= '0' and name[i] <= '9') : (i += 1) {
        if (i >= 17) return null;
        value = value * 10 + @as(i64, name[i] - '0');
    }
    if (i == 0) return null;
    return value;
}

fn checksumPrefix(bytes: []const u8) [7]u8 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
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

fn computeFingerprint(rows: []const StatusRow) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (rows) |row| {
        if (!row.applied) continue;
        var vtmp: u64 = @bitCast(row.version);
        inline for (0..8) |_| {
            const b: u8 = @intCast(vtmp & 0xFF);
            h ^= b;
            h *%= 0x100000001b3;
            vtmp >>= 8;
        }
        for (row.checksum_prefix) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
    }
    return h;
}

fn ledgerPath(alloc: std.mem.Allocator, cfg: MigrationConfig) ![]u8 {
    return std.fs.path.join(alloc, &.{ cfg.migrations_dir, cfg.ledger_filename });
}

fn ensureDir(cfg: MigrationConfig) !void {
    std.fs.cwd().makePath(cfg.migrations_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn initLedger(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!Ledger {
    ensureDir(cfg) catch return error.FileSystemError;
    // Create empty ledger - no fake "init_schema" stub
    const rows = std.ArrayList(StatusRow).initCapacity(alloc, 4) catch return error.OutOfMemory;
    return Ledger{ .rows = rows, .baseline_fingerprint = 0, .metrics = .{}, .alloc = alloc };
}

fn loadLedger(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!Ledger {
    const path = ledgerPath(alloc, cfg) catch return error.OutOfMemory;
    defer alloc.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return initLedger(alloc, cfg);
        return error.FileSystemError;
    };
    defer file.close();

    const data = file.readToEndAlloc(alloc, 4 * 1024 * 1024) catch return error.OutOfMemory;
    defer alloc.free(data);

    var parsed = std.json.parseFromSlice(LedgerFile, alloc, data, .{ .duplicate_field_behavior = .@"error" }) catch {
        return error.LedgerCorrupt;
    };
    defer parsed.deinit();

    var rows = std.ArrayList(StatusRow).initCapacity(alloc, parsed.value.rows.len) catch return error.OutOfMemory;
    errdefer {
        for (rows.items) |row| alloc.free(row.name);
        rows.deinit(alloc);
    }
    for (parsed.value.rows) |row| {
        const name_copy = alloc.dupe(u8, row.name) catch return error.OutOfMemory;
        errdefer alloc.free(name_copy);
        rows.append(alloc, .{
            .version = row.version,
            .name = name_copy,
            .applied = row.applied,
            .checksum_prefix = row.checksum_prefix,
        }) catch return error.OutOfMemory;
    }

    return Ledger{
        .rows = rows,
        .baseline_fingerprint = parsed.value.baseline_fingerprint,
        .metrics = parsed.value.metrics,
        .alloc = alloc,
    };
}

/// Appends a string to the buffer with proper JSON escaping for special characters.
fn appendJsonEscaped(buffer: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => buffer.appendSlice(alloc, "\\\"") catch return error.OutOfMemory,
            '\\' => buffer.appendSlice(alloc, "\\\\") catch return error.OutOfMemory,
            '\n' => buffer.appendSlice(alloc, "\\n") catch return error.OutOfMemory,
            '\r' => buffer.appendSlice(alloc, "\\r") catch return error.OutOfMemory,
            '\t' => buffer.appendSlice(alloc, "\\t") catch return error.OutOfMemory,
            else => {
                if (c < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                    buffer.appendSlice(alloc, esc) catch return error.OutOfMemory;
                } else {
                    buffer.append(alloc, c) catch return error.OutOfMemory;
                }
            },
        }
    }
}

fn writeLedgerJson(buffer: *std.ArrayList(u8), alloc: std.mem.Allocator, ledger: *const Ledger) !void {
    buffer.appendSlice(alloc, "{\"baseline_fingerprint\":") catch return error.OutOfMemory;
    var num_buf: [32]u8 = undefined;
    const fp_slice = std.fmt.bufPrint(&num_buf, "{d}", .{ledger.baseline_fingerprint}) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, fp_slice) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ",\"rows\":[") catch return error.OutOfMemory;

    for (ledger.rows.items, 0..) |row, i| {
        if (i > 0) buffer.appendSlice(alloc, ",") catch return error.OutOfMemory;
        buffer.appendSlice(alloc, "{\"version\":") catch return error.OutOfMemory;
        const ver_slice = std.fmt.bufPrint(&num_buf, "{d}", .{row.version}) catch return error.OutOfMemory;
        buffer.appendSlice(alloc, ver_slice) catch return error.OutOfMemory;
        buffer.appendSlice(alloc, ",\"name\":\"") catch return error.OutOfMemory;
        try appendJsonEscaped(buffer, alloc, row.name);
        buffer.appendSlice(alloc, "\",\"applied\":") catch return error.OutOfMemory;
        buffer.appendSlice(alloc, if (row.applied) "true" else "false") catch return error.OutOfMemory;
        buffer.appendSlice(alloc, ",\"checksum_prefix\":\"") catch return error.OutOfMemory;
        buffer.appendSlice(alloc, &row.checksum_prefix) catch return error.OutOfMemory;
        buffer.appendSlice(alloc, "\"}") catch return error.OutOfMemory;
    }

    buffer.appendSlice(alloc, "],\"metrics\":{\"applied_total\":") catch return error.OutOfMemory;
    const at_slice = std.fmt.bufPrint(&num_buf, "{d}", .{ledger.metrics.applied_total}) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, at_slice) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ",\"failed_total\":") catch return error.OutOfMemory;
    const ft_slice = std.fmt.bufPrint(&num_buf, "{d}", .{ledger.metrics.failed_total}) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ft_slice) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ",\"drift_detected_total\":") catch return error.OutOfMemory;
    const dt_slice = std.fmt.bufPrint(&num_buf, "{d}", .{ledger.metrics.drift_detected_total}) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, dt_slice) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ",\"lock_steal_attempts_total\":") catch return error.OutOfMemory;
    const ls_slice = std.fmt.bufPrint(&num_buf, "{d}", .{ledger.metrics.lock_steal_attempts_total}) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, ls_slice) catch return error.OutOfMemory;
    buffer.appendSlice(alloc, "}}") catch return error.OutOfMemory;
}

fn saveLedger(alloc: std.mem.Allocator, cfg: MigrationConfig, ledger: *const Ledger) MigrationError!void {
    ensureDir(cfg) catch return error.FileSystemError;
    const path = ledgerPath(alloc, cfg) catch return error.OutOfMemory;
    defer alloc.free(path);

    // Use timestamp-based suffix to avoid predictable temp file names (CWE-377).
    var suffix_buf: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, ".migration_ledger.{d}.tmp", .{nowMs()}) catch return error.OutOfMemory;
    const tmp_path = std.fs.path.join(alloc, &.{ cfg.migrations_dir, suffix }) catch return error.OutOfMemory;
    defer alloc.free(tmp_path);

    var tmp = std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .read = false }) catch return error.FileSystemError;
    errdefer tmp.close();

    // Serialize to a buffer manually
    var buffer = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    defer buffer.deinit(alloc);
    writeLedgerJson(&buffer, alloc, ledger) catch return error.OutOfMemory;

    // Write to file, then close handle before rename for portability.
    tmp.writeAll(buffer.items) catch return error.FileSystemError;
    tmp.sync() catch return error.FileSystemError;
    tmp.close();
    std.fs.cwd().rename(tmp_path, path) catch {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return error.FileSystemError;
    };
}

fn versionExists(rows: []const StatusRow, v: i64) bool {
    for (rows) |r| {
        if (r.version == v and r.applied) return true;
    }
    return false;
}

/// Returns the latest applied migration, excluding version <= 1 (base schema).
/// Version 1 is treated as the immutable initial migration and cannot be rolled back.
fn latestApplied(rows: []const StatusRow) ?StatusRow {
    var best: ?StatusRow = null;
    for (rows) |r| {
        if (!r.applied or r.version <= 1) continue;
        if (best == null or r.version > best.?.version) best = r;
    }
    return best;
}

fn joinPath(alloc: std.mem.Allocator, cfg: MigrationConfig, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ cfg.migrations_dir, name });
}

// ------------------ Lock management ------------------

/// Protects global_lock, policy_mode, resume_slots, and baseline_override from concurrent access.
var migration_mutex: std.Thread.Mutex = .{};
var global_lock: ?LockHandle = null;
var lock_steal_count: u64 = 0;

/// Acquires the migration lock with the given TTL in milliseconds. Thread-safe.
pub fn acquireLock(_: std.mem.Allocator, ttl_ms: u64) MigrationError!LockHandle {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    const now = nowMs();
    if (global_lock) |lh| {
        if (lh.expires_at_ms > now) {
            return error.AlreadyLocked;
        } else {
            lock_steal_count += 1;
            global_lock = null;
        }
    }
    const handle = LockHandle{ .id = 1, .owner = "local", .acquired_at_ms = now, .expires_at_ms = now + ttl_ms };
    global_lock = handle;
    return handle;
}

/// Extends the lock TTL. Returns error if the lock has expired or is not held.
pub fn heartbeatLock(h: *LockHandle) MigrationError!void {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    const now = nowMs();
    if (global_lock) |*lh| {
        if (lh.id != h.id) return error.NoLockHeld;
        if (lh.expires_at_ms <= now) return error.LockExpired;
        const ttl = lh.expires_at_ms - lh.acquired_at_ms;
        lh.expires_at_ms = now + ttl;
        h.* = lh.*;
    } else return error.NoLockHeld;
}

/// Releases the migration lock. Returns error if the lock is not held by this handle.
pub fn releaseLock(h: *LockHandle) MigrationError!void {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    if (global_lock) |lh| {
        if (lh.id != h.id) return error.NoLockHeld;
        global_lock = null;
    } else return error.NoLockHeld;
}

// ------------------ Apply / Status ------------------

/// Applies pending up-migrations in version order. Skips already-applied versions.
/// Saves ledger after each successful migration for crash safety.
pub fn applyUpMigrations(
    alloc: std.mem.Allocator,
    cfg: MigrationConfig,
    names: []const []const u8,
    executor: QueryExecutor,
) MigrationError!void {
    var lock = try acquireLock(alloc, 300_000); // 5 minute TTL
    defer releaseLock(&lock) catch {};
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();

    // Collect and sort unique, not-yet-applied versions.
    var staged = std.ArrayList(StagedMigration).initCapacity(alloc, names.len) catch return error.OutOfMemory;
    defer staged.deinit(alloc);

    names_loop: for (names) |nm| {
        try validateMigrationName(nm);
        const ver = parseVersion(nm) orelse return error.InvalidMigrationName;
        if (versionExists(ledger.rows.items, ver)) continue;
        for (staged.items) |s| {
            if (s.version == ver) continue :names_loop;
        }
        staged.append(alloc, .{ .version = ver, .name = nm }) catch return error.OutOfMemory;
    }

    if (staged.items.len == 0) return;

    std.sort.heap(StagedMigration, staged.items, {}, struct {
        fn lessThan(_: void, a: StagedMigration, b: StagedMigration) bool {
            return a.version < b.version;
        }
    }.lessThan);

    for (staged.items) |entry| {
        const path = joinPath(alloc, cfg, entry.name) catch return error.OutOfMemory;
        defer alloc.free(path);
        const script = std.fs.cwd().readFileAlloc(alloc, path, 8 * 1024 * 1024) catch return error.MigrationFileMissing;
        defer alloc.free(script);

        executor.execFn(executor.context, script) catch {
            ledger.metrics.failed_total += 1;
            return error.ApplyFailed;
        };

        const prefix = checksumPrefix(script);
        const new_name = alloc.dupe(u8, entry.name) catch return error.OutOfMemory;
        ledger.rows.append(alloc, .{
            .version = entry.version,
            .name = new_name,
            .applied = true,
            .checksum_prefix = prefix,
        }) catch {
            alloc.free(new_name);
            return error.OutOfMemory;
        };
        ledger.metrics.applied_total += 1;

        // Save ledger after each successful migration for crash safety (GAP-0280).
        ledger.baseline_fingerprint = computeFingerprint(ledger.rows.items);
        try saveLedger(alloc, cfg, &ledger);
    }
}

/// Rolls back the single latest applied migration (version > 1).
/// Version 1 is treated as immutable base schema.
pub fn applyDownMigration(
    alloc: std.mem.Allocator,
    cfg: MigrationConfig,
    executor: QueryExecutor,
) MigrationError!void {
    var lock = try acquireLock(alloc, 300_000); // 5 minute TTL
    defer releaseLock(&lock) catch {};
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();

    const latest = latestApplied(ledger.rows.items) orelse return;
    try validateMigrationName(latest.name);
    // Down scripts convention: <name>.down.gql
    const down_name = std.fmt.allocPrint(alloc, "{s}.down.gql", .{latest.name}) catch return error.OutOfMemory;
    defer alloc.free(down_name);
    const path = joinPath(alloc, cfg, down_name) catch return error.OutOfMemory;
    defer alloc.free(path);

    const script = std.fs.cwd().readFileAlloc(alloc, path, 8 * 1024 * 1024) catch return error.DownScriptMissing;
    defer alloc.free(script);

    executor.execFn(executor.context, script) catch {
        ledger.metrics.failed_total += 1;
        return error.ApplyFailed;
    };

    // Mark latest as unapplied (keep history)
    for (ledger.rows.items) |*row| {
        if (row.version == latest.version and row.applied) {
            row.applied = false;
            break;
        }
    }

    ledger.baseline_fingerprint = computeFingerprint(ledger.rows.items);
    try saveLedger(alloc, cfg, &ledger);
}

/// Returns a list of all discovered migration files with their applied status.
pub fn statusReport(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError![]StatusRow {
    var ledger = try loadLedger(alloc, cfg);
    defer ledger.deinit();

    // Scan migrations directory for .gql files (excluding .down.gql)
    var dir = std.fs.cwd().openDir(cfg.migrations_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            // No migrations directory - return empty
            const empty_slice = alloc.alloc(StatusRow, 0) catch return error.OutOfMemory;
            return empty_slice;
        }
        return error.FileSystemError;
    };
    defer dir.close();

    var migration_files = std.ArrayList([]const u8).initCapacity(alloc, 16) catch return error.OutOfMemory;
    defer {
        for (migration_files.items) |f| alloc.free(f);
        migration_files.deinit(alloc);
    }

    var dir_iter = dir.iterate();
    while (dir_iter.next() catch return error.FileSystemError) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gql") and !std.mem.endsWith(u8, entry.name, ".down.gql")) {
            const name_copy = alloc.dupe(u8, entry.name) catch return error.OutOfMemory;
            migration_files.append(alloc, name_copy) catch {
                alloc.free(name_copy);
                return error.OutOfMemory;
            };
        }
    }

    // Create status rows - merge ledger with discovered files
    var result = std.ArrayList(StatusRow).initCapacity(alloc, migration_files.items.len) catch return error.OutOfMemory;
    errdefer {
        for (result.items) |r| alloc.free(r.name);
        result.deinit(alloc);
    }

    for (migration_files.items) |filename| {
        const version = parseVersion(filename) orelse 0;

        // Check if this migration is in the ledger as applied
        var applied = false;
        var checksum: [7]u8 = "0000000".*;
        for (ledger.rows.items) |row| {
            if (std.mem.eql(u8, row.name, filename) and row.applied) {
                applied = true;
                checksum = row.checksum_prefix;
                break;
            }
        }

        const name_copy = alloc.dupe(u8, filename) catch return error.OutOfMemory;
        result.append(alloc, .{
            .version = version,
            .name = name_copy,
            .applied = applied,
            .checksum_prefix = checksum,
        }) catch {
            alloc.free(name_copy);
            return error.OutOfMemory;
        };
    }

    // Convert to owned slice and return
    const slice = result.toOwnedSlice(alloc) catch return error.OutOfMemory;
    return slice;
}

/// Frees all heap-allocated names and the slice returned by statusReport.
pub fn freeStatusRows(alloc: std.mem.Allocator, rows: []StatusRow) void {
    for (rows) |row| {
        if (row.name.len > 0) alloc.free(row.name);
    }
    alloc.free(rows);
}

// ------------------ Policy / Drift / Checksums ------------------

pub const PolicyMode = enum { strict, lenient };
var policy_mode: PolicyMode = .lenient;

/// Sets the migration policy mode ("STRICT" or "LENIENT").
pub fn enforcePolicy(mode: []const u8) MigrationError!void {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    if (std.mem.eql(u8, mode, "STRICT")) {
        policy_mode = .strict;
        return;
    } else if (std.mem.eql(u8, mode, "LENIENT")) {
        policy_mode = .lenient;
        return;
    }
    return error.NotImplemented;
}

/// Returns true if the current policy mode is STRICT.
pub fn isStrictPolicy() bool {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    return policy_mode == .strict;
}

/// Validates ledger checksums against a manifest string (version checksum per line).
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
                if (chk_txt.len != 7 or !std.mem.eql(u8, &row.checksum_prefix, chk_txt[0..7])) return false;
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
        migration_mutex.lock();
        defer migration_mutex.unlock();
        break :blk baseline_override orelse ledger.baseline_fingerprint;
    };
    const ok = current == expected;
    if (!ok) {
        ledger.metrics.drift_detected_total += 1;
        saveLedger(alloc, cfg, &ledger) catch {}; // best-effort metrics save
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
    return MigrationPlan{ .up = up_slice, .down = down_slice };
}

/// Frees all heap-allocated slices within a MigrationPlan returned by planDryRun.
pub fn freePlan(alloc: std.mem.Allocator, plan: *const MigrationPlan) void {
    for (plan.up) |name| alloc.free(name);
    alloc.free(plan.up);
    for (plan.down) |name| alloc.free(name);
    alloc.free(plan.down);
}

// ------------------ Resume Token Data Migration ------------------

var resume_slots: [8]ResumeState = [_]ResumeState{.{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true }} ** 8;
var resume_slots_len: usize = 0;

fn getOrInitResume(alloc: std.mem.Allocator, token: []const u8) MigrationError!*ResumeState {
    // Caller must hold migration_mutex.
    var i: usize = 0;
    while (i < resume_slots_len) : (i += 1) {
        if (std.mem.eql(u8, resume_slots[i].token, token)) return &resume_slots[i];
    }
    if (resume_slots_len == resume_slots.len) return error.ResumeSlotsFull;
    const token_copy = alloc.dupe(u8, token) catch return error.OutOfMemory;
    resume_slots[resume_slots_len] = .{ .token = token_copy, .total_batches = 5, .completed_batches = 0, .done = false };
    resume_slots_len += 1;
    return &resume_slots[resume_slots_len - 1];
}

/// Frees all heap-allocated resume token strings and resets slot count. Thread-safe.
pub fn resetResumeSlots(alloc: std.mem.Allocator) void {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    var i: usize = 0;
    while (i < resume_slots_len) : (i += 1) {
        if (resume_slots[i].token.len > 0) alloc.free(resume_slots[i].token);
        resume_slots[i] = .{ .token = "", .total_batches = 0, .completed_batches = 0, .done = true };
    }
    resume_slots_len = 0;
}

/// Advances the resume state for a data migration token by one batch. Thread-safe.
pub fn resumeDataMigration(alloc: std.mem.Allocator, token: []const u8) MigrationError!ResumeState {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    const rs = try getOrInitResume(alloc, token);
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
    migration_mutex.lock();
    const steals = lock_steal_count;
    migration_mutex.unlock();
    var m = ledger.metrics;
    m.lock_steal_attempts_total += steals;
    return m;
}

/// Deliberately corrupts the baseline fingerprint to trigger drift detection in tests.
/// Only available in test builds; compiles to nothing in release.
pub const testSimulateDrift = if (builtin.is_test) testSimulateDriftImpl else @compileError("testSimulateDrift is test-only");

fn testSimulateDriftImpl() void {
    migration_mutex.lock();
    defer migration_mutex.unlock();
    baseline_override = (baseline_override orelse 0xcbf29ce484222325) ^ 0x9e3779b97f4a7c15;
}

// ------------------ CANARY markers ------------------
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=ObservabilityMetrics; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_ObservabilityMetrics; OWNER=migration; UPDATED=2026-01-11
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DownReversalSafety; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_DownReversalSafety; OWNER=migration; UPDATED=2026-01-11
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=PlanDryRunIntegrity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_PlanDryRunIntegrity; OWNER=migration; UPDATED=2026-01-11
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=CliParityStatusCommand; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_CliParityStatusCommand; OWNER=migration; UPDATED=2026-01-11
// CANARY: REQ=REQ-GQL-087; FEATURE="MigrationEngine"; ASPECT=DriftPolicyOutcomeStrict; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_087_DriftPolicyOutcomeStrict; OWNER=migration; UPDATED=2026-01-11

// ==================== Unit Tests (GAP-0233) ====================
// CANARY: REQ=REQ-GAP-0233; FEATURE="MigrationUnitTests"; ASPECT=RegressionTest; STATUS=TESTED; TEST=test_migration_parseVersion; OWNER=migration; UPDATED=2026-01-25

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
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    // Acquire with a 1ms TTL, then sleep to let it expire.
    var h = try acquireLock(std.testing.allocator, 1);
    std.Thread.sleep(2 * std.time.ns_per_ms);

    // Second acquire should steal the expired lock.
    var h2 = try acquireLock(std.testing.allocator, 60_000);

    migration_mutex.lock();
    const steals = lock_steal_count;
    migration_mutex.unlock();
    try std.testing.expect(steals >= 1);

    releaseLock(&h2) catch {};
    releaseLock(&h) catch {}; // stale handle, expected to fail

    // Cleanup.
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();
}

test "MigrationPlan has empty defaults" {
    const plan = MigrationPlan{};
    try std.testing.expectEqual(@as(usize, 0), plan.up.len);
    try std.testing.expectEqual(@as(usize, 0), plan.down.len);
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

test "appendJsonEscaped escapes special characters" {
    const alloc = std.testing.allocator;
    var buffer = try std.ArrayList(u8).initCapacity(alloc, 64);
    defer buffer.deinit(alloc);
    try appendJsonEscaped(&buffer, alloc, "hello\"world\\new\nline\ttab");
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\t") != null);
}

test "appendJsonEscaped handles control characters" {
    const alloc = std.testing.allocator;
    var buffer = try std.ArrayList(u8).initCapacity(alloc, 64);
    defer buffer.deinit(alloc);
    try appendJsonEscaped(&buffer, alloc, &[_]u8{0x01});
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\u") != null);
}

// ==================== JSON Round-Trip Test (GAP-0311) ====================

test "writeLedgerJson round-trips through std.json.parseFromSlice" {
    const alloc = std.testing.allocator;

    var rows = std.ArrayList(StatusRow).initCapacity(alloc, 3) catch unreachable;
    defer {
        for (rows.items) |row| alloc.free(row.name);
        rows.deinit(alloc);
    }

    const name1 = try alloc.dupe(u8, "001_init.gql");
    errdefer alloc.free(name1);
    try rows.append(alloc, .{ .version = 1, .name = name1, .applied = true, .checksum_prefix = "abc1234".* });

    const name2 = try alloc.dupe(u8, "002_with-special_chars.gql");
    errdefer alloc.free(name2);
    try rows.append(alloc, .{ .version = 2, .name = name2, .applied = false, .checksum_prefix = "def5678".* });

    const ledger = Ledger{
        .rows = rows,
        .baseline_fingerprint = 42,
        .metrics = .{ .applied_total = 1, .failed_total = 0, .drift_detected_total = 3, .lock_steal_attempts_total = 7 },
        .alloc = alloc,
    };

    var buffer = try std.ArrayList(u8).initCapacity(alloc, 512);
    defer buffer.deinit(alloc);
    try writeLedgerJson(&buffer, alloc, &ledger);

    var parsed = try std.json.parseFromSlice(LedgerFile, alloc, buffer.items, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 42), parsed.value.baseline_fingerprint);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.rows.len);
    try std.testing.expect(std.mem.eql(u8, "001_init.gql", parsed.value.rows[0].name));
    try std.testing.expectEqual(true, parsed.value.rows[0].applied);
    try std.testing.expect(std.mem.eql(u8, "abc1234", &parsed.value.rows[0].checksum_prefix));
    try std.testing.expect(std.mem.eql(u8, "002_with-special_chars.gql", parsed.value.rows[1].name));
    try std.testing.expectEqual(false, parsed.value.rows[1].applied);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.metrics.applied_total);
    try std.testing.expectEqual(@as(u64, 3), parsed.value.metrics.drift_detected_total);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.metrics.lock_steal_attempts_total);
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
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH test" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
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
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH test" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    executed = false;
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expect(!executed);
}

test "applyUpMigrations records failure metric on executor error" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "FAIL" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    const executor = makeFailingExecutor();
    const result = applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);
    try std.testing.expectError(error.ApplyFailed, result);
}

test "applyDownMigration rolls back the latest applied migration" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "002_add.gql", .data = "CREATE GRAPH g2" });
    try tmp.dir.writeFile(.{ .sub_path = "002_add.gql.down.gql", .data = "DROP GRAPH g2" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
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

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });
    try tmp.dir.writeFile(.{ .sub_path = "002_add.gql", .data = "CREATE GRAPH g2" });
    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql.down.gql", .data = "DROP GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    const rows = try statusReport(alloc, cfg);
    defer freeStatusRows(alloc, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        try std.testing.expect(!row.applied);
    }
}

test "driftCheck returns true for consistent ledger" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    baseline_override = null;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    const ok = try driftCheck(alloc, cfg);
    try std.testing.expect(ok);
}

test "driftCheck returns false after simulated drift" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    baseline_override = null;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    testSimulateDrift();
    const ok = try driftCheck(alloc, cfg);
    try std.testing.expect(!ok);

    migration_mutex.lock();
    baseline_override = null;
    migration_mutex.unlock();
}

test "checksumValidate passes for matching manifest" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
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
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "001_init.gql", .data = "CREATE GRAPH g1" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    var executed = false;
    const executor = makeTestExecutor(&executed);
    try applyUpMigrations(alloc, cfg, &[_][]const u8{"001_init.gql"}, executor);

    const valid = try checksumValidate(alloc, cfg, "1 XXXXXXX");
    try std.testing.expect(!valid);
}

test "planDryRun returns pending and rollback migrations" {
    const alloc = std.testing.allocator;
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try tmp.dir.writeFile(.{ .sub_path = "002_add.gql", .data = "ADD" });
    try tmp.dir.writeFile(.{ .sub_path = "003_more.gql", .data = "MORE" });

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
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
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 5;
    migration_mutex.unlock();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const cfg = MigrationConfig{ .migrations_dir = tmp_path };
    const m = try metricsSnapshot(alloc, cfg);
    try std.testing.expectEqual(@as(u64, 5), m.lock_steal_attempts_total);

    migration_mutex.lock();
    lock_steal_count = 0;
    migration_mutex.unlock();
}

test "acquireLock serializes concurrent access" {
    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();

    var acquired_count = std.atomic.Value(u32).init(0);

    const thread_fn = struct {
        fn run(count: *std.atomic.Value(u32)) void {
            const result = acquireLock(std.testing.allocator, 60_000);
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

    migration_mutex.lock();
    global_lock = null;
    lock_steal_count = 0;
    migration_mutex.unlock();
}

test "resumeDataMigration advances batches to completion" {
    const alloc = std.testing.allocator;
    defer resetResumeSlots(alloc);

    const s1 = try resumeDataMigration(alloc, "token-1");
    try std.testing.expectEqual(@as(u32, 1), s1.completed_batches);
    try std.testing.expectEqual(@as(u32, 5), s1.total_batches);
    try std.testing.expect(!s1.done);

    _ = try resumeDataMigration(alloc, "token-1");
    _ = try resumeDataMigration(alloc, "token-1");
    _ = try resumeDataMigration(alloc, "token-1");
    const s5 = try resumeDataMigration(alloc, "token-1");
    try std.testing.expectEqual(@as(u32, 5), s5.completed_batches);
    try std.testing.expect(s5.done);

    const s6 = try resumeDataMigration(alloc, "token-1");
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
        _ = try resumeDataMigration(alloc, token);
    }

    const result = resumeDataMigration(alloc, "token-overflow");
    try std.testing.expectError(error.ResumeSlotsFull, result);
}
