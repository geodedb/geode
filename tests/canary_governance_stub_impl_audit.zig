const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=StubImplAudit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_GovernanceStubImplAudit; OWNER=tooling; UPDATED=2026-11-14

fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".direnv") or
        std.mem.eql(u8, name, "docs") or
        std.mem.eql(u8, name, "vendor") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "bin") or
        std.mem.eql(u8, name, "clients") or
        std.mem.eql(u8, name, "certs") or
        std.mem.eql(u8, name, "data") or
        std.mem.eql(u8, name, "tools"); // tools contains scanner fixtures and examples
}

fn shouldScanFile(path: []const u8) bool {
    // Only Zig sources to avoid catching non-Zig fixtures.
    return std.mem.endsWith(u8, path, ".zig");
}

fn auditPath(alloc: std.mem.Allocator, root: std.fs.Dir, file_name: []const u8, display_path: []const u8, violations: *std.ArrayList([]const u8)) !void {
    if (!shouldScanFile(file_name)) return;
    const file = try root.openFile(file_name, .{});
    defer file.close();
    const buf = try file.readToEndAlloc(alloc, 8 * 1024 * 1024);
    defer alloc.free(buf);
    // Split into lines and search for forbidden patterns.
    var it = std.mem.splitScalar(u8, buf, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| : (line_no += 1) {
        // Reject explicit uppercase STUB markers
        if (std.mem.indexOf(u8, line, "STATUS=STUB")) |_| {
            const msg = try std.fmt.allocPrint(alloc, "{s}:{d}: STATUS=STUB not allowed", .{ display_path, line_no + 1 });
            try violations.append(msg);
            continue;
        }
        // Allow lowercase 'stub' in comments/documentation wording; only uppercase token is flagged.
        // For STATUS=IMPL, require presence of TEST= or BENCH= on the same line to be considered disclosed.
        if (std.mem.indexOf(u8, line, "STATUS=IMPL")) |idx| {
            _ = idx;
            const has_test = std.mem.indexOf(u8, line, "TEST=") != null;
            const has_bench = std.mem.indexOf(u8, line, "BENCH=") != null;
            if (!has_test and !has_bench) {
                const msg2 = try std.fmt.allocPrint(alloc, "{s}:{d}: STATUS=IMPL must include TEST= or BENCH= (undisclosed)", .{ display_path, line_no + 1 });
                try violations.append(msg2);
            }
        }
    }
}

fn walkAndAudit(alloc: std.mem.Allocator, root_dir: std.fs.Dir, prefix: []const u8, violations: *std.ArrayList([]const u8)) !void {
    var it = root_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(entry.name)) continue;
                const sub = try root_dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                const new_prefix = try std.fs.path.join(alloc, &.{ prefix, entry.name });
                defer alloc.free(new_prefix);
                try walkAndAudit(alloc, sub, new_prefix, violations);
            },
            .file => {
                const display_path = try std.fs.path.join(alloc, &.{ prefix, entry.name });
                defer alloc.free(display_path);
                try auditPath(alloc, root_dir, entry.name, display_path, violations) catch |e| switch (e) {
                    // Ignore non-utf8 or too-large errors gracefully
                    error.FileTooBig, error.StreamTooLong => {},
                    else => return e,
                };
            },
            else => {},
        }
    }
}

test "TestCANARY_REQ_GQL_010_GovernanceStubImplAudit" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var violations = std.ArrayList([]const u8).init(alloc);
    defer {
        for (violations.items) |v| alloc.free(v);
        violations.deinit();
    }

    var cwd = std.fs.cwd();
    try walkAndAudit(alloc, cwd, ".", &violations);
    if (violations.items.len > 0) {
        std.debug.print("Governance audit found {d} violation(s):\n", .{violations.items.len});
        for (violations.items) |v| std.debug.print(" - {s}\n", .{v});
        return error.GovernanceAuditFailed;
    }
}
