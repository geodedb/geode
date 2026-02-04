const std = @import("std");

// E2E: snapshot isolation should prevent seeing inserted rows mid-transaction (no phantoms)

test "protocol MVCC phantom reads prevented under SI" {
    const gpa = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    var child = std.process.Child.init(&[_][]const u8{exe}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        // T1 begin
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        // T1 initial read
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"SELECT count(v) AS c FROM SCAN_VALUES()\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":10}\n");
        // T2 autocommit insert, then commit
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"INSERT VALUE 'x'\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":2,\"page_size\":10}\n");
        try stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        // T1 second read in same txn
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"SELECT count(v) AS c FROM SCAN_VALUES()\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":3,\"page_size\":10}\n");

        stdin.close();
        child.stdin = null;
    }
    var out = std.ArrayList(u8).initCapacity(gpa, 0);
    defer out.deinit(gpa);
    if (child.stdout) |so| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
    }
    _ = child.wait() catch {};
    const lines = std.mem.splitScalar(u8, out.items, '\n');
    var read1: ?usize = null;
    var read2: ?usize = null;
    var phase: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null) {
            // extract c value
            if (std.mem.indexOf(u8, line, "\"rows\":") != null) {
                // parse row object {"c":X}
                if (std.mem.indexOf(u8, line, "{\"c\":")) |p| {
                    var i = p + 5;
                    while (i < line.len and (line[i] < '0' or line[i] > '9')) i += 1;
                    const start = i;
                    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
                    if (start < i) {
                        const parsed = std.fmt.parseInt(usize, line[start..i], 10) catch 0;
                        switch (phase) {
                            0 => {
                                read1 = parsed;
                            },
                            1 => {
                                read2 = parsed;
                            },
                            else => {},
                        }
                        phase += 1;
                    }
                }
            }
        }
    }
    // Under SI, T1 should see same initial and second count = 0 rows
    try std.testing.expect(read1 == 0);
    try std.testing.expect(read2 == 0);
}

// CANARY wrapper providing named test for scanner linkage
test "TestCANARY_REQ_GQL_013_SSIPhantomPrevention" {
    // Re-run the same scenario to ensure determinism and provide CANARY evidence
    const gpa = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    var child = std.process.Child.init(&[_][]const u8{exe}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"SELECT count(v) AS c FROM SCAN_VALUES()\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":10}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"INSERT VALUE 'x'\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":2,\"page_size\":10}\n");
        try stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"SELECT count(v) AS c FROM SCAN_VALUES()\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":3,\"page_size\":10}\n");
        stdin.close();
        child.stdin = null;
    }
    var out = std.ArrayList(u8).initCapacity(gpa, 0);
    defer out.deinit(gpa);
    if (child.stdout) |so| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
    }
    _ = child.wait() catch {};
    const lines = std.mem.splitScalar(u8, out.items, '\n');
    var read1: ?usize = null;
    var read2: ?usize = null;
    var phase: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null) {
            if (std.mem.indexOf(u8, line, "\"rows\":") != null) {
                if (std.mem.indexOf(u8, line, "{\"c\":")) |p| {
                    var i = p + 5;
                    while (i < line.len and (line[i] < '0' or line[i] > '9')) i += 1;
                    const start = i;
                    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
                    if (start < i) {
                        const parsed = std.fmt.parseInt(usize, line[start..i], 10) catch 0;
                        switch (phase) {
                            0 => read1 = parsed,
                            1 => read2 = parsed,
                            else => {},
                        }
                        phase += 1;
                    }
                }
            }
        }
    }
    try std.testing.expect(read1 == 0);
    try std.testing.expect(read2 == 0);
}
