const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
const tde = @import("tde_file_encryption");

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_argv = proc_init.args.vector;
    const args = try allocator.alloc([:0]u8, raw_argv.len);
    defer allocator.free(args);
    for (raw_argv, 0..) |arg, i| {
        args[i] = @constCast(std.mem.span(arg));
    }

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "generate")) {
        try generateKey(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "rotate")) {
        try rotateKeys(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "verify")) {
        try verifyEncryption(allocator, args[2..]);
    } else {
        // Legacy mode: accept hex key directly
        const key = args[1];
        if (key.len != 64) return error.InvalidKey;
        var i: usize = 0;
        while (i < 32) : (i += 1) _ = try std.fmt.parseInt(u8, key[i * 2 .. i * 2 + 2], 16);
        std.debug.print("export GEODE_TDE_KEY={s}\n", .{key});
    }
}

fn printUsage() !void {
    std.debug.print(
        \\Usage: key_rotate <command> [options]
        \\
        \\Commands:
        \\  generate        Generate a new TDE key
        \\  rotate          Rotate TDE keys for encrypted files
        \\  verify          Verify TDE encryption header
        \\
        \\Options:
        \\  --algorithm     Encryption algorithm (aes_256_gcm only)
        \\  --kms           KMS provider (aws_kms, azure_key_vault, hashicorp_vault)
        \\  --input         Input data file path
        \\  --output        Output data file path
        \\  --old-key       Path to old key file
        \\  --new-key       Path to new key file
        \\  --file          File path for verification
        \\  --key           Key path for verification
        \\
        \\Legacy mode: key_rotate <64-char-hex-key> (prints GEODE_TDE_KEY export)
        \\
    , .{});
}

fn generateKey(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    _ = allocator;

    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--algorithm")) {
            // File-level encryption currently supports AES-256-GCM only.
            i += 1;
        }
    }

    // Generate random key
    var key_data: [tde.KEY_BYTES]u8 = undefined;
    try cb.Csprng.bytes(&key_data);

    if (output_path) |path| {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(io);

        try file.writeStreamingAll(io, &key_data);
        std.debug.print("Key generated and saved to {s}\n", .{path});
    } else {
        // Print hex-encoded key
        std.debug.print("Generated key (hex): ", .{});
        for (key_data) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    }
}

fn rotateKeys(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var old_key_path: ?[]const u8 = null;
    var new_key_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            if (i < args.len) {
                input_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--old-key")) {
            i += 1;
            if (i < args.len) {
                old_key_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--new-key")) {
            i += 1;
            if (i < args.len) {
                new_key_path = args[i];
            }
        }
    }

    if (input_path == null or output_path == null or old_key_path == null or new_key_path == null) {
        std.debug.print("Error: Missing required arguments\n", .{});
        try printUsage();
        return;
    }

    // Read old key
    const io_kr = std.Io.Threaded.global_single_threaded.io();
    const old_key_file = try std.Io.Dir.cwd().openFile(io_kr, old_key_path.?, .{});
    defer old_key_file.close(io_kr);
    var old_key_data: [tde.KEY_BYTES]u8 = undefined;
    _ = try old_key_file.readPositionalAll(io_kr, &old_key_data, 0);

    // Read new key
    const new_key_file = try std.Io.Dir.cwd().openFile(io_kr, new_key_path.?, .{});
    defer new_key_file.close(io_kr);
    var new_key_data: [tde.KEY_BYTES]u8 = undefined;
    _ = try new_key_file.readPositionalAll(io_kr, &new_key_data, 0);

    // Read input file
    const in_file = try std.Io.Dir.cwd().openFile(io_kr, input_path.?, .{});
    defer in_file.close(io_kr);
    const in_size = try in_file.length(io_kr);
    const raw = try allocator.alloc(u8, @intCast(in_size));
    defer allocator.free(raw);
    const read_bytes = try in_file.readPositionalAll(io_kr, raw, 0);

    // Decrypt with old key (passes through if not encrypted)
    const plaintext = try tde.decryptWithKey(allocator, raw[0..read_bytes], old_key_data);
    defer allocator.free(plaintext);

    // Encrypt with new key
    const encrypted = try tde.encryptWithKey(allocator, plaintext, new_key_data);
    defer allocator.free(encrypted);

    // Write output
    const out_file = try std.Io.Dir.cwd().createFile(io_kr, output_path.?, .{});
    defer out_file.close(io_kr);
    try out_file.writeStreamingAll(io_kr, encrypted);

    std.debug.print("\nKey rotation completed successfully\n", .{});
}

fn verifyEncryption(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    _ = allocator;

    var file_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file")) {
            i += 1;
            if (i < args.len) {
                file_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--key")) {
            i += 1;
            if (i < args.len) {
                key_path = args[i];
            }
        }
    }

    if (file_path == null or key_path == null) {
        std.debug.print("Error: Missing required arguments\n", .{});
        try printUsage();
        return;
    }

    const io_v = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io_v, file_path.?, .{});
    defer file.close(io_v);

    var header: [tde.MAGIC.len]u8 = undefined;
    const read_len = try file.readPositionalAll(io_v, &header, 0);
    const encrypted = read_len >= tde.MAGIC.len and tde.isEncrypted(header[0..tde.MAGIC.len]);

    if (encrypted) {
        std.debug.print("File appears to be TDE encrypted (AES-256-GCM)\n", .{});
    } else {
        std.debug.print("Warning: File does not appear to be TDE encrypted\n", .{});
    }
}
