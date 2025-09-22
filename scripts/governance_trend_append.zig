const std = @import("std");
const builtin = @import("builtin");

// governance_trend_append.zig
// Appends a single JSON line with current evidence snapshot to badges/history.jsonl.
// Extracts counts (TESTED, BENCHED, IMPL, STUB, total, generated_at) from status.json.
// Creates directory badges/ if missing. Idempotent per exact generated_at (skips if an identical line exists).
// Exit codes: 0 success (appended or already present), 2 failure (missing status.json or parse error), 1 usage.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=TrendAppend; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_TrendAppend; OWNER=tooling; UPDATED=2025-09-22

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDERR_FILENO };
}
fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // No flags presently; future: --status, --out
    if (!fileExists("status.json")) return fail(2, "status.json missing");
    const data = std.fs.cwd().readFileAlloc(alloc, "status.json", 4 * 1024 * 1024) catch return fail(2, "read status.json failed");
    defer alloc.free(data);

    const counts = try parseCounts(alloc, data);
    defer counts.deinit(alloc);

    // Ensure badges directory exists
    _ = std.fs.cwd().makePath("badges") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return fail(2, "mkdir badges failed"),
    };

    // Open/create history file
    var hist_file = std.fs.cwd().createFile("badges/history.jsonl", .{ .read = true }) catch |e| switch (e) {
        error.PathAlreadyExists => std.fs.cwd().openFile("badges/history.jsonl", .{ .mode = .read_write }) catch return fail(2, "open history failed"),
        else => return fail(2, "create history failed"),
    };
    defer hist_file.close();

    // Scan existing lines for identical generated_at (quick heuristic); if found and counts identical -> exit 0 no-op.
    const existing = hist_file.readToEndAlloc(alloc, 2 * 1024 * 1024) catch |e| switch (e) {
        error.EndOfStream => alloc.alloc(u8, 0) catch unreachable,
        else => return fail(2, "read history failed"),
    };
    defer alloc.free(existing);
    var already: bool = false;
    if (existing.len > 0) {
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, counts.generated_at) != null and std.mem.indexOf(u8, line, "\"total\":") != null) {
                // Quick structural match; verify TESTED & BENCHED substrings
                if (std.mem.indexOf(u8, line, counts.tested_s) != null and std.mem.indexOf(u8, line, counts.benched_s) != null) {
                    already = true;
                    break;
                }
            }
        }
    }
    if (already) {
        const msg = "trend_append: already present\n";
        _ = getStdOut().write(msg) catch {};
        return;
    }

    // Append line
    try hist_file.seekFromEnd(0);
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{\"generated_at\":\"{s}\",\"total\":{d},\"tested\":{d},\"benched\":{d},\"impl\":{d},\"stub\":{d},\"coverage\":{d:.4},\"source\":\"status.json\"}\n", .{ counts.generated_at, counts.total, counts.tested, counts.benched, counts.impl_cnt, counts.stub_cnt, counts.coverage }) catch return fail(2, "format failed");
    _ = hist_file.write(line) catch return fail(2, "write history failed");
    _ = getStdOut().write("trend_append: appended\n") catch {};
}

fn fail(code: u8, msg: []const u8) noreturn {
    _ = getStdErr().write("trend_append: ") catch {};
    _ = getStdErr().write(msg) catch {};
    _ = getStdErr().write("\n") catch {};
    std.process.exit(code);
}

fn fileExists(p: []const u8) bool {
    _ = std.fs.cwd().statFile(p) catch return false;
    return true;
}

const Counts = struct {
    generated_at: []const u8,
    total: usize,
    tested: usize,
    benched: usize,
    impl_cnt: usize,
    stub_cnt: usize,
    coverage: f64,
    tested_s: []const u8,
    benched_s: []const u8,
    fn deinit(self: Counts, alloc: std.mem.Allocator) void {
        alloc.free(self.generated_at);
        alloc.free(self.tested_s);
        alloc.free(self.benched_s);
    }
};

fn parseCounts(a: std.mem.Allocator, data: []const u8) !Counts {
    const gen_key = "\"generated_at\": \"";
    const gi = std.mem.indexOf(u8, data, gen_key) orelse return error.ParseFail;
    const pos = gi + gen_key.len;
    var end = pos;
    while (end < data.len and data[end] != '"') : (end += 1) {}
    if (end >= data.len) return error.ParseFail;
    const gen_slice = try dup(a, data[pos..end]);
    var tested: usize = 0;
    _ = patternCount(data, "\"TESTED\": ", &tested);
    var benched: usize = 0;
    _ = patternCount(data, "\"BENCHED\": ", &benched);
    var impl_cnt: usize = 0;
    _ = patternCount(data, "\"IMPL\": ", &impl_cnt);
    var stub_cnt: usize = 0;
    _ = patternCount(data, "\"STUB\": ", &stub_cnt);
    const total = tested + benched + impl_cnt + stub_cnt;
    const coverage: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(tested + benched)) / @as(f64, @floatFromInt(total));
    const tested_s = try fmtNum(a, tested);
    const benched_s = try fmtNum(a, benched);
    return Counts{ .generated_at = gen_slice, .total = total, .tested = tested, .benched = benched, .impl_cnt = impl_cnt, .stub_cnt = stub_cnt, .coverage = coverage, .tested_s = tested_s, .benched_s = benched_s };
}

fn patternCount(data: []const u8, pat: []const u8, out: *usize) bool {
    if (std.mem.indexOf(u8, data, pat)) |p| {
        var i = p + pat.len;
        var val: usize = 0;
        var any = false;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            any = true;
            val = val * 10 + @as(usize, data[i] - '0');
        }
        if (any) {
            out.* = val;
            return true;
        }
    }
    return false;
}

fn dup(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try a.alloc(u8, s.len);
    @memcpy(buf, s);
    return buf;
}
fn fmtNum(a: std.mem.Allocator, v: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{d}", .{v});
}

pub const TrendAppendError = error{ParseFail};
