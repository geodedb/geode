const std = @import("std");

// GAP-0875: doccheck was an existence-check placeholder that printed "OK"
// unconditionally (and required docs/NEXT.md, which does not exist). It now
// verifies the canonical tracking documents actually exist and FAILS the
// build step (exit 1) when any are missing.
const required_docs = [_][]const u8{
    "docs/GAP_ANALYSIS.md",
    "docs/GAP_ANALYSIS_RESOLVED.md",
    "docs/KNOWN_TEST_ISSUES.md",
    "CLAUDE.md",
};

pub fn main() !void {
    const cwd = std.Io.Dir.cwd();
    const io = std.Io.Threaded.global_single_threaded.io();
    var missing: usize = 0;
    for (required_docs) |path| {
        cwd.access(io, path, .{}) catch {
            std.debug.print("doccheck: MISSING required doc: {s}\n", .{path});
            missing += 1;
        };
    }
    if (missing != 0) {
        std.debug.print("doccheck: FAIL ({d} of {d} required docs missing)\n", .{ missing, required_docs.len });
        std.process.exit(1);
    }
    std.debug.print("doccheck: OK ({d} required docs present)\n", .{required_docs.len});
}
