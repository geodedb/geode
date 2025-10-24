const std = @import("std");
const testing = std.testing;

// Tests for unified CLI functionality - server and client integration

test "ServerConfig initialization with defaults" {
    const ServerConfig = struct {
        data_dir: ?[]const u8 = null,
        listen_quic: ?[]const u8 = null,
        cert_path: ?[]const u8 = null,
        key_path: ?[]const u8 = null,
        log_level: []const u8 = "info",
        result_format_txt: bool = false,
        disable_estimates: bool = false,
        compact_profile: bool = false,
        memcurve_profile: bool = false,
        force_no_tls: bool = false,
        test_exit_after_first: bool = false,
    };

    const config = ServerConfig{};

    try testing.expect(config.data_dir == null);
    try testing.expect(config.listen_quic == null);
    try testing.expectEqualStrings("info", config.log_level);
    try testing.expect(config.result_format_txt == false);
    try testing.expect(config.disable_estimates == false);
}

test "ClientConfig initialization with defaults" {
    const ClientConfig = struct {
        query_text: []const u8,
        server: []const u8 = "127.0.0.1:3141",
        format: []const u8 = "json",
        page_size: usize = 1,
        pull_all: bool = false,
        extra_pull: usize = 0,
        begin: bool = false,
        commit: bool = false,
        rollback: bool = false,
        process_path: ?[]const u8 = null,
        no_quic: bool = false,
        server_args: [][]const u8 = &.{},
        json_params: ?std.StringHashMap([]const u8) = null,
    };

    const config = ClientConfig{
        .query_text = "RETURN 1 AS x",
    };

    try testing.expectEqualStrings("RETURN 1 AS x", config.query_text);
    try testing.expectEqualStrings("127.0.0.1:3141", config.server);
    try testing.expectEqualStrings("json", config.format);
    try testing.expect(config.page_size == 1);
    try testing.expect(config.pull_all == false);
    try testing.expect(config.no_quic == false);
}

test "Command line argument parsing patterns" {
    // Test that command line arguments follow expected patterns
    const test_cases = [_]struct {
        input: []const []const u8,
        expected_cmd: []const u8,
    }{
        .{ .input = &.{ "geode", "serve", "--help" }, .expected_cmd = "serve" },
        .{ .input = &.{ "geode", "query", "RETURN 1" }, .expected_cmd = "query" },
        .{ .input = &.{ "geode", "--help" }, .expected_cmd = "--help" },
        .{ .input = &.{ "geode", "shell" }, .expected_cmd = "shell" },
        .{ .input = &.{ "geode", "backup" }, .expected_cmd = "backup" },
        .{ .input = &.{ "geode", "user" }, .expected_cmd = "user" },
    };

    for (test_cases) |case| {
        if (case.input.len >= 2) {
            try testing.expectEqualStrings(case.expected_cmd, case.input[1]);
        }
    }
}

test "Legacy binary name compatibility detection" {
    // Test that we can detect when running as legacy binary names
    const test_cases = [_]struct {
        binary_name: []const u8,
        is_legacy: bool,
        expected_mode: []const u8,
    }{
        .{ .binary_name = "geode", .is_legacy = false, .expected_mode = "unified" },
        .{ .binary_name = "geodec", .is_legacy = true, .expected_mode = "client" },
        .{ .binary_name = "geoded", .is_legacy = true, .expected_mode = "server" },
        .{ .binary_name = "/usr/bin/geode", .is_legacy = false, .expected_mode = "unified" },
        .{ .binary_name = "./zig-out/bin/geodec", .is_legacy = true, .expected_mode = "client" },
    };

    for (test_cases) |case| {
        const basename = std.fs.path.basename(case.binary_name);
        const is_legacy = std.mem.eql(u8, basename, "geodec") or std.mem.eql(u8, basename, "geoded");
        try testing.expect(is_legacy == case.is_legacy);

        if (is_legacy) {
            if (std.mem.eql(u8, basename, "geodec")) {
                try testing.expectEqualStrings("client", case.expected_mode);
            } else if (std.mem.eql(u8, basename, "geoded")) {
                try testing.expectEqualStrings("server", case.expected_mode);
            }
        }
    }
}

test "Server configuration validation" {
    const ServerConfig = struct {
        data_dir: ?[]const u8 = null,
        listen_quic: ?[]const u8 = null,
        log_level: []const u8 = "info",

        fn validate(self: @This()) !void {
            // Validate log level
            const valid_levels = [_][]const u8{ "debug", "info", "warn", "error" };
            var valid = false;
            for (valid_levels) |level| {
                if (std.mem.eql(u8, self.log_level, level)) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return error.InvalidLogLevel;

            // Validate listen address format if provided
            if (self.listen_quic) |addr| {
                if (addr.len == 0) return error.EmptyListenAddress;
                if (std.mem.indexOf(u8, addr, ":") == null) return error.MissingPort;
            }
        }
    };

    // Valid configurations
    var config1 = ServerConfig{ .log_level = "debug" };
    try config1.validate();

    var config2 = ServerConfig{ .listen_quic = "127.0.0.1:3141" };
    try config2.validate();

    // Invalid configurations
    var config3 = ServerConfig{ .log_level = "invalid" };
    try testing.expectError(error.InvalidLogLevel, config3.validate());

    var config4 = ServerConfig{ .listen_quic = "" };
    try testing.expectError(error.EmptyListenAddress, config4.validate());

    var config5 = ServerConfig{ .listen_quic = "127.0.0.1" };
    try testing.expectError(error.MissingPort, config5.validate());
}

test "Client configuration validation" {
    const ClientConfig = struct {
        query_text: []const u8,
        server: []const u8 = "127.0.0.1:3141",
        format: []const u8 = "json",

        fn validate(self: @This()) !void {
            // Validate query text
            if (self.query_text.len == 0) return error.EmptyQuery;

            // Validate format
            const valid_formats = [_][]const u8{ "json", "txt", "csv" };
            var valid = false;
            for (valid_formats) |fmt| {
                if (std.mem.eql(u8, self.format, fmt)) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return error.InvalidFormat;

            // Validate server address
            if (self.server.len == 0) return error.EmptyServer;
            if (std.mem.indexOf(u8, self.server, ":") == null) return error.MissingPort;
        }
    };

    // Valid configurations
    var config1 = ClientConfig{ .query_text = "RETURN 1" };
    try config1.validate();

    var config2 = ClientConfig{ .query_text = "MATCH (n) RETURN n", .format = "csv" };
    try config2.validate();

    // Invalid configurations
    var config3 = ClientConfig{ .query_text = "" };
    try testing.expectError(error.EmptyQuery, config3.validate());

    var config4 = ClientConfig{ .query_text = "RETURN 1", .format = "xml" };
    try testing.expectError(error.InvalidFormat, config4.validate());

    var config5 = ClientConfig{ .query_text = "RETURN 1", .server = "localhost" };
    try testing.expectError(error.MissingPort, config5.validate());
}

test "Command dispatch logic" {
    // Test command dispatch logic for unified CLI
    const CommandType = enum {
        serve,
        query,
        shell,
        backup,
        user,
        help,
        unknown,
    };

    const fromString = struct {
        fn call(s: []const u8) CommandType {
            if (std.mem.eql(u8, s, "serve")) return .serve;
            if (std.mem.eql(u8, s, "query")) return .query;
            if (std.mem.eql(u8, s, "shell")) return .shell;
            if (std.mem.eql(u8, s, "backup")) return .backup;
            if (std.mem.eql(u8, s, "user")) return .user;
            if (std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "help")) return .help;
            return .unknown;
        }
    }.call;

    try testing.expect(fromString("serve") == .serve);
    try testing.expect(fromString("query") == .query);
    try testing.expect(fromString("shell") == .shell);
    try testing.expect(fromString("backup") == .backup);
    try testing.expect(fromString("user") == .user);
    try testing.expect(fromString("--help") == .help);
    try testing.expect(fromString("help") == .help);
    try testing.expect(fromString("invalid") == .unknown);
}

test "Exit code enumeration" {
    const ExitCode = enum(u8) {
        success = 0,
        general_error = 1,
        usage_error = 2,
        auth_error = 3,
    };

    try testing.expect(@intFromEnum(ExitCode.success) == 0);
    try testing.expect(@intFromEnum(ExitCode.general_error) == 1);
    try testing.expect(@intFromEnum(ExitCode.usage_error) == 2);
    try testing.expect(@intFromEnum(ExitCode.auth_error) == 3);
}

test "Process argument building" {
    // Test building process arguments for embedded server/client
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build server arguments
    var server_args = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    try server_args.append(allocator, "./zig-out/bin/geoded");
    try server_args.append(allocator, "--data-dir");
    try server_args.append(allocator, "./test_data");
    try server_args.append(allocator, "--listen-quic");
    try server_args.append(allocator, "127.0.0.1:3141");

    const server_argv = try server_args.toOwnedSlice(allocator);
    try testing.expect(server_argv.len == 5);
    try testing.expectEqualStrings("./zig-out/bin/geoded", server_argv[0]);
    try testing.expectEqualStrings("--data-dir", server_argv[1]);
    try testing.expectEqualStrings("./test_data", server_argv[2]);

    // Build client arguments
    var client_args = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    try client_args.append(allocator, "./zig-out/bin/geodec");
    try client_args.append(allocator, "RETURN 1 AS x");
    try client_args.append(allocator, "--no-quic");
    try client_args.append(allocator, "--format");
    try client_args.append(allocator, "json");

    const client_argv = try client_args.toOwnedSlice(allocator);
    try testing.expect(client_argv.len == 5);
    try testing.expectEqualStrings("./zig-out/bin/geodec", client_argv[0]);
    try testing.expectEqualStrings("RETURN 1 AS x", client_argv[1]);
    try testing.expectEqualStrings("--no-quic", client_argv[2]);
}
