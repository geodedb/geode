const std = @import("std");

// Stable JSON schema for perf-bench result emission (M0.4).
//
// Every perf bench in this repo that wants to participate in the
// before/after comparator (M0.6) and perf-gate (M0.7) SHOULD emit a
// ResultDocument as JSON via writeDocument(). Field names are part of
// the stable contract — renaming a field requires updating the
// comparator + perf-gate in lockstep.

pub const ResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    variant: []const u8 = "default",
    measurement: []const u8,
    value: f64,
    value_stddev: f64 = 0,
    sample_count: usize,
    wall_time_ns: u64,
};

pub const ResultDocument = struct {
    generated_at_unix_s: i64,
    rows: []ResultRow,
};

/// Read a ResultDocument from `path`. Caller owns the returned Parsed
/// and must call .deinit() to free backing memory.
///
/// Uses `.alloc_always` so parsed strings are copied into the Parsed
/// arena (not aliased into the transient file bytes), letting the
/// caller drop those bytes after this function returns.
pub fn readDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !std.json.Parsed(ResultDocument) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(ResultDocument, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Serialise `doc` as indented JSON and write it to `path`, truncating
/// any existing file. The trailing newline mirrors the convention used
/// by benchmark_tde_overhead's stdout emitter.
pub fn writeDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    doc: ResultDocument,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    const json = try std.json.Stringify.valueAlloc(allocator, doc, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try file.writeStreamingAll(io, json);
    try file.writeStreamingAll(io, "\n");
}
