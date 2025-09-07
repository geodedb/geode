const std = @import("std");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);
    if (argv.len < 2) {
        std.debug.print("usage: geodec <GQL text> [--json-param name json] [--server ./zig-out/bin/geoded] [--begin] [--commit|--rollback]\n", .{});
        return;
    }
    const text: []const u8 = argv[1];
    var server_path: []const u8 = "./zig-out/bin/geoded";
    var param_name: ?[]const u8 = null;
    var param_json: ?[]const u8 = null;
    var do_begin = false;
    var do_commit = false;
    var do_rollback = false;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) break;
            server_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--json-param")) {
            if (i + 2 >= argv.len) break;
            param_name = argv[i + 1];
            param_json = argv[i + 2];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--begin")) {
            do_begin = true;
        } else if (std.mem.eql(u8, argv[i], "--commit")) {
            do_commit = true;
        } else if (std.mem.eql(u8, argv[i], "--rollback")) {
            do_rollback = true;
        }
    }

    // Spawn server
    var child = std.process.Child.init(&.{server_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    // Inherit stderr so large error outputs don't block the child process
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const child_stdin = child.stdin.?.deprecatedWriter();
    const child_stdout = child.stdout.?.deprecatedReader();

    // Send HELLO
    try child_stdin.writeAll("{\"type\":\"HELLO\",\"client_name\":\"geodec\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}\n");
    if (do_begin) {
        try child_stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        const ack = try child_stdout.readUntilDelimiterAlloc(gpa, '\n', 1 << 16);
        defer gpa.free(ack);
        if (std.mem.indexOf(u8, ack, "\"type\":\"ERROR\"") != null) {
            const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            const stderr_writer = stderr_file.deprecatedWriter();
            try stderr_writer.writeAll(ack);
            try stderr_writer.writeAll("\n");
            child.stdin.?.close();
            _ = try child.wait();
            std.process.exit(2);
        }
    }
    // RUN_GQL
    if (param_name) |pn| {
        const pj = param_json orelse "{}";
        try child_stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"");
        try child_stdin.print("{s}", .{text});
        try child_stdin.writeAll("\",\"params\":{\"");
        try child_stdin.print("{s}", .{pn});
        try child_stdin.writeAll("\":");
        try child_stdin.writeAll(pj);
        try child_stdin.writeAll("}}\n");
    } else {
        try child_stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"");
        try child_stdin.print("{s}", .{text});
        try child_stdin.writeAll("\"}\n");
    }

    // Read first response; if ERROR, surface and exit 2
    const line1 = try child_stdout.readUntilDelimiterAlloc(gpa, '\n', 1 << 16);
    defer gpa.free(line1);
    if (std.mem.indexOf(u8, line1, "\"type\":\"ERROR\"") != null) {
        const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        const stderr_writer = stderr_file.deprecatedWriter();
        try stderr_writer.writeAll(line1);
        try stderr_writer.writeAll("\n");
        child.stdin.?.close();
        _ = try child.wait();
        std.process.exit(2);
    }

    // Print SCHEMA line and request PULL
    {
        const out_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        const outw = out_file.deprecatedWriter();
        try outw.writeAll(line1);
        try outw.writeAll("\n");
    }
    try child_stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":1000}\n");
    const line2 = try child_stdout.readUntilDelimiterAlloc(gpa, '\n', 1 << 16);
    defer gpa.free(line2);
    {
        const out_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        const outw = out_file.deprecatedWriter();
        try outw.writeAll(line2);
        try outw.writeAll("\n");
    }

    // Flush buffered writes before waiting on further responses
    // no buffered writer now
    if (do_commit) {
        try child_stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        const ackc = try child_stdout.readUntilDelimiterAlloc(gpa, '\n', 1 << 16);
        defer gpa.free(ackc);
        if (std.mem.indexOf(u8, ackc, "\"type\":\"ERROR\"") != null) {
            const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            const stderr_writer = stderr_file.deprecatedWriter();
            try stderr_writer.writeAll(ackc);
            try stderr_writer.writeAll("\n");
            child.stdin.?.close();
            _ = try child.wait();
            std.process.exit(2);
        }
    } else if (do_rollback) {
        try child_stdin.writeAll("{\"type\":\"ROLLBACK\"}\n");
        const ackr = try child_stdout.readUntilDelimiterAlloc(gpa, '\n', 1 << 16);
        defer gpa.free(ackr);
        if (std.mem.indexOf(u8, ackr, "\"type\":\"ERROR\"") != null) {
            const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            const stderr_writer = stderr_file.deprecatedWriter();
            try stderr_writer.writeAll(ackr);
            try stderr_writer.writeAll("\n");
            child.stdin.?.close();
            _ = try child.wait();
            std.process.exit(2);
        }
    }

    // Done; shutdown server
    // no buffered writer now
    if (child.stdin) |s| {
        s.close();
        child.stdin = null;
    }
    if (child.stdout) |so| {
        so.close();
        child.stdout = null;
    }
    _ = try child.wait();
}
