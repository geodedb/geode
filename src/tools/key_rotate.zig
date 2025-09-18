const std = @import("std");
const crypto = @import("crypto");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
        std.debug.print("export GEODE_DISK_KEY_HEX={s}\n", .{key});
    }
}

fn printUsage() !void {
    std.debug.print(
        \\Usage: key_rotate <command> [options]
        \\
        \\Commands:
        \\  generate        Generate a new encryption key
        \\  rotate          Rotate encryption keys for data files
        \\  verify          Verify encryption of data files
        \\
        \\Options:
        \\  --algorithm     Encryption algorithm (aes_256_gcm)
        \\  --kms           KMS provider (aws_kms, azure_key_vault, hashicorp_vault)
        \\  --input         Input data file path
        \\  --output        Output data file path
        \\  --old-key       Path to old key file
        \\  --new-key       Path to new key file
        \\
        \\Legacy mode: key_rotate <64-char-hex-key>
        \\
    , .{});
}

fn generateKey(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    _ = allocator;
    
    var output_path: ?[]const u8 = null;
    var algorithm: crypto.EncryptionAlgorithm = .aes_256_gcm;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--algorithm")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "aes_256_gcm")) {
                    algorithm = .aes_256_gcm;
                }
            }
        }
    }
    
    // Generate random key
    var key_data: [32]u8 = undefined;
    std.crypto.random.bytes(&key_data);
    
    const key = crypto.EncryptionKey{
        .data = key_data,
        .algorithm = algorithm,
        .provenance = .{
            .source = .local_file,
            .key_id = "generated-key",
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 1,
        },
    };
    
    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
        defer file.close();
        
        try file.writeAll(&key_data);
        std.debug.print("Key generated and saved to {s}\n", .{path});
    } else {
        // Print hex-encoded key
        std.debug.print("Generated key (hex): ", .{});
        for (key_data) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    }
    
    _ = key;
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
    const old_key_file = try std.fs.cwd().openFile(old_key_path.?, .{});
    defer old_key_file.close();
    var old_key_data: [32]u8 = undefined;
    _ = try old_key_file.read(&old_key_data);
    
    const old_key = crypto.EncryptionKey{
        .data = old_key_data,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .local_file,
            .key_id = "old-key",
            .created_at = 0,
            .rotated_at = null,
            .version = 1,
        },
    };
    
    // Read new key
    const new_key_file = try std.fs.cwd().openFile(new_key_path.?, .{});
    defer new_key_file.close();
    var new_key_data: [32]u8 = undefined;
    _ = try new_key_file.read(&new_key_data);
    
    const new_key = crypto.EncryptionKey{
        .data = new_key_data,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .local_file,
            .key_id = "new-key",
            .created_at = std.time.milliTimestamp(),
            .rotated_at = null,
            .version = 2,
        },
    };
    
    // Initialize crypto engines
    var old_crypto = try crypto.PageCrypto.init(allocator, old_key, null);
    defer old_crypto.deinit();
    
    var new_crypto = try crypto.PageCrypto.init(allocator, new_key, null);
    defer new_crypto.deinit();
    
    // Create rotation tool
    var rotation_tool = crypto.KeyRotationTool.init(allocator, &old_crypto, &new_crypto);
    rotation_tool.progress_callback = printProgress;
    
    // Perform rotation
    try rotation_tool.rotateDataFile(input_path.?, output_path.?);
    
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
    
    // Verify file is encrypted
    const file = try std.fs.cwd().openFile(file_path.?, .{});
    defer file.close();
    
    var header: [28]u8 = undefined;
    _ = try file.read(&header);
    
    // Check for encryption header (nonce + tag)
    const is_encrypted = header[0] != 0 or header[1] != 0;
    
    if (is_encrypted) {
        std.debug.print("File appears to be encrypted (AES-256-GCM)\n", .{});
    } else {
        std.debug.print("Warning: File does not appear to be encrypted\n", .{});
    }
}

fn printProgress(pages_processed: u64, total_pages: u64) void {
    const percent = (pages_processed * 100) / total_pages;
    std.debug.print("\rProgress: {d}/{d} pages ({d}%%)", .{ pages_processed, total_pages, percent });
}
