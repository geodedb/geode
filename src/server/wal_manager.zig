const std = @import("std");
const wal_mod = @import("wal");

// CANARY: REQ=REQ-PERF-WAL-GLOBAL-001; FEATURE="GlobalWALManager"; ASPECT=ConnectionHotPath; STATUS=IMPL; OWNER=storage; UPDATED=2026-01-27
/// Thread-safe WAL wrapper that is initialized once and shared across connections.
pub const WalManager = struct {
    allocator: std.mem.Allocator,
    wal: wal_mod.Wal,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, test_wal_skip_ratio: ?f64) WalManager {
        var wal = wal_mod.Wal.init(allocator);
        wal.openFile("/tmp/geode_ephemeral_wal") catch {};
        if (test_wal_skip_ratio) |ov| {
            wal.test_skip_ratio_override = ov;
        }
        return .{
            .allocator = allocator,
            .wal = wal,
        };
    }

    pub fn deinit(self: *WalManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.wal.deinit();
    }

    pub fn append(self: *WalManager, txn_id: u64, typ: wal_mod.RecordType, payload: []const u8, payload_len: usize) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.wal.append(txn_id, typ, payload, payload_len);
    }

    pub fn appendAndFsync(self: *WalManager, txn_id: u64, typ: wal_mod.RecordType, payload: []const u8, payload_len: usize) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const lsn = try self.wal.append(txn_id, typ, payload, payload_len);
        try self.wal.flushForRecord(typ);
        return lsn;
    }

    pub fn fsync(self: *WalManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.wal.fsync();
    }

    pub fn checkpointAndCompact(self: *WalManager) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.wal.writeCheckpoint();
        const durable_lsn = self.wal.next_lsn;
        try self.wal.compact(durable_lsn);
        return durable_lsn;
    }
};

var g_wal_manager: ?*WalManager = null;
var g_wal_init_mutex: std.Thread.Mutex = .{};

/// Get or create the shared WAL manager.
pub fn getOrCreateWalManager(allocator: std.mem.Allocator, test_wal_skip_ratio: ?f64) !*WalManager {
    g_wal_init_mutex.lock();
    defer g_wal_init_mutex.unlock();

    if (g_wal_manager) |mgr| {
        return mgr;
    }

    const mgr = try allocator.create(WalManager);
    mgr.* = WalManager.init(allocator, test_wal_skip_ratio);
    g_wal_manager = mgr;
    return mgr;
}

/// Deinitialize the shared WAL manager on server shutdown.
pub fn deinitGlobalWalManager() void {
    g_wal_init_mutex.lock();
    defer g_wal_init_mutex.unlock();

    if (g_wal_manager) |mgr| {
        const allocator = mgr.allocator;
        mgr.deinit();
        allocator.destroy(mgr);
        g_wal_manager = null;
    }
}
