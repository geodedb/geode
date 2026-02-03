const std = @import("std");
const crypto = std.crypto; // AES‑GCM for WAL encryption (aligned with page-level TDE)
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=CorruptPageRecovery; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_CorruptPageRecovery; OWNER=storage; UPDATED=2025-09-20
// Page manager imported via build alias to avoid relative path escaping module root.
const storage = @import("storage_page_manager");
const fsync_util = storage.fs_fsync;
const commit_coord = @import("commit_coordinator");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=WAL; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("wal");
const Attr = logging.Attr;

// CANARY: REQ=REQ-WAL-HEX-001; FEATURE="SecureWalHexKeyParsing"; ASPECT=SECURITY; STATUS=TESTED; TEST=test_parseWalHexKey_valid|test_parseWalHexKey_invalid_char|test_parseWalHexKey_wrong_length; OWNER=security; UPDATED=2026-01-15
// GAP-0155 SECURITY FIX: Proper error handling for WAL encryption key hex parsing instead of silent catch 0

/// Parse a 64-character hex string into a 32-byte key with proper error handling.
/// GAP-0155: Replaces unsafe `catch 0` pattern that could corrupt encryption keys.
/// Returns error.InvalidWalKeyLength if the hex string is not exactly 64 characters.
/// Returns error.InvalidWalKeyHex if any character is not a valid hex digit.
pub fn parseWalHexKey(hex_str: []const u8) ![32]u8 {
    if (hex_str.len != 64) {
        log.err("SECURITY: GEODE_DISK_KEY_HEX must be exactly 64 hex characters", &.{
            Attr.uint("expected_len", 64),
            Attr.uint("actual_len", @intCast(hex_str.len)),
        });
        return error.InvalidWalKeyLength;
    }

    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_DISK_KEY_HEX", &.{
                Attr.uint("position", i * 2),
            });
            return error.InvalidWalKeyHex;
        };
        const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_DISK_KEY_HEX", &.{
                Attr.uint("position", i * 2 + 1),
            });
            return error.InvalidWalKeyHex;
        };
        key[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return key;
}

// WAL encryption wrapper: AES-256-GCM per record (nonce: 12 bytes derived from LSN + payload len).
// Layout when encrypted: [nonce(12)][tag(16)][ciphertext]. Header payload length = 28 + plaintext_len.
// CANARY: REQ=REQ-GQL-TDE-002; FEATURE="WAL encryption"; ASPECT=STORAGE; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_002_WalEncryptionRoundTrip; OWNER=security; UPDATED=2025-09-27
const WalEnc = struct {
    pub const NonceBytes: usize = 12;
    pub const TagBytes: usize = 16;
    pub const Overhead: usize = NonceBytes + TagBytes; // 28

    fn deriveNonce(lsn: u64, plain_len: usize) [NonceBytes]u8 {
        var n: [NonceBytes]u8 = undefined;
        // First 8 bytes = LSN little-endian
        std.mem.writeInt(u64, n[0..8], lsn, .little);
        // Last 4 bytes = wyhash(payload length) truncated (stable for same size)
        const h = std.hash.Wyhash.hash(0, std.mem.asBytes(&@as(u32, @intCast(plain_len))));
        std.mem.writeInt(u32, n[8..12], @as(u32, @intCast(h & 0xFFFFFFFF)), .little);
        return n;
    }

    pub fn encrypt(allocator: std.mem.Allocator, key: *const [32]u8, lsn: u64, plaintext: []const u8) ![]u8 {
        var nonce = deriveNonce(lsn, plaintext.len);
        var tag: [TagBytes]u8 = undefined;
        const aad = std.mem.asBytes(&lsn); // minimal AAD: LSN number
        const ct = try allocator.alloc(u8, plaintext.len);
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct, &tag, plaintext, aad, nonce, key.*);
        const out = try allocator.alloc(u8, Overhead + ct.len);
        @memcpy(out[0..NonceBytes], &nonce);
        @memcpy(out[NonceBytes .. NonceBytes + TagBytes], &tag);
        @memcpy(out[NonceBytes + TagBytes ..], ct);
        allocator.free(ct);
        return out; // caller owns
    }

    pub fn decrypt(allocator: std.mem.Allocator, key: *const [32]u8, lsn: u64, enc: []u8) ![]u8 {
        if (enc.len < Overhead) return error.CorruptCiphertext;
        var nonce: [NonceBytes]u8 = undefined;
        var tag: [TagBytes]u8 = undefined;
        @memcpy(&nonce, enc[0..NonceBytes]);
        @memcpy(&tag, enc[NonceBytes .. NonceBytes + TagBytes]);
        const ciphertext = enc[Overhead..];
        const aad = std.mem.asBytes(&lsn);
        const out = try allocator.alloc(u8, ciphertext.len);
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, ciphertext, tag, aad, nonce, key.*) catch {
            allocator.free(out);
            return error.DecryptFailed;
        };
        return out;
    }
};

// Log Sequence Number (LSN) wrapper. Future: encode epoch or segment.
pub const Lsn = struct {
    value: u64,
};

pub const CommitFlushMode = enum { always, every_n, time_window_ms };

pub const RecordType = enum { Begin, Insert, Delete, Commit, Abort, CLR, Checkpoint, PageCompact };

pub const UpdatePayload = struct { page: u32, slot: u16, data: []const u8 };

pub const DeletePayload = struct { page: u32, slot: u16 };

pub const ClrPayload = struct { page: u32, slot: u16, undo_next: u64 };

pub const Record = struct {
    lsn: Lsn,
    prev_lsn: u64 = 0,
    txn_id: u64 = 0,
    typ: RecordType,
    // Only one of the below used depending on typ; for simplicity store as raw bytes in file.
    payload: []const u8 = &.{},
    checksum: u32 = 0, // adler32 over header(with zeroed checksum) + payload
};

pub const Wal = struct {
    allocator: std.mem.Allocator,
    next_lsn: u64 = 1,
    buf: std.ArrayList(Record),
    file: ?std.fs.File = null,
    base_path: []const u8 = &.{},
    segment_index: u32 = 0,
    segment_bytes: usize = 0,
    segment_limit: usize = 1 * 1024 * 1024, // 1MB default rollover threshold (tunable later)
    // Sparse page LSN index built during recovery for fast redo start seeking.
    // Maps page id -> highest LSN seen in log (used to skip earlier segments/records).
    page_lsn_index: ?std.AutoHashMap(u32, u64) = null,
    // Metrics captured on last recovery run (for PROFILE / tests).
    last_skip_count: usize = 0,
    last_total_records: usize = 0,
    // Distinct committed txn ids discovered during initial scan (persisted segments)
    recovered_committed: usize = 0,
    // Compaction cadence management
    last_checkpoint_lsn: u64 = 0,
    commits_since_checkpoint: usize = 0,
    checkpoint_interval: usize = 10, // checkpoint every N commits
    compaction_interval: usize = 5, // compact every N checkpoints
    checkpoints_since_compaction: usize = 0,
    background_compaction_enabled: bool = false,
    // Encryption
    enc_enabled: bool = false,
    enc_key: [32]u8 = undefined,
    // Commit flush policy
    commit_flush_mode: CommitFlushMode = .always,
    group_n: u32 = 10,
    time_window_ms: u32 = 0,
    last_flush_lsn: u64 = 0,
    last_flush_ms: i64 = 0,
    pending_commit_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Wal {
        return .{ .allocator = allocator, .buf = std.ArrayList(Record).empty };
    }

    // GAP-0155 FIX: Updated to use parseWalHexKey with proper error handling
    fn loadEncConfig(self: *Wal) void {
        self.enc_enabled = false;
        if (std.process.getEnvVarOwned(self.allocator, "GEODE_WAL_ENCRYPTION")) |v| {
            defer self.allocator.free(v);
            if (std.mem.eql(u8, v, "on")) self.enc_enabled = true;
        } else |_| {
            if (std.process.getEnvVarOwned(self.allocator, "GEODE_DISK_ENCRYPTION")) |v2| {
                defer self.allocator.free(v2);
                if (std.mem.eql(u8, v2, "on")) self.enc_enabled = true;
            } else |_| {}
        }
        if (self.enc_enabled) {
            const hex = std.process.getEnvVarOwned(self.allocator, "GEODE_DISK_KEY_HEX") catch null;
            if (hex == null) {
                log.err("SECURITY: GEODE_DISK_KEY_HEX not set but encryption enabled", &.{
                    Attr.string("action", "disabling_encryption"),
                });
                self.enc_enabled = false;
                return;
            }
            defer self.allocator.free(hex.?);

            // GAP-0155 FIX: Use parseWalHexKey with proper error handling instead of catch 0
            const master = parseWalHexKey(hex.?) catch |err| {
                log.err("SECURITY: Failed to parse GEODE_DISK_KEY_HEX", &.{
                    Attr.err("error", err),
                    Attr.string("action", "disabling_encryption"),
                });
                self.enc_enabled = false;
                return;
            };

            const tde = @import("tde_hierarchy");
            const kh = tde.KeyHierarchy.init(master);
            self.enc_key = kh.wal_key;
        }
    }

    fn loadFlushConfig(self: *Wal) void {
        // Segment rollover size (bytes)
        if (std.process.getEnvVarOwned(self.allocator, "GEODE_WAL_SEGMENT_SIZE")) |v| {
            defer self.allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 0;
            if (parsed > 0) {
                self.segment_limit = parsed;
            } else {
                log.warn("Invalid GEODE_WAL_SEGMENT_SIZE; using default", &.{
                    Attr.string("value", v),
                    Attr.int("default_bytes", @intCast(self.segment_limit)),
                });
            }
        } else |_| {}

        // Commit flush mode: always | every_n | time_window_ms
        if (std.process.getEnvVarOwned(self.allocator, "GEODE_WAL_FLUSH_MODE")) |v| {
            defer self.allocator.free(v);
            if (std.ascii.eqlIgnoreCase(v, "always")) {
                self.commit_flush_mode = .always;
            } else if (std.ascii.eqlIgnoreCase(v, "every_n")) {
                self.commit_flush_mode = .every_n;
            } else if (std.ascii.eqlIgnoreCase(v, "time_window_ms")) {
                self.commit_flush_mode = .time_window_ms;
            } else {
                log.warn("Invalid GEODE_WAL_FLUSH_MODE; using default", &.{
                    Attr.string("value", v),
                    Attr.string("default", "always"),
                });
            }
        } else |_| {}

        if (std.process.getEnvVarOwned(self.allocator, "GEODE_WAL_FLUSH_EVERY_N")) |v| {
            defer self.allocator.free(v);
            const parsed = std.fmt.parseInt(u32, v, 10) catch 0;
            if (parsed > 0) {
                self.group_n = parsed;
            } else {
                log.warn("Invalid GEODE_WAL_FLUSH_EVERY_N; using default", &.{
                    Attr.string("value", v),
                    Attr.int("default", @intCast(self.group_n)),
                });
            }
        } else |_| {}

        if (std.process.getEnvVarOwned(self.allocator, "GEODE_WAL_FLUSH_WINDOW_MS")) |v| {
            defer self.allocator.free(v);
            const parsed = std.fmt.parseInt(u32, v, 10) catch 0;
            if (parsed > 0) {
                self.time_window_ms = parsed;
            } else {
                log.warn("Invalid GEODE_WAL_FLUSH_WINDOW_MS; using default", &.{
                    Attr.string("value", v),
                    Attr.int("default", @intCast(self.time_window_ms)),
                });
            }
        } else |_| {}

        if (self.commit_flush_mode == .time_window_ms and self.time_window_ms == 0) {
            self.time_window_ms = 5;
        }
    }

    fn openSegment(self: *Wal) !void {
        // Close previous if open
        if (self.file) |*f| f.close();
        const dir = std.fs.cwd();
        const path = try std.fmt.allocPrint(self.allocator, "{s}.wal.{d}", .{ self.base_path, self.segment_index });
        defer self.allocator.free(path);
        self.file = try dir.createFile(path, .{ .read = true, .truncate = false, .exclusive = false, .mode = 0o600 });
        self.segment_bytes = 0;
        fsync_util.fsyncParent(path) catch |err| {
            log.err("Failed to fsync WAL parent directory", &.{
                Attr.string("path", path),
                Attr.err("error", err),
                Attr.string("risk", "durability"),
            });
        };
    }

    pub fn openFile(self: *Wal, base_path: []const u8) !void {
        self.base_path = try self.allocator.dupe(u8, base_path);
        self.segment_index = 0;
        self.loadEncConfig();
        self.loadFlushConfig();
        try self.openSegment();
        // Perform lightweight committed txn scan across existing segments (if any)
        self.recovered_committed = try self.scanCommitted();
    }

    pub fn deinit(self: *Wal) void {
        if (self.pending_commit_count > 0) {
            self.fsync() catch {};
        }
        if (self.file) |*f| f.close();
        self.buf.deinit(self.allocator);
        if (self.page_lsn_index) |*m| m.deinit();
        if (self.base_path.len > 0) self.allocator.free(self.base_path);
    }

    pub fn skipRatio(self: *const Wal) f64 {
        if (self.last_total_records == 0) return 0.0;
        return @as(f64, @floatFromInt(self.last_skip_count)) / @as(f64, @floatFromInt(self.last_total_records));
    }

    pub fn committedTxnTotal(self: *const Wal) usize {
        // Count commit records in in-memory buffer plus recovered_committed.
        var map = std.AutoHashMap(u64, void).init(self.allocator);
        defer map.deinit();
        for (self.buf.items) |r| if (r.typ == .Commit) {
            map.put(r.txn_id, {}) catch |err| {
                log.warn("Failed to track committed txn in count", &.{
                    Attr.uint("txn_id", r.txn_id),
                    Attr.err("error", err),
                });
            };
        };
        return self.recovered_committed + map.count();
    }

    /// Lightweight scan for committed txn ids across sequential wal segments.
    pub fn scanCommitted(self: *Wal) !usize {
        if (self.base_path.len == 0) return 0;
        const dir = std.fs.cwd();
        var seen = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen.deinit();
        var seg_index: u32 = 0;
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4;
        while (seg_index <= self.segment_index + 128) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(self.allocator, "{s}.wal.{d}", .{ self.base_path, seg_index });
            defer self.allocator.free(path);
            const f = dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            defer f.close();
            var buf: [HeaderLen]u8 = undefined;
            while (true) {
                const n = f.readAll(&buf) catch 0; // treat any read error as segment end in lightweight scan
                if (n != HeaderLen) break; // partial or EOF
                const typ: RecordType = @enumFromInt(buf[0]);
                if (typ == .Commit) {
                    const txn_id = std.mem.readInt(u64, buf[1..9], .little);
                    _ = seen.put(txn_id, {}) catch |err| {
                        log.warn("Failed to track txn in scan", &.{
                            Attr.uint("txn_id", txn_id),
                            Attr.err("error", err),
                        });
                    };
                }
                const plen = std.mem.readInt(u32, buf[9..13], .little);
                if (plen > 0) try f.seekBy(@as(i64, plen));
                var sentinel: [4]u8 = undefined;
                const sn = f.readAll(&sentinel) catch 0;
                if (sn != 4) break;
            }
        }
        return seen.count();
    }

    /// Compact WAL segments whose maximum LSN is strictly less than durable_lsn.
    /// Keeps current open segment even if old (safety); caller should checkpoint+rotate first for deeper reclaim.
    pub fn compact(self: *Wal, durable_lsn: u64) !void {
        if (self.base_path.len == 0) return; // not opened
        const dir = std.fs.cwd();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Enumerate sequential segment indices until a gap; stop at first missing.
        var seg_index: u32 = 0;
        while (seg_index <= self.segment_index + 64) : (seg_index += 1) { // hard cap scan window
            const seg_path = try std.fmt.allocPrint(a, "{s}.wal.{d}", .{ self.base_path, seg_index });
            const maybe_file = dir.openFile(seg_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (maybe_file) |f| {
                defer f.close();
                // Skip active segment (never delete the one currently open for append).
                if (seg_index == self.segment_index) continue;
                // Scan headers computing max lsn.
                const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4; // with checksum
                var buf: [HeaderLen]u8 = undefined;
                var max_lsn: u64 = 0;
                try f.seekTo(0);
                while (true) {
                    const n = f.readAll(&buf) catch {
                        break; // treat any short read as end
                    };
                    if (n != buf.len) break;
                    const plen = std.mem.readInt(u32, buf[9..13], .little);
                    const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
                    if (lsn_v > max_lsn) max_lsn = lsn_v;
                    // skip payload + sentinel
                    if (plen > 0) try f.seekBy(@as(i64, plen));
                    // attempt to read sentinel (4 bytes) and discard (ignore mismatch here)
                    var sentinel: [4]u8 = undefined;
                    const sn = f.readAll(&sentinel) catch 0;
                    if (sn != 4) break;
                }
                if (max_lsn < durable_lsn and max_lsn != 0) {
                    // Safe to delete.
                    dir.deleteFile(seg_path) catch |errd| switch (errd) {
                        error.FileNotFound => {},
                        else => return errd,
                    };
                }
            } else if (seg_index > self.segment_index) break; // gap beyond active -> stop
        }
    }

    /// Scan segments (read-only) to discover last checkpoint LSN and highest segment present.
    pub fn scanMetadata(self: *Wal) !struct { last_checkpoint_lsn: u64, max_segment: u32 } {
        if (self.base_path.len == 0) return .{ .last_checkpoint_lsn = 0, .max_segment = 0 };
        const dir = std.fs.cwd();
        var seg_index: u32 = 0;
        var last_ckpt: u64 = 0;
        var highest: u32 = 0;
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4;
        while (seg_index <= self.segment_index + 128) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(self.allocator, "{s}.wal.{d}", .{ self.base_path, seg_index });
            defer self.allocator.free(path);
            const f = dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            defer f.close();
            highest = seg_index;
            var buf: [HeaderLen]u8 = undefined;
            try f.seekTo(0);
            while (true) {
                const n = f.readAll(&buf) catch {
                    // Treat partial read as end-of-segment for tools that import with reduced error set.
                    break;
                };
                if (n != buf.len) break;
                const typ: RecordType = @enumFromInt(buf[0]);
                if (typ == .Checkpoint) {
                    const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
                    if (lsn_v > last_ckpt) last_ckpt = lsn_v;
                }
                const plen = std.mem.readInt(u32, buf[9..13], .little);
                if (plen > 0) try f.seekBy(@as(i64, plen));
                var sentinel: [4]u8 = undefined;
                const sn = f.readAll(&sentinel) catch 0;
                if (sn != 4) break;
            }
        }
        return .{ .last_checkpoint_lsn = last_ckpt, .max_segment = highest };
    }

    fn adler32(data: []const u8) u32 {
        var a: u32 = 1;
        var b: u32 = 0;
        for (data) |c| {
            a = (a + c) % 65521;
            b = (b + a) % 65521;
        }
        return (b << 16) | a;
    }

    fn diskWrite(self: *Wal, rec: Record) !void {
        if (self.file) |f| {
            const HeaderLen: usize = 1 + 8 + 4 + 8 + 8 + 4; // + checksum field (zeroed for calc)
            var header: [1 + 8 + 4 + 8 + 8 + 4]u8 = undefined;
            header[0] = @intFromEnum(rec.typ);
            std.mem.writeInt(u64, header[1..9], rec.txn_id, .little);
            var payload_buf = rec.payload;
            var enc_owned: []u8 = &.{};
            defer if (enc_owned.len != 0) self.allocator.free(enc_owned);
            if (self.enc_enabled and rec.payload.len > 0) {
                enc_owned = try WalEnc.encrypt(self.allocator, &self.enc_key, rec.lsn.value, rec.payload);
                payload_buf = enc_owned;
            }
            std.mem.writeInt(u32, header[9..13], @intCast(payload_buf.len), .little); // may be plaintext or encrypted length
            std.mem.writeInt(u64, header[13..21], rec.lsn.value, .little);
            std.mem.writeInt(u64, header[21..29], rec.prev_lsn, .little);
            std.mem.writeInt(u32, header[29..33], 0, .little); // zero before checksum
            // P2-3: Use WAL's allocator instead of page_allocator
            var cs_buf = std.ArrayList(u8).empty;
            defer cs_buf.deinit(self.allocator);
            cs_buf.appendSlice(self.allocator, header[0..]) catch |err| {
                log.err("Failed to append header to checksum buffer", &.{
                    Attr.err("error", err),
                });
            };
            cs_buf.appendSlice(self.allocator, payload_buf) catch |err| {
                log.err("Failed to append payload to checksum buffer", &.{
                    Attr.err("error", err),
                });
            };
            const cs = adler32(cs_buf.items);
            std.mem.writeInt(u32, header[29..33], cs, .little);
            // Rollover check: if writing header+payload+sentinel would exceed limit, rotate segment first.
            const needed = HeaderLen + payload_buf.len + 4; // add sentinel size
            if (self.segment_bytes + needed > self.segment_limit) {
                self.segment_index += 1;
                try self.openSegment();
            }
            try f.writeAll(header[0..]);
            if (payload_buf.len > 0) try f.writeAll(payload_buf);
            // Torn-write sentinel magic (GEODE) 0xEC0DDBAD
            var sentinel: [4]u8 = undefined;
            std.mem.writeInt(u32, sentinel[0..4], 0xEC0DDBAD, .little);
            try f.writeAll(&sentinel);
            self.segment_bytes += needed;
        }
    }

    pub fn append(self: *Wal, txn_id: u64, typ: RecordType, payload: []const u8, prev_lsn: u64) !Lsn {
        const lsn_val = self.next_lsn;
        self.next_lsn += 1;
        const rec_lsn: Lsn = .{ .value = lsn_val };
        const rec = Record{ .lsn = .{ .value = lsn_val }, .txn_id = txn_id, .typ = typ, .payload = payload, .prev_lsn = prev_lsn };
        try self.buf.append(self.allocator, rec);
        try self.diskWrite(rec);

        // Automatic compaction cadence
        if (typ == .Commit) {
            self.commits_since_checkpoint += 1;
            if (self.commits_since_checkpoint >= self.checkpoint_interval) {
                _ = self.writeCheckpoint() catch |err| {
                    log.err("Failed to write WAL checkpoint", &.{
                        Attr.err("error", err),
                        Attr.string("risk", "slow_recovery"),
                    });
                };
                self.commits_since_checkpoint = 0;
                self.checkpoints_since_compaction += 1;

                if (self.checkpoints_since_compaction >= self.compaction_interval) {
                    // Use current LSN as durable horizon for compaction
                    self.compact(lsn_val) catch |err| {
                        log.err("Failed to compact WAL", &.{
                            Attr.err("error", err),
                            Attr.string("risk", "disk_space"),
                        });
                    };
                    self.checkpoints_since_compaction = 0;
                }
            }
        }

        return rec_lsn;
    }

    // Structured payload encoders -------------------------------------------------
    pub fn encodeInsert(allocator: std.mem.Allocator, page: u32, slot: u16, data: []const u8) ![]u8 {
        var buf = try allocator.alloc(u8, 8 + data.len);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        std.mem.writeInt(u16, buf[6..8], @intCast(data.len), .little);
        @memcpy(buf[8..], data);
        return buf;
    }

    pub fn encodeDelete(allocator: std.mem.Allocator, page: u32, slot: u16) ![]u8 {
        var buf = try allocator.alloc(u8, 6);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        return buf;
    }

    // Delete with before-image: [page(4)|slot(2)|len(2)|data]
    pub fn encodeDeleteBefore(allocator: std.mem.Allocator, page: u32, slot: u16, data: []const u8) ![]u8 {
        var buf = try allocator.alloc(u8, 8 + data.len);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        std.mem.writeInt(u16, buf[6..8], @intCast(data.len), .little);
        @memcpy(buf[8..], data);
        return buf;
    }

    pub fn decodeDeleteBefore(payload: []const u8) ?struct { page: u32, slot: u16, len: u16, data: []const u8 } {
        if (payload.len < 8) return null;
        const page = std.mem.readInt(u32, payload[0..4], .little);
        const slot = std.mem.readInt(u16, payload[4..6], .little);
        const dlen = std.mem.readInt(u16, payload[6..8], .little);
        if (payload.len < 8 + dlen) return null;
        return .{ .page = page, .slot = slot, .len = dlen, .data = payload[8 .. 8 + dlen] };
    }

    pub fn decodeInsert(payload: []const u8) ?struct { page: u32, slot: u16, len: u16, data: []const u8 } {
        if (payload.len < 8) return null;
        const page = std.mem.readInt(u32, payload[0..4], .little);
        const slot = std.mem.readInt(u16, payload[4..6], .little);
        const dlen = std.mem.readInt(u16, payload[6..8], .little);
        if (payload.len < 8 + dlen) return null;
        return .{ .page = page, .slot = slot, .len = dlen, .data = payload[8 .. 8 + dlen] };
    }

    pub fn decodeDelete(payload: []const u8) ?struct { page: u32, slot: u16 } {
        if (payload.len < 6) return null;
        return .{ .page = std.mem.readInt(u32, payload[0..4], .little), .slot = std.mem.readInt(u16, payload[4..6], .little) };
    }

    pub fn fsync(self: *Wal) !void {
        if (self.file) |f| try f.sync();
        self.last_flush_lsn = self.next_lsn - 1;
        self.last_flush_ms = std.time.milliTimestamp();
        self.pending_commit_count = 0;
    }

    // CANARY: REQ=REQ-GQL-028; FEATURE="WAL Flush Batch"; ASPECT=Durability; STATUS=IMPL; OWNER=storage; UPDATED=2026-01-27
    pub fn setFlushMode(self: *Wal, mode: CommitFlushMode, group_n: u32, time_window_ms: u32) void {
        self.commit_flush_mode = mode;
        if (group_n > 0) self.group_n = group_n;
        if (time_window_ms > 0) self.time_window_ms = time_window_ms;
    }

    pub fn flushForRecord(self: *Wal, typ: RecordType) !void {
        if (typ != .Commit) {
            try self.fsync();
            return;
        }

        switch (self.commit_flush_mode) {
            .always => try self.fsync(),
            .every_n => {
                self.pending_commit_count += 1;
                if (self.group_n == 0) self.group_n = 1;
                if (self.pending_commit_count >= self.group_n) {
                    try self.fsync();
                }
            },
            .time_window_ms => {
                self.pending_commit_count += 1;
                if (self.time_window_ms == 0) {
                    try self.fsync();
                    return;
                }
                const now = std.time.milliTimestamp();
                if (self.last_flush_ms == 0 or (now - self.last_flush_ms) >= @as(i64, @intCast(self.time_window_ms))) {
                    try self.fsync();
                }
            },
        }
    }

    pub fn writeCheckpoint(self: *Wal) !Lsn {
        const lsn_val = self.next_lsn;
        self.next_lsn += 1;
        const rec_lsn: Lsn = .{ .value = lsn_val };
        const rec = Record{ .lsn = .{ .value = lsn_val }, .txn_id = 0, .typ = .Checkpoint, .payload = &.{}, .prev_lsn = 0 };
        try self.buf.append(self.allocator, rec);
        try self.diskWrite(rec);

        self.last_checkpoint_lsn = lsn_val;
        try self.fsync();
        return rec_lsn;
    }

    /// Configure compaction cadence
    pub fn setCompactionCadence(self: *Wal, checkpoint_interval: usize, compaction_interval: usize) void {
        self.checkpoint_interval = checkpoint_interval;
        self.compaction_interval = compaction_interval;
    }

    /// Get compaction statistics
    pub fn getCompactionStats(self: *const Wal) struct {
        commits_since_checkpoint: usize,
        checkpoints_since_compaction: usize,
        last_checkpoint_lsn: u64,
        segment_count: usize,
        total_wal_size_bytes: usize,
        oldest_segment_age_seconds: i64,
        background_compaction_enabled: bool,
    } {
        return .{
            .commits_since_checkpoint = self.commits_since_checkpoint,
            .checkpoints_since_compaction = self.checkpoints_since_compaction,
            .last_checkpoint_lsn = self.last_checkpoint_lsn,
            .segment_count = self.countSegments() catch 0,
            .total_wal_size_bytes = self.getTotalWalSize() catch 0,
            .oldest_segment_age_seconds = self.getOldestSegmentAge() catch 0,
            .background_compaction_enabled = self.background_compaction_enabled,
        };
    }

    /// Live rollback: walk backward via prev_lsn producing CLR records for each undone Insert.
    pub fn rollback(self: *Wal, txn_id: u64) !void {
        // Find last record for txn
        var last: ?*const Record = null;
        for (self.buf.items) |*r| {
            if (r.txn_id == txn_id) last = r;
        }
        var cursor = last;
        while (cursor) |rec| {
            switch (rec.typ) {
                .Insert => {
                    // generate CLR tombstoning same slot
                    if (decodeInsert(rec.payload)) |ins| {
                        const clr_payload = try encodeDelete(self.allocator, ins.page, ins.slot);
                        _ = try self.append(txn_id, .CLR, clr_payload, rec.lsn.value);
                    }
                },
                else => {},
            }
            // follow prev_lsn
            var prev: ?*const Record = null;
            for (self.buf.items) |*r2| {
                if (r2.lsn.value == rec.prev_lsn and r2.txn_id == txn_id) {
                    prev = r2;
                    break;
                }
            }
            cursor = prev;
        }
        // finally emit Abort
        _ = try self.append(txn_id, .Abort, &.{}, 0);
        try self.fsync();
    }

    pub fn iter(self: *Wal) WalIter {
        return .{ .wal = self, .idx = 0 };
    }

    /// ARIES-style recovery (simplified): redo committed (or loser updates needed), then undo losers.
    pub fn recover(self: *Wal, pm: *storage.PageManager, path: []const u8) !usize {
        // Baseline recover delegates to internal implementation without prebuilt record index
        return try self.recoverOptimized(pm, path, false);
    }

    /// Optimized recovery with optional pre-scan building a dense LSN -> record offset index to avoid
    /// materializing all payloads before redo start point. When optimize=true, only payload headers are
    /// read until redo start, deferring full payload allocation past sparse pageLSN index derived start.
    pub fn recoverOptimized(self: *Wal, pm: *storage.PageManager, path: []const u8, optimize: bool) !usize {
        const dir = std.fs.cwd();
        var f = dir.openFile(path, .{}) catch return 0; // nothing to recover
        defer f.close();
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4; // w/ checksum
        // txn table
        var txn_map = std.AutoHashMap(u64, struct { committed: bool, last_lsn: u64 }).init(self.allocator);
        defer txn_map.deinit();
        var records = std.ArrayListUnmanaged(Record){};
        defer records.deinit(self.allocator);
        var buf: [HeaderLen]u8 = undefined;
        // Find last checkpoint offset (linear scan; future: index).
        var last_ckpt: usize = 0;
        var last_ckpt_lsn: u64 = 0;
        try f.seekTo(0);
        // Build sparse page->lsn index while scanning headers (payload needed for page id extraction on Insert/Delete/CLR).
        if (self.page_lsn_index == null) {
            self.page_lsn_index = std.AutoHashMap(u32, u64).init(self.allocator);
        } else {
            // clear previous
            var it_clear = self.page_lsn_index.?.iterator();
            while (it_clear.next()) |_| {}
        }
        const idx_map_ptr = &self.page_lsn_index.?;
        while (true) {
            const n = f.readAll(&buf) catch {
                break; // treat any read error as EOF/termination for simplified optimized recovery
            };
            if (n == 0) break;
            if (n != buf.len) break; // tolerate partial tail
            const typ: RecordType = @enumFromInt(buf[0]);
            const txn_id = std.mem.readInt(u64, buf[1..9], .little);
            const plen = std.mem.readInt(u32, buf[9..13], .little);
            const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
            if (typ == .Checkpoint) {
                last_ckpt = @intCast(try f.getPos());
                last_ckpt_lsn = lsn_v;
            }
            const prev_lsn_v = std.mem.readInt(u64, buf[21..29], .little);
            const file_cs = std.mem.readInt(u32, buf[29..33], .little);
            var payload_slice: []u8 = &.{};
            if (plen > 0) {
                if (optimize and last_ckpt_lsn != 0 and lsn_v < last_ckpt_lsn) {
                    // Skip materializing payload prior to last checkpoint when optimizing.
                    try f.seekBy(@as(i64, plen));
                } else {
                    payload_slice = try self.allocator.alloc(u8, plen);
                    const got = f.readAll(payload_slice) catch 0;
                    if (got != plen) {
                        self.allocator.free(payload_slice);
                        break;
                    }
                }
            }
            // verify checksum (reconstruct header with zeroed checksum)
            var verify_header: [HeaderLen]u8 = undefined;
            @memcpy(verify_header[0..HeaderLen], buf[0..HeaderLen]);
            std.mem.writeInt(u32, verify_header[29..33], 0, .little);
            // Compute checksum using existing adler32 helper.
            const calc_cs = adler32(verify_header[0..HeaderLen]) ^ adler32(payload_slice);
            if (calc_cs != file_cs) {
                // stop recovery at first checksum failure (truncate tail)
                if (payload_slice.len > 0) self.allocator.free(payload_slice);
                break;
            }
            // Read and validate torn-write sentinel (4 bytes). If mismatch, treat as torn tail and stop.
            var sentinel_buf: [4]u8 = undefined;
            const sn = f.readAll(&sentinel_buf) catch 0;
            if (sn != 4) break; // partial sentinel -> torn tail
            const sent_val = std.mem.readInt(u32, &sentinel_buf, .little);
            if (sent_val != 0xEC0DDBAD) break; // torn write or corruption
            // Decrypt payload if enabled
            if (self.enc_enabled and payload_slice.len > 0) {
                // Decrypt into fresh buffer; free encrypted slice afterwards.
                const dec = WalEnc.decrypt(self.allocator, &self.enc_key, lsn_v, payload_slice) catch {
                    // If decryption fails treat as corruption/truncated tail.
                    if (payload_slice.len > 0) self.allocator.free(payload_slice);
                    break;
                };
                if (payload_slice.len > 0) self.allocator.free(payload_slice);
                payload_slice = dec;
            }
            var entry = try txn_map.getOrPut(txn_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .committed = false, .last_lsn = 0 };
            entry.value_ptr.last_lsn = lsn_v;
            if (typ == .Commit) entry.value_ptr.committed = true;
            try records.append(self.allocator, .{ .lsn = .{ .value = lsn_v }, .txn_id = txn_id, .typ = typ, .payload = payload_slice, .prev_lsn = prev_lsn_v });
            // Populate sparse index for data-bearing records.
            switch (typ) {
                .Insert, .Delete, .CLR => {
                    if (payload_slice.len >= 6) {
                        const page_id = std.mem.readInt(u32, payload_slice[0..4], .little);
                        const ie = try idx_map_ptr.getOrPut(page_id);
                        if (!ie.found_existing or ie.value_ptr.* < lsn_v) ie.value_ptr.* = lsn_v;
                    }
                },
                else => {},
            }
        }

        // REDO pass (forward): starting at last checkpoint if present.
        var start_index: usize = 0;
        if (last_ckpt_lsn != 0) {
            var idx: usize = 0;
            while (idx < records.items.len) : (idx += 1) {
                if (records.items[idx].lsn.value >= last_ckpt_lsn) {
                    start_index = idx;
                    break;
                }
            }
        }
        // Fast-seek optimization via sparse pageLSN index
        var skip_count: usize = 0;
        self.last_skip_count = 0;
        self.last_total_records = records.items.len;
        if (self.page_lsn_index) |m| {
            var min_lsn: u64 = std.math.maxInt(u64);
            var itp = m.iterator();
            while (itp.next()) |e| {
                if (e.value_ptr.* < min_lsn) min_lsn = e.value_ptr.*;
            }
            if (min_lsn != std.math.maxInt(u64)) {
                var lo: isize = @intCast(start_index);
                var hi: isize = @as(isize, @intCast(records.items.len)) - 1;
                var target_idx: isize = @intCast(start_index);
                while (lo <= hi) {
                    const mid: isize = @divTrunc(lo + hi, 2);
                    const mid_lsn = records.items[@intCast(mid)].lsn.value;
                    if (mid_lsn < min_lsn) {
                        lo = mid + 1;
                        target_idx = lo;
                    } else {
                        hi = mid - 1;
                        target_idx = mid;
                    }
                }
                if (target_idx > @as(isize, @intCast(start_index)) and target_idx < @as(isize, @intCast(records.items.len))) {
                    skip_count = @as(usize, @intCast(target_idx)) - start_index;
                    start_index = @as(usize, @intCast(target_idx));
                }
            }
        }
        self.last_skip_count = skip_count;
        self.last_total_records = records.items.len;
        var applied: usize = 0;
        for (records.items[start_index..]) |rec| {
            switch (rec.typ) {
                .Insert => {
                    if (decodeInsert(rec.payload)) |ins| {
                        while (ins.page >= pm.pages.items.len) try pm.newPage();
                        var p = pm.asPage(ins.page);
                        if (p.lsn() >= rec.lsn.value) continue; // already applied
                        if (ins.slot >= p.slotCount()) {
                            _ = p.insert(ins.data) catch |err| {
                                log.err("Failed to insert during WAL replay", &.{
                                    Attr.uint("page", ins.page),
                                    Attr.uint("slot", ins.slot),
                                    Attr.uint("lsn", rec.lsn.value),
                                    Attr.err("error", err),
                                });
                            };
                        }
                        p.setLsn(rec.lsn.value);
                        applied += 1;
                    }
                },
                .Delete, .CLR => {
                    if (decodeDelete(rec.payload)) |del| {
                        if (del.page < pm.pages.items.len) {
                            var p = pm.asPage(del.page);
                            if (p.lsn() >= rec.lsn.value) continue;
                            p.tombstone(del.slot) catch |err| {
                                log.err("Failed to tombstone during WAL replay", &.{
                                    Attr.uint("page", del.page),
                                    Attr.uint("slot", del.slot),
                                    Attr.uint("lsn", rec.lsn.value),
                                    Attr.err("error", err),
                                });
                            };
                            p.setLsn(rec.lsn.value);
                            applied += 1;
                        }
                    }
                },
                else => {},
            }
        }
        // UNDO pass
        var losers = std.AutoHashMap(u64, u64).init(self.allocator);
        defer losers.deinit();
        var it_l = txn_map.iterator();
        while (it_l.next()) |e| {
            if (!e.value_ptr.committed) try losers.put(e.key_ptr.*, e.value_ptr.last_lsn);
        }
        var i: isize = @as(isize, @intCast(records.items.len)) - 1;
        while (i >= 0) : (i -= 1) {
            const rec = records.items[@intCast(i)];
            if (!losers.contains(rec.txn_id)) continue;
            switch (rec.typ) {
                .Insert => {
                    if (rec.payload.len >= 8) {
                        const page = std.mem.readInt(u32, rec.payload[0..4], .little);
                        const slot = std.mem.readInt(u16, rec.payload[4..6], .little);
                        if (page < pm.pages.items.len) {
                            var p = pm.asPage(page);
                            p.tombstone(slot) catch |err| {
                                log.err("Failed to tombstone during WAL UNDO", &.{
                                    Attr.uint("page", page),
                                    Attr.uint("slot", slot),
                                    Attr.uint("txn_id", rec.txn_id),
                                    Attr.err("error", err),
                                });
                            };
                        }
                        if (self.file != null) {
                            const clr_payload = try encodeDelete(self.allocator, page, slot);
                            defer self.allocator.free(clr_payload);
                            _ = try self.append(rec.txn_id, .CLR, clr_payload, rec.lsn.value);
                        }
                    }
                },
                .Delete => {
                    if (decodeDeleteBefore(rec.payload)) |delb| {
                        while (delb.page >= pm.pages.items.len) try pm.newPage();
                        var p = pm.asPage(delb.page);
                        if (delb.slot >= p.slotCount()) {
                            _ = p.insert(delb.data) catch |err| {
                                log.err("Failed to insert during WAL UNDO", &.{
                                    Attr.uint("page", delb.page),
                                    Attr.uint("slot", delb.slot),
                                    Attr.uint("txn_id", rec.txn_id),
                                    Attr.err("error", err),
                                });
                            };
                        } else {
                            const slot_meta = p.readSlot(delb.slot);
                            if (slot_meta.sz == 0 and @as(usize, slot_meta.off) + delb.len <= p.buf.len) {
                                @memcpy(p.buf[slot_meta.off .. slot_meta.off + delb.len], delb.data);
                                p.writeSlot(delb.slot, slot_meta.off, delb.len);
                            } else if (slot_meta.sz == 0) {
                                _ = p.insert(delb.data) catch |err| {
                                    log.err("Failed to insert during WAL UNDO", &.{
                                        Attr.uint("page", delb.page),
                                        Attr.uint("slot", delb.slot),
                                        Attr.uint("txn_id", rec.txn_id),
                                        Attr.err("error", err),
                                    });
                                };
                            }
                        }
                        if (self.file != null) {
                            const clr_ins = try encodeInsert(self.allocator, delb.page, delb.slot, delb.data);
                            defer self.allocator.free(clr_ins);
                            _ = try self.append(rec.txn_id, .CLR, clr_ins, rec.lsn.value);
                        }
                    }
                },
                else => {},
            }
        }
        // CLR chain validation (basic)
        var clr_ok: bool = true;
        var ci: usize = 0;
        while (ci < records.items.len) : (ci += 1) {
            const r = records.items[ci];
            if (r.typ == .CLR) {
                var found_prev = false;
                var sj: usize = 0;
                while (sj < ci) : (sj += 1) {
                    const pr = records.items[sj];
                    if (pr.lsn.value == r.prev_lsn and pr.txn_id == r.txn_id) {
                        found_prev = true;
                        break;
                    }
                }
                if (!found_prev) {
                    clr_ok = false;
                    break;
                }
            }
        }
        if (!clr_ok) {
            // placeholder branch to avoid discard warning
        }
        return applied;
    }

    fn countSegments(self: *const Wal) !usize {
        _ = self;
        return 0;
    }
    fn getTotalWalSize(self: *const Wal) !usize {
        _ = self;
        return 0;
    }
    fn getOldestSegmentAge(self: *const Wal) !i64 {
        _ = self;
        return 0;
    }
};

pub const WalIter = struct {
    wal: *Wal,
    idx: usize,
    pub fn next(self: *WalIter) ?Record {
        if (self.idx >= self.wal.buf.items.len) return null;
        const r = self.wal.buf.items[self.idx];
        self.idx += 1;
        return r;
    }
};

// =============================================================================
// Unit Tests for GAP-0155: Secure WAL Hex Key Parsing
// CANARY: REQ=REQ-WAL-HEX-001; FEATURE="SecureWalHexKeyParsing"; ASPECT=TESTING; STATUS=TESTED; OWNER=security; UPDATED=2026-01-14
// =============================================================================

test "test_parseWalHexKey_valid" {
    // Valid 64-character lowercase hex string
    const valid_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const key = try parseWalHexKey(valid_hex);
    try std.testing.expectEqual(@as(u8, 0x01), key[0]);
    try std.testing.expectEqual(@as(u8, 0x23), key[1]);
    try std.testing.expectEqual(@as(u8, 0x45), key[2]);
    try std.testing.expectEqual(@as(u8, 0x67), key[3]);
    try std.testing.expectEqual(@as(u8, 0xef), key[31]);
}

test "test_parseWalHexKey_valid_uppercase" {
    // Valid 64-character uppercase hex string
    const valid_hex = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
    const key = try parseWalHexKey(valid_hex);
    try std.testing.expectEqual(@as(u8, 0x01), key[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), key[5]);
    try std.testing.expectEqual(@as(u8, 0xEF), key[31]);
}

test "test_parseWalHexKey_valid_mixed_case" {
    // Valid 64-character mixed case hex string
    const valid_hex = "0123456789AbCdEf0123456789aBcDeF0123456789AbCdEf0123456789aBcDeF";
    const key = try parseWalHexKey(valid_hex);
    try std.testing.expectEqual(@as(u8, 0x01), key[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), key[5]);
}

test "test_parseWalHexKey_invalid_char" {
    // Invalid hex character 'g'
    const invalid_hex = "0123456789abcdef0123456789abcdefg123456789abcdef0123456789abcdef";
    const result = parseWalHexKey(invalid_hex);
    try std.testing.expectError(error.InvalidWalKeyHex, result);
}

test "test_parseWalHexKey_invalid_char_space" {
    // Invalid hex character ' ' (space)
    const invalid_hex = "0123456789abcdef0123456789abcdef 123456789abcdef0123456789abcdef";
    const result = parseWalHexKey(invalid_hex);
    try std.testing.expectError(error.InvalidWalKeyHex, result);
}

test "test_parseWalHexKey_wrong_length_short" {
    // Too short (63 characters)
    const short_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde";
    const result = parseWalHexKey(short_hex);
    try std.testing.expectError(error.InvalidWalKeyLength, result);
}

test "test_parseWalHexKey_wrong_length_long" {
    // Too long (65 characters)
    const long_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0";
    const result = parseWalHexKey(long_hex);
    try std.testing.expectError(error.InvalidWalKeyLength, result);
}

test "test_parseWalHexKey_empty" {
    // Empty string
    const empty_hex = "";
    const result = parseWalHexKey(empty_hex);
    try std.testing.expectError(error.InvalidWalKeyLength, result);
}

test "test_parseWalHexKey_all_zeros" {
    // All zeros - valid but weak key
    const zero_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const key = try parseWalHexKey(zero_hex);
    for (key) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "test_parseWalHexKey_all_ff" {
    // All 0xFF - valid key
    const ff_hex = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const key = try parseWalHexKey(ff_hex);
    for (key) |byte| {
        try std.testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

// =============================================================================
// WAL Flush Mode Tests
// =============================================================================

test "test_wal_flush_mode_every_n" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/flush.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);

    var w = Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    w.setFlushMode(.every_n, 2, 0);

    _ = try w.append(1, .Commit, &.{}, 0);
    try w.flushForRecord(.Commit);
    try std.testing.expectEqual(@as(u64, 0), w.last_flush_lsn);

    _ = try w.append(1, .Commit, &.{}, 0);
    try w.flushForRecord(.Commit);
    try std.testing.expectEqual(@as(u64, 2), w.last_flush_lsn);
}

test "test_wal_flush_mode_always" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/flush_always.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);

    var w = Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    w.setFlushMode(.always, 0, 0);

    _ = try w.append(1, .Commit, &.{}, 0);
    try w.flushForRecord(.Commit);
    try std.testing.expectEqual(@as(u64, 1), w.last_flush_lsn);
}

test "test_wal_flush_mode_time_window" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/flush_window.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);

    var w = Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    w.setFlushMode(.time_window_ms, 0, 50);

    _ = try w.append(1, .Commit, &.{}, 0);
    try w.flushForRecord(.Commit);
    try std.testing.expectEqual(@as(u64, 1), w.last_flush_lsn);
}
