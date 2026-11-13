// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6463 item 5: test root for CLI files whose inline tests no step ran.
// They are compiled only into the geode executable (relative imports from
// src/unified_entry.zig), and a root at src/cli cannot import their `../`
// siblings, so this root sits at src/ and build.zig gives it geode_exe's
// import table (`test-sonny6463-inline-wired`). Test-only; never linked into
// the binary.

test {
    _ = @import("cli/backup_cli.zig");
    _ = @import("cli/cli_dispatcher.zig");
}
