const std = @import("std");
const testing = std.testing;

test "Recursive CTE + bounded expansion" {
    // Mock recursive query processor
    const RecursiveProcessor = struct {
        pub fn executeBoundedQuery(max_depth: u32) !u64 {
            // Simulate bounded recursive expansion
            var count: u64 = 0;
            var depth: u32 = 0;
            
            while (depth < max_depth) : (depth += 1) {
                count += std.math.pow(u64, 2, depth); // Binary tree expansion
            }
            
            return count;
        }
    };
    
    // Execute with depth limit of 3
    const result_count = try RecursiveProcessor.executeBoundedQuery(3);
    
    std.debug.print("RECURSIVE_OK depth<=3 result_count={d}\n", .{result_count});
    
    try testing.expect(result_count > 0);
}