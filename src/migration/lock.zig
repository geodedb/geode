/// Migration lock management and HMAC signature verification.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("mod.zig");
const ledger_mod = root.ledger_mod;
const MigrationError = root.MigrationError;
const MigrationConfig = root.MigrationConfig;
const LockHandle = root.LockHandle;
const max_script_bytes = root.max_script_bytes;

pub fn acquireLock(ttl_ms: u64) MigrationError!LockHandle {
    root.migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer root.migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const now = root.nowMs();
    if (root.global_lock) |lh| {
        if (lh.expires_at_ms > now) return error.AlreadyLocked;
        root.lock_steal_count += 1;
        root.global_lock = null;
    }
    const handle = LockHandle{ .id = 1, .owner = "local", .acquired_at_ms = now, .expires_at_ms = now + ttl_ms };
    root.global_lock = handle;
    return handle;
}

pub fn heartbeatLock(h: *LockHandle) MigrationError!void {
    root.migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer root.migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const now = root.nowMs();
    if (root.global_lock) |*lh| {
        if (lh.id != h.id) return error.NoLockHeld;
        if (lh.expires_at_ms <= now) return error.LockExpired;
        const ttl = lh.expires_at_ms - lh.acquired_at_ms;
        lh.expires_at_ms = now + ttl;
        h.* = lh.*;
    } else return error.NoLockHeld;
}

pub fn releaseLock(h: *LockHandle) MigrationError!void {
    root.migration_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer root.migration_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (root.global_lock) |lh| {
        if (lh.id != h.id) return error.NoLockHeld;
        root.global_lock = null;
    } else return error.NoLockHeld;
}

// CANARY: REQ=REQ-SEC-MIG-04; FEATURE="CrossProcessMigrationLock"; ASPECT=FileLock; STATUS=TESTED; OWNER=migration; UPDATED=2026-04-10
pub const FileLock = struct {
    file: std.Io.File,
    pub fn acquire(alloc: std.mem.Allocator, cfg: MigrationConfig) MigrationError!FileLock {
        ledger_mod.ensureDir(cfg) catch return error.FileSystemError;
        const path = std.fs.path.join(alloc, &.{ cfg.migrations_dir, root.lock_filename }) catch return error.OutOfMemory;
        defer alloc.free(path);
        const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = false, .read = true }) catch return error.FileSystemError;
        errdefer file.close();
        if (builtin.os.tag != .windows) file.chmod(0o600) catch {};
        if (builtin.os.tag != .windows) file.lock(.exclusive) catch return error.AlreadyLocked;
        return .{ .file = file };
    }
    pub fn release(self: *FileLock) void {
        if (builtin.os.tag != .windows) self.file.unlock(std.Io.Threaded.global_single_threaded.io());
        self.file.close();
    }
};

// CANARY: REQ=REQ-SEC-MIG-01; FEATURE="MigrationSignatureVerification"; ASPECT=IntegrityCheck; STATUS=TESTED; OWNER=migration; UPDATED=2026-04-10
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn computeHmacSha256(key: *const [32]u8, data: []const u8) [64]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, data, key);
    return std.fmt.bytesToHex(mac, .lower);
}

pub fn verifyMigrationSignature(alloc: std.mem.Allocator, cfg: MigrationConfig, name: []const u8, script: []const u8) MigrationError!void {
    if (cfg.allow_unsigned) {
        std.log.warn("migration: running unsigned migration '{s}' (allow_unsigned=true)", .{name});
        return;
    }
    const hmac_key = cfg.hmac_key orelse return error.MigrationSignatureMissing;
    const sig_name = std.fmt.allocPrint(alloc, "{s}.sig", .{name}) catch return error.OutOfMemory;
    defer alloc.free(sig_name);
    const sig_path = root.joinPath(alloc, cfg, sig_name) catch return error.OutOfMemory;
    defer alloc.free(sig_path);
    const sig_contents = std.Io.Dir.cwd().readFileAlloc(alloc, sig_path, 128) catch return error.MigrationSignatureMissing;
    defer alloc.free(sig_contents);
    const sig_hex = std.mem.trim(u8, sig_contents, " \t\r\n");
    if (sig_hex.len != 64) return error.MigrationSignatureInvalid;
    const expected = computeHmacSha256(hmac_key, script);
    if (!constTimeEqlHex(sig_hex, &expected)) return error.MigrationSignatureInvalid;
}

pub fn constTimeEqlHex(a: []const u8, b: []const u8) bool {
    if (a.len != 64 or b.len != 64) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

pub fn signMigrationFile(alloc: std.mem.Allocator, cfg: MigrationConfig, name: []const u8) MigrationError!void {
    try root.validateMigrationName(name);
    const hmac_key = cfg.hmac_key orelse return error.MigrationSignatureMissing;
    const path = root.joinPath(alloc, cfg, name) catch return error.OutOfMemory;
    defer alloc.free(path);
    const script = std.Io.Dir.cwd().readFileAlloc(alloc, path, max_script_bytes) catch return error.MigrationFileMissing;
    defer alloc.free(script);
    const hex_sig = computeHmacSha256(hmac_key, script);
    const sig_name = std.fmt.allocPrint(alloc, "{s}.sig", .{name}) catch return error.OutOfMemory;
    defer alloc.free(sig_name);
    const sig_path = root.joinPath(alloc, cfg, sig_name) catch return error.OutOfMemory;
    defer alloc.free(sig_path);
    var file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), sig_path, .{ .truncate = true }) catch return error.FileSystemError;
    defer file.close();
    if (builtin.os.tag != .windows) file.chmod(0o600) catch {};
    file.writeAll(&hex_sig) catch return error.FileSystemError;
    file.writeAll("\n") catch return error.FileSystemError;
}
