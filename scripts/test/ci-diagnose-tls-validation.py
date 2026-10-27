#!/usr/bin/env python3
"""Diagnostic branch only: reveal the error already rejected by TLS validation."""
from pathlib import Path

package = "tls-0.1.24-mtEaLGHFKgC0dE9AXYJJTmRdEwJbG2kcznZmGQbPyrut"
source = Path("zig-pkg") / package / "src/tls13/context/cert_handlers.zig"
text = source.read_text()
needle = ") catch return HandshakeError.CertificateValidationFailed;"
assert text.count(needle) == 2
text = text.replace(needle, ''') catch |err| {
        std.debug.print("TLS chain rejection: {s}; now={d}; anchors={d}\\n", .{ @errorName(err), now_unix, trusted_ca_der.len });
        return HandshakeError.CertificateValidationFailed;
    };''')
needle = "var parsed = x509.parseCert(alloc, anchor_der) catch continue;"
assert text.count(needle) == 1
text = text.replace(needle, '''var parsed = x509.parseCert(alloc, anchor_der) catch |err| {
            std.debug.print("TLS anchor parse rejection: {s}\\n", .{@errorName(err)});
            continue;
        };''')
source.write_text(text)
print("Instrumented the pinned TLS validator; all rejection paths remain unchanged")

source = Path("zig-pkg") / package / "src/x509.zig"
text = source.read_text()
needle = "pub fn verifyCertSig(issuer_spki_der: []const u8, tbs: []const u8, algo_oid: []const u8, sig_der: []const u8, alloc: std.mem.Allocator) bool {"
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n    std.debug.print("TLS signature algorithm: {x}; fips={any}\\n", .{ algo_oid, fips_cb.fips_enabled });')
start = text.index("fn verifyEcdsaWith(")
end = text.index("fn oidIsRsaPss(", start)
helper = text[start:end]
for operation, label in [
    ("E.Signature.fromDer(sig_der)", "signature parse"),
    ("E.PublicKey.fromSec1(sec1_uncompressed)", "public key parse"),
    ("signature.verify(tbs, pubkey)", "verification"),
]:
    needle = operation + " catch return false;"
    assert helper.count(needle) == 1
    helper = helper.replace(needle, operation + ' catch |err| { std.debug.print("TLS ECDSA ' + label + ': {s}\\n", .{@errorName(err)}); return false; };')
text = text[:start] + helper + text[end:]
source.write_text(text)
print("Instrumented certificate signature dispatch; all failures still reject")
