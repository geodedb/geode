const std = @import("std");
const builtin = @import("builtin");
const quic_transport = @import("transport/quic");
const logger = @import("log/logger.zig");

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

fn readLineAlloc(ally: std.mem.Allocator, file: std.fs.File, max: usize) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    while (true) {
        var one: [1]u8 = undefined;
        const n = try file.read(&one);
        if (n == 0) { // EOF
            if (buf.items.len == 0) return error.EndOfStream; // surface empty EOF
            break;
        }
        if (one[0] == '\n') break;
        buf.append(ally, one[0]) catch return error.OutOfMemory;
        if (buf.items.len >= max) break;
    }
    return buf.toOwnedSlice(ally) catch error.OutOfMemory;
}

pub fn main() !void {
    var test_wal_skip_ratio: ?[]const u8 = null;
    const build_options = @import("build_options");
    const sentinel = @import("sentinel");
    const gpa = if (build_options.enable_sentinel) sentinel.maybeSentinel(std.heap.page_allocator) else std.heap.page_allocator;
    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);
    if (argv.len < 2) {
        std.debug.print("usage: geodec <GQL text> [--json-param name json] [--server host:port] [--process /path/to/geoded] [--page-size N] [--pull-all] [--extra-pull N] [--format txt|json] [--begin] [--commit|--rollback] [--server-arg <arg>]...\n", .{});
        std.debug.print("\nNote: v0.16.0 uses QUIC+TLS by default. TCP has been removed.\n", .{});
        return;
    }
    const text: []const u8 = argv[1];
    var server_address: []const u8 = "127.0.0.1";
    var server_port: u16 = 8443; // v0.16.0: Default QUIC port
    var param_name: ?[]const u8 = null;
    var param_json: ?[]const u8 = null;
    var do_begin = false;
    var do_commit = false;
    var do_rollback = false;
    var page_size: usize = 1; // small default to produce multiple pages in multi-row results
    var pull_all = true; // pull all pages by default for JSON mode
    var i: usize = 2;
    var extra_pulls: usize = 0;
    var fmt_txt = false;
    var use_quic = true; // v0.16.0: QUIC is default and only network transport
    var log_level_arg: ?[]const u8 = null;
    var use_stdio = false;

    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--test-wal-skip-ratio")) {
            if (i + 1 < argv.len) {
                test_wal_skip_ratio = argv[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) break;
            const server_str = argv[i + 1];
            // Parse host:port for QUIC
            if (std.mem.lastIndexOfScalar(u8, server_str, ':')) |colon| {
                server_address = server_str[0..colon];
                server_port = std.fmt.parseInt(u16, server_str[colon + 1 ..], 10) catch 8443;
            } else {
                server_address = server_str;
            }
            use_quic = true;
            use_stdio = false;
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--process")) {
            // Process mode for local testing
            if (i + 1 >= argv.len) break;
            use_stdio = true;
            use_quic = false;
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--json-param")) {
            if (i + 2 >= argv.len) break;
            param_name = argv[i + 1];
            param_json = argv[i + 2];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--page-size")) {
            if (i + 1 >= argv.len) break;
            page_size = std.fmt.parseInt(usize, argv[i + 1], 10) catch 1000;
            if (page_size == 0) page_size = 1000;
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--pull-all")) {
            pull_all = true;
        } else if (std.mem.eql(u8, argv[i], "--format")) {
            if (i + 1 >= argv.len) break;
            const f = argv[i + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) fmt_txt = true;
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--begin")) {
            do_begin = true;
        } else if (std.mem.eql(u8, argv[i], "--commit")) {
            do_commit = true;
        } else if (std.mem.eql(u8, argv[i], "--rollback")) {
            do_rollback = true;
        } else if (std.mem.eql(u8, argv[i], "--extra-pull")) {
            if (i + 1 >= argv.len) break;
            extra_pulls = std.fmt.parseInt(usize, argv[i + 1], 10) catch 0;
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--log-level")) {
            if (i + 1 < argv.len) {
                log_level_arg = argv[i + 1];
                i += 1;
            }
        }
    }

    if (log_level_arg) |lla| logger.setLevel(logger.parseLevel(lla));
    logger.info("client.start", .{.{ .key = "level", .value = log_level_arg orelse "info" }});

    // Collect extra server args for stdio-spawned server (e.g., --data_dir, feature flags)
    var server_extra_args = std.ArrayList([]const u8).initCapacity(gpa, 0) catch return error.OutOfMemory;
    defer server_extra_args.deinit(gpa);

    // Re-scan argv for passthrough flags (supports repetition)
    var i_scan: usize = 1;
    while (i_scan < argv.len) : (i_scan += 1) {
        if (std.mem.eql(u8, argv[i_scan], "--server-arg") and i_scan + 1 < argv.len) {
            // store next token as a single arg; caller may pass flag name and value via two occurrences
            server_extra_args.append(gpa, argv[i_scan + 1]) catch return error.OutOfMemory;
            i_scan += 1;
        }
    }

    if (use_quic) {
        // Use QUIC transport with graceful fallback to stdio if connection fails
        var client = quic_transport.QuicClient.init(gpa);
        defer client.deinit();

        var connected = true;
        client.connect(server_address, server_port) catch |err| {
            connected = false;
            logger.warn("client.quic_connect_failed", .{.{ .key = "err", .value = @errorName(err) }});
        };

        if (connected) {
            const stream = try client.getStream();
            defer stream.deinit();

            // Send HELLO and consume server capabilities response
            try stream.writeAll("{{\"type\":\"HELLO\",\"client_name\":\"geodec\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}}\n");
            const _hello_ack = try stream.readLine(1 << 16);
            defer gpa.free(_hello_ack);

            if (do_begin) {
                try stream.writeAll("{{\"type\":\"BEGIN\"}}\n");
                const ack = try stream.readLine(1 << 16);
                defer gpa.free(ack);
                if (std.mem.indexOf(u8, ack, "\"type\":\"ERROR\"") != null) {
                    const stderr_file = getStdErr();
                    try stderr_file.writeAll(ack);
                    try stderr_file.writeAll("\n");
                    std.process.exit(2);
                }
            }

            // RUN_GQL
            if (param_name) |pn| {
                const pj = param_json orelse "{}";
                const msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\",\"params\":{{\"{s}\":{s}}}}}\n", .{ text, pn, pj });
                defer gpa.free(msg);
                try stream.writeAll(msg);
            } else {
                const msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}}\n", .{text});
                defer gpa.free(msg);
                try stream.writeAll(msg);
            }

            // Read SCHEMA response
            const line1 = try stream.readLine(1 << 16);
            defer gpa.free(line1);

            if (std.mem.indexOf(u8, line1, "\"type\":\"ERROR\"") != null) {
                const stderr_file = getStdErr();
                try stderr_file.writeAll(line1);
                try stderr_file.writeAll("\n");
                std.process.exit(2);
            }

            const stdout_file = getStdOut();
            if (!fmt_txt) {
                try stdout_file.writeAll(line1);
                try stdout_file.writeAll("\n");
            } else {
                // Minimal text mode: parse SCHEMA columns and emit header like stdio path
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, line1, .{}) catch {
                    const stderr_file = getStdErr();
                    try stderr_file.writeAll("schema parse error\n");
                    std.process.exit(2);
                };
                defer parsed.deinit();
                if (parsed.value != .object) std.process.exit(2);
                const robj = parsed.value.object;
                const result_v = robj.get("result") orelse std.process.exit(2);
                if (result_v != .object) std.process.exit(2);
                const cols_v = result_v.object.get("columns") orelse std.process.exit(2);
                if (cols_v != .array) std.process.exit(2);
                const arr = cols_v.array.items;
                var hi: usize = 0;
                while (hi < arr.len) : (hi += 1) {
                    const cv = arr[hi];
                    if (cv != .object) continue;
                    const name_v = cv.object.get("name") orelse std.process.exit(2);
                    if (name_v != .string) std.process.exit(2);
                    if (hi > 0) try stdout_file.writeAll("\t");
                    try stdout_file.writeAll(name_v.string);
                }
                try stdout_file.writeAll("\n");
            }

            // Always request one page (mirror stdio behavior)
            if (!fmt_txt) {
                const pull_msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"PULL\",\"request_id\":1,\"page_size\":{d}}}\n", .{page_size});
                defer gpa.free(pull_msg);
                try stream.writeAll(pull_msg);
                const response = try stream.readLine(1 << 16);
                defer gpa.free(response);
                try stdout_file.writeAll(response);
                try stdout_file.writeAll("\n");
                // Optional pagination: keep pulling when requested and response indicates more pages
                if (pull_all) {
                    var keep = std.mem.indexOf(u8, response, "\"final\":false") != null;
                    while (keep) {
                        const pull_more = try std.fmt.allocPrint(gpa, "{{\"type\":\"PULL\",\"request_id\":1,\"page_size\":{d}}}\n", .{page_size});
                        defer gpa.free(pull_more);
                        try stream.writeAll(pull_more);
                        const more = try stream.readLine(1 << 16);
                        defer gpa.free(more);
                        try stdout_file.writeAll(more);
                        try stdout_file.writeAll("\n");
                        keep = std.mem.indexOf(u8, more, "\"final\":false") != null;
                    }
                }
            } else {
                const pull_msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"PULL\",\"request_id\":1,\"page_size\":{d}}}\n", .{page_size});
                defer gpa.free(pull_msg);
                try stream.writeAll(pull_msg);
                const response = try stream.readLine(1 << 16);
                defer gpa.free(response);
                // Text formatting of rows similar to stdio path
                const parsedB = std.json.parseFromSlice(std.json.Value, gpa, response, .{}) catch {
                    const stderr_file = getStdErr();
                    try stderr_file.writeAll("bindings parse error\n");
                    std.process.exit(2);
                };
                defer parsedB.deinit();
                if (parsedB.value != .object) std.process.exit(2);
                const broot = parsedB.value.object;
                const resultB = broot.get("result") orelse std.process.exit(2);
                if (resultB != .object) std.process.exit(2);
                const rows_v = resultB.object.get("rows") orelse std.process.exit(2);
                if (rows_v != .array) std.process.exit(2);
                const rows_arr = rows_v.array.items;
                // We need schema column order; parse from prior schema line
                const parsedS = std.json.parseFromSlice(std.json.Value, gpa, line1, .{}) catch std.process.exit(2);
                defer parsedS.deinit();
                const resultS = parsedS.value.object.get("result") orelse std.process.exit(2);
                const colsS = resultS.object.get("columns") orelse std.process.exit(2);
                const colsArr = colsS.array.items;
                var ri: usize = 0;
                while (ri < rows_arr.len) : (ri += 1) {
                    const rv = rows_arr[ri];
                    if (rv != .object) continue;
                    var cj: usize = 0;
                    while (cj < colsArr.len) : (cj += 1) {
                        if (cj > 0) try stdout_file.writeAll("\t");
                        const cv = colsArr[cj];
                        const name_v = cv.object.get("name") orelse std.process.exit(2);
                        const key = name_v.string;
                        const val = rv.object.get(key) orelse std.json.Value{ .null = {} };
                        switch (val) {
                            .string => |s| try stdout_file.writeAll(s),
                            .integer => |iv| {
                                var num_buf: [64]u8 = undefined;
                                const ns = std.fmt.bufPrint(&num_buf, "{d}", .{iv}) catch "0";
                                try stdout_file.writeAll(ns);
                            },
                            .bool => |bv| try stdout_file.writeAll(if (bv) "true" else "false"),
                            .null => try stdout_file.writeAll("null"),
                            else => try stdout_file.writeAll("null"),
                        }
                    }
                    try stdout_file.writeAll("\n");
                }
            }

            if (do_commit) {
                try stream.writeAll("{{\"type\":\"COMMIT\"}}\n");
                const ack = try stream.readLine(1 << 16);
                defer gpa.free(ack);
            } else if (do_rollback) {
                try stream.writeAll("{{\"type\":\"ROLLBACK\"}}\n");
                const ack = try stream.readLine(1 << 16);
                defer gpa.free(ack);
            }

            return;
        }
        // If not connected, fall through to stdio mode
    }

    // Fallback to stdio mode for backward compatibility
    var server_path: []const u8 = "./zig-out/bin/geoded";
    if (use_stdio) {
        // Use the server address as the path if it looks like a path
        if (std.mem.startsWith(u8, server_address, "./") or std.mem.startsWith(u8, server_address, "/")) {
            server_path = server_address;
        }
    }

    // Spawn server
    // Build server args
    var server_args = std.ArrayList([]const u8).initCapacity(gpa, 4 + server_extra_args.items.len) catch return error.OutOfMemory;
    defer server_args.deinit(gpa);
    try server_args.append(gpa, server_path);
    if (test_wal_skip_ratio) |val| {
        try server_args.append(gpa, "--test-wal-skip-ratio");
        try server_args.append(gpa, val);
    }
    // Append any passthrough server args after binary path
    var sai: usize = 0;
    while (sai < server_extra_args.items.len) : (sai += 1) {
        try server_args.append(gpa, server_extra_args.items[sai]);
    }

    var child = std.process.Child.init(server_args.items, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    // Optionally capture server stderr when requested (for tests/telemetry); otherwise inherit to avoid blocking
    const capture_server_stderr = std.posix.getenv("GEODE_CAPTURE_SERVER_STDERR") != null;
    child.stderr_behavior = if (capture_server_stderr) .Pipe else .Inherit;
    try child.spawn();
    const child_stdin_file = child.stdin.?; // use direct file writes (simpler API under Zig 0.15)

    // Send HELLO (no ack expected in stdio mode)
    try child_stdin_file.writeAll("{\"type\":\"HELLO\",\"client_name\":\"geodec\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}\n");
    if (do_begin) {
        try child_stdin_file.writeAll("{\"type\":\"BEGIN\"}\n");
        const ack = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(ack);
        if (std.mem.indexOf(u8, ack, "\"type\":\"ERROR\"") != null) {
            const stderr_file = getStdErr();
            try stderr_file.writeAll(ack);
            try stderr_file.writeAll("\n");
            if (child.stdin) |s| {
                s.close();
                child.stdin = null;
            }
            _ = try child.wait();
            std.process.exit(2);
        }
    }
    // RUN_GQL
    if (param_name) |pn| {
        const pj = param_json orelse "{}";
        try child_stdin_file.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"");
        try child_stdin_file.writeAll(text);
        try child_stdin_file.writeAll("\",\"params\":{\"");
        try child_stdin_file.writeAll(pn);
        try child_stdin_file.writeAll("\":");
        try child_stdin_file.writeAll(pj);
        try child_stdin_file.writeAll("}}\n");
    } else {
        try child_stdin_file.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"");
        try child_stdin_file.writeAll(text);
        try child_stdin_file.writeAll("\"}\n");
    }

    // Read first response; if ERROR, surface and exit 2
    const line1 = readLineAlloc(gpa, child.stdout.?, 1 << 16) catch |e| {
        if (e == error.EndOfStream) {
            // Server closed before emitting any response (treat as error)
            const stderr_file = getStdErr();
            stderr_file.writeAll("no response from server\n") catch {};
            std.process.exit(2);
        }
        return e;
    };
    defer gpa.free(line1);
    if (std.mem.indexOf(u8, line1, "\"type\":\"ERROR\"") != null) {
        const stderr_file = getStdErr();
        try stderr_file.writeAll(line1);
        try stderr_file.writeAll("\n");
        if (child.stdin) |s| {
            s.close();
            child.stdin = null;
        }
        _ = try child.wait();
        std.process.exit(2);
    }

    // Print or translate SCHEMA line and request PULL (unless EXPLAIN mode)
    var schema_columns: [][]const u8 = &.{};
    var ps_buf: [32]u8 = undefined;
    var last_response_final_false = false;
    const is_explain = std.mem.startsWith(u8, text, "EXPLAIN");
    if (!fmt_txt) {
        const out_file = getStdOut();
        try out_file.writeAll(line1);
        try out_file.writeAll("\n");
    } else {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, line1, .{}) catch {
            const stderr_file = getStdErr();
            try stderr_file.writeAll("schema parse error\n");
            try stderr_file.writeAll("schema parse error\n");
            std.process.exit(2);
        };
        defer parsed.deinit();
        if (parsed.value != .object) std.process.exit(2);
        const robj = parsed.value.object;
        const result_v = robj.get("result") orelse std.process.exit(2);
        if (result_v != .object) std.process.exit(2);
        const cols_v = result_v.object.get("columns") orelse std.process.exit(2);
        if (cols_v != .array) std.process.exit(2);
        const arr = cols_v.array.items;
        schema_columns = try gpa.alloc([]const u8, arr.len);
        var ci: usize = 0;
        while (ci < arr.len) : (ci += 1) {
            const cv = arr[ci];
            if (cv != .object) std.process.exit(2);
            const name_v = cv.object.get("name") orelse std.process.exit(2);
            if (name_v != .string) std.process.exit(2);
            schema_columns[ci] = try gpa.dupe(u8, name_v.string);
        }
        const out_file = getStdOut();
        var hi: usize = 0;
        while (hi < schema_columns.len) : (hi += 1) {
            if (hi > 0) try out_file.writeAll("\t");
            try out_file.writeAll(schema_columns[hi]);
        }
        try out_file.writeAll("\n");
    }
    if (is_explain and !fmt_txt) {
        // Server emits SCHEMA then EXPLAIN immediately; consume EXPLAIN now and skip PULL
        const explain_line = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(explain_line);
        const out_file = getStdOut();
        try out_file.writeAll(explain_line);
        try out_file.writeAll("\n");
    } else {
        // Request first page
        try child_stdin_file.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":");
        const ps = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
        try child_stdin_file.writeAll(ps);
        try child_stdin_file.writeAll("}\n");
        const line2 = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(line2);
        if (!fmt_txt) {
            const out_file = getStdOut();
            try out_file.writeAll(line2);
            try out_file.writeAll("\n");
            last_response_final_false = std.mem.indexOf(u8, line2, "\"final\":false") != null;
        } else {
            const parsedB = std.json.parseFromSlice(std.json.Value, gpa, line2, .{}) catch {
                const stderr_file = getStdErr();
                try stderr_file.writeAll("bindings parse error\n");
                try stderr_file.writeAll("bindings parse error\n");
                std.process.exit(2);
            };
            defer parsedB.deinit();
            if (parsedB.value != .object) std.process.exit(2);
            const broot = parsedB.value.object;
            const resultB = broot.get("result") orelse std.process.exit(2);
            if (resultB != .object) std.process.exit(2);
            const rows_v = resultB.object.get("rows") orelse std.process.exit(2);
            if (rows_v != .array) std.process.exit(2);
            const rows_arr = rows_v.array.items;
            const out_file = getStdOut();
            var ri: usize = 0;
            while (ri < rows_arr.len) : (ri += 1) {
                const rv = rows_arr[ri];
                if (rv != .object) continue;
                var cj: usize = 0;
                while (cj < schema_columns.len) : (cj += 1) {
                    if (cj > 0) try out_file.writeAll("\t");
                    const key = schema_columns[cj];
                    const val = rv.object.get(key) orelse std.json.Value{ .null = {} };
                    switch (val) {
                        .string => |s| try out_file.writeAll(s),
                        .integer => |iv| {
                            var num_buf: [64]u8 = undefined;
                            const ns = std.fmt.bufPrint(&num_buf, "{d}", .{iv}) catch "0";
                            try out_file.writeAll(ns);
                        },
                        .bool => |bv| try out_file.writeAll(if (bv) "true" else "false"),
                        .null => try out_file.writeAll("null"),
                        else => try out_file.writeAll("null"),
                    }
                }
                try out_file.writeAll("\n");
            }

            // Text mode: continue pulling until final true (or missing treated as final)
            var is_final = true;
            if (resultB.object.get("final")) |fv| {
                if (fv == .bool) {
                    is_final = fv.bool;
                } else {
                    is_final = true;
                }
            }
            last_response_final_false = !is_final;
            while (!is_final) {
                try child_stdin_file.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":");
                const ps_more = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                try child_stdin_file.writeAll(ps_more);
                try child_stdin_file.writeAll("}\n");
                const more = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
                defer gpa.free(more);

                const parsedMore = std.json.parseFromSlice(std.json.Value, gpa, more, .{}) catch {
                    const stderr_file = getStdErr();
                    try stderr_file.writeAll("bindings parse error\n");
                    std.process.exit(2);
                };
                defer parsedMore.deinit();
                if (parsedMore.value != .object) std.process.exit(2);
                const brootM = parsedMore.value.object;
                const resultM = brootM.get("result") orelse std.process.exit(2);
                if (resultM != .object) std.process.exit(2);
                const rowsM_v = resultM.object.get("rows") orelse std.process.exit(2);
                if (rowsM_v != .array) std.process.exit(2);
                const rowsM_arr = rowsM_v.array.items;
                var rmi: usize = 0;
                while (rmi < rowsM_arr.len) : (rmi += 1) {
                    const rv = rowsM_arr[rmi];
                    if (rv != .object) continue;
                    var cj2: usize = 0;
                    while (cj2 < schema_columns.len) : (cj2 += 1) {
                        if (cj2 > 0) try out_file.writeAll("\t");
                        const key = schema_columns[cj2];
                        const val = rv.object.get(key) orelse std.json.Value{ .null = {} };
                        switch (val) {
                            .string => |s| try out_file.writeAll(s),
                            .integer => |iv| {
                                var num_buf: [64]u8 = undefined;
                                const ns = std.fmt.bufPrint(&num_buf, "{d}", .{iv}) catch "0";
                                try out_file.writeAll(ns);
                            },
                            .bool => |bv| try out_file.writeAll(if (bv) "true" else "false"),
                            .null => try out_file.writeAll("null"),
                            else => try out_file.writeAll("null"),
                        }
                    }
                    try out_file.writeAll("\n");
                }
                is_final = true;
                if (resultM.object.get("final")) |fv2| {
                    if (fv2 == .bool) {
                        is_final = fv2.bool;
                    } else {
                        is_final = true;
                    }
                }
            }
        }
    }

    if (pull_all and !fmt_txt and !is_explain) {
        // Continue pulling while final:false appears
        var keep = last_response_final_false;
        while (keep) {
            try child_stdin_file.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":");
            const ps_more = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
            try child_stdin_file.writeAll(ps_more);
            try child_stdin_file.writeAll("}\n");
            const more = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
            defer gpa.free(more);
            const out_file = getStdOut();
            try out_file.writeAll(more);
            try out_file.writeAll("\n");
            keep = std.mem.indexOf(u8, more, "\"final\":false") != null;
        }
    }

    var ep: usize = 0;
    while (ep < extra_pulls and !fmt_txt and !is_explain) : (ep += 1) {
        try child_stdin_file.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":");
        const ps_extra = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
        try child_stdin_file.writeAll(ps_extra);
        try child_stdin_file.writeAll("}\n");
        const extra = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(extra);
        const out_file = getStdOut();
        try out_file.writeAll(extra);
        try out_file.writeAll("\n");
    }

    // Flush buffered writes before waiting on further responses
    // no buffered writer now
    if (do_commit) {
        try child_stdin_file.writeAll("{\"type\":\"COMMIT\"}\n");
        const ackc = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(ackc);
        if (std.mem.indexOf(u8, ackc, "\"type\":\"ERROR\"") != null) {
            const stderr_file = getStdErr();
            try stderr_file.writeAll(ackc);
            try stderr_file.writeAll("\n");
            if (child.stdin) |s| {
                s.close();
                child.stdin = null;
            }
            _ = try child.wait();
            std.process.exit(2);
        }
    } else if (do_rollback) {
        try child_stdin_file.writeAll("{\"type\":\"ROLLBACK\"}\n");
        const ackr = try readLineAlloc(gpa, child.stdout.?, 1 << 16);
        defer gpa.free(ackr);
        if (std.mem.indexOf(u8, ackr, "\"type\":\"ERROR\"") != null) {
            const stderr_file = getStdErr();
            try stderr_file.writeAll(ackr);
            try stderr_file.writeAll("\n");
            if (child.stdin) |s| {
                s.close();
                child.stdin = null;
            }
            _ = try child.wait();
            std.process.exit(2);
        }
    }

    // If capturing server stderr, drain and forward to our own stderr before shutdown
    if (capture_server_stderr) {
        if (child.stderr) |serr| {
            const data = serr.readToEndAlloc(gpa, 1 << 20) catch &[_]u8{};
            if (data.len > 0) {
                const stderr_file = getStdErr();
                _ = stderr_file.write(data) catch {};
            }
            serr.close();
            child.stderr = null;
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
