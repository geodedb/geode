const std = @import("std");
// CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedEntry; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
// Unified entry point for geode binary that can dispatch to either CLI or server mode

// Import CLI main module
const cli_main = @import("cli/main.zig");

// Import server main module (now accessible since we're rooted at src/)
const server_main = @import("server/main.zig");

// Portable process-argv holder: Zig 0.16 removed std.process.argsAlloc, so the
// argv delivered here via proc_init is the only authoritative source. Capture
// it once so deep call paths (cli_args.parseArgs, parseLspBootstrapConfig) can
// recover argv portably instead of reading the Linux-only /proc/self/cmdline.
const process_args = @import("server/process_args.zig");

pub fn main(proc_init: std.process.Init.Minimal) !void {
    // Capture argv before any code path that needs it (server parseArgs, etc.).
    process_args.init(proc_init.args);
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
