const std = @import("std");
const geode = @import("geode");

// Comprehensive fuzzing test for GQL parser robustness
// Tests various parser edge cases, malformed inputs, and stress scenarios

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read fuzzer input from stdin
    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(input);

    // Run the fuzzer
    fuzzParser(allocator, input) catch |err| {
        // Expected errors from malformed input
        switch (err) {
            error.UnexpectedToken,
            error.UnexpectedEOF,
            error.InvalidNumber,
            error.OutOfMemory,
            error.InvalidCharacter,
            error.InvalidUtf8,
            error.Overflow,
            => return, // These are expected, not crashes
            else => return err, // Unexpected error, propagate
        }
    };
}

fn fuzzParser(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test 1: Basic parsing
    _ = geode.parse(allocator, input, .{}) catch |err| switch (err) {
        error.UnexpectedToken,
        error.UnexpectedEOF,
        error.OutOfMemory,
        => return, // Expected
        else => return err,
    };

    // Test 2: Parse with different options
    const options = [_]geode.ParseOptions{
        .{}, // Default
        .{ .strict_order_keys = true },
        .{ .ident_order_only = true },
        .{ .forbid_orderby_calls = true },
        .{ .forbid_orderby_paths = true },
        .{ .ts_extensions = true },
        .{ .strict_order_keys = true, .ident_order_only = true },
    };

    for (options) |opt| {
        var result = geode.parse(allocator, input, opt) catch continue;
        defer result.deinit();

        // Try to use the parsed result
        if (result.program.statements.len > 0) {
            const stmt = result.program.statements[0];
            testStatement(allocator, stmt) catch continue;
        }
    }

    // Test 3: Stress test with repeated parsing
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var result = geode.parse(allocator, input, .{}) catch break;
        defer result.deinit();
    }

    // Test 4: Parse fragments and combinations
    testFragments(allocator, input) catch {};
}

fn testStatement(allocator: std.mem.Allocator, stmt: geode.ast.Statement) !void {
    switch (stmt) {
        .Query => |q| {
            // Test query components
            if (q.where_clause) |where| {
                _ = testExpression(allocator, where) catch {};
            }
            if (q.order_by) |ob| {
                for (ob.keys) |key| {
                    _ = testExpression(allocator, key.expr) catch {};
                }
            }
            // Test pattern matching
            for (q.match.chains) |chain| {
                for (chain.hops) |hop| {
                    _ = hop.left.name;
                    _ = hop.right.name;
                    _ = hop.rel.name;

                    // Test variable-length paths
                    if (hop.rel.min_len) |min| {
                        if (min > 1000000) return error.InvalidRange;
                    }
                    if (hop.rel.max_len) |max| {
                        if (max > 1000000) return error.InvalidRange;
                    }
                }
            }
        },
        .Union => |u| {
            _ = testStatement(allocator, .{ .Query = u.first }) catch {};
            for (u.tails) |tail| {
                _ = testStatement(allocator, .{ .Query = tail.query }) catch {};
            }
        },
        .CreateIndex => |ci| {
            // Test index creation parameters
            if (ci.properties.len > 100) return error.TooManyProperties;
            _ = ci.name;
            _ = ci.label;
        },
        .DropIndex => |di| {
            _ = di.name;
        },
        .Backup => |b| {
            if (b.path.len > 4096) return error.PathTooLong;
        },
        .Restore => |r| {
            if (r.path.len > 4096) return error.PathTooLong;
        },
        else => {},
    }
}

fn testExpression(allocator: std.mem.Allocator, expr: geode.ast.Expr) anyerror!void {
    _ = allocator;
    switch (expr) {
        .Ident => |id| {
            if (id.orig.len > 1024) return error.IdentifierTooLong;
        },
        .String => |s| {
            if (s.len > 1024 * 1024) return error.StringTooLong;
        },
        .Int => |i| {
            if (i > std.math.maxInt(i64) or i < std.math.minInt(i64)) {
                return error.IntegerOverflow;
            }
        },
        .List => |list| {
            if (list.len > 10000) return error.ListTooLarge;
            for (list) |item| {
                testExpression(allocator, item.*) catch continue;
            }
        },
        .Call => |call| {
            if (call.args.len > 100) return error.TooManyArguments;
            for (call.args) |arg| {
                testExpression(allocator, arg.*) catch continue;
            }
        },
        .BinOp => |binop| {
            testExpression(allocator, binop.lhs.*) catch {};
            testExpression(allocator, binop.rhs.*) catch {};
        },
        .UnaryOp => |unop| {
            testExpression(allocator, unop.arg.*) catch {};
        },
        else => {},
    }
}

fn testFragments(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test parsing fragments of the input
    const fragments = [_][]const u8{
        "MATCH ",
        "RETURN ",
        "WHERE ",
        "ORDER BY ",
        "LIMIT ",
        "UNION ",
        "CREATE INDEX ",
        "DROP INDEX ",
        "BACKUP TO ",
        "RESTORE FROM ",
    };

    for (fragments) |prefix| {
        // Test prefix + input
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, input });
        defer allocator.free(combined);

        _ = geode.parse(allocator, combined, .{}) catch continue;

        // Test input + suffix
        const suffixed = try std.fmt.allocPrint(allocator, "{s} {s}", .{ input, prefix });
        defer allocator.free(suffixed);

        _ = geode.parse(allocator, suffixed, .{}) catch continue;
    }

    // Test nested structures
    testNestedStructures(allocator, input) catch {};
}

fn testNestedStructures(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test deeply nested parentheses
    const nested_parens = try buildNested(allocator, "(", input, ")", 10);
    defer allocator.free(nested_parens);
    _ = geode.parse(allocator, nested_parens, .{}) catch {};

    // Test deeply nested function calls
    const nested_calls = try buildNested(allocator, "func(", input, ")", 10);
    defer allocator.free(nested_calls);
    _ = geode.parse(allocator, nested_calls, .{}) catch {};

    // Test complex UNION chains
    var union_chain = try std.fmt.allocPrint(allocator, "RETURN 1", .{});
    defer allocator.free(union_chain);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const new_chain = try std.fmt.allocPrint(allocator, "{s} UNION RETURN {d}", .{ union_chain, i });
        allocator.free(union_chain);
        union_chain = new_chain;
    }
    _ = geode.parse(allocator, union_chain, .{}) catch {};
}

fn buildNested(allocator: std.mem.Allocator, prefix: []const u8, content: []const u8, suffix: []const u8, depth: usize) ![]u8 {
    if (depth == 0) {
        return try allocator.dupe(u8, content);
    }

    var result = content;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const new_result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, result, suffix });
        if (i > 0) allocator.free(result);
        result = new_result;
    }
    return result;
}

// Edge case tests
fn testEdgeCases(allocator: std.mem.Allocator) !void {
    const edge_cases = [_][]const u8{
        // Empty and whitespace
        "",
        " ",
        "\n",
        "\t",
        "\r\n",

        // Special characters
        "MATCH (n) WHERE n.prop = '\\0'",
        "MATCH (n) WHERE n.prop = '\\'",
        "MATCH (n) WHERE n.prop = '\"'",

        // Unicode
        "MATCH (n) WHERE n.名前 = '値'",
        "MATCH (n) WHERE n.prop = '🦀'",
        "MATCH (n) WHERE n.prop = '\\u{1F980}'",

        // Large numbers
        "RETURN 999999999999999999999999999999",
        "RETURN -999999999999999999999999999999",
        "RETURN 1.23456789012345678901234567890",

        // Complex patterns
        "MATCH (a)-[*0..]->(b)",
        "MATCH (a)-[*999999]->(b)",
        "MATCH (a)-[*1..999999]->(b)",

        // Malformed queries
        "MATCH (",
        "MATCH (n",
        "MATCH (n)",
        "MATCH (n) RETURN",
        "MATCH (n) RETURN n.",
        "MATCH (n) WHERE",
        "MATCH (n) ORDER BY",
        "MATCH (n) LIMIT",

        // SQL injection attempts
        "MATCH (n) WHERE n.prop = ''; DROP TABLE nodes; --'",
        "MATCH (n) WHERE n.prop = '\\'; DROP TABLE nodes; --'",

        // Buffer overflow attempts
        "MATCH (n) WHERE n.prop = '" ++ ("A" ** 10000) ++ "'",

        // Nested structures
        "MATCH ((((((((((n))))))))))",
        "RETURN [[[[[[[[[[1]]]]]]]]]]",

        // Reserved words as identifiers
        "MATCH (MATCH) RETURN RETURN",
        "MATCH (WHERE) WHERE WHERE.WHERE = WHERE",
    };

    for (edge_cases) |case| {
        _ = geode.parse(allocator, case, .{}) catch continue;
    }
}
