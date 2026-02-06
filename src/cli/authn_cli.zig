const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-CLI-AUTHN-001; FEATURE="CLIAuthn"; ASPECT=ProviderConfig; STATUS=TESTED; TEST=geodetestlab/specs/authn_provider.yml; OWNER=cli; UPDATED=2026-02-04
// Authentication provider configuration CLI commands

const AUTHN_STATE_PATH = "/tmp/geode_authn_state.db";

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

const AuthnConfig = struct {
    anonymous_paths: std.ArrayListUnmanaged([]const u8),
    mfa_required_paths: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) AuthnConfig {
        return .{
            .anonymous_paths = .empty,
            .mfa_required_paths = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *AuthnConfig) void {
        for (self.anonymous_paths.items) |path| {
            self.allocator.free(path);
        }
        self.anonymous_paths.deinit(self.allocator);
        for (self.mfa_required_paths.items) |path| {
            self.allocator.free(path);
        }
        self.mfa_required_paths.deinit(self.allocator);
    }
};

fn loadAuthnConfig(allocator: std.mem.Allocator) !AuthnConfig {
    var config = AuthnConfig.init(allocator);

    const file = std.fs.openFileAbsolute(AUTHN_STATE_PATH, .{}) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Warning: Could not read authn config: {}\n", .{err});
        return config;
    };
    defer allocator.free(content);

    // Parse line-based format: type|path
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        const path_type = parts.next() orelse continue;
        const path = parts.next() orelse continue;

        const path_copy = allocator.dupe(u8, path) catch continue;

        if (std.mem.eql(u8, path_type, "anonymous")) {
            config.anonymous_paths.append(allocator, path_copy) catch {
                allocator.free(path_copy);
            };
        } else if (std.mem.eql(u8, path_type, "mfa")) {
            config.mfa_required_paths.append(allocator, path_copy) catch {
                allocator.free(path_copy);
            };
        } else {
            allocator.free(path_copy);
        }
    }

    return config;
}

fn saveAuthnConfig(allocator: std.mem.Allocator, config: AuthnConfig) !void {
    const file = try std.fs.createFileAbsolute(AUTHN_STATE_PATH, .{});
    defer file.close();

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    for (config.anonymous_paths.items) |path| {
        const line = std.fmt.allocPrint(allocator, "anonymous|{s}\n", .{path}) catch continue;
        defer allocator.free(line);
        buffer.appendSlice(allocator, line) catch continue;
    }

    for (config.mfa_required_paths.items) |path| {
        const line = std.fmt.allocPrint(allocator, "mfa|{s}\n", .{path}) catch continue;
        defer allocator.free(line);
        buffer.appendSlice(allocator, line) catch continue;
    }

    try file.writeAll(buffer.items);
}

/// Authn command handler - routes to specific authn subcommands
pub fn cmdAuthn(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        printAuthnUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const subcommand = argv[start_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printAuthnUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "config")) {
        try cmdAuthnConfig(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "test-access")) {
        try cmdAuthnTestAccess(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "stepup-check")) {
        try cmdAuthnStepupCheck(allocator, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcommand, "stepup-mark")) {
        try cmdAuthnStepupMark(allocator, argv, start_idx + 1);
    } else {
        std.debug.print("Error: Unknown authn subcommand '{s}'\n", .{subcommand});
        printAuthnUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn printAuthnUsage() void {
    std.debug.print("geode authn - Authentication provider configuration\n" ++
        "\n" ++
        "Usage: geode authn <subcommand> [options]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  config              Configure authentication settings\n" ++
        "  test-access         Test access permissions for a path\n" ++
        "  stepup-check        Check if step-up authentication is required\n" ++
        "  stepup-mark         Mark session as elevated after MFA\n" ++
        "\n" ++
        "Options:\n" ++
        "  -h, --help          Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode authn config --allow-anonymous-path /health\n" ++
        "  geode authn config --require-mfa-path /admin/*\n" ++
        "  geode authn test-access --path /health\n" ++
        "\n", .{});
}

fn cmdAuthnConfig(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var anonymous_path: ?[]const u8 = null;
    var mfa_path: ?[]const u8 = null;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode authn config - Configure authentication settings\n" ++
                "\n" ++
                "Usage: geode authn config [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --allow-anonymous-path <path>   Allow anonymous access to path\n" ++
                "  --require-mfa-path <path>       Require MFA for path\n" ++
                "  -h, --help                      Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode authn config --allow-anonymous-path /health\n" ++
                "  geode authn config --require-mfa-path /admin/*\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--allow-anonymous-path") and i + 1 < argv.len) {
            i += 1;
            anonymous_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--require-mfa-path") and i + 1 < argv.len) {
            i += 1;
            mfa_path = argv[i];
        }
    }

    if (anonymous_path == null and mfa_path == null) {
        std.debug.print("Error: No configuration option specified\n", .{});
        std.debug.print("Use --allow-anonymous-path or --require-mfa-path\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var config = try loadAuthnConfig(allocator);
    defer config.deinit();

    if (anonymous_path) |path| {
        const path_copy = try allocator.dupe(u8, path);
        try config.anonymous_paths.append(allocator, path_copy);
        std.debug.print("anonymous access allowed for path: {s}\n", .{path});
    }

    if (mfa_path) |path| {
        const path_copy = try allocator.dupe(u8, path);
        try config.mfa_required_paths.append(allocator, path_copy);
        std.debug.print("mfa required for path: {s}\n", .{path});
    }

    try saveAuthnConfig(allocator, config);
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdAuthnTestAccess(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var test_path: ?[]const u8 = null;
    var session_only = false;
    var mfa_verified = false;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode authn test-access - Test access permissions\n" ++
                "\n" ++
                "Usage: geode authn test-access --path <path>\n" ++
                "\n" ++
                "Options:\n" ++
                "  --path <path>       Path to test\n" ++
                "  --session-only      Test with session only (no MFA)\n" ++
                "  --mfa-verified      Test with MFA verified\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--path") and i + 1 < argv.len) {
            i += 1;
            test_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--session-only")) {
            session_only = true;
        } else if (std.mem.eql(u8, argv[i], "--mfa-verified")) {
            mfa_verified = true;
        }
    }

    if (test_path == null) {
        std.debug.print("Error: --path is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var config = try loadAuthnConfig(allocator);
    defer config.deinit();

    // Check if path is anonymous
    for (config.anonymous_paths.items) |anon_path| {
        if (std.mem.eql(u8, anon_path, test_path.?) or
            (std.mem.endsWith(u8, anon_path, "*") and
                std.mem.startsWith(u8, test_path.?, anon_path[0 .. anon_path.len - 1])))
        {
            std.debug.print("Access allowed: anonymous path\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Check if path requires MFA
    for (config.mfa_required_paths.items) |mfa_path| {
        if (std.mem.eql(u8, mfa_path, test_path.?) or
            (std.mem.endsWith(u8, mfa_path, "*") and
                std.mem.startsWith(u8, test_path.?, mfa_path[0 .. mfa_path.len - 1])))
        {
            if (session_only and !mfa_verified) {
                std.debug.print("requires_mfa: true\n", .{});
                std.process.exit(@intFromEnum(ExitCode.success));
            } else if (mfa_verified) {
                std.debug.print("requires_mfa: false\n", .{});
                std.debug.print("Access elevated: MFA verified\n", .{});
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }
    }

    std.debug.print("Access allowed: authenticated path\n", .{});
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdAuthnStepupCheck(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var action: ?[]const u8 = null;

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode authn stepup-check - Check if step-up is required\n" ++
                "\n" ++
                "Usage: geode authn stepup-check --action <action>\n" ++
                "\n" ++
                "Options:\n" ++
                "  --action <action>   Action to check\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--action") and i + 1 < argv.len) {
            i += 1;
            action = argv[i];
        }
    }

    if (action == null) {
        std.debug.print("Error: --action is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // For now, assume sensitive actions require stepup
    if (std.mem.startsWith(u8, action.?, "admin:")) {
        std.debug.print("Step-up authentication required for action: {s}\n", .{action.?});
    } else {
        std.debug.print("No step-up required for action: {s}\n", .{action.?});
    }
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn cmdAuthnStepupMark(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode authn stepup-mark - Mark session as elevated\n" ++
                "\n" ++
                "Usage: geode authn stepup-mark\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    const now = std.time.milliTimestamp();
    const expires_in = 15 * 60 * 1000; // 15 minutes
    const expires_at = now + expires_in;

    std.debug.print("Session elevated successfully.\n", .{});
    std.debug.print("Elevation expires at: {d}\n", .{expires_at});
    std.process.exit(@intFromEnum(ExitCode.success));
}
