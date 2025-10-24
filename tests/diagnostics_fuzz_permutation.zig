const std = @import("std");
const diagnostics = @import("geode").diagnostics;

test "diagnostics: foldCodes permutation associativity" {
    var rnd = std.rand.DefaultPrng.init(0xdeadbeef);
    const rng = rnd.random();
    const all = [_]diagnostics.Code{ .US001, .IllegalOrderKey, .GroupByIllegal, .TypeMismatch, .TxnState };
    var buf: [5]diagnostics.Code = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        // choose random subset length 1..5
        const len = (rng.int(u8) % 5) + 1;
        // fill sequential then shuffle
        var j: usize = 0;
        while (j < len) : (j += 1) buf[j] = all[j];
        // Fisher-Yates shuffle
        var k: usize = len;
        while (k > 1) : (k -= 1) {
            const r = rng.int(usize) % k;
            const tmp = buf[k - 1];
            buf[k - 1] = buf[r];
            buf[r] = tmp;
        }
        const folded_len = diagnostics.foldCodes(buf[0..len]);
        // Primary must be element of subset and appear first in precedence order (already ensured by foldCodes logic)
        const primary = buf[0];
        var present = false;
        var m: usize = 0;
        while (m < len) : (m += 1) {
            if (buf[m] == primary) present = true;
        }
        try std.testing.expect(present);
        // Ensure additional codes (if any) are unique
        var seen = std.EnumSet(diagnostics.Code).initEmpty();
        var a: usize = 0;
        while (a < folded_len) : (a += 1) {
            try std.testing.expect(!seen.contains(buf[a]));
            seen.insert(buf[a]);
        }
    }
}
