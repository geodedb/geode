// CANARY: REQ=REQ-SONNY-2979-DURABLE-UNDO; FEATURE="TransactionManagement"; ASPECT=DurableUndoLog; STATUS=TESTED; TEST=tests/test_sonny2979_txn_crash_atomicity.zig; OWNER=storage; UPDATED=2026-11-16
//! SONNY-2979: the durable transaction undo log, `<data dir>/txn_undo.wal`.
//!
//! A transaction's changes reach the storage engine as they run, and the
//! engine commits them request by request (the session's shard) or change by
//! change (the other 15 shards). The in-memory undo log (`txn_undo_log`)
//! takes them back at ROLLBACK, but a crash skipped it: after a restart
//! every change an open transaction had made was still there.
//!
//! This log makes the undo durable. Inside an explicit transaction:
//!
//!   * WRITE-AHEAD. Every undo entry is appended and fsynced BEFORE the
//!     change it undoes is made (`statement_undo.append` records the state a
//!     write is about to change; a create records an intent naming the id it
//!     is about to create, `noteCreateIntent`). So no engine commit can carry
//!     a change whose undo is not on disk.
//!   * COMMIT. When the transaction commits, after its engine transactions
//!     have committed, a COMMITTED record is appended and fsynced
//!     (`markEnded`). It is the transaction's commit point: COMMIT is
//!     acknowledged only after it.
//!   * ROLLBACK. When a rollback has undone the transaction and the undo's
//!     changes have committed in the engine, a ROLLED_BACK record is appended
//!     and fsynced.
//!   * RECOVERY. At startup, once the store is open and before any request
//!     is served (`recoverAtStartup`), every transaction with entries and
//!     neither record is undone: its entries, newest first across all such
//!     transactions, through the store's logged write methods
//!     (`txn_undo_log.undoEntryLogged`, the ROLLBACK path). The undo is
//!     idempotent (each entry checks what is there: a node never created is
//!     not deleted, a property is set back to its old value), so a crash
//!     during recovery repeats it. Then the file is emptied.
//!
//! Records are framed `len u32 | crc32c u32 | body`, the body
//! `kind u8 | boot u64 | txn u64 | entry`. A record that does not frame (a
//! torn tail: its write never completed, so the change it preceded was never
//! made) ends the log. Under at-rest encryption (`GraphConfig.encryption_key`)
//! each body is sealed with graph-storage's side-file envelope
//! (AES-256-GCM, `side_file_crypto`, kind `side_kind_txn_undo`): an entry
//! holds property values. A sealed body that does not authenticate refuses
//! the start.
//!
//! `boot` is a random number drawn when the log opens: transaction ids
//! (`txn_undo_log`'s) restart at 1 in every process, and a log that recovery
//! could not empty still holds the previous process's.
//!
//! Lock order: `mutex` is a leaf. It is taken with graph locks held and never
//! held while taking another lock.

const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");
const txn_undo_log = @import("txn_undo_log.zig");
const graph_store = @import("graph_store.zig");
const statement_undo = @import("statement_undo.zig");
const logging = @import("logging");
const log = logging.scoped("txn_durable_undo");
const Attr = logging.Attr;

const UndoEntry = txn_undo_log.UndoEntry;
const SerializedProperty = txn_undo_log.SerializedProperty;

pub const file_name = "txn_undo.wal";
/// The side-file kind of a sealed record (geode's consumer kinds 0..2 are
/// the exact-index and dropped-graphs files).
pub const side_kind_txn_undo = gs.side_file_crypto.Kind.consumer(3);

/// The cipher records are sealed with under at-rest key `key` (null: none).
pub const Cipher = gs.side_file_crypto.Cipher;
pub fn cipherForKey(key: ?[32]u8) ?Cipher {
    return Cipher.forKey(key, gs.registry.SEAL_UUID);
}

/// A record larger than this does not frame (a corrupt length).
const max_record_len: u32 = 64 << 20;
const frame_header_len: usize = 8;

pub const RecordKind = enum(u8) {
    entry = 1,
    committed = 2,
    rolled_back = 3,
};

pub const Error = error{
    /// A record's body does not decode (it framed, so it is not a torn tail).
    InvalidTxnUndoRecord,
    /// The log was written under at-rest encryption and no key is configured.
    TxnUndoLogEncrypted,
    /// The log holds plaintext records and a key is configured.
    TxnUndoLogNotSealed,
};

/// SONNY-2979: counters (exported as `txn_undo_wal_*`, `registerAll`).
pub var records_written_total: std.atomic.Value(u64) = .init(0);
pub var recovered_txns_total: std.atomic.Value(u64) = .init(0);
pub var recovered_entries_total: std.atomic.Value(u64) = .init(0);
pub var recovery_failures_total: std.atomic.Value(u64) = .init(0);

pub fn registerAll(registry: anytype) !void {
    try registry.register("txn_undo_wal_records_written_total", &records_written_total);
    try registry.register("txn_undo_wal_recovered_txns_total", &recovered_txns_total);
    try registry.register("txn_undo_wal_recovered_entries_total", &recovered_entries_total);
    try registry.register("txn_undo_wal_recovery_failures_total", &recovery_failures_total);
}

// ---------------------------------------------------------------------------
// Entry codec
// ---------------------------------------------------------------------------

const Writer = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn int(self: Writer, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn bytes(self: Writer, s: []const u8) !void {
        try self.int(u32, @intCast(s.len));
        try self.buf.appendSlice(self.allocator, s);
    }

    fn optBytes(self: Writer, s: ?[]const u8) !void {
        if (s) |v| {
            try self.int(u8, 1);
            try self.bytes(v);
        } else try self.int(u8, 0);
    }

    fn property(self: Writer, p: SerializedProperty) !void {
        try self.bytes(p.key);
        try self.int(u8, p.value_type);
        try self.optBytes(p.string_value);
        try self.optBytes(p.binary_value);
        try self.int(i64, p.int_value);
        try self.int(u64, @bitCast(p.float_value));
        try self.int(u8, @intFromBool(p.bool_value));
    }

    fn properties(self: Writer, ps: []const SerializedProperty) !void {
        try self.int(u32, @intCast(ps.len));
        for (ps) |p| try self.property(p);
    }
};

/// Append the encoding of `entry` to `buf`.
pub fn encodeEntry(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), entry: UndoEntry) !void {
    const w = Writer{ .buf = buf, .allocator = allocator };
    try w.int(u8, @intFromEnum(std.meta.activeTag(entry)));
    switch (entry) {
        .CreateNode => |e| {
            try w.int(u64, e.node_id);
            try w.bytes(e.graph_name);
        },
        .CreateEdge => |e| {
            try w.int(u64, e.edge_id);
            try w.bytes(e.graph_name);
        },
        .SetNodeProperty => |e| {
            try w.int(u64, e.node_id);
            try w.bytes(e.key);
            try w.int(u8, @intFromBool(e.had_old_value));
            try w.property(e.old_value);
        },
        .SetEdgeProperty => |e| {
            try w.int(u64, e.edge_id);
            try w.bytes(e.key);
            try w.int(u8, @intFromBool(e.had_old_value));
            try w.property(e.old_value);
        },
        .RemoveNodeProperty => |e| {
            try w.int(u64, e.node_id);
            try w.property(e.old_value);
        },
        .RemoveEdgeProperty => |e| {
            try w.int(u64, e.edge_id);
            try w.property(e.old_value);
        },
        .DeleteNode => |e| {
            try w.int(u64, e.node_id);
            try w.int(u32, @intCast(e.labels.len));
            for (e.labels) |l| try w.bytes(l);
            try w.properties(e.properties);
            try w.bytes(e.graph_name);
            try w.bytes(e.tenant_id);
        },
        .DeleteEdge => |e| {
            try w.int(u64, e.edge_id);
            try w.int(u64, e.from_id);
            try w.int(u64, e.to_id);
            try w.bytes(e.label);
            try w.properties(e.properties);
            try w.bytes(e.graph_name);
            try w.bytes(e.tenant_id);
        },
        .AddNodeLabel => |e| {
            try w.int(u64, e.node_id);
            try w.bytes(e.label);
        },
        .RemoveNodeLabel => |e| {
            try w.int(u64, e.node_id);
            try w.bytes(e.label);
        },
    }
}

/// Decodes into memory owned by `allocator`, laid out as
/// `txn_undo_log.freeEntryWith` frees it. Every string is copied, so a
/// partly decoded entry is freed by the reader's `owned` list.
const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn int(self: *Reader, comptime T: type) Error!T {
        if (self.data.len - self.pos < @sizeOf(T)) return error.InvalidTxnUndoRecord;
        const v = std.mem.readInt(T, self.data[self.pos..][0..@sizeOf(T)], .little);
        self.pos += @sizeOf(T);
        return v;
    }

    fn bytes(self: *Reader) (Error || error{OutOfMemory})![]const u8 {
        const n = try self.int(u32);
        if (self.data.len - self.pos < n) return error.InvalidTxnUndoRecord;
        const out = try self.allocator.dupe(u8, self.data[self.pos..][0..n]);
        self.pos += n;
        return out;
    }

    fn optBytes(self: *Reader) (Error || error{OutOfMemory})!?[]const u8 {
        return switch (try self.int(u8)) {
            0 => null,
            1 => try self.bytes(),
            else => error.InvalidTxnUndoRecord,
        };
    }

    fn boolean(self: *Reader) Error!bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidTxnUndoRecord,
        };
    }

    fn property(self: *Reader) (Error || error{OutOfMemory})!SerializedProperty {
        const key = try self.bytes();
        errdefer self.allocator.free(key);
        const value_type = try self.int(u8);
        if (value_type > 5) return error.InvalidTxnUndoRecord;
        const string_value = try self.optBytes();
        errdefer if (string_value) |s| self.allocator.free(s);
        const binary_value = try self.optBytes();
        errdefer if (binary_value) |s| self.allocator.free(s);
        const int_value = try self.int(i64);
        const float_value: f64 = @bitCast(try self.int(u64));
        const bool_value = try self.boolean();
        return .{
            .key = key,
            .value_type = value_type,
            .string_value = string_value,
            .binary_value = binary_value,
            .int_value = int_value,
            .float_value = float_value,
            .bool_value = bool_value,
        };
    }

    fn properties(self: *Reader) (Error || error{OutOfMemory})![]const SerializedProperty {
        const n = try self.int(u32);
        if (n > self.data.len - self.pos) return error.InvalidTxnUndoRecord;
        const out = try self.allocator.alloc(SerializedProperty, n);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |p| p.deinit(self.allocator);
            self.allocator.free(out);
        }
        while (done < n) : (done += 1) out[done] = try self.property();
        return out;
    }

    fn labels(self: *Reader) (Error || error{OutOfMemory})![]const []const u8 {
        const n = try self.int(u32);
        if (n > self.data.len - self.pos) return error.InvalidTxnUndoRecord;
        const out = try self.allocator.alloc([]const u8, n);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |l| self.allocator.free(l);
            self.allocator.free(out);
        }
        while (done < n) : (done += 1) out[done] = try self.bytes();
        return out;
    }
};

/// Decode one entry (all of `data`). The caller frees it with
/// `txn_undo_log.freeEntryWith(allocator, ...)`.
pub fn decodeEntry(allocator: std.mem.Allocator, data: []const u8) (Error || error{OutOfMemory})!UndoEntry {
    var r = Reader{ .data = data, .allocator = allocator };
    const tag = std.enums.fromInt(txn_undo_log.UndoOpType, try r.int(u8)) orelse return error.InvalidTxnUndoRecord;
    const entry: UndoEntry = switch (tag) {
        .CreateNode => blk: {
            const id = try r.int(u64);
            break :blk .{ .CreateNode = .{ .node_id = id, .graph_name = try r.bytes() } };
        },
        .CreateEdge => blk: {
            const id = try r.int(u64);
            break :blk .{ .CreateEdge = .{ .edge_id = id, .graph_name = try r.bytes() } };
        },
        .SetNodeProperty, .SetEdgeProperty => blk: {
            const id = try r.int(u64);
            const key = try r.bytes();
            errdefer allocator.free(key);
            const had = try r.boolean();
            const old = try r.property();
            break :blk if (tag == .SetNodeProperty)
                .{ .SetNodeProperty = .{ .node_id = id, .key = key, .had_old_value = had, .old_value = old } }
            else
                .{ .SetEdgeProperty = .{ .edge_id = id, .key = key, .had_old_value = had, .old_value = old } };
        },
        .RemoveNodeProperty => blk: {
            const id = try r.int(u64);
            break :blk .{ .RemoveNodeProperty = .{ .node_id = id, .old_value = try r.property() } };
        },
        .RemoveEdgeProperty => blk: {
            const id = try r.int(u64);
            break :blk .{ .RemoveEdgeProperty = .{ .edge_id = id, .old_value = try r.property() } };
        },
        .DeleteNode => blk: {
            const id = try r.int(u64);
            const ls = try r.labels();
            errdefer {
                for (ls) |l| allocator.free(l);
                allocator.free(ls);
            }
            const ps = try r.properties();
            errdefer {
                for (ps) |p| p.deinit(allocator);
                allocator.free(ps);
            }
            const graph_name = try r.bytes();
            errdefer allocator.free(graph_name);
            const tenant = try r.bytes();
            break :blk .{ .DeleteNode = .{ .node_id = id, .labels = ls, .properties = ps, .graph_name = graph_name, .tenant_id = tenant } };
        },
        .DeleteEdge => blk: {
            const id = try r.int(u64);
            const from_id = try r.int(u64);
            const to_id = try r.int(u64);
            const label = try r.bytes();
            errdefer allocator.free(label);
            const ps = try r.properties();
            errdefer {
                for (ps) |p| p.deinit(allocator);
                allocator.free(ps);
            }
            const graph_name = try r.bytes();
            errdefer allocator.free(graph_name);
            const tenant = try r.bytes();
            break :blk .{ .DeleteEdge = .{ .edge_id = id, .from_id = from_id, .to_id = to_id, .label = label, .properties = ps, .graph_name = graph_name, .tenant_id = tenant } };
        },
        .AddNodeLabel => blk: {
            const id = try r.int(u64);
            break :blk .{ .AddNodeLabel = .{ .node_id = id, .label = try r.bytes() } };
        },
        .RemoveNodeLabel => blk: {
            const id = try r.int(u64);
            break :blk .{ .RemoveNodeLabel = .{ .node_id = id, .label = try r.bytes() } };
        },
    };
    if (r.pos != data.len) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return error.InvalidTxnUndoRecord;
    }
    return entry;
}

// ---------------------------------------------------------------------------
// Record framing
// ---------------------------------------------------------------------------

/// Append one framed record (`kind`, `boot`, `txn`, then `payload`) to `out`.
pub fn appendRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    cipher: ?*const gs.side_file_crypto.Cipher,
    kind: RecordKind,
    boot: u64,
    txn: u64,
    payload: []const u8,
) !void {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, body.items);
        body.deinit(allocator);
    }
    try body.ensureTotalCapacity(allocator, 17 + payload.len);
    body.appendAssumeCapacity(@intFromEnum(kind));
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, boot, .little);
    body.appendSliceAssumeCapacity(&b8);
    std.mem.writeInt(u64, &b8, txn, .little);
    body.appendSliceAssumeCapacity(&b8);
    body.appendSliceAssumeCapacity(payload);

    const sealed: ?[]u8 = if (cipher) |c| try c.seal(allocator, side_kind_txn_undo, file_name, body.items) else null;
    defer if (sealed) |s| allocator.free(s);
    const framed = sealed orelse body.items;

    var hdr: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(framed.len), .little);
    std.mem.writeInt(u32, hdr[4..8], std.hash.crc.Crc32Iscsi.hash(framed), .little);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, framed);
}

pub const Record = struct {
    kind: RecordKind,
    boot: u64,
    txn: u64,
    /// Set for `.entry`; owned (free with `txn_undo_log.freeEntryWith`).
    entry: ?UndoEntry = null,
};

pub const Parsed = struct {
    records: std.ArrayListUnmanaged(Record) = .empty,
    /// Bytes of `data` that framed; the rest is a torn tail.
    valid_len: usize = 0,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        for (self.records.items) |r| if (r.entry) |e| txn_undo_log.freeEntryWith(allocator, e);
        self.records.deinit(allocator);
    }
};

/// Parse a log. A record whose frame does not hold (short, a length past the
/// end or above the cap, a CRC mismatch) ends the log: everything from it on
/// is a torn tail. A record that frames but does not decode or authenticate
/// is an error (the log is damaged, or was written under another key).
pub fn parse(allocator: std.mem.Allocator, cipher: ?*const gs.side_file_crypto.Cipher, data: []const u8) !Parsed {
    var parsed: Parsed = .{};
    errdefer parsed.deinit(allocator);
    var pos: usize = 0;
    while (data.len - pos >= frame_header_len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .little);
        const crc = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        if (len > max_record_len or data.len - pos - frame_header_len < len) break;
        const framed = data[pos + frame_header_len ..][0..len];
        if (std.hash.crc.Crc32Iscsi.hash(framed) != crc) break;

        const sealed = gs.side_file_crypto.isSealed(framed);
        if (sealed and cipher == null) return error.TxnUndoLogEncrypted;
        if (!sealed and cipher != null) return error.TxnUndoLogNotSealed;
        const body_owned: ?[]u8 = if (cipher) |c| try c.open(allocator, side_kind_txn_undo, file_name, framed) else null;
        defer if (body_owned) |b| {
            std.crypto.secureZero(u8, b);
            allocator.free(b);
        };
        const body = body_owned orelse framed;
        if (body.len < 17) return error.InvalidTxnUndoRecord;
        const kind = std.enums.fromInt(RecordKind, body[0]) orelse return error.InvalidTxnUndoRecord;
        var rec = Record{
            .kind = kind,
            .boot = std.mem.readInt(u64, body[1..9], .little),
            .txn = std.mem.readInt(u64, body[9..17], .little),
        };
        switch (kind) {
            .entry => rec.entry = try decodeEntry(allocator, body[17..]),
            .committed, .rolled_back => if (body.len != 17) return error.InvalidTxnUndoRecord,
        }
        errdefer if (rec.entry) |e| txn_undo_log.freeEntryWith(allocator, e);
        try parsed.records.append(allocator, rec);
        pos += frame_header_len + len;
        parsed.valid_len = pos;
    }
    return parsed;
}

const TxnKey = struct { boot: u64, txn: u64 };

/// Indexes into `parsed.records` of the entries recovery must undo, in the
/// order to undo them: the entries of every transaction that has entries and
/// neither a COMMITTED nor a ROLLED_BACK record, newest first. Caller frees.
pub fn losersNewestFirst(allocator: std.mem.Allocator, parsed: *const Parsed) ![]usize {
    var ended: std.AutoHashMapUnmanaged(TxnKey, void) = .empty;
    defer ended.deinit(allocator);
    for (parsed.records.items) |r| switch (r.kind) {
        .committed, .rolled_back => try ended.put(allocator, .{ .boot = r.boot, .txn = r.txn }, {}),
        .entry => {},
    };
    var out: std.ArrayListUnmanaged(usize) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = parsed.records.items.len;
    while (i > 0) {
        i -= 1;
        const r = parsed.records.items[i];
        if (r.kind != .entry) continue;
        if (ended.contains(.{ .boot = r.boot, .txn = r.txn })) continue;
        try out.append(allocator, i);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// The process's log
// ---------------------------------------------------------------------------

pub const Log = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    file: std.Io.File,
    cipher: ?Cipher,
    boot: u64,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Bytes in the file; the next record is written here.
    end: u64 = 0,
    /// Transactions of this process with entries and no end record yet.
    open_txns: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn lock(self: *Log) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *Log) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// Open (or create) the log in `data_dir`. Nothing is read or changed:
    /// `recoverAtStartup` does that once the store is open.
    pub fn open(allocator: std.mem.Allocator, data_dir: []const u8, encryption_key: ?[32]u8) !*Log {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try allocator.create(Log);
        errdefer allocator.destroy(self);
        const path = try std.fs.path.join(allocator, &.{ data_dir, file_name });
        errdefer allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        errdefer file.close(io);
        var boot_bytes: [8]u8 = undefined;
        try io.randomSecure(&boot_bytes);
        self.* = .{
            .allocator = allocator,
            .path = path,
            .file = file,
            .cipher = cipherForKey(encryption_key),
            .boot = std.mem.readInt(u64, &boot_bytes, .little),
            .end = try file.length(io),
        };
        return self;
    }

    pub fn close(self: *Log) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.file.close(io);
        if (self.cipher) |*c| c.deinit();
        self.open_txns.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Append `bytes` (whole records) and fsync. `self` locked. On a failure
    /// the file is cut back to its previous end, so a later record never
    /// follows a partial one.
    fn writeSyncedLocked(self: *Log, bytes: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        errdefer self.file.setLength(io, self.end) catch {};
        try self.file.writePositionalAll(io, bytes, self.end);
        try self.file.sync(io);
        self.end += bytes.len;
    }

    /// Write `entries` of transaction `txn` and fsync once.
    pub fn logEntries(self: *Log, txn: u64, entries: []const UndoEntry) !void {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.allocator);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer {
            if (self.cipher == null) std.crypto.secureZero(u8, out.items);
            out.deinit(self.allocator);
        }
        for (entries) |entry| {
            payload.clearRetainingCapacity();
            try encodeEntry(self.allocator, &payload, entry);
            try appendRecord(self.allocator, &out, if (self.cipher) |*c| c else null, .entry, self.boot, txn, payload.items);
            std.crypto.secureZero(u8, payload.items);
        }
        self.lock();
        defer self.unlock();
        try self.open_txns.ensureUnusedCapacity(self.allocator, 1);
        try self.writeSyncedLocked(out.items);
        self.open_txns.putAssumeCapacity(txn, {});
        _ = records_written_total.fetchAdd(entries.len, .monotonic);
    }

    /// Transaction `txn` ended (`kind`: committed or rolled back). A
    /// transaction that wrote no entry needs no record. When none of this
    /// process's transactions is open any more, the log is emptied.
    pub fn markEnded(self: *Log, txn: u64, kind: RecordKind) !void {
        std.debug.assert(kind != .entry);
        self.lock();
        defer self.unlock();
        if (!self.open_txns.contains(txn)) return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try appendRecord(self.allocator, &out, if (self.cipher) |*c| c else null, kind, self.boot, txn, &.{});
        try self.writeSyncedLocked(out.items);
        _ = self.open_txns.remove(txn);
        _ = records_written_total.fetchAdd(1, .monotonic);
        if (self.open_txns.count() == 0) self.truncateLocked();
    }

    /// Empty the file. Every record in it is of an ended transaction, so a
    /// failure only leaves records recovery skips.
    fn truncateLocked(self: *Log) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.file.setLength(io, 0) catch |err| {
            log.warn("could not empty the transaction undo log; its records are of ended transactions", &.{Attr.string("error", @errorName(err))});
            return;
        };
        self.file.sync(io) catch {};
        self.end = 0;
    }

    /// Read the whole file (the caller frees it).
    pub fn readAll(self: *Log) ![]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const len = try self.file.length(io);
        const buf = try self.allocator.alloc(u8, @intCast(len));
        errdefer self.allocator.free(buf);
        const n = try self.file.readPositionalAll(io, buf, 0);
        if (n != buf.len) return error.UnexpectedEndOfFile;
        return buf;
    }
};

var g_log: ?*Log = null;

/// The process's log, once `install`ed (the server's startup).
pub fn current() ?*Log {
    return g_log;
}

pub fn install(l: *Log) void {
    g_log = l;
}

pub fn uninstall() ?*Log {
    const l = g_log;
    g_log = null;
    return l;
}

pub const RecoveryReport = struct {
    txns: usize = 0,
    entries: usize = 0,
    failed_entries: usize = 0,
    torn_tail_bytes: usize = 0,
};

/// Undo every transaction the log holds that neither committed nor rolled
/// back (see the module doc), then empty the log. Runs at startup, after
/// the store opened and before any request is served; nothing else writes.
/// An entry that cannot be undone is logged and counted, and the rest are
/// still undone (as at ROLLBACK, where it answers 40003).
pub fn recoverAtStartup(l: *Log, store: *graph_store.GraphStore) !RecoveryReport {
    const allocator = l.allocator;
    var report: RecoveryReport = .{};
    const raw = try l.readAll();
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    var parsed = try parse(allocator, if (l.cipher) |*c| c else null, raw);
    defer parsed.deinit(allocator);
    report.torn_tail_bytes = raw.len - parsed.valid_len;
    if (report.torn_tail_bytes > 0) {
        log.warn("transaction undo log: a torn last record was dropped (its change was never made)", &.{Attr.uint("bytes", report.torn_tail_bytes)});
    }

    const order = try losersNewestFirst(allocator, &parsed);
    defer allocator.free(order);
    if (order.len > 0) {
        var seen: std.AutoHashMapUnmanaged(TxnKey, void) = .empty;
        defer seen.deinit(allocator);
        for (order) |i| {
            const r = parsed.records.items[i];
            try seen.put(allocator, .{ .boot = r.boot, .txn = r.txn }, {});
        }
        report.txns = seen.count();
        report.entries = order.len;

        statement_undo.suspendCapture();
        defer statement_undo.resumeCapture();
        var repair = txn_undo_log.IndexRepair.init(allocator);
        defer repair.finish(store);
        for (order) |i| {
            txn_undo_log.undoEntryLogged(store, parsed.records.items[i].entry.?, &repair) catch |err| {
                report.failed_entries += 1;
                log.err("transaction undo log: an entry of a transaction open at the crash could not be undone; it is partly applied", &.{Attr.string("error", @errorName(err))});
            };
        }
        log.info("transaction undo log: undid the transactions open at the last stop", &.{
            Attr.uint("transactions", report.txns),
            Attr.uint("entries", report.entries),
            Attr.uint("failed", report.failed_entries),
        });
    }
    _ = recovered_txns_total.fetchAdd(report.txns, .monotonic);
    _ = recovered_entries_total.fetchAdd(report.entries, .monotonic);
    _ = recovery_failures_total.fetchAdd(report.failed_entries, .monotonic);

    // The undo's changes were committed by the engine as they ran (no
    // transaction is open here), so the log can go.
    l.lock();
    defer l.unlock();
    if (l.end != 0 or raw.len != 0) l.truncateLocked();
    return report;
}

// ---------------------------------------------------------------------------
// Hooks for the transaction paths
// ---------------------------------------------------------------------------

/// Is a durable entry due for a change on this thread? Inside an explicit
/// transaction (`txn_undo_log.threadInTxn`) with the log installed.
pub fn active() bool {
    return g_log != null and txn_undo_log.threadInTxn();
}

/// SONNY-2979: the ids of the last creates whose intents this thread logged
/// (`[t_intent_lo, t_intent_hi]`), so a create's own record
/// (`statement_undo.appendCreated`) does not log it a second time. Public
/// ids are minted increasing (`generateTimeBasedId`), so every id this
/// thread minted after `t_intent_lo` and up to `t_intent_hi` is one of them.
threadlocal var t_intent_lo: u64 = 1;
threadlocal var t_intent_hi: u64 = 0;

fn entryId(entry: UndoEntry) u64 {
    return switch (entry) {
        .CreateNode => |e| e.node_id,
        .CreateEdge => |e| e.edge_id,
        else => 0,
    };
}

/// Log `entries` for the calling thread's transaction, before the changes
/// they undo are made. No-op outside a transaction or without the log.
pub fn logForThread(entries: []const UndoEntry) !void {
    const l = g_log orelse return;
    const txn = txn_undo_log.currentThreadTxnId();
    if (txn == 0 or !txn_undo_log.threadInTxn()) return;
    try l.logEntries(txn, entries);
}

/// A create is about to make `id` (a node's or an edge's public id).
pub fn noteCreateIntent(entry: UndoEntry) !void {
    return noteCreateIntents(&.{entry});
}

/// Does a create about to be made need its intent noted? Inside an explicit
/// transaction, or an auto-commit statement (SONNY-6658).
pub fn wantsCreateIntents() bool {
    return active() or statement_undo.wantsCreateIntents();
}

/// Creates are about to make the ids of `entries` (CreateNode or CreateEdge,
/// ids increasing): one record each, one fsync. In an auto-commit statement
/// (SONNY-6658) they are kept in its record until it next writes the log.
pub fn noteCreateIntents(entries: []const UndoEntry) !void {
    if (entries.len == 0) return;
    if (!active()) return statement_undo.noteCreateIntents(entries);
    try logForThread(entries);
    t_intent_lo = entryId(entries[0]);
    t_intent_hi = entryId(entries[entries.len - 1]);
}

/// A create made `entry`'s id: logged unless its intent was. For a create
/// path that logs no intent, this follows the change.
pub fn noteCreated(entry: UndoEntry) !void {
    if (!active()) return;
    const id = entryId(entry);
    if (id != 0 and id >= t_intent_lo and id <= t_intent_hi) return;
    try logForThread(&.{entry});
}

/// SONNY-6658: auto-commit statements are logged under ids of their own,
/// with the top bit set, so they never meet a transaction's
/// (`txn_undo_log`'s ids count from 1).
const statement_id_bit: u64 = @as(u64, 1) << 63;
var next_statement_id: std.atomic.Value(u64) = .init(1);

pub fn newStatementId() u64 {
    return statement_id_bit | next_statement_id.fetchAdd(1, .monotonic);
}

/// SONNY-6658: write `entries` of auto-commit statement `id` (one fsync).
pub fn logStatementEntries(id: u64, entries: []const UndoEntry) !void {
    const l = g_log orelse return;
    try l.logEntries(id, entries);
}

/// SONNY-6658: auto-commit statement `id` ended: committed (its engine
/// transactions committed first; this record is its commit point) or rolled
/// back (its undo committed first). A statement that wrote no entry needs
/// none.
pub fn markStatementEnded(id: u64, kind: RecordKind) !void {
    const l = g_log orelse return;
    try l.markEnded(id, kind);
}

/// The calling thread's transaction committed: its engine transactions have
/// committed (the caller ran them first). The COMMITTED record is its commit
/// point; a failure fails the COMMIT.
pub fn markThreadCommitted() !void {
    const l = g_log orelse return;
    const txn = txn_undo_log.currentThreadTxnId();
    if (txn == 0) return;
    try l.markEnded(txn, .committed);
}

/// The calling thread's transaction was rolled back. The undo's changes are
/// committed in the engine first (they joined the session's engine
/// transaction, or a failed statement's), then ROLLED_BACK is written. A
/// failure is logged: the next start undoes the transaction again (each
/// entry checks what is there).
pub fn markThreadRolledBack() void {
    const l = g_log orelse return;
    const txn = txn_undo_log.currentThreadTxnId();
    if (txn == 0) return;
    l.lock();
    const has = l.open_txns.contains(txn);
    l.unlock();
    if (!has) return;
    const gsa = @import("storage/graph_storage_adapter.zig");
    gsa.settleFailedStatementTxn();
    gsa.commitThreadSessionTxn() catch |err| {
        log.err("transaction undo log: the rollback's engine transaction did not commit; the transaction stays open in the log and is undone again at the next start", &.{Attr.string("error", @errorName(err))});
        return;
    };
    l.markEnded(txn, .rolled_back) catch |err| {
        log.err("transaction undo log: could not record a rollback; the next start undoes the transaction again", &.{Attr.string("error", @errorName(err))});
    };
}
