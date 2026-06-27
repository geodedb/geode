// grpc_server_test_shim.zig
//
// Thin shim that roots the test module at src/ so grpc_server.zig's
// relative imports (../server/rls_filter.zig, ../server/auth_rate_limiter.zig)
// resolve correctly: they land at src/server/*, which is within the src/
// module path.
//
// Zig 0.16 discovers inline test blocks from all files transitively
// imported via direct file paths, so grpc_server.zig's `test {}` blocks
// are discovered and run from here.
//
// Run via: zig build test-sec002-grpc-cdc
const std = @import("std");
// Direct file import — makes grpc_server.zig part of the transitive
// compilation so its inline test blocks are discovered by the test runner.
const _impl = @import("transport/grpc_server.zig");
comptime {
    _ = _impl;
}
