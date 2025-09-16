const std = @import("std");

// Test baseline transaction functionality: BEGIN/COMMIT/ROLLBACK
test "e2e: transaction baseline BEGIN/COMMIT/ROLLBACK" {
    const ally = std.testing.allocator;
    
    const exe_dir = try std.fs.cwd().realpathAlloc(ally, ".");
    defer ally.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(ally, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer ally.free(exe_path);
    
    var child = std.process.Child.init(&[_][]const u8{exe_path}, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    
    if (child.stdin) |stdin| {
        // Test successful transaction sequence
        var write_buf: [8192]u8 = undefined;
        try stdin.writer(&write_buf).writeAll("{\"type\":\"HELLO\",\"client_name\":\"test\",\"client_ver\":\"1.0\",\"wanted_conformance\":\"basic\"}\n");
        try stdin.writer(&write_buf).writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer(&write_buf).writeAll("{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS x\"}\n");
        try stdin.writer(&write_buf).writeAll("{\"type\":\"COMMIT\"}\n");
        
        // Test error case: BEGIN when already in transaction
        try stdin.writer(&write_buf).writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer(&write_buf).writeAll("{\"type\":\"BEGIN\"}\n"); // Should return error
        try stdin.writer(&write_buf).writeAll("{\"type\":\"ROLLBACK\"}\n");
        
        stdin.close();
    }
    
    var out_buf = std.ArrayList(u8).init(ally);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }
    
    _ = child.wait() catch {};
    const output = out_buf.items;
    
    // Verify successful BEGIN and COMMIT both return status_class 00000
    const success_count = std.mem.count(u8, output, "\"status_class\":\"00000\"");
    try std.testing.expect(success_count >= 4); // HELLO, BEGIN, RUN_GQL, COMMIT
    
    // Verify error case: second BEGIN should return error status_class 25000 (active txn)
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status_class\":\"25000\"") != null);
    
    // Verify TxnState diagnostic is present
    try std.testing.expect(std.mem.indexOf(u8, output, "TxnState") != null);
    
    // Verify additional_status contains TxnState
    try std.testing.expect(std.mem.indexOf(u8, output, "additional_status") != null or std.mem.indexOf(u8, output, "TxnState") != null);
}

// Test transaction rollback functionality
test "e2e: transaction rollback" {
    const ally = std.testing.allocator;
    
    const exe_dir = try std.fs.cwd().realpathAlloc(ally, ".");
    defer ally.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(ally, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer ally.free(exe_path);
    
    var child = std.process.Child.init(&[_][]const u8{exe_path}, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    
    if (child.stdin) |stdin| {
        // Test rollback sequence
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS x\"}\n");
        try stdin.writer().writeAll("{\"type\":\"ROLLBACK\"}\n");
        
        // Test error case: COMMIT when no active transaction
        try stdin.writer().writeAll("{\"type\":\"COMMIT\"}\n"); // Should return error
        
        try stdin.close();
    }
    
    var out_buf = std.ArrayList(u8).init(ally);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }
    
    _ = child.wait() catch {};
    const output = out_buf.items;
    
    // Verify successful BEGIN, RUN_GQL, and ROLLBACK return status_class 00000
    const success_count = std.mem.count(u8, output, "\"status_class\":\"00000\"");
    try std.testing.expect(success_count >= 3); // BEGIN, RUN_GQL, ROLLBACK
    
    // Verify error case: COMMIT without active transaction should return error
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status_class\":\"25000\"") != null or 
                          std.mem.indexOf(u8, output, "no active transaction") != null);
}

// Test transaction state management
test "e2e: transaction state management" {
    const ally = std.testing.allocator;
    
    const exe_dir = try std.fs.cwd().realpathAlloc(ally, ".");
    defer ally.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(ally, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer ally.free(exe_path);
    
    var child = std.process.Child.init(&[_][]const u8{exe_path}, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    
    if (child.stdin) |stdin| {
        // Test multiple transaction cycles
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"COMMIT\"}\n");
        
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"ROLLBACK\"}\n");
        
        // Should be able to start new transaction after previous one ended
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"COMMIT\"}\n");
        
        try stdin.close();
    }
    
    var out_buf = std.ArrayList(u8).init(ally);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }
    
    _ = child.wait() catch {};
    const output = out_buf.items;
    
    // All operations should succeed (6 operations: 3 BEGIN + 2 COMMIT + 1 ROLLBACK)
    const success_count = std.mem.count(u8, output, "\"status_class\":\"00000\"");
    try std.testing.expect(success_count >= 6);
    
    // Should not have any transaction state errors
    try std.testing.expect(std.mem.indexOf(u8, output, "already in transaction") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no active transaction") == null);
}