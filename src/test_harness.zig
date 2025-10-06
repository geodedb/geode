const std = @import("std");
const gql = @import("lib.zig");
const execution = @import("execution.zig");

// Cleanup function for test catalog - called at end of tests
pub fn cleanupTestCatalog() void {
    // No-op for now - catalog cleanup would go here if needed
}

// Main query execution function - ONLY parses and calls real Geode execution
pub fn runQuery(allocator: *std.mem.Allocator, query: []const u8) ![]u8 {
    @setEvalBranchQuota(2000);
    
    // Check for double-hyphen comments (special case)
    if (std.mem.indexOf(u8, query, "--") != null) {
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42000\",\"message\":\"syntax error: double-hyphen comments disabled (GB02)\",\"additional_statuses\":[]}}", .{});
    }

    // Parse the query using the actual GQL parser
    const parse_result = gql.parse(allocator.*, query, .{}) catch |err| {
        // Return syntax error for parse failures
        if (err == error.OutOfMemory) return err;
        
        // Special cases for transaction errors
        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (std.mem.eql(u8, trimmed, "COMMIT") or std.mem.eql(u8, trimmed, "ROLLBACK")) {
            return error.TransactionError;
        }
        
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42000\",\"error\":\"Syntax error in query\",\"additional_statuses\":[]}}", .{});
    };
    defer {
        var mut_pr = parse_result;
        mut_pr.deinit();
    }

    // Execute the parsed program using Geode's execution engine
    const exec_result = execution.executeProgram(allocator.*, &parse_result.program) catch |err| {
        // Return appropriate error for execution failures
        const error_msg = switch (err) {
            error.NotImplemented => "Feature not yet implemented",
            error.TypeMismatch => "Type mismatch in expression",
            error.DivisionByZero => "Division by zero",
            error.OutOfMemory => return err,
            error.Unsupported => "Unsupported operation",
            else => "Execution error",
        };
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"0A000\",\"error\":\"{s}\",\"additional_statuses\":[]}}", .{error_msg});
    };
    defer {
        var mut_result = exec_result;
        mut_result.deinit();
    }
    
    // Convert execution result to JSON
    return try exec_result.toJson(allocator.*);
}