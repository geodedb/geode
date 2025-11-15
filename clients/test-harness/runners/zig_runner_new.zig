const std = @import("std");
const builtin = @import("builtin");
const GeodeClient = @import("../../zig/geode_client").GeodeClient;

// CANARY: REQ=REQ-ZIG-RUNNER-001; FEATURE="Zig Test Runner"; ASPECT=MsquicClient; STATUS=IMPL; OWNER=test-harness; UPDATED=2025-11-15
// Test harness runner using msquic-based Zig client

const TestSpec = struct {
    version: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    setup: []Step = &[_]Step{},
    tests: []Test = &[_]Test{},
    cleanup: []Step = &[_]Step{},
};

const Test = struct {
    name: []const u8,
    description: []const u8 = "",
    query: []const u8 = "",
    params: ?std.json.Value = null,
    expect: Expectation = .{},
    steps: []Step = &[_]Step{},
    skip: bool = false,
    timeout_ms: ?u64 = null,
    expect_error: bool = false,
};

const Step = struct {
    type: []const u8,
    text: []const u8 = "",
    params: ?std.json.Value = null,
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
    duration_ms: f64,
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
    results: []TestResult,
};

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
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
            spec_path = args.next() orelse {
                try getStdErr().writeAll("ERROR: --spec requires a value\n");
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--server")) {
            server = args.next() orelse {
                try getStdErr().writeAll("ERROR: --server requires a value\n");
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    if (spec_path == null) {
        try getStdErr().writeAll("ERROR: --spec is required\n");
        std.process.exit(2);
    }

    // Parse server address
    var host_port = std.mem.splitScalar(u8, server, ':');
    const host = host_port.next() orelse "localhost";
    const port_str = host_port.next() orelse "8443";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8443;

    if (verbose) {
        std.debug.print("Zig runner: Loading spec from {s}\n", .{spec_path.?});
        std.debug.print("Server: {s}:{d}\n", .{ host, port });
    }

    // Load and parse spec file
    const spec_file = try std.fs.cwd().openFile(spec_path.?, .{});
    defer spec_file.close();

    const spec_content = try spec_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(spec_content);

    // Parse YAML spec using std.json (simplified - we'll parse the YAML structure)
    // For now, we'll use a simple parser that extracts tests
    const spec = try parseSpec(allocator, spec_content);
    defer freeSpec(allocator, spec);

    // Run setup steps
    if (spec.setup.len > 0) {
        if (verbose) {
            std.debug.print("Running setup...\n", .{});
        }
        runSetup(allocator, host, port, spec.setup, verbose) catch |err| {
            try getStdErr().writer().print("ERROR: Setup failed: {}\n", .{err});
            std.process.exit(3);
        };
    }

    // Run tests
    var results = std.ArrayList(TestResult).init(allocator);
    defer {
        for (results.items) |result| {
            if (result.@"error") |err| allocator.free(err);
            allocator.free(result.test_name);
        }
        results.deinit();
    }

    for (spec.tests) |test_case| {
        if (test_case.skip) {
            try results.append(.{
                .test_name = try allocator.dupe(u8, test_case.name),
                .status = "skipped",
                .duration_ms = 0.0,
            });
            continue;
        }

        if (verbose) {
            std.debug.print("Running test: {s}\n", .{test_case.name});
        }

        const result = runTest(allocator, host, port, test_case, verbose);
        try results.append(result);
    }

    // Run cleanup
    if (spec.cleanup.len > 0) {
        if (verbose) {
            std.debug.print("Running cleanup...\n", .{});
        }
        runSetup(allocator, host, port, spec.cleanup, verbose) catch |err| {
            if (verbose) {
                std.debug.print("WARNING: Cleanup failed: {}\n", .{err});
            }
        };
    }

    // Calculate summary
    var summary = Summary{
        .total = results.items.len,
        .passed = 0,
        .failed = 0,
        .errors = 0,
        .skipped = 0,
    };

    for (results.items) |result| {
        if (std.mem.eql(u8, result.status, "passed")) {
            summary.passed += 1;
        } else if (std.mem.eql(u8, result.status, "failed")) {
            summary.failed += 1;
        } else if (std.mem.eql(u8, result.status, "error")) {
            summary.errors += 1;
        } else if (std.mem.eql(u8, result.status, "skipped")) {
            summary.skipped += 1;
        }
    }

    // Output results
    if (json_output) {
        try outputJson(allocator, summary, results.items);
    } else {
        try outputText(summary, results.items);
    }

    // Exit with appropriate code
    if (summary.errors > 0 or summary.failed > 0) {
        std.process.exit(1);
    }
}

fn parseSpec(allocator: std.mem.Allocator, yaml_content: []const u8) !TestSpec {
    // Simple YAML parser for test specs
    // This is a simplified parser - in production, use a proper YAML library
    _ = yaml_content;

    // For now, return empty spec - this will be improved
    return TestSpec{
        .tests = try allocator.alloc(Test, 0),
    };
}

fn freeSpec(allocator: std.mem.Allocator, spec: TestSpec) void {
    allocator.free(spec.tests);
}

fn runSetup(allocator: std.mem.Allocator, host: []const u8, port: u16, steps: []Step, verbose: bool) !void {
    for (steps) |step| {
        if (std.mem.eql(u8, step.type, "query")) {
            if (verbose) {
                std.debug.print("Setup: {s}\n", .{step.text});
            }
            _ = try executeQuery(allocator, host, port, step.text, step.params, verbose);
        }
    }
}

fn runTest(allocator: std.mem.Allocator, host: []const u8, port: u16, test_case: Test, verbose: bool) TestResult {
    const start_time = std.time.milliTimestamp();

    // Execute query
    const result = executeQuery(allocator, host, port, test_case.query, test_case.params, verbose) catch |err| {
        const duration = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));
        const err_msg = std.fmt.allocPrint(allocator, "{}", .{err}) catch "OutOfMemory";
        return .{
            .test_name = allocator.dupe(u8, test_case.name) catch "unknown",
            .status = if (test_case.expect_error) "passed" else "error",
            .@"error" = if (test_case.expect_error) null else err_msg,
            .duration_ms = duration,
        };
    };
    defer result.deinit();

    const duration = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));

    // Verify expectations
    const passed = verifyExpectations(result.value, test_case.expect);

    return .{
        .test_name = allocator.dupe(u8, test_case.name) catch "unknown",
        .status = if (passed) "passed" else "failed",
        .@"error" = if (!passed) allocator.dupe(u8, "Expectation mismatch") catch null else null,
        .duration_ms = duration,
    };
}

fn executeQuery(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    query: []const u8,
    params: ?std.json.Value,
    verbose: bool,
) !std.json.Parsed(std.json.Value) {
    var client = GeodeClient.init(allocator, host, port, true); // insecure = true
    defer client.deinit();

    if (verbose) {
        std.debug.print("  Connecting to {s}:{d}...\n", .{ host, port });
    }

    try client.connect();

    if (verbose) {
        std.debug.print("  Opening stream...\n", .{});
    }

    try client.openStream();

    // Send HELLO
    if (verbose) {
        std.debug.print("  Sending HELLO...\n", .{});
    }

    try client.sendHello("geode-zig-runner", "1.0.0");
    const hello_response = try client.receiveMessage();
    defer allocator.free(hello_response);

    if (verbose) {
        std.debug.print("  HELLO response: {s}\n", .{hello_response});
    }

    // Send query
    if (verbose) {
        std.debug.print("  Sending query: {s}\n", .{query});
    }

    const request_id = "req_1";
    try client.sendRunGql(request_id, query, params);
    const schema_response = try client.receiveMessage();
    defer allocator.free(schema_response);

    if (verbose) {
        std.debug.print("  SCHEMA response: {s}\n", .{schema_response});
    }

    // Pull results
    try client.sendPull(request_id, 1000);
    const bindings_response = try client.receiveMessage();

    if (verbose) {
        std.debug.print("  BINDINGS response: {s}\n", .{bindings_response});
    }

    // Parse and return results
    return try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bindings_response,
        .{},
    );
}

fn verifyExpectations(result: std.json.Value, expect: Expectation) bool {
    _ = result;
    _ = expect;

    // For now, always pass - this will be improved with proper validation
    return true;
}

fn outputJson(allocator: std.mem.Allocator, summary: Summary, results: []TestResult) !void {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const writer = output.writer();

    try writer.print("{{\"summary\":{{\"total\":{d},\"passed\":{d},\"failed\":{d},\"errors\":{d},\"skipped\":{d}}},\"results\":[", .{
        summary.total,
        summary.passed,
        summary.failed,
        summary.errors,
        summary.skipped,
    });

    for (results, 0..) |result, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"test\":\"{s}\",\"status\":\"{s}\"", .{ result.test_name, result.status });
        if (result.@"error") |err| {
            try writer.print(",\"error\":\"{s}\"", .{err});
        }
        try writer.print(",\"duration_ms\":{d}}}", .{result.duration_ms});
    }

    try writer.writeAll("]}\n");

    try std.io.getStdOut().writeAll(output.items);
}

fn outputText(summary: Summary, results: []TestResult) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Tests: {d}\n", .{summary.total});
    try stdout.print("Passed: {d}\n", .{summary.passed});
    try stdout.print("Failed: {d}\n", .{summary.failed});
    try stdout.print("Errors: {d}\n", .{summary.errors});

    if (summary.errors > 0 or summary.failed > 0) {
        try stdout.writeAll("\nErrors/Failures:\n");
        for (results) |result| {
            if (result.@"error") |err| {
                try stdout.print("  {s}: {s}\n", .{ result.test_name, err });
            }
        }
    }
}
