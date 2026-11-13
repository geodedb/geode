// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6463 item 5 / SONNY-6484 item 1: test root for the MCP files whose
// inline tests no step ran. The build imports src/mcp only as the named
// module `geode_mcp` (src/mcp/mod.zig), and Zig collects test blocks from
// the test root's own module only, so this root gives the files a module of
// their own with mcp_cli_mod's import table (`test-sonny6484-inline`).
// Test-only; never linked into the binary.

test {
    _ = @import("mcp/lsp.zig");
    _ = @import("mcp/resources.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp/tools.zig");
    _ = @import("mcp/client.zig");
}
