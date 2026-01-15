const std = @import("std");

// key_rotation.zig
// Complete encryption key rotation subsystem with audit logging and rollback support.
// CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2026-01-15
// Provides full key rotation lifecycle management with online rotation capability.

/// Audit log entry for rotation events
pub const RotationAuditEntry = struct {
    timestamp: i64,
    event_type: AuditEventType,
    old_key_id: u64,
    new_key_id: u64,
    status: RotationStatus,
    affected_pages: u64,
    error_message: ?[]const u8,
    duration_ms: u64,

    pub const AuditEventType = enum {
        rotation_started,
        rotation_completed,
        rotation_failed,
        rotation_rollback,
        reencryption_started,
        reencryption_completed,
        reencryption_failed,
    };

    pub const RotationStatus = enum {
        success,
        failed,
        rolled_back,
        in_progress,
    };
};

/// Rollback state for failed rotations
pub const RollbackState = struct {
    enabled: bool = false,
    checkpoint_key_id: u64 = 0,
    checkpoint_timestamp: i64 = 0,
    pages_to_restore: std.ArrayList(u64),
    original_key_material: ?[32]u8 = null,
};

pub const RotationPolicy = struct {
    // Minimum seconds between automatic rotations
    min_interval_secs: u64 = 24 * 60 * 60,
    // Maximum key age before forced rotation (seconds)
    max_age_secs: u64 = 30 * 24 * 60 * 60,
    // If true, re-encrypt pages lazily on access; else eager full scan.
    lazy_reencrypt: bool = true,
};

pub const DataKeyRef = struct {
    id: u64, // monotonically increasing key identifier (LSN anchor)
    created_unix_epoch: i64,
    material: [32]u8, // 256-bit AES key material (plaintext in memory)
    envelope_json: ?[]u8 = null, // wrapped key envelope (KMS) if present (owned by registry allocator)
    is_wrapped: bool = false,
};

pub const RotationEvent = struct {
    old_id: u64,
    new_id: u64,
    ts: i64,
    method: enum { scheduled, manual },
};

pub const KeyRegistry = struct {
    allocator: *std.mem.Allocator,
    active: ?DataKeyRef = null,
    history: std.ArrayList(DataKeyRef),
    // Audit log for rotation events
    audit_log: std.ArrayList(RotationAuditEntry),
    // Rollback state for failed rotations
    rollback_state: RollbackState,
    // persisted state path (optional)
    state_path: ?[]const u8 = null,
    kms_seed: ?u64 = null, // deterministic seed for simulated external KMS
    remote_kms_host: ?[]const u8 = null,
    remote_kms_port: ?u16 = null,
    // Version tracking
    current_version: u32 = 1,

    pub fn init(allocator: *std.mem.Allocator) KeyRegistry {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(DataKeyRef).init(allocator),
            .audit_log = std.ArrayList(RotationAuditEntry).init(allocator),
            .rollback_state = .{
                .pages_to_restore = std.ArrayList(u64).init(allocator),
            },
            .state_path = null,
            .kms_seed = null,
            .remote_kms_host = null,
            .remote_kms_port = null,
        };
    }

    pub fn deinit(self: *KeyRegistry) void {
        // free any envelope json slices
        for (self.history.items) |*ref| if (ref.envelope_json) |ej| self.allocator.free(ej);
        self.history.deinit();
        self.audit_log.deinit();
        self.rollback_state.pages_to_restore.deinit();
    }

    /// Log an audit entry for rotation events
    pub fn logAuditEvent(
        self: *KeyRegistry,
        event_type: RotationAuditEntry.AuditEventType,
        old_key_id: u64,
        new_key_id: u64,
        status: RotationAuditEntry.RotationStatus,
        affected_pages: u64,
        error_message: ?[]const u8,
        duration_ms: u64,
    ) !void {
        try self.audit_log.append(.{
            .timestamp = std.time.timestamp(),
            .event_type = event_type,
            .old_key_id = old_key_id,
            .new_key_id = new_key_id,
            .status = status,
            .affected_pages = affected_pages,
            .error_message = error_message,
            .duration_ms = duration_ms,
        });
    }

    /// Create a checkpoint for rollback capability
    pub fn createRollbackCheckpoint(self: *KeyRegistry) !void {
        if (self.active) |current_key| {
            self.rollback_state.enabled = true;
            self.rollback_state.checkpoint_key_id = current_key.id;
            self.rollback_state.checkpoint_timestamp = std.time.timestamp();
            self.rollback_state.original_key_material = current_key.material;
            self.rollback_state.pages_to_restore.clearRetainingCapacity();
        }
    }

    /// Rollback to the checkpoint state if rotation fails
    pub fn rollbackToCheckpoint(self: *KeyRegistry) !void {
        if (!self.rollback_state.enabled) return error.NoCheckpointAvailable;

        // Find the checkpointed key in history
        for (self.history.items) |key| {
            if (key.id == self.rollback_state.checkpoint_key_id) {
                self.active = key;
                try self.logAuditEvent(
                    .rotation_rollback,
                    if (self.active) |a| a.id else 0,
                    self.rollback_state.checkpoint_key_id,
                    .rolled_back,
                    self.rollback_state.pages_to_restore.items.len,
                    "Rolled back to checkpoint",
                    0,
                );
                self.rollback_state.enabled = false;
                return;
            }
        }

        return error.CheckpointKeyNotFound;
    }

    /// Discard rollback checkpoint (call after successful rotation)
    pub fn discardRollbackCheckpoint(self: *KeyRegistry) void {
        self.rollback_state.enabled = false;
        self.rollback_state.checkpoint_key_id = 0;
        self.rollback_state.original_key_material = null;
        self.rollback_state.pages_to_restore.clearRetainingCapacity();
    }

    pub fn setKmsSeed(self: *KeyRegistry, seed: u64) void {
        self.kms_seed = seed;
    }

    pub fn setRemoteKms(self: *KeyRegistry, host: []const u8, port: u16) void {
        self.remote_kms_host = host;
        self.remote_kms_port = port;
    }

    /// Load or generate active data key using cryptographically secure random source
    /// CANARY: REQ=REQ-KEY-ROTATION-001; FEATURE="SecureKeyGeneration"; ASPECT=Security; STATUS=IMPL; UPDATED=2026-01-10
    pub fn loadActiveDataKey(self: *KeyRegistry) !DataKeyRef {
        if (self.active) |k| return k;
        // Generate key material using cryptographically secure random source
        var key: DataKeyRef = .{
            .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1,
            .created_unix_epoch = std.time.timestamp(),
            .material = undefined,
            .envelope_json = null,
            .is_wrapped = false,
        };
        // Use std.crypto.random for secure key generation
        std.crypto.random.bytes(&key.material);
        try self.history.append(key);
        self.active = key;
        return key;
    }

    /// Rotate key immediately using cryptographically secure random source
    /// CANARY: REQ=REQ-KEY-ROTATION-002; FEATURE="SecureKeyRotation"; ASPECT=Security; STATUS=IMPL; UPDATED=2026-01-10
    pub fn rotateNow(self: *KeyRegistry, policy: RotationPolicy) !RotationEvent {
        _ = policy; // placeholder until policy used
        const old = self.active;
        // Generate new key material using cryptographically secure random source
        var key: DataKeyRef = .{
            .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1,
            .created_unix_epoch = std.time.timestamp(),
            .material = undefined,
            .envelope_json = null,
            .is_wrapped = false,
        };
        // Use std.crypto.random for secure key generation
        std.crypto.random.bytes(&key.material);
        try self.history.append(key);
        self.active = key;
        return .{ .old_id = if (old) |o| o.id else 0, .new_id = key.id, .ts = std.time.timestamp(), .method = .manual };
    }

    /// Rotate key with KMS wrapping using cryptographically secure random source
    /// CANARY: REQ=REQ-KEY-ROTATION-003; FEATURE="SecureKmsKeyRotation"; ASPECT=Security; STATUS=IMPL; UPDATED=2026-01-10
    pub fn rotateWithKms(self: *KeyRegistry) !RotationEvent {
        if (self.kms_seed == null) return error.KmsNotConfigured;
        const old = self.active;
        // Generate plaintext key material using cryptographically secure random
        var plaintext: [32]u8 = undefined;
        std.crypto.random.bytes(&plaintext);
        // Wrap key using KMS client
        const kms = @import("external_kms_client.zig");
        var client = kms.Client.init(self.allocator.*, self.kms_seed.?);
        const env = try client.wrap(plaintext);
        const env_json = try kms.envelopeToJson(env, self.allocator.*);
        const key_ref: DataKeyRef = .{
            .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1,
            .created_unix_epoch = std.time.timestamp(),
            .material = plaintext,
            .envelope_json = env_json,
            .is_wrapped = true,
        };
        try self.history.append(key_ref);
        self.active = key_ref;
        return .{ .old_id = if (old) |o| o.id else 0, .new_id = key_ref.id, .ts = std.time.timestamp(), .method = .manual };
    }

    pub fn rotateWithRemoteKms(self: *KeyRegistry) !RotationEvent {
        if (self.remote_kms_host == null or self.remote_kms_port == null) return error.RemoteKmsNotConfigured;
        const host = self.remote_kms_host.?;
        const port = self.remote_kms_port.?;
        const kms_remote = @import("kms_remote.zig");
        var client = kms_remote.RemoteKmsClient.init(self.allocator.*);
        // Best-effort connect; propagate error if fails
        try client.connect(host, port);
        // Request generate envelope
        const env = try client.generate();
        // We cannot unwrap remotely without plaintext; for now treat ct as opaque and store envelope only.
        // Mark is_wrapped=true and leave material zeroed (future: request plaintext via privileged unwrap).
        const zero: [32]u8 = [_]u8{0} ** 32;
        var env_json_buf = std.ArrayList(u8).init(self.allocator.*);
        defer env_json_buf.deinit();
        try env_json_buf.writer().print("{", .{}); // minimal re-serialization using external client helpers would be better; reuse envelopeToJson path via external client module for consistency in future
        // For brevity, reuse kms_remote internal printer by reconstructing JSON (lossless enough for test)
        env_json_buf.clearRetainingCapacity();
        // Simpler: call external_kms_client.envelopeToJson since schema same
        const ekc = @import("external_kms_client.zig");
        const env_json = try ekc.envelopeToJson(.{ .nonce = env.nonce, .tag = env.tag, .ct = env.ct, .version = env.version, .alg = env.alg }, self.allocator.*);
        const key_ref: DataKeyRef = .{ .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1, .created_unix_epoch = std.time.timestamp(), .material = zero, .envelope_json = env_json, .is_wrapped = true };
        try self.history.append(key_ref);
        self.active = key_ref;
        return .{ .old_id = 0, .new_id = key_ref.id, .ts = std.time.timestamp(), .method = .manual };
    }

    pub fn saveState(self: *KeyRegistry, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var w = file.writer();
        // Compute checksum over stored representation (envelope JSON if wrapped else plaintext material)
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.history.items) |entry| {
            if (entry.is_wrapped and entry.envelope_json) |ej| {
                h.update(ej);
            } else {
                h.update(&entry.material);
            }
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);
        var checksum_buf: [16]u8 = undefined;
        std.mem.copy(u8, checksum_buf[0..16], digest[0..16]);
        try w.print("{{\n", .{});
        try w.print("  \"version\": 1,\n", .{});
        if (self.active) |a| {
            try w.print("  \"active_id\": {},\n", .{a.id});
        } else {
            try w.print("  \"active_id\": null,\n", .{});
        }
        try w.print("  \"checksum\": \"", .{});
        var i_cs: usize = 0;
        while (i_cs < 16) : (i_cs += 1) try w.print("{x:0>2}", .{checksum_buf[i_cs]});
        try w.print("\",\n", .{});
        try w.print("  \"history\": [\n", .{});
        var i: usize = 0;
        while (i < self.history.items.len) : (i += 1) {
            const hist_entry = self.history.items[i];
            if (hist_entry.is_wrapped and hist_entry.envelope_json) |ej| {
                try w.print("    {\"id\":{},\"created\":{},\"envelope\":", .{ hist_entry.id, hist_entry.created_unix_epoch });
                // envelope JSON already object; write raw
                try w.print("{s}}}{s}\n", .{ ej, if (i + 1 == self.history.items.len) "" else "," });
            } else {
                try w.print("    {\"id\":{},\"created\":{},\"material_hex\":\"", .{ hist_entry.id, hist_entry.created_unix_epoch });
                for (hist_entry.material) |b| try w.print("{x:0>2}", .{b});
                try w.print("\"}}{s}\n", .{if (i + 1 == self.history.items.len) "" else ","});
            }
        }
        try w.print("  ]\n}}\n", .{});
    }

    pub fn loadState(self: *KeyRegistry, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return, // nothing to load
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(*self.allocator, 1 << 16);
        defer self.allocator.free(data);
        // Minimal JSON scan (avoid full parser): find history and active_id tokens
        // NOT robust JSON; acceptable for internal persistence (documented)
        var it = std.mem.tokenizeAny(u8, data, "\n\r");
        var parsed_checksum: [16]u8 = [_]u8{0} ** 16;
        var have_checksum = false;
        self.history.clearRetainingCapacity();
        self.active = null;
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"active_id\"")) |idx| {
                const colon = std.mem.indexOfScalarPos(u8, line, idx, ':') orelse continue;
                const tail = std.mem.trim(u8, line[colon + 1 ..], " \t,");
                if (!std.mem.startsWith(u8, tail, "null")) {
                    const id_val = std.fmt.parseInt(u64, tail, 10) catch continue;
                    // active will be resolved after reading history
                    self.active = .{ .id = id_val, .created_unix_epoch = 0, .material = [_]u8{0} ** 32, .envelope_json = null, .is_wrapped = false };
                }
            } else if (std.mem.indexOf(u8, line, "\"checksum\"")) |_| {
                // extract checksum hex (first 32 hex chars representing 16 bytes)
                const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse continue;
                const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse continue;
                const third_quote = std.mem.indexOfScalarPos(u8, line, second_quote + 1, '"') orelse continue;
                // GAP-0141: Safe hex parsing with proper error handling
                // CANARY: REQ=REQ-HEX-PARSE-KEYROT-001; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2026-01-15
                const fourth_quote = std.mem.indexOfScalarPos(u8, line, third_quote + 1, '"') orelse continue;
                const hex_slice = line[third_quote + 1 .. fourth_quote];
                if (hex_slice.len == 32) {
                    var j: usize = 0;
                    var checksum_valid = true;
                    while (j < 16) : (j += 1) {
                        parsed_checksum[j] = std.fmt.parseInt(u8, hex_slice[j * 2 .. j * 2 + 2], 16) catch {
                            std.log.warn("Invalid hex in checksum at position {d}", .{j * 2});
                            checksum_valid = false;
                            break;
                        };
                    }
                    have_checksum = checksum_valid;
                }
            } else if (std.mem.indexOf(u8, line, "\"id\"")) |idx2| {
                // parse history entry line simplistic
                if (std.mem.indexOf(u8, line, "material_hex")) |_| {
                    // Extract id
                    const id_colon = std.mem.indexOfScalarPos(u8, line, idx2, ':') orelse continue;
                    var after = std.mem.trim(u8, line[id_colon + 1 ..], " \t,");
                    const id_end = std.mem.indexOfScalar(u8, after, ',') orelse continue;
                    const id_slice = after[0..id_end];
                    const id_parsed = std.fmt.parseInt(u64, id_slice, 10) catch continue;
                    // created
                    const created_pos = std.mem.indexOf(u8, line, "\"created\"") orelse continue;
                    const created_colon = std.mem.indexOfScalarPos(u8, line, created_pos, ':') orelse continue;
                    var created_after = std.mem.trim(u8, line[created_colon + 1 ..], " \t,");
                    const created_end = std.mem.indexOfScalar(u8, created_after, ',') orelse continue;
                    const created_slice = created_after[0..created_end];
                    const created_parsed = std.fmt.parseInt(i64, created_slice, 10) catch continue;
                    // hex material
                    const hex_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
                    const second_last_quote = blk: {
                        var j: usize = hex_quote - 1;
                        while (true) : (j -= 1) {
                            if (line[j] == '"') break :blk j;
                            if (j == 0) break :blk 0;
                        }
                    };
                    // GAP-0141: Safe hex parsing with proper error handling
                    // CANARY: REQ=REQ-HEX-PARSE-KEYROT-002; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2026-01-15
                    const hex_slice = line[second_last_quote + 1 .. hex_quote];
                    if (hex_slice.len == 64) {
                        var material: [32]u8 = undefined;
                        var k: usize = 0;
                        var material_valid = true;
                        while (k < 32) : (k += 1) {
                            material[k] = std.fmt.parseInt(u8, hex_slice[k * 2 .. k * 2 + 2], 16) catch {
                                std.log.warn("Invalid hex in key material at position {d}", .{k * 2});
                                material_valid = false;
                                break;
                            };
                        }
                        if (material_valid) {
                            const entry = DataKeyRef{ .id = id_parsed, .created_unix_epoch = created_parsed, .material = material, .envelope_json = null, .is_wrapped = false };
                            try self.history.append(entry);
                        }
                    }
                } else if (std.mem.indexOf(u8, line, "\"envelope\"")) |_| {
                    // expect envelope JSON starts after : and may span single line
                    const id_colon = std.mem.indexOfScalarPos(u8, line, idx2, ':') orelse continue;
                    var after = std.mem.trim(u8, line[id_colon + 1 ..], " \t,");
                    const id_end = std.mem.indexOfScalar(u8, after, ',') orelse continue;
                    const id_slice = after[0..id_end];
                    const id_parsed = std.fmt.parseInt(u64, id_slice, 10) catch continue;
                    const created_pos = std.mem.indexOf(u8, line, "\"created\"") orelse continue;
                    const created_colon = std.mem.indexOfScalarPos(u8, line, created_pos, ':') orelse continue;
                    var created_after = std.mem.trim(u8, line[created_colon + 1 ..], " \t,");
                    const created_end = std.mem.indexOfScalar(u8, created_after, ',') orelse continue;
                    const created_slice = created_after[0..created_end];
                    const created_parsed = std.fmt.parseInt(i64, created_slice, 10) catch continue;
                    // envelope raw JSON object assumed to follow "envelope":{ ... }}
                    const env_start = std.mem.indexOf(u8, line, "{\"version\"") orelse continue;
                    const env_end = std.mem.lastIndexOfScalar(u8, line, '}') orelse continue;
                    const env_slice = line[env_start .. env_end + 1];
                    const env_copy = try self.allocator.alloc(u8, env_slice.len);
                    std.mem.copy(u8, env_copy, env_slice);
                    // unwrap if kms_seed configured
                    var material: [32]u8 = [_]u8{0} ** 32;
                    var wrapped_flag = true;
                    if (self.kms_seed) |seed| {
                        const kms = @import("external_kms_client.zig");
                        var client = kms.Client.init(self.allocator.*, seed);
                        const parsed = kms.envelopeFromJson(env_slice) catch {
                            wrapped_flag = false; // mark invalid
                            continue;
                        };
                        const plain = client.unwrap(parsed) catch {
                            wrapped_flag = false;
                            continue;
                        };
                        material = plain;
                    } else {
                        // KMS not configured; leave material zero; caller must unwrap later
                        wrapped_flag = true;
                    }
                    const entry = DataKeyRef{ .id = id_parsed, .created_unix_epoch = created_parsed, .material = material, .envelope_json = env_copy, .is_wrapped = wrapped_flag };
                    try self.history.append(entry);
                }
            }
        }
        if (self.active) |act| {
            // match active id to history entry
            var found: ?DataKeyRef = null;
            for (self.history.items) |h| if (h.id == act.id) {
                found = h;
                break;
            };
            if (found) |f| self.active = f else self.active = null;
        }
        if (have_checksum) {
            // verify checksum matches current history
            var h2 = std.crypto.hash.sha2.Sha256.init(.{});
            for (self.history.items) |entry| {
                if (entry.is_wrapped and entry.envelope_json) |ej| h2.update(ej) else h2.update(&entry.material);
            }
            var digest2: [32]u8 = undefined;
            h2.final(&digest2);
            var mismatch = false;
            var k: usize = 0;
            while (k < 16) : (k += 1) if (digest2[k] != parsed_checksum[k]) {
                mismatch = true;
                break;
            };
            if (mismatch) {
                // integrity failure: clear loaded state (treat as no-op load)
                self.history.clearRetainingCapacity();
                self.active = null;
            }
        }
    }

    pub fn scheduleRotation(self: *KeyRegistry, policy: RotationPolicy, now_epoch: i64) bool {
        if (self.active) |k| {
            const age: u64 = @intCast(now_epoch - k.created_unix_epoch);
            if (age >= policy.max_age_secs) return true; // hard age limit
            if (age >= policy.min_interval_secs) return true; // periodic rotation window
            return false;
        }
        return true; // no key yet
    }

    // CANARY: REQ=REQ-STREAMING-KEYROT-REENCRYPT-001; FEATURE="Page Re-encryption"; ASPECT=ReEncryption; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2026-01-15
    /// Re-encrypt a page with the current active key
    /// This supports online rotation without downtime by re-encrypting pages lazily
    pub fn reencryptPage(self: *KeyRegistry, page_id: u64, ciphertext: []u8) !void {
        const start_time = std.time.milliTimestamp();

        // Need at least two keys in history for re-encryption (old and new)
        if (self.history.items.len < 2) {
            return; // Nothing to re-encrypt if only one key exists
        }

        const active_key = self.active orelse return error.NoActiveKey;
        const previous_key = self.history.items[self.history.items.len - 2];

        // Track page for potential rollback
        if (self.rollback_state.enabled) {
            try self.rollback_state.pages_to_restore.append(page_id);
        }

        // Re-encryption workflow:
        // 1. Decrypt with previous key using AES-256-GCM
        // 2. Re-encrypt with active key
        const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

        // Extract nonce (first 12 bytes) and tag (last 16 bytes) from ciphertext
        if (ciphertext.len < aes_gcm.nonce_length + aes_gcm.tag_length) {
            return error.InvalidCiphertext;
        }

        const nonce = ciphertext[0..aes_gcm.nonce_length].*;
        const encrypted_data = ciphertext[aes_gcm.nonce_length .. ciphertext.len - aes_gcm.tag_length];
        const tag = ciphertext[ciphertext.len - aes_gcm.tag_length ..][0..aes_gcm.tag_length].*;

        // Decrypt with previous key
        var plaintext = self.allocator.alloc(u8, encrypted_data.len) catch return error.OutOfMemory;
        defer self.allocator.free(plaintext);

        aes_gcm.decrypt(plaintext, encrypted_data, tag, "", nonce, previous_key.material) catch {
            try self.logAuditEvent(
                .reencryption_failed,
                previous_key.id,
                active_key.id,
                .failed,
                1,
                "Decryption failed with previous key",
                @intCast(std.time.milliTimestamp() - start_time),
            );
            return error.DecryptionFailed;
        };

        // Generate new nonce for re-encryption
        var new_nonce: [aes_gcm.nonce_length]u8 = undefined;
        std.crypto.random.bytes(&new_nonce);

        // Re-encrypt with active key
        var new_tag: [aes_gcm.tag_length]u8 = undefined;
        aes_gcm.encrypt(encrypted_data, &new_tag, plaintext, "", new_nonce, active_key.material);

        // Update ciphertext buffer with new nonce and tag
        @memcpy(ciphertext[0..aes_gcm.nonce_length], &new_nonce);
        @memcpy(ciphertext[ciphertext.len - aes_gcm.tag_length ..], &new_tag);

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        try self.logAuditEvent(
            .reencryption_completed,
            previous_key.id,
            active_key.id,
            .success,
            1,
            null,
            duration,
        );
    }

    /// Perform batch re-encryption of multiple pages (for eager rotation strategy)
    pub fn reencryptBatch(self: *KeyRegistry, page_ids: []const u64, ciphertexts: [][]u8) !u64 {
        const start_time = std.time.milliTimestamp();
        var success_count: u64 = 0;

        const active_key = self.active orelse return error.NoActiveKey;
        const previous_key_id = if (self.history.items.len >= 2)
            self.history.items[self.history.items.len - 2].id
        else
            0;

        try self.logAuditEvent(
            .reencryption_started,
            previous_key_id,
            active_key.id,
            .in_progress,
            page_ids.len,
            null,
            0,
        );

        for (page_ids, 0..) |page_id, i| {
            self.reencryptPage(page_id, ciphertexts[i]) catch |err| {
                std.debug.print("KEYROT: Failed to re-encrypt page {d}: {}\n", .{ page_id, err });
                continue;
            };
            success_count += 1;
        }

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const status: RotationAuditEntry.RotationStatus = if (success_count == page_ids.len) .success else .failed;

        try self.logAuditEvent(
            .reencryption_completed,
            previous_key_id,
            active_key.id,
            status,
            success_count,
            if (success_count < page_ids.len) "Some pages failed re-encryption" else null,
            duration,
        );

        return success_count;
    }

    /// Get key by version number
    pub fn getKeyByVersion(self: *KeyRegistry, version: u64) ?DataKeyRef {
        for (self.history.items) |key| {
            if (key.id == version) {
                return key;
            }
        }
        return null;
    }

    /// Get current key version
    pub fn getCurrentVersion(self: *KeyRegistry) u32 {
        return self.current_version;
    }

    /// Increment key version after rotation
    pub fn incrementVersion(self: *KeyRegistry) void {
        self.current_version += 1;
    }
};

// CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2026-01-15
// Simple unit test for scaffold ensuring rotate increases key id and history grows.
// CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2025-09-26
test "key rotation scaffold increments id" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var reg = KeyRegistry.init(alloc);
    defer reg.deinit();
    const k1 = try reg.loadActiveDataKey();
    const ev = try reg.rotateNow(.{});
    try std.testing.expect(ev.new_id == k1.id + 1);
    try std.testing.expect(reg.history.items.len == 2);
}
