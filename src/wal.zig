const std = @import("std");
const graph_store = @import("graph_store.zig");
const txn_undo_log = @import("txn_undo_log.zig");
const tde = @import("storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-PERF-WAL-001; FEATURE="WriteAheadLog"; ASPECT=DeltaPersistence; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// CANARY: REQ=REQ-TDE-ENFORCE-002; FEATURE=TDEEnforcement; ASPECT=WALEncryption; STATUS=TESTED; OWNER=security; UPDATED=2026-02-19
// Issue #445: Write-Ahead Log for delta persistence.
// Instead of serializing the entire graph on every commit, mutations are appended as
// WAL records. Full snapshots (checkpoints) happen periodically. On recovery, the last
// checkpoint is loaded and WAL records after that LSN are replayed.

const logging = @import("logging");
const log = logging.scoped("wal");
const Attr = logging.Attr;

/// WAL record operation types (post-images for redo, reuse UndoOpType discriminants)
pub const WalOpType = enum(u8) {
    CreateNode = 1,
    CreateEdge = 2,
    SetNodeProperty = 3,
    RemoveNodeProperty = 4,
    SetEdgeProperty = 5,
    RemoveEdgeProperty = 6,
    DeleteNode = 7,
    DeleteEdge = 8,
    AddNodeLabel = 9,
    RemoveNodeLabel = 10,
};

/// WAL record payload (post-image for redo)
pub const WalRecord = union(WalOpType) {
    CreateNode: struct {
        node_id: u64,
        graph_name: []const u8,
        labels: []const []const u8,
    },
    CreateEdge: struct {
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        label: []const u8,
        graph_name: []const u8,
    },
    SetNodeProperty: struct {
        node_id: u64,
        key: []const u8,
        value: txn_undo_log.SerializedProperty,
    },
    RemoveNodeProperty: struct {
        node_id: u64,
        key: []const u8,
    },
    SetEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
        value: txn_undo_log.SerializedProperty,
    },
    RemoveEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
    },
    DeleteNode: struct {
        node_id: u64,
        graph_name: []const u8,
    },
    DeleteEdge: struct {
        edge_id: u64,
        graph_name: []const u8,
    },
    AddNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
    RemoveNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
};

/// On-disk WAL record header:
///   [u64: LSN][u64: txn_id][u8: op_type][u32: payload_len][payload...][u32: CRC32]
const RECORD_HEADER_SIZE = 8 + 8 + 1 + 4; // 21 bytes
const CRC_SIZE = 4;

/// Load the WAL encryption key. Checks GEODE_WAL_KEY first (WAL-specific key),
/// then falls back to GEODE_TDE_KEY. Returns null if neither is set.
fn loadWalKey(allocator: std.mem.Allocator) !?[tde.KEY_BYTES]u8 {
    // Try WAL-specific key first
    const wal_hex = std.process.getEnvVarOwned(allocator, "GEODE_WAL_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => return e,
    };
    if (wal_hex) |hex| {
        defer allocator.free(hex);
        if (hex.len == 64) {
            // Parse the 64-char hex string into 32 bytes
            var key: [tde.KEY_BYTES]u8 = undefined;
            var i: usize = 0;
            while (i < tde.KEY_BYTES) : (i += 1) {
                const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return tde.TdeError.InvalidKey;
                const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return tde.TdeError.InvalidKey;
                key[i] = @as(u8, @intCast(hi * 16 + lo));
            }
            return key;
        }
    }
    // Fall back to GEODE_TDE_KEY
    return try tde.loadKey(allocator);
}

pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    file: ?std.fs.File,
    current_lsn: u64,
    checkpoint_lsn: u64,
    bytes_since_checkpoint: u64,
    last_checkpoint_ms: i64,
    lock: std.Thread.Mutex,
    file_path: []const u8,
    /// Non-null when WAL encryption is active (GEODE_WAL_KEY or GEODE_TDE_KEY set).
    tde_key: ?[tde.KEY_BYTES]u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !WriteAheadLog {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        // Load WAL encryption key: GEODE_WAL_KEY takes precedence, then GEODE_TDE_KEY.
        const wal_key = try loadWalKey(allocator);

        // Open or create the WAL file for append
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) {
                // Create new WAL file
                const new_file = try std.fs.cwd().createFile(path, .{ .read = true });
                return WriteAheadLog{
                    .allocator = allocator,
                    .file = new_file,
                    .current_lsn = 0,
                    .checkpoint_lsn = 0,
                    .bytes_since_checkpoint = 0,
                    .last_checkpoint_ms = std.time.milliTimestamp(),
                    .lock = .{},
                    .file_path = owned_path,
                    .tde_key = wal_key,
                };
            }
            return err;
        };

        // Scan to find the last LSN, handling encrypted or plaintext format.
        var last_lsn: u64 = 0;
        var bytes_count: u64 = 0;

        if (wal_key) |key| {
            // Encrypted WAL: [u32: enc_len][GEOTDEFL_magic + nonce + tag + ciphertext]
            while (true) {
                var len_buf: [4]u8 = undefined;
                const lr = file.readAll(&len_buf) catch break;
                if (lr < 4) break;
                const enc_len = std.mem.readInt(u32, &len_buf, .little);
                if (enc_len == 0 or enc_len > 16 * 1024 * 1024) break;

                const encrypted = allocator.alloc(u8, enc_len) catch break;
                defer allocator.free(encrypted);
                const er = file.readAll(encrypted) catch break;
                if (er < enc_len) break;

                const decrypted = tde.decryptWithKey(allocator, encrypted, key) catch break;
                defer allocator.free(decrypted);

                if (decrypted.len < RECORD_HEADER_SIZE) break;
                const lsn = std.mem.readInt(u64, decrypted[0..8], .little);
                const payload_len = std.mem.readInt(u32, decrypted[17..21], .little);
                if (decrypted.len != RECORD_HEADER_SIZE + payload_len + CRC_SIZE) break;

                last_lsn = lsn;
                bytes_count += 4 + enc_len;
            }
        } else {
            // Plaintext WAL (original format)
            while (true) {
                var header_buf: [RECORD_HEADER_SIZE]u8 = undefined;
                const header_read = file.readAll(&header_buf) catch break;
                if (header_read < RECORD_HEADER_SIZE) break;

                const lsn = std.mem.readInt(u64, header_buf[0..8], .little);
                const payload_len = std.mem.readInt(u32, header_buf[17..21], .little);

                file.seekBy(@intCast(payload_len + CRC_SIZE)) catch break;

                last_lsn = lsn;
                bytes_count += RECORD_HEADER_SIZE + payload_len + CRC_SIZE;
            }
        }

        // Seek to end for appending
        file.seekFromEnd(0) catch {};

        return WriteAheadLog{
            .allocator = allocator,
            .file = file,
            .current_lsn = last_lsn,
            .checkpoint_lsn = 0,
            .bytes_since_checkpoint = bytes_count,
            .last_checkpoint_ms = std.time.milliTimestamp(),
            .lock = .{},
            .file_path = owned_path,
            .tde_key = wal_key,
        };
    }

    pub fn deinit(self: *WriteAheadLog) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        self.allocator.free(self.file_path);
    }

    /// Append a WAL record and return the assigned LSN.
    /// Thread-safe: acquires internal mutex.
    pub fn appendRecord(self: *WriteAheadLog, txn_id: u64, record: WalRecord) !u64 {
        self.lock.lock();
        defer self.lock.unlock();

        const file = self.file orelse return error.NotOpenReading;
        self.current_lsn += 1;
        const lsn = self.current_lsn;

        // Serialize payload
        var payload_buf = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        defer payload_buf.deinit(self.allocator);

        try serializePayload(self.allocator, &payload_buf, record);

        const payload = payload_buf.items;

        // Build header
        var header: [RECORD_HEADER_SIZE]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], lsn, .little);
        std.mem.writeInt(u64, header[8..16], txn_id, .little);
        header[16] = @intFromEnum(std.meta.activeTag(record));
        std.mem.writeInt(u32, header[17..21], @intCast(payload.len), .little);

        // Compute CRC32 over header + payload
        var crc32 = std.hash.crc.Crc32IsoHdlc.init();
        crc32.update(&header);
        crc32.update(payload);
        const checksum = crc32.final();
        var crc_buf: [CRC_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, checksum, .little);

        if (self.tde_key) |key| {
            // TDE enabled: assemble header+payload+crc, encrypt, write with 4-byte length prefix.
            // Format: [u32: enc_len][GEOTDEFL_magic][nonce][tag][ciphertext]
            var rec_buf = std.ArrayList(u8).initCapacity(self.allocator, RECORD_HEADER_SIZE + payload.len + CRC_SIZE) catch return error.OutOfMemory;
            defer rec_buf.deinit(self.allocator);
            try rec_buf.appendSlice(self.allocator, &header);
            try rec_buf.appendSlice(self.allocator, payload);
            try rec_buf.appendSlice(self.allocator, &crc_buf);

            const encrypted = try tde.encryptWithKey(self.allocator, rec_buf.items, key);
            defer self.allocator.free(encrypted);

            var len_prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_prefix, @intCast(encrypted.len), .little);
            try file.writeAll(&len_prefix);
            try file.writeAll(encrypted);

            self.bytes_since_checkpoint += 4 + encrypted.len;
        } else {
            // Plaintext: write header + payload + crc directly.
            try file.writeAll(&header);
            try file.writeAll(payload);
            try file.writeAll(&crc_buf);

            self.bytes_since_checkpoint += RECORD_HEADER_SIZE + payload.len + CRC_SIZE;
        }

        return lsn;
    }

    /// Flush WAL to disk (fsync)
    pub fn sync(self: *WriteAheadLog) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.file) |f| {
            try f.sync();
        }
    }

    /// Replay WAL records from checkpoint_lsn onto the given store.
    /// Returns the last replayed LSN.
    pub fn replay(self: *WriteAheadLog, store: *graph_store.GraphStore) !u64 {
        self.lock.lock();
        defer self.lock.unlock();

        // Inhibit mutation callbacks during replay to prevent re-emitting WAL records
        graph_store.setMutationNotifyInhibit(true);
        defer graph_store.setMutationNotifyInhibit(false);

        const file = self.file orelse return 0;

        // Seek to beginning
        try file.seekTo(0);
        var last_lsn: u64 = 0;
        var replayed: u64 = 0;

        if (self.tde_key) |key| {
            // Encrypted WAL replay: [u32: enc_len][encrypted record]
            while (true) {
                var len_buf: [4]u8 = undefined;
                const lr = file.readAll(&len_buf) catch break;
                if (lr < 4) break;
                const enc_len = std.mem.readInt(u32, &len_buf, .little);
                if (enc_len == 0 or enc_len > 16 * 1024 * 1024) break;

                const encrypted = self.allocator.alloc(u8, enc_len) catch break;
                defer self.allocator.free(encrypted);
                const er = file.readAll(encrypted) catch break;
                if (er < enc_len) break;

                const rec = tde.decryptWithKey(self.allocator, encrypted, key) catch {
                    log.warn("WAL: decryption failed, stopping replay", &.{});
                    break;
                };
                defer self.allocator.free(rec);

                if (rec.len < RECORD_HEADER_SIZE + CRC_SIZE) break;
                const lsn = std.mem.readInt(u64, rec[0..8], .little);
                const op_type_byte = rec[16];
                const payload_len = std.mem.readInt(u32, rec[17..21], .little);
                if (rec.len < RECORD_HEADER_SIZE + payload_len + CRC_SIZE) break;

                const payload = rec[RECORD_HEADER_SIZE .. RECORD_HEADER_SIZE + payload_len];

                var crc32 = std.hash.crc.Crc32IsoHdlc.init();
                crc32.update(rec[0..RECORD_HEADER_SIZE]);
                crc32.update(payload);
                const computed_crc = crc32.final();
                const stored_crc = std.mem.readInt(u32, rec[RECORD_HEADER_SIZE + payload_len ..][0..4], .little);
                if (computed_crc != stored_crc) {
                    log.warn("WAL CRC mismatch at LSN, stopping replay", &.{
                        Attr.int("lsn", @intCast(lsn)),
                    });
                    break;
                }

                if (lsn <= self.checkpoint_lsn) continue;

                const op_type: WalOpType = @enumFromInt(op_type_byte);
                applyRecord(store, op_type, payload) catch |err| {
                    log.warn("WAL replay failed for record", &.{
                        Attr.int("lsn", @intCast(lsn)),
                        Attr.string("error", @errorName(err)),
                    });
                    continue;
                };

                last_lsn = lsn;
                replayed += 1;
            }
        } else {
            // Plaintext WAL replay (original format)
            while (true) {
                var header_buf: [RECORD_HEADER_SIZE]u8 = undefined;
                const header_read = file.readAll(&header_buf) catch break;
                if (header_read < RECORD_HEADER_SIZE) break;

                const lsn = std.mem.readInt(u64, header_buf[0..8], .little);
                const op_type_byte = header_buf[16];
                const payload_len = std.mem.readInt(u32, header_buf[17..21], .little);

                const payload = self.allocator.alloc(u8, payload_len) catch break;
                defer self.allocator.free(payload);
                const payload_read = file.readAll(payload) catch break;
                if (payload_read < payload_len) break;

                var crc_buf: [CRC_SIZE]u8 = undefined;
                const crc_read = file.readAll(&crc_buf) catch break;
                if (crc_read < CRC_SIZE) break;

                var crc32 = std.hash.crc.Crc32IsoHdlc.init();
                crc32.update(&header_buf);
                crc32.update(payload);
                const computed_crc = crc32.final();
                const stored_crc = std.mem.readInt(u32, &crc_buf, .little);
                if (computed_crc != stored_crc) {
                    log.warn("WAL CRC mismatch at LSN, stopping replay", &.{
                        Attr.int("lsn", @intCast(lsn)),
                    });
                    break;
                }

                if (lsn <= self.checkpoint_lsn) continue;

                const op_type: WalOpType = @enumFromInt(op_type_byte);
                applyRecord(store, op_type, payload) catch |err| {
                    log.warn("WAL replay failed for record", &.{
                        Attr.int("lsn", @intCast(lsn)),
                        Attr.string("error", @errorName(err)),
                    });
                    continue;
                };

                last_lsn = lsn;
                replayed += 1;
            }
        }

        if (replayed > 0) {
            log.info("WAL replay complete", &.{
                Attr.int("records_replayed", @intCast(replayed)),
                Attr.int("last_lsn", @intCast(last_lsn)),
            });
        }

        self.current_lsn = last_lsn;
        return last_lsn;
    }

    /// Truncate WAL records up to the given LSN (after a successful checkpoint).
    /// Rewrites the file keeping only records with LSN > up_to_lsn.
    pub fn truncate(self: *WriteAheadLog, up_to_lsn: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const file = self.file orelse return;

        try file.seekTo(0);
        var kept = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch return error.OutOfMemory;
        defer kept.deinit(self.allocator);

        var kept_bytes: u64 = 0;

        if (self.tde_key) |key| {
            // Encrypted WAL truncation: read framed encrypted records, decrypt to check LSN,
            // then keep the encrypted bytes verbatim (no re-encryption needed).
            while (true) {
                var len_buf: [4]u8 = undefined;
                const lr = file.readAll(&len_buf) catch break;
                if (lr < 4) break;
                const enc_len = std.mem.readInt(u32, &len_buf, .little);
                if (enc_len == 0 or enc_len > 16 * 1024 * 1024) break;

                const encrypted = self.allocator.alloc(u8, enc_len) catch break;
                defer self.allocator.free(encrypted);
                const er = file.readAll(encrypted) catch break;
                if (er < enc_len) break;

                const rec = tde.decryptWithKey(self.allocator, encrypted, key) catch break;
                defer self.allocator.free(rec);

                if (rec.len < RECORD_HEADER_SIZE) break;
                const lsn = std.mem.readInt(u64, rec[0..8], .little);

                if (lsn > up_to_lsn) {
                    // Keep: write the original framed encrypted bytes
                    try kept.appendSlice(self.allocator, &len_buf);
                    try kept.appendSlice(self.allocator, encrypted);
                    kept_bytes += 4 + enc_len;
                }
            }
        } else {
            // Plaintext WAL truncation (original logic)
            while (true) {
                var header_buf: [RECORD_HEADER_SIZE]u8 = undefined;
                const header_read = file.readAll(&header_buf) catch break;
                if (header_read < RECORD_HEADER_SIZE) break;

                const lsn = std.mem.readInt(u64, header_buf[0..8], .little);
                const payload_len = std.mem.readInt(u32, header_buf[17..21], .little);

                const total_record_size = RECORD_HEADER_SIZE + payload_len + CRC_SIZE;
                const record_data = self.allocator.alloc(u8, payload_len + CRC_SIZE) catch break;
                defer self.allocator.free(record_data);
                const data_read = file.readAll(record_data) catch break;
                if (data_read < payload_len + CRC_SIZE) break;

                if (lsn > up_to_lsn) {
                    try kept.appendSlice(self.allocator, &header_buf);
                    try kept.appendSlice(self.allocator, record_data);
                    kept_bytes += total_record_size;
                }
            }
        }

        // Rewrite the file with only kept records
        try file.seekTo(0);
        if (kept.items.len > 0) {
            try file.writeAll(kept.items);
        }
        // Truncate the file to the new size
        try file.setEndPos(kept.items.len);

        self.checkpoint_lsn = up_to_lsn;
        self.bytes_since_checkpoint = kept_bytes;
        self.last_checkpoint_ms = std.time.milliTimestamp();
    }

    /// Perform a checkpoint: save full snapshot via store.saveToFile(), then truncate WAL.
    pub fn checkpoint(self: *WriteAheadLog, store: *graph_store.GraphStore) !void {
        // Save the full snapshot first (caller should hold appropriate locks)
        try store.saveToFile();

        // Truncate WAL records that are now covered by the snapshot
        const checkpoint_at = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.current_lsn;
        };

        try self.truncate(checkpoint_at);
    }

    /// Check if a checkpoint is needed based on byte or time thresholds.
    /// Returns true if bytes since last checkpoint exceed byte_threshold,
    /// or if time since last checkpoint exceeds time_threshold_ms (when > 0).
    pub fn needsCheckpoint(self: *WriteAheadLog, byte_threshold: u64, time_threshold_ms: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.bytes_since_checkpoint >= byte_threshold) return true;
        if (time_threshold_ms > 0 and self.bytes_since_checkpoint > 0) {
            const now = std.time.milliTimestamp();
            const elapsed: u64 = @intCast(@max(0, now - self.last_checkpoint_ms));
            return elapsed >= time_threshold_ms;
        }
        return false;
    }
};

// ---- Serialization helpers ----

fn serializePayload(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), record: WalRecord) !void {
    switch (record) {
        .CreateNode => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.graph_name);
            try appendU32(buf, allocator, @intCast(r.labels.len));
            for (r.labels) |label| {
                try appendString(buf, allocator, label);
            }
        },
        .CreateEdge => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendU64(buf, allocator, r.from_id);
            try appendU64(buf, allocator, r.to_id);
            try appendString(buf, allocator, r.label);
            try appendString(buf, allocator, r.graph_name);
        },
        .SetNodeProperty => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.key);
            try serializeProperty(buf, allocator, r.value);
        },
        .RemoveNodeProperty => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.key);
        },
        .SetEdgeProperty => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.key);
            try serializeProperty(buf, allocator, r.value);
        },
        .RemoveEdgeProperty => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.key);
        },
        .DeleteNode => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.graph_name);
        },
        .DeleteEdge => |r| {
            try appendU64(buf, allocator, r.edge_id);
            try appendString(buf, allocator, r.graph_name);
        },
        .AddNodeLabel => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.label);
        },
        .RemoveNodeLabel => |r| {
            try appendU64(buf, allocator, r.node_id);
            try appendString(buf, allocator, r.label);
        },
    }
}

fn serializeProperty(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, prop: txn_undo_log.SerializedProperty) !void {
    try buf.append(allocator, prop.value_type);
    switch (prop.value_type) {
        0 => {}, // Null
        1 => try appendString(buf, allocator, prop.string_value orelse ""),
        2 => try appendI64(buf, allocator, prop.int_value),
        3 => try appendF64(buf, allocator, prop.float_value),
        4 => try buf.append(allocator, if (prop.bool_value) @as(u8, 1) else @as(u8, 0)),
        else => {},
    }
}

fn appendU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendI64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendF64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64) !void {
    const bits: u64 = @bitCast(value);
    try appendU64(buf, allocator, bits);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try appendU32(buf, allocator, @intCast(str.len));
    try buf.appendSlice(allocator, str);
}

// ---- Deserialization / replay helpers ----

fn readU64(data: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

fn readI64(data: []const u8, offset: *usize) !i64 {
    if (offset.* + 8 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(i64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

fn readF64(data: []const u8, offset: *usize) !f64 {
    const bits = try readU64(data, offset);
    return @bitCast(bits);
}

fn readU32(data: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > data.len) return error.UnexpectedEndOfStream;
    const value = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return value;
}

fn readString(data: []const u8, offset: *usize) ![]const u8 {
    const len = try readU32(data, offset);
    if (offset.* + len > data.len) return error.UnexpectedEndOfStream;
    const str = data[offset.* .. offset.* + len];
    offset.* += len;
    return str;
}

fn applyRecord(store: *graph_store.GraphStore, op_type: WalOpType, payload: []const u8) !void {
    var offset: usize = 0;
    switch (op_type) {
        .CreateNode => {
            const node_id = try readU64(payload, &offset);
            const graph_name = try readString(payload, &offset);
            const label_count = try readU32(payload, &offset);
            var labels = try store.allocator.alloc([]const u8, label_count);
            defer store.allocator.free(labels);
            for (0..label_count) |i| {
                labels[i] = try readString(payload, &offset);
            }
            store.createNodeWithId(node_id, labels, graph_name) catch {
                // Node might already exist if replaying after partial recovery
            };
        },
        .CreateEdge => {
            const edge_id = try readU64(payload, &offset);
            const from_id = try readU64(payload, &offset);
            const to_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            const graph_name = try readString(payload, &offset);
            store.createEdgeWithId(edge_id, from_id, to_id, label, graph_name) catch {
                // Edge might already exist
            };
        },
        .SetNodeProperty => {
            const node_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            const value_type = if (offset < payload.len) payload[offset] else return error.UnexpectedEndOfStream;
            offset += 1;
            const pv = deserializePropertyValue(payload, &offset, value_type) catch graph_store.PropertyValue.Null;
            store.setNodeProperty(node_id, key, pv) catch {};
        },
        .RemoveNodeProperty => {
            const node_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            store.removeNodeProperty(node_id, key);
        },
        .SetEdgeProperty => {
            const edge_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            const value_type = if (offset < payload.len) payload[offset] else return error.UnexpectedEndOfStream;
            offset += 1;
            const pv = deserializePropertyValue(payload, &offset, value_type) catch graph_store.PropertyValue.Null;
            store.setEdgeProperty(edge_id, key, pv) catch {};
        },
        .RemoveEdgeProperty => {
            const edge_id = try readU64(payload, &offset);
            const key = try readString(payload, &offset);
            store.removeEdgeProperty(edge_id, key);
        },
        .DeleteNode => {
            const node_id = try readU64(payload, &offset);
            _ = try readString(payload, &offset); // graph_name
            store.deleteNode(node_id);
        },
        .DeleteEdge => {
            const edge_id = try readU64(payload, &offset);
            _ = try readString(payload, &offset); // graph_name
            store.deleteEdge(edge_id);
        },
        .AddNodeLabel => {
            const node_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            store.addNodeLabel(node_id, label) catch {};
        },
        .RemoveNodeLabel => {
            const node_id = try readU64(payload, &offset);
            const label = try readString(payload, &offset);
            store.removeNodeLabel(node_id, label) catch {};
        },
    }
}

fn deserializePropertyValue(data: []const u8, offset: *usize, value_type: u8) !graph_store.PropertyValue {
    return switch (value_type) {
        0 => graph_store.PropertyValue.Null,
        1 => graph_store.PropertyValue{ .String = try readString(data, offset) },
        2 => graph_store.PropertyValue{ .Int = try readI64(data, offset) },
        3 => graph_store.PropertyValue{ .Float = try readF64(data, offset) },
        4 => blk: {
            if (offset.* >= data.len) return error.UnexpectedEndOfStream;
            const b = data[offset.*] != 0;
            offset.* += 1;
            break :blk graph_store.PropertyValue{ .Bool = b };
        },
        else => graph_store.PropertyValue.Null,
    };
}

// ---- Global WAL instance ----

pub var g_wal: ?*WriteAheadLog = null;
pub var g_wal_storage: ?WriteAheadLog = null;

/// Initialize the global WAL instance using the data directory
pub fn initGlobalWal(allocator: std.mem.Allocator, data_dir: ?[]const u8) !void {
    const dir = data_dir orelse "/tmp";
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/geode_wal.log", .{dir});
    defer allocator.free(wal_path);

    // Ensure the directory exists
    std.fs.cwd().makePath(dir) catch {};

    g_wal_storage = try WriteAheadLog.init(allocator, wal_path);
    g_wal = &g_wal_storage.?;
}

/// Get the global WAL instance (null if not initialized)
pub fn getGlobalWal() ?*WriteAheadLog {
    return g_wal;
}

/// Deinitialize the global WAL
pub fn deinitGlobalWal() void {
    if (g_wal_storage) |*wal| {
        wal.deinit();
        g_wal_storage = null;
        g_wal = null;
    }
}

// ---- Mutation callback integration ----

/// Convert a graph_store.PropertyValue to a txn_undo_log.SerializedProperty for WAL records.
fn propertyValueToSerialized(prop_key: []const u8, value: graph_store.PropertyValue) txn_undo_log.SerializedProperty {
    return switch (value) {
        .String => |s| .{ .key = prop_key, .value_type = 1, .string_value = s },
        .Int => |i| .{ .key = prop_key, .value_type = 2, .int_value = i },
        .Float => |f| .{ .key = prop_key, .value_type = 3, .float_value = f },
        .Bool => |b| .{ .key = prop_key, .value_type = 4, .bool_value = b },
        .Null => .{ .key = prop_key, .value_type = 0 },
        .Decimal => |d| .{ .key = prop_key, .value_type = 2, .int_value = @intCast(@as(i128, d.coeff)) },
        .ExtValue => .{ .key = prop_key, .value_type = 0 },
    };
}

/// Mutation callback installed in graph_store. Receives notifications of all store
/// mutations and emits corresponding WAL records. The graph_store inhibits this
/// callback during WAL replay to prevent re-emission.
fn mutationCallback(
    op: graph_store.MutationOp,
    id1: u64,
    id2: u64,
    id3: u64,
    label: ?[]const u8,
    key: ?[]const u8,
    value: ?graph_store.PropertyValue,
    graph_name: ?[]const u8,
) void {
    const w = getGlobalWal() orelse return;
    const record: WalRecord = switch (op) {
        .create_node => .{ .CreateNode = .{
            .node_id = id1,
            .graph_name = graph_name orelse "default",
            .labels = if (label != null) @as([]const []const u8, &.{label.?}) else &.{},
        } },
        .create_edge => .{ .CreateEdge = .{
            .edge_id = id1,
            .from_id = id2,
            .to_id = id3,
            .label = label orelse "",
            .graph_name = graph_name orelse "default",
        } },
        .set_node_property => .{ .SetNodeProperty = .{
            .node_id = id1,
            .key = key orelse "",
            .value = propertyValueToSerialized(key orelse "", value orelse graph_store.PropertyValue.Null),
        } },
        .remove_node_property => .{ .RemoveNodeProperty = .{
            .node_id = id1,
            .key = key orelse "",
        } },
        .set_edge_property => .{ .SetEdgeProperty = .{
            .edge_id = id1,
            .key = key orelse "",
            .value = propertyValueToSerialized(key orelse "", value orelse graph_store.PropertyValue.Null),
        } },
        .remove_edge_property => .{ .RemoveEdgeProperty = .{
            .edge_id = id1,
            .key = key orelse "",
        } },
        .delete_node => .{ .DeleteNode = .{
            .node_id = id1,
            .graph_name = graph_name orelse "default",
        } },
        .delete_edge => .{ .DeleteEdge = .{
            .edge_id = id1,
            .graph_name = graph_name orelse "default",
        } },
        .add_node_label => .{ .AddNodeLabel = .{
            .node_id = id1,
            .label = label orelse "",
        } },
        .remove_node_label => .{ .RemoveNodeLabel = .{
            .node_id = id1,
            .label = label orelse "",
        } },
    };
    _ = w.appendRecord(0, record) catch {};
}

/// Install the WAL mutation callback in graph_store.
/// Call after initGlobalWal() to start capturing mutations.
pub fn installMutationCallback() void {
    graph_store.setMutationNotify(&mutationCallback);
}

/// Remove the WAL mutation callback (e.g., during shutdown).
pub fn removeMutationCallback() void {
    graph_store.setMutationNotify(null);
}

// ---- Persistence integration ----

/// Default checkpoint thresholds
pub const CHECKPOINT_BYTE_THRESHOLD: u64 = 16 * 1024 * 1024; // 16MB
pub const CHECKPOINT_INTERVAL_MS: u64 = 60_000; // 60 seconds

// Persistence hook implementations for graph_store.persistenceLoop()

/// Sync the global WAL (fsync). Called by persistence loop on every wake.
fn walSyncHook() void {
    if (g_wal) |w| {
        w.sync() catch {};
    }
}

/// Check if a full checkpoint is needed based on WAL byte or time threshold.
fn walNeedsCheckpointHook() bool {
    if (g_wal) |w| {
        return w.needsCheckpoint(CHECKPOINT_BYTE_THRESHOLD, CHECKPOINT_INTERVAL_MS);
    }
    return true; // If WAL not available, always checkpoint (legacy behavior)
}

/// Perform a full checkpoint: saveToFile() + truncate WAL.
fn walCheckpointHook(store: *graph_store.GraphStore) void {
    if (g_wal) |w| {
        w.checkpoint(store) catch |err| {
            log.err("WAL checkpoint failed", &.{
                Attr.string("error", @errorName(err)),
            });
            // Fall back to direct save on checkpoint failure
            store.saveToFile() catch {};
        };
    } else {
        // No WAL — fall back to direct save
        store.saveToFile() catch {};
    }
}

/// Install WAL persistence hooks in graph_store's persistence loop.
/// Call after initGlobalWal() and installMutationCallback().
pub fn installPersistenceHooks() void {
    graph_store.setWalPersistenceHooks(
        &walSyncHook,
        &walNeedsCheckpointHook,
        &walCheckpointHook,
    );
}

/// Remove WAL persistence hooks (e.g., during shutdown).
pub fn removePersistenceHooks() void {
    graph_store.setWalPersistenceHooks(null, null, null);
}
