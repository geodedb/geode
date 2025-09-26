const std = @import("std");

// key_rotation.zig
// Skeleton for encryption key rotation subsystem.
// CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=SECURITY; STATUS=STUB; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2025-09-26
// Provides interfaces only; actual integration with page/WAL encryption will follow.

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
    material: [32]u8, // 256-bit AES key material
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
    // persisted state path (optional)
    state_path: ?[]const u8 = null,

    pub fn init(allocator: *std.mem.Allocator) KeyRegistry {
        return .{ .allocator = allocator, .history = std.ArrayList(DataKeyRef).init(allocator), .state_path = null };
    }

    pub fn deinit(self: *KeyRegistry) void {
        self.history.deinit();
    }

    pub fn loadActiveDataKey(self: *KeyRegistry) !DataKeyRef {
        if (self.active) |k| return k;
        // For now generate a random key; future: load from KMS / persisted keystore
        // Deterministic seed placeholder; future: secure random source / KMS
        var prng = std.rand.DefaultPrng.init(0x4B45594B455931); // 'KEYKEY1'
        const r = prng.random();
        var key: DataKeyRef = .{
            .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1,
            .created_unix_epoch = std.time.timestamp(),
            .material = undefined,
        };
        r.bytes(&key.material);
        try self.history.append(key);
        self.active = key;
        return key;
    }

    pub fn rotateNow(self: *KeyRegistry, policy: RotationPolicy) !RotationEvent {
        _ = policy; // placeholder until policy used
        const old = self.active;
        var prng = std.rand.DefaultPrng.init(0x4B45594B455932); // 'KEYKEY2'
        const r = prng.random();
        var key: DataKeyRef = .{
            .id = if (self.history.items.len == 0) 1 else self.history.items[self.history.items.len - 1].id + 1,
            .created_unix_epoch = std.time.timestamp(),
            .material = undefined,
        };
        r.bytes(&key.material);
        try self.history.append(key);
        self.active = key;
        return .{ .old_id = if (old) |o| o.id else 0, .new_id = key.id, .ts = std.time.timestamp(), .method = .manual };
    }

    pub fn saveState(self: *KeyRegistry, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var w = file.writer();
        // Compute checksum over concatenated materials (simple SHA-256 then first 16 hex chars)
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.history.items) |entry| h.update(&entry.material);
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
            try w.print("    {\"id\":{},\"created\":{},\"material_hex\":\"", .{ hist_entry.id, hist_entry.created_unix_epoch });
            for (hist_entry.material) |b| try w.print("{x:0>2}", .{b});
            try w.print("\"}}{s}\n", .{if (i + 1 == self.history.items.len) "" else ","});
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
                    self.active = .{ .id = id_val, .created_unix_epoch = 0, .material = [_]u8{0} ** 32 };
                }
            } else if (std.mem.indexOf(u8, line, "\"checksum\"")) |_| {
                // extract checksum hex (first 32 hex chars representing 16 bytes)
                const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse continue;
                const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse continue;
                const third_quote = std.mem.indexOfScalarPos(u8, line, second_quote + 1, '"') orelse continue;
                const fourth_quote = std.mem.indexOfScalarPos(u8, line, third_quote + 1, '"') orelse continue;
                const hex_slice = line[third_quote + 1 .. fourth_quote];
                if (hex_slice.len == 32) {
                    var j: usize = 0;
                    while (j < 16) : (j += 1) {
                        parsed_checksum[j] = std.fmt.parseInt(u8, hex_slice[j * 2 .. j * 2 + 2], 16) catch 0;
                    }
                    have_checksum = true;
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
                    const hex_slice = line[second_last_quote + 1 .. hex_quote];
                    if (hex_slice.len == 64) {
                        var material: [32]u8 = undefined;
                        var k: usize = 0;
                        while (k < 32) : (k += 1) {
                            material[k] = std.fmt.parseInt(u8, hex_slice[k * 2 .. k * 2 + 2], 16) catch 0;
                        }
                        const entry = DataKeyRef{ .id = id_parsed, .created_unix_epoch = created_parsed, .material = material };
                        try self.history.append(entry);
                    }
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
            for (self.history.items) |entry| h2.update(&entry.material);
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

    pub fn reencryptPage(self: *KeyRegistry, page_id: u64, ciphertext: []u8) !void {
        _ = self;
        _ = page_id;
        _ = ciphertext;
        // Intentionally no-op for scaffold
    }
};

// CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2025-09-26
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
