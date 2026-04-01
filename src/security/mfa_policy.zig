const std = @import("std");
const ext_mfa = @import("auth_lib").mfa;

pub fn defaultConfig() ext_mfa.MfaConfig {
    return .{
        .digits = 6,
        .step_seconds = 30,
        .window = 1,
        .scratch_code_count = 8,
        .deterministic = false,
        .salt = "",
    };
}

pub fn codeConfig(step_seconds: u64, digits: u8, window: i32) ext_mfa.MfaConfig {
    var config = defaultConfig();
    config.step_seconds = step_seconds;
    config.digits = digits;
    config.window = window;
    return config;
}

pub fn buildProvisioningUri(
    allocator: std.mem.Allocator,
    username: []const u8,
    secret_base32: []const u8,
) ![]u8 {
    const config = defaultConfig();
    const encoded_user = try percentEncode(allocator, username);
    defer allocator.free(encoded_user);

    return std.fmt.allocPrint(
        allocator,
        "otpauth://totp/Geode:{s}?secret={s}&issuer=Geode&algorithm=SHA1&digits={d}&period={d}",
        .{ encoded_user, secret_base32, config.digits, config.step_seconds },
    );
}

fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer output.deinit(allocator);

    for (input) |c| {
        if (isUnreserved(c)) {
            try output.append(allocator, c);
            continue;
        }

        try output.writer(allocator).print("%{X:0>2}", .{c});
    }

    return output.toOwnedSlice(allocator);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}
