const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");
const parity = @import("transport_parity_util.zig");

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics US001"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_US001; OWNER=engine; UPDATED=2026-08-25
//
// US001 ("unordered pagination") is NOT enforced. ISO/IEC 39075:2024 leaves the
// ordering of an unordered result set implementation-defined, and geode declares
// `UnorderedPaginationAllowed` in its implementation-defined flagger report
// (src/server/flagger_impl_defined.zig:66). The 2025-09-26 ISO gap prompt ordered
// US001 default-off (specs/gql/gql-iso-gap-2025-09-26-prompt.md:9-11) and the
// 2025-09-28 A7 item ordered the enforcement removed
// (specs/gql/gql-gap-analysis-2025-09-28-CP.md:92-96).
//
// This smoke therefore pins the CURRENT standards-correct contract and, being a
// transport-parity smoke, pins that BOTH transports produce it identically:
// `LIMIT`/`OFFSET` without `ORDER BY` succeeds with status class 00000 and no
// diagnostic on either QUIC or gRPC. The CLI arm additionally pins the
// documented GAP-0272 decision (src/cli/main.zig:2767-2770) that GQL-level
// errors do not change the process exit status.
//
// An opt-in strict mode (`ExecutionContext.strict_offset_validation`) remains an
// available future feature per the 2025-09-26 spec; it is hardcoded false at
// grpc_server.zig and quic_connection_handler.zig and is deliberately not wired.
test "protocol: transport parity diagnostics (US001) QUIC vs gRPC (gated)" {
    util.testStart("transport parity diagnostics (US001) QUIC vs gRPC");
    errdefer util.testFail();

    const allocator = testing.allocator;
    const exe = geode_test_bin.geode_exe;
    const q = "RETURN 1 LIMIT 10 OFFSET 5";

    // `util.GrpcProtoClient` speaks plaintext HTTP/2 while the gRPC listener is
    // TLS-required and fail-closed, so the parity arm needs the Debug-only
    // plaintext opt-in (grpc_server.zig:151).
    var parity_run = parity.runParityRandom(
        allocator,
        q,
        util.emptyParams(),
        util.emptyParams(),
        100,
        util.TestEnv.grpcPlaintext(),
    ) catch |err| {
        util.progress("Parity run failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer parity_run.server.deinit();
    defer parity_run.result.quic.deinit(allocator);
    defer parity_run.result.grpc.deinit(allocator);

    const quic_res = parity_run.result.quic;
    const grpc_res = parity_run.result.grpc;

    util.progress("Asserting US001 is not enforced on either transport...", .{});
    // No diagnostic: unordered pagination is legal.
    try testing.expect(quic_res.error_code == null);
    try testing.expect(grpc_res.error_code == null);
    try testing.expectEqualStrings("00000", quic_res.status_class);
    try testing.expectEqualStrings("00000", grpc_res.status_class);
    try testing.expectEqual(@as(usize, 0), quic_res.additional_statuses.len);
    try testing.expectEqual(@as(usize, 0), grpc_res.additional_statuses.len);

    util.progress("Comparing transport parity...", .{});
    // Parity: identical observable result on both transports.
    try testing.expectEqual(quic_res.ordered, grpc_res.ordered);
    try testing.expectEqual(quic_res.rows.len, grpc_res.rows.len);
    try testing.expectEqual(quic_res.columns.len, grpc_res.columns.len);
    try testing.expectEqual(quic_res.flagger_findings.len, grpc_res.flagger_findings.len);
    for (quic_res.flagger_findings, 0..) |finding, i| {
        try testing.expectEqualStrings(finding, grpc_res.flagger_findings[i]);
        // No US001 diagnostic is ever flagged.
        try testing.expect(!contains(finding, "US001"));
    }

    util.progress("Asserting CLI exit status (GAP-0272)...", .{});
    const cli = try cli_test_util.runAgainstServer(allocator, parity_run.server.quic_addr, &.{ exe, q, "--format", "json" });
    defer allocator.free(cli.out);
    defer allocator.free(cli.err);
    try testing.expectEqual(@as(i32, 0), cli.code);
    try testing.expect(!contains(cli.err, "US001"));
    try testing.expect(contains(cli.out, "\"status_class\":\"00000\""));

    util.testPass();
}
