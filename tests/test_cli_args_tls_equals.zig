// Regression for Kubernetes-style long options supplied as --name=value.
//
// A Mentats StatefulSet used this conventional argv shape.  The server parser
// only recognized `--name value`, silently ignored every inline value, and
// consequently auto-generated a geode.local certificate instead of loading
// the mounted cert-manager leaf.
//
// CANARY: REQ=REQ-CLI-TLS-EQUALS-001; FEATURE="TLS certificate CLI"; ASPECT=InlineValueParsing; STATUS=TESTED; TEST=tests/test_cli_args_tls_equals.zig; OWNER=cli; UPDATED=2026-07-20

const std = @import("std");
const cli_args = @import("cli_args");

test "TLS and adjacent server options accept --name=value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "geode",
        "serve",
        "--listen=0.0.0.0:3141",
        "--data-dir=/data",
        "--cert=/tls/tls.crt",
        "--key=/tls/tls.key",
        "--log-level=info",
    };

    var config = (try cli_args.parseArgsFromSlice(allocator, &argv)).?;
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("0.0.0.0:3141", config.listen_quic.?);
    try std.testing.expectEqualStrings("/data", config.data_dir.?);
    try std.testing.expectEqualStrings("/tls/tls.crt", config.cert_path.?);
    try std.testing.expectEqualStrings("/tls/tls.key", config.key_path.?);
    try std.testing.expectEqualStrings("info", config.log_level_arg.?);
    try std.testing.expect(config.cert_explicit);
    try std.testing.expect(config.key_explicit);
}

test "space-separated TLS options remain supported" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "geode", "serve", "--cert", "/tls/tls.crt", "--key", "/tls/tls.key",
    };

    var config = (try cli_args.parseArgsFromSlice(allocator, &argv)).?;
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("/tls/tls.crt", config.cert_path.?);
    try std.testing.expectEqualStrings("/tls/tls.key", config.key_path.?);
    try std.testing.expect(config.cert_explicit);
    try std.testing.expect(config.key_explicit);
}
