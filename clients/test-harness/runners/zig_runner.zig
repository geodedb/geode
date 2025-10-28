const std = @import("std");
const builtin = @import("builtin");
const yaml = @import("geode");

// Helper functions to get stdout/stderr in a cross-platform way
fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
}

const TestSpec = struct {
    version: []const u8,
    name: []const u8,
    description: []const u8 = "",
    setup: []StepDef = &[_]StepDef{},
    tests: []Test,
    cleanup: []StepDef = &[_]StepDef{},
};

const Test = struct {
    name: []const u8,
    description: []const u8 = "",
    query: []const u8 = "",
    params: std.json.Value = .null,
    expect: Expectation = .{},
    steps: []StepDef = &[_]StepDef{},
    skip: bool = false,
    timeout_ms: ?u64 = null,
    expect_error: bool = false,
};

const StepDef = struct {
    step_type: []const u8,
    text: []const u8 = "",
    params: std.json.Value = .null,
    expect: Expectation = .{},
    expect_error: bool = false,
};

const Expectation = struct {
    rows: ?usize = null,
    min_rows: ?usize = null,
    max_rows: ?usize = null,
    columns: ?[][]const u8 = null,
    values: ?[]std.json.Value = null,
};

const TestResult = struct {
    test_name: []const u8,
    status: []const u8,
    @"error": ?[]const u8 = null,
    result: ?QueryResult = null,
    duration_ms: f64,
};

const QueryResult = struct {
    rows: usize,
    columns: [][]const u8,
    data: []std.json.Value,
};

const Summary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    errors: usize,
    skipped: usize,
};

const Output = struct {
    summary: Summary,
    results: []const TestResult,
};

fn printOutput(output: Output, json_output: bool) !void {
    if (json_output) {
        std.debug.print("Warning: JSON output format not yet supported in Zig runner\n", .{});
    }

    std.debug.print("Tests: {d}\n", .{output.summary.total});
    std.debug.print("Passed: {d}\n", .{output.summary.passed});
    std.debug.print("Failed: {d}\n", .{output.summary.failed});
    std.debug.print("Errors: {d}\n", .{output.summary.errors});

    if (output.summary.errors > 0 or output.summary.failed > 0) {
        std.debug.print("\nErrors/Failures:\n", .{});
        for (output.results) |result| {
            if (result.@"error") |err| {
                std.debug.print("  {s}: {s}\n", .{ result.test_name, err });
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    var spec_path: ?[]const u8 = null;
    var server: []const u8 = "localhost:8443";
    var json_output = false;
    var verbose = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--spec")) {
            spec_path = args.next() orelse return error.MissingSpecPath;
        } else if (std.mem.eql(u8, arg, "--server")) {
            server = args.next() orelse return error.MissingServer;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    if (spec_path == null) {
        const stderr_file = getStdErr();
        try stderr_file.writeAll("ERROR: --spec is required\n");
        std.process.exit(2);
    }

    // Load spec file
    const spec_file = try std.fs.cwd().openFile(spec_path.?, .{});
    defer spec_file.close();

    const spec_content = try spec_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(spec_content);

    if (verbose) {
        std.debug.print("Zig runner: Loading spec from {s}\n", .{spec_path.?});
        std.debug.print("Server: {s}\n", .{server});
    }

    // Parse YAML spec
    var spec_value = yaml.parse(allocator, spec_content) catch |err| {
        std.debug.print("Error parsing YAML: {}\n", .{err});
        var results = [_]TestResult{
            .{
                .test_name = "yaml-parse",
                .status = "error",
                .@"error" = "Failed to parse YAML spec",
                .duration_ms = 0.0,
            },
        };
        const summary = Summary{
            .total = 1,
            .passed = 0,
            .failed = 0,
            .errors = 1,
            .skipped = 0,
        };
        const output = Output{
            .summary = summary,
            .results = results[0..],
        };
        try printOutput(output, json_output);
        std.process.exit(1);
    };
    defer spec_value.deinit(allocator);

    // Extract tests from spec
    if (spec_value != .map) {
        std.debug.print("Error: Spec root must be a map\n", .{});
        std.process.exit(1);
    }

    const tests_value = spec_value.map.get("tests") orelse {
        std.debug.print("Error: No 'tests' field in spec\n", .{});
        std.process.exit(1);
    };

    if (tests_value != .list) {
        std.debug.print("Error: 'tests' must be a list\n", .{});
        std.process.exit(1);
    }

    const tests = tests_value.list;

    // Run tests and collect results
    var results = try std.ArrayList(TestResult).initCapacity(allocator, tests.items.len);
    defer {
        for (results.items) |*result| {
            if (result.@"error") |err| {
                allocator.free(err);
            }
        }
        results.deinit(allocator);
    }

    const passed: usize = 0;
    const failed: usize = 0;
    var errors: usize = 0;

    for (tests.items) |test_val| {
        if (test_val != .map) continue;

        const test_name = if (test_val.map.get("name")) |name|
            if (name == .string_value) name.string_value else "unknown"
        else
            "unknown";

        if (verbose) {
            std.debug.print("Running test: {s}\n", .{test_name});
        }

        const start_time = std.time.milliTimestamp();

        // For now, all tests error since we don't have client implementation yet
        const test_result = TestResult{
            .test_name = test_name,
            .status = "error",
            .@"error" = try allocator.dupe(u8, "Zig client not yet implemented"),
            .result = null,
            .duration_ms = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time)),
        };

        try results.append(allocator, test_result);
        errors += 1;
    }

    const summary = Summary{
        .total = results.items.len,
        .passed = passed,
        .failed = failed,
        .errors = errors,
        .skipped = 0,
    };

    const output = Output{
        .summary = summary,
        .results = results.items,
    };

    try printOutput(output, json_output);

    if (output.summary.failed + output.summary.errors > 0) {
        std.process.exit(1);
    }
}
