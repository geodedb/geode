const std = @import("std");
const evalmod = @import("../src/eval.zig");

// Test for NFC compare in eval equality/ordering (REQ-GQL-UNICODE-009)
test "TestCANARY_REQ_GQL_UNICODE_009_EvalCompareNfc" {
    const Value = evalmod.Value;
    const ast = @import("../src/gql/ast.zig");
    // Build two Value.Str forms: precomposed and decomposed É
    const a = Value{ .Str = "\xC9" };
    const b = Value{ .Str = "E\xCC\x81" };
    // Use internal evalBinary with Eq
    const res = evalmod.evalBinary(ast.BinOp.Eq, a, b) catch return error.Unexpected;
    try std.testing.expect(res == .Bool and res.Bool);
}
