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

/// SONNY-1560: re-export so a test file OUTSIDE src/ can reach
/// grpc_server.zig's public decls. A test module rooted at tests/ cannot
/// `@import("../src/transport/grpc_server.zig")` — that file's own
/// `../server/*.zig` imports would escape the module root — so the regression
/// suite imports this shim as a named module and reaches the implementation
/// through `impl`.
pub const impl = _impl;

/// SONNY-2776: the transport RLS post-filter engine the gRPC handler consults
/// (the same file, so the same global), for tests that install a policy.
pub const rls_filter = @import("server/rls_filter.zig");
