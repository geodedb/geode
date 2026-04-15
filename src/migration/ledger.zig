/// Ledger persistence — durable JSON ledger for migration state.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("mod.zig");
const MigrationError = root.MigrationError;
const MigrationConfig = root.MigrationConfig;
const StatusRow = root.StatusRow;
const Metrics = root.Metrics;
const max_ledger_bytes = root.max_ledger_bytes;

pub const Ledger = struct {
    rows: std.ArrayList(StatusRow),
    baseline_fingerprint: u64,
    metrics: Metrics,
    alloc: std.mem.Allocator,
    pub fn deinit(self: *Ledger) void {
        for (self.rows.items) |row| self.alloc.free(row.name);
        self.rows.deinit(self.alloc);
    }
};

const LedgerFile = struct {
    baseline_fingerprint: u64,
    rows: []StatusRow,
    metrics: Metrics = .{},
};

pub fn ledgerPath(alloc: std.mem.Allocator, cfg: MigrationConfig) ![]u8 {
    return std.fs.path.join(alloc, &.{ cfg.migrations_dir, cfg.ledger_filename });
}

pub fn ensureDir(cfg: MigrationConfig) !void {
    std.Io.Dir.cwd().makePath(cfg.migrations_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub fn initLedger(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!Ledger {
    ensureDir(cfg) catch return error.FileSystemError;
    const rows = std.ArrayList(StatusRow).initCapacity(alloc, 4) catch return error.OutOfMemory;
    return Ledger{ .rows = rows, .baseline_fingerprint = 0, .metrics = .{}, .alloc = alloc };
}

pub fn loadLedger(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!Ledger {
    const path = ledgerPath(alloc, cfg) catch return error.OutOfMemory;
    defer alloc.free(path);
    var file = std.Io.Dir.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return initLedger(alloc, cfg);
        return error.FileSystemError;
    };
    defer file.close();
    const data = file.readToEndAlloc(alloc, max_ledger_bytes) catch return error.OutOfMemory;
    defer alloc.free(data);
    var parsed = std.json.parseFromSlice(LedgerFile, alloc, data, .{ .duplicate_field_behavior = .@"error" }) catch return error.LedgerCorrupt;
    defer parsed.deinit();
    var rows = std.ArrayList(StatusRow).initCapacity(alloc, parsed.value.rows.len) catch return error.OutOfMemory;
    errdefer {
        for (rows.items) |row| alloc.free(row.name);
        rows.deinit(alloc);
    }
    for (parsed.value.rows) |row| {
        const name_copy = alloc.dupe(u8, row.name) catch return error.OutOfMemory;
        errdefer alloc.free(name_copy);
        rows.append(alloc, .{ .version = row.version, .name = name_copy, .applied = row.applied, .checksum_prefix = row.checksum_prefix, .content_sha256 = row.content_sha256 }) catch return error.OutOfMemory;
    }
    return Ledger{ .rows = rows, .baseline_fingerprint = parsed.value.baseline_fingerprint, .metrics = parsed.value.metrics, .alloc = alloc };
}

pub fn writeLedgerJson(buffer: *std.ArrayList(u8), alloc: std.mem.Allocator, ledger: *const Ledger) !void {
    const ledger_file = LedgerFile{ .baseline_fingerprint = ledger.baseline_fingerprint, .rows = ledger.rows.items, .metrics = ledger.metrics };
    const json_bytes = std.json.Stringify.valueAlloc(alloc, ledger_file, .{}) catch return error.OutOfMemory;
    defer alloc.free(json_bytes);
    buffer.appendSlice(alloc, json_bytes) catch return error.OutOfMemory;
}

pub fn saveLedger(alloc: std.mem.Allocator, cfg: MigrationConfig, ledger: *const Ledger) MigrationError!void {
    ensureDir(cfg) catch return error.FileSystemError;
    const path = ledgerPath(alloc, cfg) catch return error.OutOfMemory;
    defer alloc.free(path);
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);
    var suffix_buf: [96]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, ".migration_ledger.{d}.{s}.tmp", .{ root.nowMs(), rand_hex }) catch return error.OutOfMemory;
    const tmp_path = std.fs.path.join(alloc, &.{ cfg.migrations_dir, suffix }) catch return error.OutOfMemory;
    defer alloc.free(tmp_path);
    var tmp = std.Io.Dir.cwd().createFile(tmp_path, .{ .truncate = true, .read = false }) catch return error.FileSystemError;
    errdefer tmp.close();
    if (builtin.os.tag != .windows) tmp.chmod(0o600) catch {};
    var buffer = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    defer buffer.deinit(alloc);
    writeLedgerJson(&buffer, alloc, ledger) catch return error.OutOfMemory;
    tmp.writeAll(buffer.items) catch return error.FileSystemError;
    tmp.sync() catch return error.FileSystemError;
    tmp.close();
    std.Io.Dir.cwd().rename(tmp_path, path) catch {
        std.Io.Dir.cwd().deleteFile(tmp_path) catch {};
        return error.FileSystemError;
    };
}
