#!/usr/bin/env python3
"""Diagnostic branch only: reveal the error already rejected by TLS validation."""
import os
from pathlib import Path

package = "tls-0.1.24-mtEaLGHFKgC0dE9AXYJJTmRdEwJbG2kcznZmGQbPyrut"
source = Path(os.environ["ZIG_GLOBAL_CACHE_DIR"]) / "p" / package / "src/tls13/context/cert_handlers.zig"
if not source.is_file():
    cache_packages = source.parents[4]
    print("TLS packages present:", sorted(p.name for p in cache_packages.glob("tls-*")), flush=True)
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
