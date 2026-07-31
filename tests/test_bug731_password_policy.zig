//! Regression: the three password-policy entry points must agree.
//!
//! docs/@BUGS_731.md bug 4 surfaced that geode enforced three different,
//! partly *incompatible* password policies depending on how a password was
//! set:
//!
//!   1. the wire path (`ALTER USER ... SET PASSWORD`) — PasswordPolicy.geodeSecure():
//!      >=20 chars, upper + lower, >=3 space-separated words, digit NOT required;
//!   2. the offline `geode user` CLI — its own rule: >=8 chars, one letter, one digit;
//!   3. the `GEODE_ADMIN_PASSWORD` first-boot seed — no validation whatsoever.
//!
//! (1) and (2) were not merely different strengths, they were mutually
//! exclusive: the passphrase the server's own error message instructs
//! operators to use (`Correct horse battery staple`) was rejected by the CLI
//! for containing no digit, while a CLI-accepted `abc12345` was rejected by
//! the server for being too short and not a passphrase.
//!
//! These tests pin the unified behaviour: (1) and (2) now share one
//! implementation, `PasswordPolicy.validate`. (3) validates against the same
//! policy but only WARNS — it must never start refusing to boot, which would
//! brick deployments seeded before the check existed.

const std = @import("std");
const testing = std.testing;

const PasswordPolicy = @import("geode_auth").PasswordPolicy;
const cli_auth = @import("cli_auth_helpers");

/// The exact passphrase the server's own `Password reset required` error
/// tells the operator to use.
const documented_passphrase = "Correct horse battery staple";

test "bug731 policy: the documented recovery passphrase is accepted by the policy" {
    const policy = PasswordPolicy.geodeSecure();
    try testing.expect(policy.validate(documented_passphrase) == null);
}

test "bug731 policy: the offline CLI accepts exactly what the policy accepts" {
    // The regression: this passphrase was rejected by the CLI (no digit) while
    // being the only thing the server would accept.
    try testing.expect(cli_auth.isPasswordStrong(documented_passphrase));
}

test "bug731 policy: CLI and wire policy agree across a matrix of candidates" {
    const policy = PasswordPolicy.geodeSecure();
    const candidates = [_][]const u8{
        documented_passphrase,
        "abc12345", // old CLI-valid, wire-invalid
        "password1", // old CLI-valid, wire-invalid
        "SecureP4ss!", // old CLI-valid, wire-invalid
        "Supercalifragilistic", // long enough, single word
        "correct horse battery staple", // passphrase, no uppercase
        "CORRECT HORSE BATTERY STAPLE", // passphrase, no lowercase
        "Two Words", // too short, too few words
        "Correct Horse Battery Staple 42", // compliant, with a digit
        "", // degenerate
    };
    for (candidates) |pw| {
        const policy_ok = policy.validate(pw) == null;
        const cli_ok = cli_auth.isPasswordStrong(pw);
        testing.expectEqual(policy_ok, cli_ok) catch |err| {
            std.debug.print(
                "policy/CLI disagreement for \"{s}\": policy_ok={} cli_ok={}\n",
                .{ pw, policy_ok, cli_ok },
            );
            return err;
        };
    }
}

test "bug731 policy: rejections explain themselves" {
    const policy = PasswordPolicy.geodeSecure();

    const short = policy.validate("Two Words") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, short, "too short") != null);

    const single_word = policy.validate("Supercalifragilistic") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, single_word, "passphrase") != null);

    const no_upper = policy.validate("correct horse battery staple") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, no_upper, "uppercase") != null);

    const no_lower = policy.validate("CORRECT HORSE BATTERY STAPLE") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, no_lower, "lowercase") != null);

    // The CLI surfaces the same reason rather than a bare boolean.
    const cli_reason = cli_auth.passwordPolicyError("Two Words") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(short, cli_reason);
}

test "bug731 policy: a compliant password is accepted by every entry point" {
    const policy = PasswordPolicy.geodeSecure();
    const good = "Correct Horse Battery Staple";
    try testing.expect(policy.validate(good) == null);
    try testing.expect(cli_auth.isPasswordStrong(good));
    try testing.expect(cli_auth.passwordPolicyError(good) == null);
}
