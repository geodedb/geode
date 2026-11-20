// SONNY-6430 (2): GEODE_MASTER_KEY was used as raw bytes and only the first
// 32 counted, so the common `openssl rand -hex 32` value (64 hex characters)
// gave a key of 32 hex characters (128 bits of entropy) and the rest was
// ignored without a word. There was no way to give a full 256-bit key from a
// hex or base64 secret.
//
// The contract (docs/FIELD_LEVEL_ENCRYPTION.md "Master key format"):
//   - GEODE_MASTER_KEY_FORMAT unset: the legacy reading, unchanged: at least
//     32 bytes, the first 32 used as raw bytes. A longer value still derives
//     exactly the key it always derived (existing encrypted fields stay
//     readable), and the server warns at startup that the rest is ignored.
//   - GEODE_MASTER_KEY_FORMAT=hex: exactly 64 hex characters, decoded.
//   - GEODE_MASTER_KEY_FORMAT=base64: standard base64 of exactly 32 bytes.
//   - GEODE_MASTER_KEY_FORMAT=raw: exactly 32 bytes, used as they are.
//   - anything else (an unknown format, a value that does not match its
//     format, a format without a key) is refused, naming the variables and
//     never printing the value.
// The format is a separate variable, not a prefix inside the value: every
// GEODE_MASTER_KEY value accepted before keeps the key it derived, because
// no previously accepted configuration set GEODE_MASTER_KEY_FORMAT.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;
const fle_key_manager = geode.fle_key_manager;
const fle = geode.fle_integration;
const fle_catalog = fle.catalog_mod;
const geode_binary = geode_test_bin.geode_exe;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn clearKeyEnv() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    _ = unsetenv("GEODE_MASTER_KEY");
    _ = unsetenv("GEODE_MASTER_KEY_FORMAT");
}

fn setEnv(name: [*:0]const u8, value: []const u8) !void {
    const z = try testing.allocator.dupeZ(u8, value);
    defer testing.allocator.free(z);
    _ = setenv(name, z, 1);
}

/// `openssl rand -hex 32` style value: 64 hex characters.
const hex64 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const hex64_bytes = blk: {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex64) catch unreachable;
    break :blk out;
};

test "SONNY-6430 (2) GEODE_MASTER_KEY_FORMAT=hex|base64|raw decode a full 32-byte key; the legacy reading of an unformatted value is unchanged" {
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;

    // Legacy: what the code always did (`@memcpy(&key, value[0..32])`).
    try setEnv("GEODE_MASTER_KEY", hex64);
    try testing.expectEqualSlices(u8, hex64[0..32], &(try fle_key_manager.loadMasterKeyFromEnv(allocator)));

    // hex: the 64 characters are the 32 key bytes.
    try setEnv("GEODE_MASTER_KEY_FORMAT", "hex");
    try testing.expectEqualSlices(u8, &hex64_bytes, &(try fle_key_manager.loadMasterKeyFromEnv(allocator)));
    // Upper case hex is the same key.
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, hex64);
    try setEnv("GEODE_MASTER_KEY", &upper);
    try testing.expectEqualSlices(u8, &hex64_bytes, &(try fle_key_manager.loadMasterKeyFromEnv(allocator)));

    // base64: standard alphabet, padded, of exactly 32 bytes.
    var b64: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &hex64_bytes);
    try setEnv("GEODE_MASTER_KEY_FORMAT", "base64");
    try setEnv("GEODE_MASTER_KEY", &b64);
    try testing.expectEqualSlices(u8, &hex64_bytes, &(try fle_key_manager.loadMasterKeyFromEnv(allocator)));

    // raw: exactly 32 bytes.
    try setEnv("GEODE_MASTER_KEY_FORMAT", "raw");
    try setEnv("GEODE_MASTER_KEY", hex64[0..32]);
    try testing.expectEqualSlices(u8, hex64[0..32], &(try fle_key_manager.loadMasterKeyFromEnv(allocator)));
}

test "SONNY-6430 (2) a value that does not match GEODE_MASTER_KEY_FORMAT, an unknown format and a format without a key are refused" {
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    const Case = struct { format: []const u8, value: ?[]const u8 };
    const cases = [_]Case{
        .{ .format = "hex", .value = hex64[0..63] }, // one short
        .{ .format = "hex", .value = hex64 ++ "00" }, // longer: never truncated
        .{ .format = "hex", .value = "zz" ++ hex64[2..] }, // not hex
        .{ .format = "base64", .value = "c2hvcnQ=" }, // 5 bytes
        .{ .format = "base64", .value = "not base64 at all, but long enough to pass a length check" },
        .{ .format = "raw", .value = hex64 }, // 64 bytes, raw is exactly 32
        .{ .format = "raw", .value = hex64[0..31] },
        .{ .format = "HEX64", .value = hex64 }, // unknown format
        .{ .format = "hex", .value = "" }, // a format but no key (empty is unset)
    };
    for (cases) |c| {
        clearKeyEnv();
        try setEnv("GEODE_MASTER_KEY_FORMAT", c.format);
        if (c.value) |v| try setEnv("GEODE_MASTER_KEY", v);
        if (fle_key_manager.loadMasterKeyFromEnv(allocator)) |_| {
            std.debug.print("SONNY-6430 (2): format '{s}' accepted a {?d}-byte value\n", .{ c.format, if (c.value) |v| v.len else null });
            return error.TestExpectedError;
        } else |err| {
            const want: anyerror = if (c.value.?.len == 0) error.MasterKeyRequired else if (std.mem.eql(u8, c.format, "HEX64")) error.MasterKeyFormatUnknown else error.MasterKeyInvalid;
            try testing.expectEqual(want, @as(anyerror, err));
        }
    }
}

/// Encrypts `plaintext` through the real FLE write path with the key the
/// current environment yields, in an isolated catalog under `data_dir`.
fn fleEncrypt(allocator: std.mem.Allocator, plaintext: []const u8) ![]const u8 {
    fle.resetGlobalKeyStateForTesting();
    const ctx = fle.EncryptionContext{ .tenant_id = "t6430", .schema_name = "Sonny6430", .allocator = allocator };
    return fle.encryptFieldIfNeeded(ctx, "Sonny6430", "secret", plaintext, "rec-1");
}

/// Decrypts `ciphertext` through the real FLE read path with the key the
/// current environment yields.
fn fleDecrypt(allocator: std.mem.Allocator, ciphertext: []const u8) ![]const u8 {
    fle.resetGlobalKeyStateForTesting();
    const ctx = fle.EncryptionContext{ .tenant_id = "t6430", .schema_name = "Sonny6430", .allocator = allocator };
    return fle.decryptFieldIfNeeded(ctx, "Sonny6430", "secret", ciphertext, "rec-1", false);
}

test "SONNY-6430 (2) a field encrypted under a legacy 64-hex GEODE_MASTER_KEY stays readable, and the hex reading is a different key that is never applied silently" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    clearKeyEnv();
    defer clearKeyEnv();
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-fle");
    defer root.remove();
    const saved = fle_catalog.saveDataDirOverride();
    defer saved.restore();
    fle_catalog.setDataDirOverride(root.path());
    fle_catalog.resetGlobalCatalog(allocator);
    fle.setHasEncryptedFields(false);
    defer {
        fle_catalog.resetGlobalCatalog(allocator);
        fle.setHasEncryptedFields(false);
        fle.resetGlobalKeyStateForTesting();
    }
    const catalog = try fle_catalog.globalCatalog(allocator);
    try catalog.configureField("Sonny6430", .{ .field_name = "secret", .encryption = .{ .enabled = true, .algorithm = .aes256_gcm } });
    fle.setHasEncryptedFields(true);

    const plaintext = "sonny6430 field encrypted before the format change";

    // Written with the deployment's legacy 64-hex value (no format set):
    // the key the old code derived, its first 32 bytes.
    try setEnv("GEODE_MASTER_KEY", hex64);
    const ciphertext = try fleEncrypt(allocator, plaintext);
    defer allocator.free(ciphertext);
    try testing.expect(!std.mem.eql(u8, ciphertext, plaintext));

    // Same environment after the change: readable.
    {
        const got = try fleDecrypt(allocator, ciphertext);
        defer if (got.ptr != ciphertext.ptr) allocator.free(got);
        try testing.expectEqualStrings(plaintext, got);
    }
    // The documented explicit equivalent of the legacy key (raw, its first
    // 32 bytes) reads it too: an operator can silence the warning without
    // re-encrypting anything.
    {
        try setEnv("GEODE_MASTER_KEY_FORMAT", "raw");
        try setEnv("GEODE_MASTER_KEY", hex64[0..32]);
        const got = try fleDecrypt(allocator, ciphertext);
        defer if (got.ptr != ciphertext.ptr) allocator.free(got);
        try testing.expectEqualStrings(plaintext, got);
    }
    // The full-entropy hex reading of the same characters is another key:
    // it cannot decrypt the old field. That is why it is opt-in
    // (GEODE_MASTER_KEY_FORMAT=hex) and never applied to an existing value.
    {
        try setEnv("GEODE_MASTER_KEY_FORMAT", "hex");
        try setEnv("GEODE_MASTER_KEY", hex64);
        if (fleDecrypt(allocator, ciphertext)) |got| {
            defer if (got.ptr != ciphertext.ptr) allocator.free(got);
            try testing.expect(!std.mem.eql(u8, got, plaintext));
        } else |_| {}
    }
    // SONNY-6442: in this directory, whose fields use the legacy key, the
    // in-process key manager refuses the hex key (the recorded master key
    // check value does not match) instead of writing a field under it.
    try testing.expectError(error.MasterKeyMismatch, fleEncrypt(allocator, plaintext));
    // And in a directory of its own a field written under the hex key
    // round-trips under it.
    {
        const fresh = try std.fmt.allocPrint(allocator, "{s}/hex-only", .{root.path()});
        defer allocator.free(fresh);
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), fresh);
        fle_catalog.setDataDirOverride(fresh);
        const c2 = try fleEncrypt(allocator, plaintext);
        defer allocator.free(c2);
        const got = try fleDecrypt(allocator, c2);
        defer if (got.ptr != c2.ptr) allocator.free(got);
        try testing.expectEqualStrings(plaintext, got);
    }
}

const Env = struct { name: []const u8, value: []const u8 };

const Run = struct {
    code: ?u8,
    started: bool,
    text: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.text);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

const ready_marker = "QUIC transport listening";

/// Runs `geode serve` with `extra` in its environment; a server that gets
/// ready (or is still running at the deadline) is stopped and reported as
/// `started`.
fn runServe(cwd: []const u8, data_dir: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6430-Admin-pw1");
    try env.put("GEODE_LSP_PORT", "0");
    for (extra) |e| try env.put(e.name, e.value);
    var port_buf: [32]u8 = undefined;
    const addr = try std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{try test_ports.freeUdpPort()});
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/serve-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
    const child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        const so_far = std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) catch null;
        const ready = if (so_far) |t| std.mem.indexOf(u8, t, ready_marker) != null else false;
        if (so_far) |t| testing.allocator.free(t);
        if (ready or waited_ms >= 60_000) {
            posix.kill(pid, .TERM) catch {};
            var grace: u32 = 0;
            while (grace < 15_000) : (grace += 100) {
                if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) break;
                sleepMs(100);
            } else {
                posix.kill(pid, .KILL) catch {};
                _ = linux.waitpid(pid, &status, 0);
            }
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .started = !exited, .text = text };
}

test "SONNY-6430 (2) geode serve refuses a GEODE_MASTER_KEY that does not match GEODE_MASTER_KEY_FORMAT, and warns that a longer unformatted key uses only its first 32 bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-serve");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);

    // Refused before the data directory exists, value never printed.
    const bad = hex64[0..40];
    for ([_][]const Env{
        &.{ .{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hex" }, .{ .name = "GEODE_MASTER_KEY", .value = bad } },
        &.{ .{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hexadecimal" }, .{ .name = "GEODE_MASTER_KEY", .value = hex64 } },
        &.{.{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hex" }},
    }, 0..) |env, i| {
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/refused{d}", .{ root.path(), i });
        defer allocator.free(data_dir);
        const r = try runServe(cwd, data_dir, env);
        defer r.deinit();
        const ok = !r.started and r.code != null and r.code.? != 0 and r.output("refusing to start") and
            r.output("GEODE_MASTER_KEY_FORMAT") and !r.output(bad) and !r.output(hex64) and !pathExists(data_dir);
        if (!ok) std.debug.print("SONNY-6430 (2) case {d}: exit={?d} started={}\n{s}\n", .{ i, r.code, r.started, r.text });
        try testing.expect(ok);
    }

    // The legacy 64-hex value still starts (same key as before) and is told
    // that only its first 32 bytes are the key; the hex form starts quietly.
    {
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/legacy", .{root.path()});
        defer allocator.free(data_dir);
        const r = try runServe(cwd, data_dir, &.{.{ .name = "GEODE_MASTER_KEY", .value = hex64 }});
        defer r.deinit();
        const ok = r.started and r.output("GEODE_MASTER_KEY is 64 bytes") and r.output("first 32") and
            r.output("GEODE_MASTER_KEY_FORMAT") and !r.output(hex64);
        if (!ok) std.debug.print("SONNY-6430 (2) legacy: started={}\n{s}\n", .{ r.started, r.text });
        try testing.expect(ok);
    }
    {
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/hex", .{root.path()});
        defer allocator.free(data_dir);
        const r = try runServe(cwd, data_dir, &.{ .{ .name = "GEODE_MASTER_KEY_FORMAT", .value = "hex" }, .{ .name = "GEODE_MASTER_KEY", .value = hex64 } });
        defer r.deinit();
        const ok = r.started and !r.output("first 32") and !r.output(hex64);
        if (!ok) std.debug.print("SONNY-6430 (2) hex: started={}\n{s}\n", .{ r.started, r.text });
        try testing.expect(ok);
    }
}
