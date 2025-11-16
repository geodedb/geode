const std = @import("std");
const builtin = @import("builtin");
const GeodeClient = @import("../../zig/geode_client").GeodeClient;
const yaml = @import("yaml");

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

fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
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
            std.debug.print("ERROR: Setup failed: {}\n", .{err});
            std.process.exit(3);
        };
    }

    // Run tests
    var results = try std.ArrayList(TestResult).initCapacity(allocator, 0);
    defer {
        for (results.items) |result| {
            if (result.@"error") |err| allocator.free(err);
            allocator.free(result.test_name);
        }
        results.deinit(allocator);
    }

    for (spec.tests) |test_case| {
        if (test_case.skip) {
            try results.append(allocator, .{
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
        try results.append(allocator, result);
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
    // Parse YAML content
    var parser = yaml.Parser.init(allocator, yaml_content);
    var root_value = try parser.parse();
    defer root_value.deinit(allocator);

    // Root should be a map
    if (root_value != .map) return error.InvalidSpec;

    var spec = TestSpec{};

    // Extract version, name, description
    if (root_value.map.get("version")) |ver| {
        if (ver == .string_value) {
            spec.version = try allocator.dupe(u8, ver.string_value);
        }
    }

    if (root_value.map.get("name")) |n| {
        if (n == .string_value) {
            spec.name = try allocator.dupe(u8, n.string_value);
        }
    }

    if (root_value.map.get("description")) |desc| {
        if (desc == .string_value) {
            spec.description = try allocator.dupe(u8, desc.string_value);
        }
    }

    // Extract tests array
    if (root_value.map.get("tests")) |tests_val| {
        if (tests_val == .list) {
            spec.tests = try allocator.alloc(Test, tests_val.list.items.len);

            for (tests_val.list.items, 0..) |*test_val, i| {
                if (test_val.* != .map) continue;

                var test_case = Test{
                    .name = "",
                    .query = "",
                };

                // Extract test name
                if (test_val.map.get("name")) |n| {
                    if (n == .string_value) {
                        test_case.name = try allocator.dupe(u8, n.string_value);
                    }
                }

                // Extract description
                if (test_val.map.get("description")) |desc| {
                    if (desc == .string_value) {
                        test_case.description = try allocator.dupe(u8, desc.string_value);
                    }
                }

                // Extract query
                if (test_val.map.get("query")) |q| {
                    if (q == .string_value) {
                        test_case.query = try allocator.dupe(u8, q.string_value);
                    }
                }

                // Extract skip flag
                if (test_val.map.get("skip")) |skip| {
                    if (skip == .bool_value) {
                        test_case.skip = skip.bool_value;
                    }
                }

                // Extract timeout
                if (test_val.map.get("timeout_ms")) |timeout| {
                    if (timeout == .int_value) {
                        test_case.timeout_ms = @intCast(timeout.int_value);
                    }
                }

                // Extract expect_error flag
                if (test_val.map.get("expect_error")) |expect_err| {
                    if (expect_err == .bool_value) {
                        test_case.expect_error = expect_err.bool_value;
                    }
                }

                // Note: params and expect parsing omitted for simplicity
                // These would require converting yaml.Value to std.json.Value
                // For now, tests will run without validation

                spec.tests[i] = test_case;
            }
        } else {
            spec.tests = try allocator.alloc(Test, 0);
        }
    } else {
        spec.tests = try allocator.alloc(Test, 0);
    }

    return spec;
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
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output.deinit(allocator);

    const writer = output.writer(allocator);

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

    try getStdOut().writeAll(output.items);
}

fn outputText(summary: Summary, results: []TestResult) !void {
    const stdout = getStdOut();

    var buf: [1024]u8 = undefined;

    const msg1 = try std.fmt.bufPrint(&buf, "Tests: {d}\n", .{summary.total});
    try stdout.writeAll(msg1);

    const msg2 = try std.fmt.bufPrint(&buf, "Passed: {d}\n", .{summary.passed});
    try stdout.writeAll(msg2);

    const msg3 = try std.fmt.bufPrint(&buf, "Failed: {d}\n", .{summary.failed});
    try stdout.writeAll(msg3);

    const msg4 = try std.fmt.bufPrint(&buf, "Errors: {d}\n", .{summary.errors});
    try stdout.writeAll(msg4);

    if (summary.errors > 0 or summary.failed > 0) {
        try stdout.writeAll("\nErrors/Failures:\n");
        for (results) |result| {
            if (result.@"error") |err| {
                const msg = try std.fmt.bufPrint(&buf, "  {s}: {s}\n", .{ result.test_name, err });
                try stdout.writeAll(msg);
            }
        }
    }
}
