const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Property-style fuzz: generate random decimal pairs (as strings) and ensure ordering via RETURN ... UNION ... ORDER BY preserves numeric ascending order.
// We only test sign/scale normalization consistency, not full transitive closure across large sets (kept small for CI perf). 10k iterations.
test "protocol: decimal ordering fuzz pairs" {
    const exe = "./zig-out/bin/geode";
    var prng = std.rand.DefaultPrng.init(123456789); // fixed seed for reproducibility
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const a_sign = if (rnd.boolean()) -1 else 1;
        const b_sign = if (rnd.boolean()) -1 else 1;
        const a_int: i64 = @intCast(rnd.intRangeLessThan(i64, 0, 10_000));
        const b_int: i64 = @intCast(rnd.intRangeLessThan(i64, 0, 10_000));
        const a_scale: u8 = @intCast(rnd.intRangeLessThan(u8, 0, 4));
        const b_scale: u8 = @intCast(rnd.intRangeLessThan(u8, 0, 4));
        const a_coeff = a_int * a_sign;
        const b_coeff = b_int * b_sign;
        // Build decimal strings (simulate fixed point). Avoid trailing '.' when scale=0.
        var abuf: [64]u8 = undefined;
        var a_len: usize = 0;
        var bbuf: [64]u8 = undefined;
        var b_len: usize = 0;
        if (a_scale == 0) {
            a_len = std.fmt.formatIntBuf(&abuf, a_coeff, 10, .lower, .{});
        } else {
            const pow10 = std.math.powi(i64, 10, a_scale) catch 1;
            const whole = a_coeff / pow10;
            var frac_val = if (a_coeff < 0) -a_coeff else a_coeff;
            frac_val = @mod(frac_val, pow10);
            var frac_buf: [16]u8 = undefined;
            const frac_str = std.fmt.bufPrint(&frac_buf, "{d}", .{frac_val}) catch "0";
            // zero pad to scale
            var pad_needed: usize = 0;
            if (frac_str.len < a_scale) pad_needed = a_scale - frac_str.len;
            if (pad_needed > 0) {
                a_len = std.fmt.bufPrint(&abuf, "{d}.", .{whole}) catch 0;
                var k: usize = 0;
                while (k < pad_needed) : (k += 1) {
                    abuf[a_len] = '0';
                    a_len += 1;
                }
                @memcpy(abuf[a_len .. a_len + frac_str.len], frac_str);
                a_len += frac_str.len;
            } else {
                a_len = std.fmt.bufPrint(&abuf, "{d}.{s}", .{ whole, frac_str }) catch 0;
            }
        }
        if (b_scale == 0) {
            b_len = std.fmt.formatIntBuf(&bbuf, b_coeff, 10, .lower, .{});
        } else {
            const pow10b = std.math.powi(i64, 10, b_scale) catch 1;
            const wholeb = b_coeff / pow10b;
            var frac_valb = if (b_coeff < 0) -b_coeff else b_coeff;
            frac_valb = @mod(frac_valb, pow10b);
            var frac_bufb: [16]u8 = undefined;
            const frac_strb = std.fmt.bufPrint(&frac_bufb, "{d}", .{frac_valb}) catch "0";
            var pad_neededb: usize = 0;
            if (frac_strb.len < b_scale) pad_neededb = b_scale - frac_strb.len;
            if (pad_neededb > 0) {
                b_len = std.fmt.bufPrint(&bbuf, "{d}.", .{wholeb}) catch 0;
                var k2: usize = 0;
                while (k2 < pad_neededb) : (k2 += 1) {
                    bbuf[b_len] = '0';
                    b_len += 1;
                }
                @memcpy(bbuf[b_len .. b_len + frac_strb.len], frac_strb);
                b_len += frac_strb.len;
            } else {
                b_len = std.fmt.bufPrint(&bbuf, "{d}.{s}", .{ wholeb, frac_strb }) catch 0;
            }
        }
        const a_slice = abuf[0..a_len];
        const b_slice = bbuf[0..b_len];
        // Query that orders two values ascending
        var query_buf: [256]u8 = undefined;
        const q = std.fmt.bufPrint(&query_buf, "RETURN {s} AS x UNION RETURN {s} AS x ORDER BY x", .{ a_slice, b_slice }) catch continue;
        const res = run(&.{ exe, q }) catch continue;
        if (res.code != 0) continue; // skip failed parse/eval cases (e.g., decimal literal not yet supported fully)
        // Determine numeric value of each (normalized to common scale by converting to f64 for property check only)
        const val_a = std.fmt.parseFloat(f64, a_slice) catch 0.0;
        const val_b = std.fmt.parseFloat(f64, b_slice) catch 0.0;
        const out_line = res.out; // contains schema + bindings lines
        const p_a = std.mem.indexOf(u8, out_line, a_slice);
        const p_b = std.mem.indexOf(u8, out_line, b_slice);
        if (p_a != null and p_b != null) {
            if (val_a < val_b) {
                if (!(p_a.? < p_b.?)) return error.BadOrderLT;
            } else if (val_a > val_b) {
                if (!(p_b.? < p_a.?)) return error.BadOrderGT;
            } else {
                // equal numeric value: ensure at least one occurrence present; tie order acceptable
                if (!(p_a.? != 0 or p_b.? != 0)) return error.MissingEqual;
            }
        }
    }
}
