const std = @import("std");
// CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedEntry; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
// Unified entry point for geode binary that can dispatch to either CLI or server mode

// Import CLI main module
const cli_main = @import("cli/main.zig");

// Import server main module (now accessible since we're rooted at src/)
const server_main = @import("server/main.zig");

pub fn main(proc_init: std.process.Init.Minimal) !void {
    // Delegate to CLI main which handles argument parsing and routing
    // including the 'serve' command which will call server_main.main()
    return cli_main.main(proc_init);
}

// Export server_main so CLI can access it
pub const server = struct {
    pub fn run() !void {
        return server_main.main();
    }
};
