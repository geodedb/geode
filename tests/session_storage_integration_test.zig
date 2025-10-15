// Integration tests for session storage system
// Tests the full auth login/logout/query workflow

const std = @import("std");
const testing = std.testing;

test "auth login with --save-session creates credentials file" {
    const allocator = testing.allocator;

    // Backup existing credentials
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.integration_backup", .{creds_path});
    defer allocator.free(backup_path);

    std.fs.copyFileAbsolute(creds_path, backup_path, .{}) catch {};
    defer {
        std.fs.copyFileAbsolute(backup_path, creds_path, .{}) catch {};
        std.fs.deleteFileAbsolute(backup_path) catch {};
    }

    // Run auth login with --save-session
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "login",
            "-U",
            "integration_test_user",
            "-P",
            "integration_test_pass",
            "--save-session",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed
    try testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Credentials file should exist
    const file = try std.fs.openFileAbsolute(creds_path, .{});
    defer file.close();

    // Verify it contains expected fields
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "token") != null);
    try testing.expect(std.mem.indexOf(u8, content, "integration_test_user") != null);
    try testing.expect(std.mem.indexOf(u8, content, "system_fingerprint") != null);

    // Cleanup
    try std.fs.deleteFileAbsolute(creds_path);
}

test "auth logout clears credentials file" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.integration_backup2", .{creds_path});
    defer allocator.free(backup_path);

    std.fs.copyFileAbsolute(creds_path, backup_path, .{}) catch {};
    defer {
        std.fs.copyFileAbsolute(backup_path, creds_path, .{}) catch {};
        std.fs.deleteFileAbsolute(backup_path) catch {};
    }

    // First login
    var result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "login",
            "-U",
            "logout_test_user",
            "-P",
            "logout_test_pass",
            "--save-session",
        },
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Verify file exists
    _ = try std.fs.openFileAbsolute(creds_path, .{});

    // Now logout
    result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "logout",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);

    // File should be gone
    const file_result = std.fs.openFileAbsolute(creds_path, .{});
    try testing.expectError(error.FileNotFound, file_result);
}

test "query command auto-loads saved session" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.integration_backup3", .{creds_path});
    defer allocator.free(backup_path);

    std.fs.copyFileAbsolute(creds_path, backup_path, .{}) catch {};
    defer {
        std.fs.copyFileAbsolute(backup_path, creds_path, .{}) catch {};
        std.fs.deleteFileAbsolute(backup_path) catch {};
    }

    // Login with save-session
    var result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "login",
            "-U",
            "query_test_user",
            "-P",
            "query_test_pass",
            "--save-session",
        },
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Run query without explicit credentials (should auto-load)
    result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "query",
            "--no-quic",
            "RETURN 1 AS auto_session_test",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "auto_session_test") != null);

    // Cleanup
    try std.fs.deleteFileAbsolute(creds_path);
}

test "query with --no-saved-session ignores credentials file" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.integration_backup4", .{creds_path});
    defer allocator.free(backup_path);

    std.fs.copyFileAbsolute(creds_path, backup_path, .{}) catch {};
    defer {
        std.fs.copyFileAbsolute(backup_path, creds_path, .{}) catch {};
        std.fs.deleteFileAbsolute(backup_path) catch {};
    }

    // Login with save-session
    var result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "login",
            "-U",
            "nosession_test_user",
            "-P",
            "nosession_test_pass",
            "--save-session",
        },
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Run query with --no-saved-session (should still work in --no-quic mode)
    result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "query",
            "--no-quic",
            "--no-saved-session",
            "RETURN 1 AS no_session_test",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "no_session_test") != null);

    // Cleanup
    try std.fs.deleteFileAbsolute(creds_path);
}

test "session token has correct file permissions (600)" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const creds_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(creds_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.integration_backup5", .{creds_path});
    defer allocator.free(backup_path);

    std.fs.copyFileAbsolute(creds_path, backup_path, .{}) catch {};
    defer {
        std.fs.copyFileAbsolute(backup_path, creds_path, .{}) catch {};
        std.fs.deleteFileAbsolute(backup_path) catch {};
    }

    // Login
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "./zig-out/bin/geode",
            "auth",
            "login",
            "-U",
            "perms_test_user",
            "-P",
            "perms_test_pass",
            "--save-session",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check file permissions
    const file = try std.fs.openFileAbsolute(creds_path, .{});
    defer file.close();

    const stat = try file.stat();
    const mode = stat.mode & 0o777;

    // Should be 600 (owner read/write only)
    try testing.expectEqual(@as(u32, 0o600), mode);

    // Cleanup
    try std.fs.deleteFileAbsolute(creds_path);
}
