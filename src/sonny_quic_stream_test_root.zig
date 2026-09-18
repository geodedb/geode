// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-1835 / SONNY-1837 / SONNY-1841 — dedicated test root (at src/ so all of
// the server graph's relative imports resolve, same pattern as
// src/conn_pool_diag_test_root.zig).
//
// The proof predicates for the QUIC stream-semantics batch are INLINE tests in
// src/server/quic_connection_handler.zig and src/server/proto_reader_registry.zig
// (neither exported through the `geode` root — server graph, circular dep). Zig
// 0.16 only collects inline `test` blocks reachable from a test module's ROOT,
// so this thin src/-rooted module force-references both namespaces. Test-only;
// never linked into the shipped binary.

const std = @import("std");

pub const quic_connection_handler = @import("server/quic_connection_handler.zig");
pub const proto_reader_registry = @import("server/proto_reader_registry.zig");

test {
    std.testing.refAllDecls(quic_connection_handler);
    std.testing.refAllDecls(proto_reader_registry);
}
