const std = @import("std");
const pm_mod = @import("storage/page_manager.zig");

fn set_env() void {
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_ENCRYPTION", "on") catch {};
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_DISK_KEY_HEX", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") catch {};
}

test "page_manager encryption: write/read persists encrypted and decrypts on load" {
    set_env();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const base = try tmp.dir.realpathAlloc(ally, ".");
    defer ally.free(base);

    var pm = pm_mod.PageManager.initPersistent(ally, 512, base);
    defer pm.deinit();
    const r = try pm.insert("secret");
    try pm.flushPage(r.page);

    // Raw on disk should not equal plaintext "secret" sequence
    const dir = std.fs.cwd();
    const path = try std.fmt.allocPrint(ally, "{s}/page_{d}.bin", .{ base, r.page });
    defer ally.free(path);
    var f = try dir.openFile(path, .{ .mode = .read_only });
    defer f.close();
    var buf: [512]u8 = undefined;
    _ = try f.readAll(&buf);
    try std.testing.expect(!std.mem.indexOf(u8, &buf, "secret").?);

    // Load via API (which decrypts) and verify content
    var pm2 = pm_mod.PageManager.initPersistent(ally, 512, base);
    defer pm2.deinit();
    try pm2.loadPage(base, 0);
    try std.testing.expectEqualStrings("secret", try pm2.read(r));
}
