const std = @import("std");
const builtin = @import("builtin");

// variance_envelope_guard.zig
// Policy guard: Ensures the README variance guard qualifier (e.g. "Variance Guards Landed: 70+")
// matches / is justified by the actual count of *VarianceEnvelope aspects in status.csv.
//
// Usage:
//   zig run scripts/variance_envelope_guard.zig -- \
//        --status status.csv --readme README.md --min 70 \
//        [--require-phrase]
//
// Exit codes:
//   0 success (policy satisfied)
//   2 policy violation (count below min OR README phrase mismatch when required)
//   1 other error (I/O, arg parse)
//
// Output: JSON summary line to stdout
//   {"type":"variance_envelope_guard","count":N,"min":M,"ok":bool,"readme_phrase_found":bool,
//    "readme_ok":bool,"status":"success"|"failure"}
//
// Detection rules:
//   - Count distinct CSV rows whose aspect field contains the token "VarianceEnvelope".
//   - README phrase pattern searched: "Variance Guards Landed" followed by ':' or '-' then whitespace then
//     either an integer or an integer with a trailing '+' (e.g. 70+). If a '+' form is present the numeric
//     portion is considered a floor (>=). If plain integer, it must equal the counted value.
//   - If --require-phrase is given and the phrase is absent -> violation.
//
// Rationale:
//   Prevents silent drift between qualitative README claim ("70+") and quantitative evidence ledger.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    var status_path: ?[]const u8 = null;
    var readme_path: ?[]const u8 = null;
    var min_required: usize = 0;
    var require_phrase = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--status")) {
            status_path = args.next() orelse return failUsage("--status requires a path");
        } else if (std.mem.eql(u8, arg, "--readme")) {
            readme_path = args.next() orelse return failUsage("--readme requires a path");
        } else if (std.mem.eql(u8, arg, "--min")) {
            const s = args.next() orelse return failUsage("--min requires an integer");
            min_required = try std.fmt.parseUnsigned(usize, s, 10);
        } else if (std.mem.eql(u8, arg, "--require-phrase")) {
            require_phrase = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return failUsageFmt("unknown flag: {s}", .{arg});
        }
    }

    if (status_path == null or readme_path == null) {
        return failUsage("--status and --readme are required");
    }

    const count = try countVarianceEnvelopes(status_path.?);
    const phrase_info = try scanReadme(alloc, readme_path.?);

    var readme_ok = true;
    if (phrase_info.found) {
        if (phrase_info.has_plus) {
            if (count < phrase_info.value) readme_ok = false;
        } else {
            if (count != phrase_info.value) readme_ok = false;
        }
    } else if (require_phrase) {
        readme_ok = false;
    }

    const min_ok = if (min_required == 0) true else count >= min_required;
    const overall_ok = min_ok and readme_ok;

    // Emit JSON summary

    var out_file = getStdOut();
    var json_buf: [512]u8 = undefined;
    const rendered = std.fmt.bufPrint(&json_buf, "{{\"type\":\"variance_envelope_guard\",\"count\":{d},\"min\":{d},\"ok\":{s},\"readme_phrase_found\":{s},\"readme_ok\":{s},\"status\":\"{s}\"}}\n", .{ count, min_required, if (overall_ok) "true" else "false", if (phrase_info.found) "true" else "false", if (readme_ok) "true" else "false", if (overall_ok) "success" else "failure" }) catch |e| switch (e) {
        error.NoSpaceLeft => &json_buf,
        else => return e,
    };
    out_file.writeAll(rendered) catch {};

    if (!overall_ok) std.process.exit(2);
}

fn getStdErr() std.Io.File {
    return if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable, .flags = .{ .nonblocking = false } }
    else
        std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
}

fn getStdOut() std.Io.File {
    return if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable, .flags = .{ .nonblocking = false } }
    else
        std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
}

fn failUsage(msg: []const u8) noreturn {
    var stderr_file = getStdErr();
    stderr_file.writeAll("variance_envelope_guard: ") catch {};
    stderr_file.writeAll(msg) catch {};
    stderr_file.writeAll("\nUsage: --status <status.csv> --readme <README.md> --min <N> [--require-phrase]\n") catch {};
    std.process.exit(1);
}

fn failUsageFmt(comptime fmt: []const u8, args: anytype) noreturn {
    var stderr_file = getStdErr();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error";
    stderr_file.writeAll("variance_envelope_guard: ") catch {};
    stderr_file.writeAll(msg) catch {};
    stderr_file.writeAll("\nUsage: --status <status.csv> --readme <README.md> --min <N> [--require-phrase]\n") catch {};
    std.process.exit(1);
}

fn countVarianceEnvelopes(path: []const u8) !usize {
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close();
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(&read_buf);
    var accum = std.ArrayListUnmanaged(u8){};
    defer accum.deinit(std.heap.page_allocator);
    var count: usize = 0;
    var first = true;
    while (true) {
        const n = reader.read(&read_buf) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = read_buf[i];
            if (c == '\n') {
                const line = accum.items[0..accum.items.len];
                if (line.len != 0) {
                    if (first) {
                        first = false; // header
                    } else if (std.mem.indexOf(u8, line, "VarianceEnvelope")) |_| {
                        count += 1;
                    }
                }
                accum.clearRetainingCapacity();
            } else {
                accum.append(std.heap.page_allocator, c) catch return error.OutOfMemory;
            }
        }
    }
    if (accum.items.len > 0) { // final line without newline
        const line = accum.items[0..accum.items.len];
        if (!first) {
            if (std.mem.indexOf(u8, line, "VarianceEnvelope") != null) count += 1;
        }
    }
    return count;
}

const PhraseInfo = struct {
    found: bool = false,
    value: usize = 0,
    has_plus: bool = false,
};

fn scanReadme(alloc: std.mem.Allocator, path: []const u8) !PhraseInfo {
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(alloc, 2 * 1024 * 1024); // up to 2MB
    defer alloc.free(data);

    var info = PhraseInfo{};
    const needle = "Variance Guards Landed";
    if (std.mem.indexOf(u8, data, needle)) |idx| {
        // scan forward for pattern like ": 70+" or ": 72".
        const slice = data[idx..];
        if (std.mem.indexOf(u8, slice, ":")) |colon| {
            var i: usize = colon + 1;
            // skip whitespace and optional '-'
            while (i < slice.len and (slice[i] == ' ' or slice[i] == '\t' or slice[i] == '-')) : (i += 1) {}
            const start = i;
            while (i < slice.len and slice[i] >= '0' and slice[i] <= '9') : (i += 1) {}
            if (i > start) {
                const num_str = slice[start..i];
                const val = std.fmt.parseUnsigned(usize, num_str, 10) catch 0;
                var has_plus = false;
                if (i < slice.len and slice[i] == '+') has_plus = true;
                info.found = true;
                info.value = val;
                info.has_plus = has_plus;
            }
        }
    }
    return info;
}
