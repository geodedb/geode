const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");

// fed_latency_validate: Validate a single JSON line produced by fed_latency_aggregate.
// Checks for presence and basic numeric type of required fields.
// Exit code: 0 on success, 2 on validation failure, 1 on IO errors.
// Usage: cat agg.jsonl | fed_latency_validate  (reads first line only unless --all)
// Options: --all  validate every line from stdin/file
// Env:
//   FED_LATENCY_FORMAT=txt  -> emit human readable summary instead of JSON diagnostics
//   FED_VALIDATE_STRICT=1   -> treat missing optional fields as errors
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateSchemaValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateSchemaValidation; OWNER=federation; UPDATED=2025-09-26

const RequiredField = struct { name: []const u8 };
const NumericField = struct { name: []const u8 };

const required = [_]RequiredField{
    .{ .name = "aggregate" },
    .{ .name = "runs" },
    .{ .name = "promotion_ready" },
};

const numeric = [_]NumericField{
    .{ .name = "avg_cv" },
    .{ .name = "avg_trim_cv" },
    .{ .name = "avg_p95_mean_ratio" },
    .{ .name = "avg_outlier_ratio" },
    .{ .name = "median_cv" },
    .{ .name = "median_p95_mean_ratio" },
    .{ .name = "median_trim_cv" },
    .{ .name = "median_outlier_ratio" },
    .{ .name = "cv_q1" },
    .{ .name = "cv_q3" },
    .{ .name = "cv_iqr" },
    .{ .name = "cv_mad" },
    .{ .name = "max_cv" },
    .{ .name = "max_trim_cv" },
    .{ .name = "max_p95_mean_ratio" },
    .{ .name = "max_outlier_ratio" },
};

fn hasField(line: []const u8, field: []const u8) bool {
    return std.mem.indexOf(u8, line, field) != null;
}

fn isNumeric(line: []const u8, field: []const u8) bool {
    if (std.mem.indexOf(u8, line, field)) |idx| {
        const after = line[idx + field.len ..];
        var i: usize = 0;
        if (after.len == 0) return false;
        // Skip optional quote if any (should not be for numeric)
        while (i < after.len) : (i += 1) {
            const c = after[i];
            if (c == '-' or c == '+' or (c >= '0' and c <= '9') or c == '.') return true;
            if (c == '"' or c == '{' or c == '[') return false;
            if (c == ' ' or c == ':') continue;
            return false;
        }
    }
    return false;
}

fn makeKey(buf: *[64]u8, field: []const u8) []const u8 {
    var i: usize = 0;
    buf.* = undefined;
    buf.*[i] = '"';
    i += 1;
    const max_copy = if (buf.len > i + 2) buf.len - i - 2 else 0;
    const copy_len = @min(field.len, max_copy);
    @memcpy(buf.*[i .. i + copy_len], field[0..copy_len]);
    i += copy_len;
    buf.*[i] = '"';
    i += 1;
    buf.*[i] = ':';
    i += 1;
    return buf.*[0..i];
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var validate_all = false;
    var file_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--all")) validate_all = true else if (std.mem.eql(u8, a, "--file")) {
            if (args.next()) |p| file_path = p;
        }
    }

    var buf: [8192]u8 = undefined;
    var file_reader = blk: {
        if (file_path) |p| {
            const f = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), p, .{ .mode = .read_only }) catch return error.OpenFileFailed;
            break :blk f.reader(&buf);
        } else {
            const stdin_file: std.Io.File = if (builtin.os.tag == .windows)
                .{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch {
                    std.process.exit(1);
                } }
            else
                .{ .handle = std.posix.STDIN_FILENO };
            break :blk stdin_file.reader(&buf);
        }
    };

    var line_buf = try std.ArrayList(u8).initCapacity(allocator, 8192);
    defer line_buf.deinit(allocator);

    var total_lines: usize = 0;
    var failures: usize = 0;
    const strict_env = getEnvVarOwned(allocator, "FED_VALIDATE_STRICT") catch null;
    defer if (strict_env) |s| allocator.free(s);
    const strict = strict_env != null;

    while (true) {
        line_buf.clearRetainingCapacity();
        var saw_any = false;
        while (true) {
            var b: [1]u8 = undefined;
            const n = file_reader.interface.readSliceShort(&b) catch break;
            if (n == 0) break;
            saw_any = true;
            if (b[0] == '\n') break;
            try line_buf.append(allocator, b[0]);
        }
        if (!saw_any and line_buf.items.len == 0) break;
        total_lines += 1;
        const line = std.mem.trim(u8, line_buf.items, " \r\n\t");
        if (line.len == 0) continue;
        var local_fail = false;
        inline for (required) |rf| {
            var key_buf: [64]u8 = undefined;
            const k = makeKey(&key_buf, rf.name);
            if (!hasField(line, k)) local_fail = true;
        }
        inline for (numeric) |nf| {
            var key_buf: [64]u8 = undefined;
            const k = makeKey(&key_buf, nf.name);
            if (!hasField(line, k)) {
                if (strict) local_fail = true;
            } else if (!isNumeric(line, k)) {
                local_fail = true;
            }
        }
        if (local_fail) failures += 1;
        if (!validate_all) break; // only first line
    }

    const want_txt = blkfmt: {
        if (getEnvVarOwned(allocator, "FED_LATENCY_FORMAT")) |fmt| {
            defer allocator.free(fmt);
            if (std.mem.eql(u8, fmt, "txt")) break :blkfmt true;
        } else |_| {}
        break :blkfmt false;
    };

    if (want_txt) {
        var out_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&out_buf);
        try fbs.writer().print("FED_VALIDATE lines={d} failures={d} strict={s}\n", .{ total_lines, failures, if (strict) "yes" else "no" });
        const written = fbs.getWritten();
        const stdout = if (builtin.os.tag == .windows)
            std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
                std.process.exit(1);
            } }
        else
            std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
        try stdout.writeAll(written);
    } else {
        var out_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&out_buf);
        // Escape literal braces with doubling for Zig format string
        try fbs.writer().print("{{\"lines\":{d},\"failures\":{d},\"strict\":{s}}}\n", .{ total_lines, failures, if (strict) "true" else "false" });
        const written = fbs.getWritten();
        const stdout = if (builtin.os.tag == .windows)
            std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
                std.process.exit(1);
            } }
        else
            std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
        try stdout.writeAll(written);
    }

    if (failures > 0) std.process.exit(2);
}

test "fed_latency_validate_basic" {
    const sample = "{\"aggregate\":\"A\",\"runs\":5,\"promotion_ready\":true,\"avg_cv\":0.1,\"cv_q1\":0.05,\"cv_q3\":0.2,\"cv_iqr\":0.15,\"cv_mad\":0.01}\n";
    var fbs = std.io.fixedBufferStream(sample);
    // Just ensure reader compiles; do a tiny read.
    var r = fbs.reader();
    var tiny: [1]u8 = undefined;
    _ = r.read(&tiny) catch {};
}
