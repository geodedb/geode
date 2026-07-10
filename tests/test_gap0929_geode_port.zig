// CANARY: REQ=REQ-GAP-0929-GEODE-PORT-ENV; FEATURE="Config"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0929_geode_port.zig:1; OWNER=config; UPDATED=2026-07-10
//
// Regression tests for GAP-0929: "`GEODE_PORT` environment variable is inert".
//
// GEODE_PORT had zero references in src/ — only --listen set the bind address,
// so setting GEODE_PORT silently had no effect. Now it is honored (precedence:
// --listen flag > GEODE_PORT env > default 3141) and an invalid value is
// rejected loudly rather than silently ignored.

const std = @import("std");
const testing = std.testing;
const cli_args = @import("cli_args");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "GAP-0929: GEODE_PORT sets the bind address when --listen is absent" {
    _ = setenv("GEODE_PORT", "4242", 1);
    defer _ = unsetenv("GEODE_PORT");

    const argv = [_][]const u8{ "geode", "serve" };
    var cfg = (try cli_args.parseArgsFromSlice(testing.allocator, &argv)) orelse return error.UnexpectedHelp;
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.listen_quic != null);
    try testing.expectEqualStrings("0.0.0.0:4242", cfg.listen_quic.?);
}

test "GAP-0929: --listen takes precedence over GEODE_PORT" {
    _ = setenv("GEODE_PORT", "4242", 1);
    defer _ = unsetenv("GEODE_PORT");

    const argv = [_][]const u8{ "geode", "serve", "--listen", "127.0.0.1:5555" };
    var cfg = (try cli_args.parseArgsFromSlice(testing.allocator, &argv)) orelse return error.UnexpectedHelp;
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("127.0.0.1:5555", cfg.listen_quic.?);
}

test "GAP-0929: default 3141 when neither --listen nor GEODE_PORT is set" {
    _ = unsetenv("GEODE_PORT");

    const argv = [_][]const u8{ "geode", "serve" };
    var cfg = (try cli_args.parseArgsFromSlice(testing.allocator, &argv)) orelse return error.UnexpectedHelp;
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("0.0.0.0:3141", cfg.listen_quic.?);
}

test "GAP-0929: an invalid GEODE_PORT is rejected, not silently ignored" {
    _ = setenv("GEODE_PORT", "notaport", 1);
    defer _ = unsetenv("GEODE_PORT");

    const argv = [_][]const u8{ "geode", "serve" };
    try testing.expectError(
        error.InvalidGeodePort,
        cli_args.parseArgsFromSlice(testing.allocator, &argv),
    );
}

test "GAP-0929: GEODE_PORT=0 is rejected" {
    _ = setenv("GEODE_PORT", "0", 1);
    defer _ = unsetenv("GEODE_PORT");

    const argv = [_][]const u8{ "geode", "serve" };
    try testing.expectError(
        error.InvalidGeodePort,
        cli_args.parseArgsFromSlice(testing.allocator, &argv),
    );
}
