const std = @import("std");
const eval = @import("../src/eval.zig");
const diagnostics = @import("../src/diagnostics.zig");

test "division by zero produces TypeMismatch.DivZero" {
    const result = eval.evalBinaryOp(.Div, .{ .Int = 1 }, .{ .Int = 0 });
    try std.testing.expectError(eval.EvalError.DivisionByZero, result);
    
    const mapped = diagnostics.mapEvalError(eval.EvalError.DivisionByZero);
    try std.testing.expect(mapped.? == .TypeMismatchDivZero);
    
    const code_name = diagnostics.codeName(.TypeMismatchDivZero);
    try std.testing.expect(std.mem.eql(u8, code_name, "TypeMismatch.DivZero"));
}