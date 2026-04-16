const std = @import("std");
const gen = @import("../tools/gen_unicode_tables.zig");

// Test for Unicode table generator dry run (REQ-GQL-UNICODE-002)
// Provides evidence for CANARY TestCANARY_REQ_GQL_UNICODE_002_GeneratorDryRun by invoking the generator logic on
// a tiny embedded UnicodeData-like snippet and ensuring output file emitted with CANARY line.
test "TestCANARY_REQ_GQL_UNICODE_002_GeneratorDryRun" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Minimal UnicodeData excerpt: code;name;category;ccc;bidi;decomp
    const snippet = "00C9;LATIN CAPITAL LETTER E WITH ACUTE;Lu;0;L;0045 0301\n" ++
        "00E9;LATIN SMALL LETTER E WITH ACUTE;Ll;0;L;0065 0301\n";
    // Write snippet to temp file
    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-out/tmp_unicode_gen", .{});
    defer tmp_dir.close();
    var ud = try tmp_dir.createFile("UnicodeData.txt", .{});
    defer ud.close();
    try ud.writeAll(snippet);
    // Output directory
    var out_dir = try std.fs.cwd().makeOpenPath("zig-out/tmp_unicode_gen_out", .{});
    defer out_dir.close();
    // Simulate args: program name, unicode data path, out dir
    var argv = [_][]const u8{ "gen_unicode_tables", "zig-out/tmp_unicode_gen/UnicodeData.txt", "zig-out/tmp_unicode_gen_out" };
    // Directly call underlying main via spawning new process is heavy; instead replicate core steps by reading and parsing
    // Use internal parse function via reflection is not accessible; fallback to invoking via child process to exercise tool end-to-end.
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    var child = std.ChildProcess.init(&argv, arena_alloc.allocator());
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    const run_result = child.spawnAndWait() catch |e| {
        std.debug.print("spawn error {s}\n", .{@errorName(e)});
        return error.Unexpected;
    };
    try std.testing.expect(run_result.Exited and run_result.term.Exited == 0);
    // Validate output file exists and contains CANARY line (003 will be covered by decomposition test separately)
    var gen_file = try out_dir.openFile("decomp.zig", .{ .mode = .read_only });
    defer gen_file.close();
    const contents = try gen_file.readToEndAlloc(alloc, 16 * 1024);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CANARY: REQ=REQ-GQL-UNICODE-003") != null);
}
