/// Migration execution — applies up/down migrations and reports status.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("mod.zig");
const lock_mod = @import("lock.zig");
const ledger_mod = root.ledger_mod;
const MigrationError = root.MigrationError;
const MigrationConfig = root.MigrationConfig;
const QueryExecutor = root.QueryExecutor;
const StatusRow = root.StatusRow;
const max_script_bytes = root.max_script_bytes;
const default_lock_ttl_ms = root.default_lock_ttl_ms;
const Ledger = ledger_mod.Ledger;
const StagedMigration = struct { version: i64, name: []const u8 };

pub fn applyUpMigrations(alloc: std.mem.Allocator, cfg: MigrationConfig, names: []const []const u8, executor: QueryExecutor) MigrationError!void {
    var file_lock = lock_mod.FileLock.acquire(alloc, cfg) catch |err| {
        std.log.warn("migration: failed to acquire file lock: {}", .{err});
        return error.AlreadyLocked;
    };
    defer file_lock.release();
    var lock = try lock_mod.acquireLock(default_lock_ttl_ms);
    defer lock_mod.releaseLock(&lock) catch {};
    var ledger = try ledger_mod.loadLedger(alloc, cfg);
    defer ledger.deinit();
    var staged = std.ArrayList(StagedMigration).initCapacity(alloc, names.len) catch return error.OutOfMemory;
    defer staged.deinit(alloc);
    names_loop: for (names) |nm| {
        try root.validateMigrationName(nm);
        const ver = root.parseVersion(nm) orelse return error.InvalidMigrationName;
        if (root.versionExists(ledger.rows.items, ver)) continue;
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
        const path = root.joinPath(alloc, cfg, entry.name) catch return error.OutOfMemory;
        defer alloc.free(path);
        const script = std.fs.cwd().readFileAlloc(alloc, path, max_script_bytes) catch return error.MigrationFileMissing;
        defer alloc.free(script);
        try lock_mod.verifyMigrationSignature(alloc, cfg, entry.name, script);
        executor.execFn(executor.context, script) catch |err| {
            std.log.warn("migration: executor failed on version {d}: {}", .{ entry.version, err });
            ledger.metrics.failed_total += 1;
            return error.ApplyFailed;
        };
        const prefix = root.checksumPrefix(script);
        const sha256 = root.computeContentSha256(script);
        const new_name = alloc.dupe(u8, entry.name) catch return error.OutOfMemory;
        ledger.rows.append(alloc, .{ .version = entry.version, .name = new_name, .applied = true, .checksum_prefix = prefix, .content_sha256 = sha256 }) catch {
            alloc.free(new_name);
            return error.OutOfMemory;
        };
        ledger.metrics.applied_total += 1;
        ledger.baseline_fingerprint = root.computeFingerprint(ledger.rows.items);
        try ledger_mod.saveLedger(alloc, cfg, &ledger);
    }
}

pub fn applyDownMigration(alloc: std.mem.Allocator, cfg: MigrationConfig, executor: QueryExecutor) MigrationError!void {
    var file_lock = lock_mod.FileLock.acquire(alloc, cfg) catch |err| {
        std.log.warn("migration: failed to acquire file lock for down-migration: {}", .{err});
        return error.AlreadyLocked;
    };
    defer file_lock.release();
    var lock = try lock_mod.acquireLock(default_lock_ttl_ms);
    defer lock_mod.releaseLock(&lock) catch {};
    var ledger = try ledger_mod.loadLedger(alloc, cfg);
    defer ledger.deinit();
    const latest = root.latestApplied(ledger.rows.items) orelse return error.DownScriptMissing;
    const down_name = std.fmt.allocPrint(alloc, "{s}.down.gql", .{latest.name}) catch return error.OutOfMemory;
    defer alloc.free(down_name);
    const down_path = root.joinPath(alloc, cfg, down_name) catch return error.OutOfMemory;
    defer alloc.free(down_path);
    const script = std.fs.cwd().readFileAlloc(alloc, down_path, max_script_bytes) catch return error.DownScriptMissing;
    defer alloc.free(script);
    executor.execFn(executor.context, script) catch |err| {
        std.log.warn("migration: down-migration executor failed on version {d}: {}", .{ latest.version, err });
        ledger.metrics.failed_total += 1;
        return error.ApplyFailed;
    };
    for (ledger.rows.items, 0..) |row, idx| {
        if (row.version == latest.version and row.applied) {
            alloc.free(row.name);
            _ = ledger.rows.orderedRemove(idx);
            break;
        }
    }
    ledger.baseline_fingerprint = root.computeFingerprint(ledger.rows.items);
    try ledger_mod.saveLedger(alloc, cfg, &ledger);
}

pub fn statusReport(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError![]StatusRow {
    var ledger = try ledger_mod.loadLedger(alloc, cfg);
    defer ledger.deinit();
    var dir = std.fs.cwd().openDir(cfg.migrations_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return alloc.alloc(StatusRow, 0) catch return error.OutOfMemory;
        }
        return error.FileSystemError;
    };
    defer dir.close();
    var result = std.ArrayList(StatusRow).initCapacity(alloc, 16) catch return error.OutOfMemory;
    errdefer {
        for (result.items) |row| {
            if (row.name.len > 0) alloc.free(row.name);
        }
        result.deinit(alloc);
    }
    var it = dir.iterate();
    while (true) {
        const entry = it.next() catch return error.FileSystemError;
        if (entry == null) break;
        if (entry.?.kind == .file and std.mem.endsWith(u8, entry.?.name, ".gql") and !std.mem.endsWith(u8, entry.?.name, ".down.gql")) {
            const ver = root.parseVersion(entry.?.name) orelse continue;
            const name_copy = alloc.dupe(u8, entry.?.name) catch return error.OutOfMemory;
            errdefer alloc.free(name_copy);
            var applied = false;
            var checksum_prefix: [7]u8 = "0000000".*;
            var content_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*;
            for (ledger.rows.items) |row| {
                if (row.version == ver and row.applied) {
                    applied = true;
                    checksum_prefix = row.checksum_prefix;
                    content_sha256 = row.content_sha256;
                    break;
                }
            }
            result.append(alloc, .{ .version = ver, .name = name_copy, .applied = applied, .checksum_prefix = checksum_prefix, .content_sha256 = content_sha256 }) catch {
                alloc.free(name_copy);
                return error.OutOfMemory;
            };
        }
    }
    if (result.items.len > 1) {
        std.sort.heap(StatusRow, result.items, {}, struct {
            fn lessThan(_: void, a: StatusRow, b: StatusRow) bool {
                return a.version < b.version;
            }
        }.lessThan);
    }
    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

pub fn freeStatusRows(alloc: std.mem.Allocator, rows: []StatusRow) void {
    for (rows) |row| {
        if (row.name.len > 0) alloc.free(row.name);
    }
    alloc.free(rows);
}
