const std = @import("std");
const pm_mod = @import("storage_page_manager");
const tde = @import("tde");

// Basic integration tests for AES-GCM page encryption using the page_encryption strategy layer.
// Scenarios:
// 1) TDE disabled: file length == page_size, plaintext present.
// 2) TDE enabled (flag + key): file length == page_size + overhead (nonce+tag), plaintext absent.
// Deterministic nonce derivation in tde.zig ensures reproducibility.
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE baseline"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_tde_integration.zig:1; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {}

test "tde: persistent page plaintext when disabled" {
    // Ensure feature disabled
    std.os.setenv("GEODE_ENABLE_TDE", "off") catch {};
    std.os.unsetenv("GEODE_TDE_KEY") catch {};
    tde.disableForTests();

    var tmp_dir = std.testing.tmpDir(.{}); // auto cleanup
    defer tmp_dir.cleanup();

    var gpa = std.testing.allocator;
    var pm = pm_mod.PageManager.initPersistent(gpa, 512, tmp_dir.path);
    defer pm.deinit();

    const payload = "HelloEncryptedWorld";
    const rid = try pm.insert(payload);
    try std.testing.expectEqualStrings(payload, try pm.read(rid));
    try pm.flushPage(rid.page);

    const filename = try std.fmt.allocPrint(gpa, "{s}/page_{d}.bin", .{ tmp_dir.path, rid.page });
    defer gpa.free(filename);
    var raw_file = try std.fs.cwd().openFile(filename, .{});
    defer raw_file.close();
    const raw = try raw_file.readToEndAlloc(gpa, 10_000);
    defer gpa.free(raw);
    try std.testing.expect(raw.len == pm.page_size); // no overhead
    try std.testing.expect(std.mem.indexOf(u8, raw, payload) != null);
}

test "tde: persistent page encrypt/decrypt round trip" {
    // Set env vars for test (GEODE_TDE_KEY 32 bytes hex) - using fixed pattern
    const key_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; // 64 hex chars
    std.os.setenv("GEODE_ENABLE_TDE", "on") catch {};
    std.os.setenv("GEODE_TDE_KEY", key_hex) catch {};
    tde.enableForTests();

    var tmp_dir = std.testing.tmpDir(.{}); // auto cleanup
    defer tmp_dir.cleanup();

    var gpa = std.testing.allocator;
    var pm = pm_mod.PageManager.initPersistent(gpa, 512, tmp_dir.path);
    defer pm.deinit();

    const payload = "HelloEncryptedWorld";
    const rid = try pm.insert(payload);
    try std.testing.expectEqualStrings(payload, try pm.read(rid));

    // Flush page to ensure encryption executed
    try pm.flushPage(rid.page);

    // Read raw file and ensure plaintext does not appear (very naive check)
    const filename = try std.fmt.allocPrint(gpa, "{s}/page_{d}.bin", .{ tmp_dir.path, rid.page });
    defer gpa.free(filename);
    var raw_file = try std.fs.cwd().openFile(filename, .{});
    defer raw_file.close();
    const raw = try raw_file.readToEndAlloc(gpa, 10_000);
    defer gpa.free(raw);

    // If AES-GCM path used, ciphertext file length == page_size + overhead (nonce+tag)
    try std.testing.expect(raw.len == (tde.NonceBytes + tde.TagBytes + pm.page_size));
    try std.testing.expect(std.mem.indexOf(u8, raw, payload) == null);
}
