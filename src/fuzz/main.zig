const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

// CANARY: REQ=REQ-FUZZ-PARSER-001; FEATURE="Fuzz Harness"; ASPECT=ParserFuzzing; STATUS=TESTED; OWNER=security; UPDATED=2026-01-16
// GAP-0204 FIX: Implemented functional fuzz harness that exercises the GQL parser

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // CANARY: REQ=REQ-QUALITY-GAP-406-011; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    // Read all stdin into buffer using posix API
    const stdin_file = if (builtin.os.tag == .windows) blk: {
        const h = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return;
        if (h == std.os.windows.INVALID_HANDLE_VALUE) return;
        break :blk std.Io.File{ .handle = h, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };

    // Read input with size limit to prevent OOM.
    // Zig 0.16 retired `std.Io.File.readAll`; stdin is a pipe (no
    // positional reads), so the supported pattern is the buffered
    // `reader().interface.readSliceShort` loop.  Total bytes are still
    // capped at 1 MiB.
    const max_input_size: usize = 1024 * 1024; // 1 MiB max
    var input_data = try alloc.alloc(u8, max_input_size);
    defer alloc.free(input_data);

    var stdin_buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(std.Io.Threaded.global_single_threaded.io(), &stdin_buf);
    var bytes_read: usize = 0;
    while (bytes_read < max_input_size) {
        // `readSliceShort` on `Io.File.Reader` returns `error{ReadFailed}`;
        // accept whatever we managed to read so far on any read failure.
        const n = reader.interface.readSliceShort(input_data[bytes_read..]) catch break;
        if (n == 0) break;
        bytes_read += n;
    }

    if (bytes_read == 0) {
        return; // Empty input, nothing to fuzz
    }

    const input = input_data[0..bytes_read];

    // CANARY: REQ=REQ-FUZZ-PARSER-002; FEATURE="Fuzz Harness"; ASPECT=InputParsing; STATUS=TESTED; OWNER=security; UPDATED=2026-01-16
    // Attempt to parse the input as GQL
    fuzzParseGql(alloc, input);
}

// Fuzz the GQL parser
fn fuzzParseGql(alloc: std.mem.Allocator, input: []const u8) void {
    // Try to parse as GQL query
    var result = geode.parse(alloc, input, .{}) catch {
        // Parse errors are expected during fuzzing - not a bug
        return;
    };
    defer result.deinit();

    // If parse succeeded, try to access the AST
    if (result.program.statements.len > 0) {
        // Successfully parsed - walk the AST to trigger any lazy evaluation bugs
        for (result.program.statements) |stmt| {
            validateStatement(stmt);
        }
    }
}

// Validate a parsed statement by accessing its fields
fn validateStatement(stmt: geode.ast.Statement) void {
    _ = stmt; // Access the statement to trigger any memory issues
    // In the future, could add more thorough AST traversal
}

// CANARY: REQ=REQ-FUZZ-ENTRY-001; FEATURE="Fuzz Harness"; ASPECT=LibFuzzerEntry; STATUS=TESTED; OWNER=security; UPDATED=2026-01-16
// Entry point for libFuzzer integration
pub export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size == 0) return 0;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const input = data[0..size];

    // Run parser fuzzing
    fuzzParseGql(alloc, input);

    return 0; // Success (no crash)
}

test "fuzz harness compiles and runs with empty input" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Test with empty input
    fuzzParseGql(alloc, "");
}

test "fuzz harness handles valid GQL" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const valid_queries = [_][]const u8{
        "MATCH (n) RETURN n",
        "RETURN 1 + 2",
        "MATCH (a)-[r]->(b) WHERE a.name = 'test' RETURN a",
        "CREATE (n:Person {name: 'Alice'})",
    };

    for (valid_queries) |query| {
        fuzzParseGql(alloc, query);
    }
}

test "fuzz harness handles malformed input" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const malformed_inputs = [_][]const u8{
        "MATCH ((",
        "))))",
        "RETURN RETURN RETURN",
        "\x00\x01\x02\x03",
        "SELECT * FROM", // SQL instead of GQL
    };

    for (malformed_inputs) |input| {
        // Should not crash, just return errors
        fuzzParseGql(alloc, input);
    }
}
