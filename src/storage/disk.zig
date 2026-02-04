// CANARY: REQ=REQ-GQL-025; FEATURE="Disk Storage"; ASPECT=Storage; STATUS=TESTED; TEST=tests/e2e_catalog_persistence_disk.zig; OWNER=storage; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-026; FEATURE="Page Management"; ASPECT=Storage; STATUS=TESTED; TEST=tests/unit_page_manager.zig; OWNER=storage; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-027; FEATURE="WAL/ARIES"; ASPECT=Storage; STATUS=TESTED; TEST=tests/e2e_wal_recovery.zig; OWNER=storage; UPDATED=2025-09-20

const std = @import("std");
const types = @import("types");

// CANARY: REQ=REQ-DISK-AES-001; FEATURE="AES-256 Disk Encryption"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=storage; UPDATED=2026-01-10
const aes = struct {
    /// AES-256 ECB encryption using Zig's standard crypto library
    /// Uses std.crypto.core.aes.Aes256 for real cryptographic security
    fn ecb_encrypt(key: [32]u8, block: *[16]u8) void {
        const cipher = std.crypto.core.aes.Aes256.initEnc(key);
        const result = cipher.encrypt(block.*);
        block.* = result;
    }

    /// AES-256 ECB decryption using Zig's standard crypto library
    fn ecb_decrypt(key: [32]u8, block: *[16]u8) void {
        const cipher = std.crypto.core.aes.Aes256.initDec(key);
        const result = cipher.decrypt(block.*);
        block.* = result;
    }

    /// GF(2^128) multiplication by alpha for XTS mode tweak update
    fn mul_alpha(t: *[16]u8) void {
        const carry: u8 = t.*[0] >> 7;
        var i: usize = 15;
        while (i > 0) : (i -= 1) t.*[i] = (t.*[i] << 1) | (t.*[i - 1] >> 7);
        t.*[0] <<= 1;
        if (carry != 0) t.*[15] ^= 0x87;
    }
};

pub const Disk = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    page_size: usize = 4096,
    enc_enabled: bool = false,
    key: [32]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Disk {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true, .mode = 0o600 });
        var d = Disk{ .allocator = allocator, .file = f };
        // encryption toggle
        if (std.process.getEnvVarOwned(allocator, "GEODE_DISK_ENCRYPTION")) |v| {
            defer allocator.free(v);
            if (std.mem.eql(u8, v, "on")) d.enc_enabled = true;
        } else |_| {}
        if (d.enc_enabled) {
            const hex = std.process.getEnvVarOwned(allocator, "GEODE_DISK_KEY_HEX") catch null;
            if (hex == null or hex.?.len != 64) return error.InvalidKey;
            defer allocator.free(hex.?);
            // parse hex into master key then derive data key
            var master: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const b = try std.fmt.parseInt(u8, hex.?[i * 2 .. i * 2 + 2], 16);
                master[i] = b;
            }
            const tde = @import("tde_hierarchy");
            const kh = tde.KeyHierarchy.init(master);
            d.key = kh.data_key; // store derived data key (master not retained beyond this scope)
        }
        return d;
    }

    pub fn deinit(self: *Disk) void {
        self.file.close();
    }

    fn tweakFor(page_id: types.PageId, sector: u64) u128 {
        return (@as(u128, page_id) << 64) | @as(u128, sector);
    }

    // CANARY: REQ=REQ-DISK-AES-001; FEATURE="AES-256 XTS Page Encryption"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=storage; UPDATED=2026-01-10
    fn encryptPage(self: *Disk, page_id: types.PageId, buf: []u8) void {
        if (!self.enc_enabled) return;
        const tweak_u128 = tweakFor(page_id, 0);
        var tweak: [16]u8 = undefined;
        // encode tweak_u128 little-endian
        var ti: usize = 0;
        while (ti < 16) : (ti += 1) tweak[ti] = @as(u8, @intCast((tweak_u128 >> @as(u7, @intCast(ti * 8))) & 0xFF));
        // T0 = AES-ECB(key, tweak) - encrypt tweak with real AES
        var T: [16]u8 = tweak;
        aes.ecb_encrypt(self.key, &T);
        var i: usize = 0;
        while (i < buf.len) : (i += 16) {
            var P: [16]u8 = .{0} ** 16;
            const n = if (i + 16 <= buf.len) 16 else buf.len - i;
            var k: usize = 0;
            // XOR with tweak, encrypt, XOR with tweak (XTS mode)
            while (k < n) : (k += 1) P[k] = buf[i + k] ^ T[k];
            aes.ecb_encrypt(self.key, &P);
            k = 0;
            while (k < n) : (k += 1) buf[i + k] = P[k] ^ T[k];
            aes.mul_alpha(&T);
        }
    }

    // CANARY: REQ=REQ-DISK-AES-001; FEATURE="AES-256 XTS Page Decryption"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=storage; UPDATED=2026-01-10
    fn decryptPage(self: *Disk, page_id: types.PageId, buf: []u8) void {
        if (!self.enc_enabled) return;
        const tweak_u128 = tweakFor(page_id, 0);
        var tweak: [16]u8 = undefined;
        var ti: usize = 0;
        while (ti < 16) : (ti += 1) tweak[ti] = @as(u8, @intCast((tweak_u128 >> @as(u7, @intCast(ti * 8))) & 0xFF));
        var T: [16]u8 = tweak;
        aes.ecb_encrypt(self.key, &T); // Note: tweak encryption uses encrypt, not decrypt
        var i: usize = 0;
        while (i < buf.len) : (i += 16) {
            var C: [16]u8 = .{0} ** 16;
            const n = if (i + 16 <= buf.len) 16 else buf.len - i;
            var k: usize = 0;
            // XOR with tweak, decrypt, XOR with tweak (XTS mode)
            while (k < n) : (k += 1) C[k] = buf[i + k] ^ T[k];
            aes.ecb_decrypt(self.key, &C); // Use actual AES decryption
            k = 0;
            while (k < n) : (k += 1) buf[i + k] = C[k] ^ T[k];
            aes.mul_alpha(&T);
        }
    }
};
