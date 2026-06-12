// SEC-SESS-LOG-01 regression (docs/SECURITY_GAP_ANALYSIS.md, issue #820):
// `geode session rotate` must never emit the session token (or any prefix of
// it) on stderr/stdout. The token is persisted to the credentials file only.
// cmdSessionRotate routes all user-facing rotate output through
// session_cli.writeRotateResult; this test pins that seam to a token-free
// contract.

const std = @import("std");
const session_cli = @import("session_cli");

test "SEC_SESS_LOG_01_rotate_output_contains_no_token" {
    const sentinel_token: [64]u8 = ("a1b2c3d4" ** 8).*;

    var out_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try session_cli.writeRotateResult(&writer, &sentinel_token);
    const out = writer.buffered();

    // The full token must not appear in CLI output.
    try std.testing.expect(std.mem.indexOf(u8, out, &sentinel_token) == null);
    // Nor any 16-char prefix (no "fingerprint" leak of token material).
    try std.testing.expect(std.mem.indexOf(u8, out, sentinel_token[0..16]) == null);
    // The user still gets a success confirmation.
    try std.testing.expect(std.mem.indexOf(u8, out, "Session token rotated successfully.") != null);
}
