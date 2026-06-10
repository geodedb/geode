// CANARY: REQ=REQ-GAP-0857-EMBEDDED-SERVER; FEATURE="EmbeddedServerGate"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0857_lib_api.zig:1; OWNER=library; UPDATED=2026-06-10
//
// Regression tests for GAP-0857: "src/lib.zig still reports embedded server mode
// unavailable and runServerWithArgs() returns EmbeddingError.NotImplemented."
//
// Decision (see src/lib.zig and docs/API_REFERENCE.md): the library does NOT
// host an in-process server — the QUIC+TLS transport stack is intentionally kept
// out of the library interface. The previously-opaque NotImplemented error is
// replaced with the self-documenting EmbeddedServerUnsupported error whose name
// is part of the public contract, and the doc comments / docs no longer advertise
// "embedded server mode". This test pins:
//   - the public lib server API surface compiles,
//   - runServerWithArgs returns the documented EmbeddedServerUnsupported error
//     (never starts a server, never returns void),
//   - the error name is exactly EmbeddedServerUnsupported (contract),
//   - isServerModeAvailable() honestly reports false.

const std = @import("std");
const geode = @import("geode");

test "GAP-0857: runServerWithArgs returns the documented EmbeddedServerUnsupported error" {
    const args: [][:0]u8 = &.{};
    const result = geode.server.runServerWithArgs(std.testing.allocator, args);
    try std.testing.expectError(
        geode.server.EmbeddingError.EmbeddedServerUnsupported,
        result,
    );
}

test "GAP-0857: EmbeddedServerUnsupported is the error name (public contract)" {
    const E = geode.server.EmbeddingError;
    const e: E = E.EmbeddedServerUnsupported;
    try std.testing.expectEqualStrings("EmbeddedServerUnsupported", @errorName(e));
}

test "GAP-0857: isServerModeAvailable honestly reports false" {
    try std.testing.expect(!geode.server.isServerModeAvailable());
}

test "GAP-0857: getRecommendedPattern for embedded_server points at the supported subprocess path" {
    const pattern = geode.server.getRecommendedPattern(.embedded_server);
    // Must not claim embedded hosting is available; must name the subprocess
    // alternative (`geode serve`).
    try std.testing.expect(std.mem.indexOf(u8, pattern, "geode serve") != null);
}

test "GAP-0857: the public server embedding API surface compiles and is reachable" {
    // Reference each public symbol so a rename/removal breaks this test.
    const fn_ptr = geode.server.runServerWithArgs;
    _ = fn_ptr;
    const avail = geode.server.isServerModeAvailable;
    _ = avail;
    const rec = geode.server.getRecommendedPattern;
    _ = rec;
    _ = geode.server.EmbeddingUseCase.local_queries;
    const init_failed: geode.server.EmbeddingError = geode.server.EmbeddingError.InitializationFailed;
    try std.testing.expectEqualStrings("InitializationFailed", @errorName(init_failed));
}
