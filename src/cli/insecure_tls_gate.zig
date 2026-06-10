//! SEC-CLI-01: production-posture gate for `--insecure-tls-skip-verify`.
//!
//! Disabling TLS certificate verification exposes every CLI <-> server
//! exchange (credentials, query results, backups) to active MITM. The flag
//! stays available for dev/test loops, but under production posture
//! (release build OR GEODE_ENV=production) it is refused unless the operator
//! also sets the explicit acknowledgement variable GEODE_ALLOW_INSECURE_TLS=1.
//!
//! Mirrors the GAP-0850 `--insecure-allow-all` startup guard: the policy is a
//! pure function (posture and override are PARAMETERS, not read from the
//! process) so it is fully unit-testable from a Debug test binary; the live
//! call sites in `src/cli/main.zig` / `src/cli/backup_cli.zig` supply the
//! real values via `enforceOrExit`.
//
// CANARY: REQ=REQ-SEC-CLI-INSECURE-TLS-GATE-001; FEATURE="InsecureTlsFlagGate"; ASPECT=Policy; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const builtin = @import("builtin");

/// Explicit acknowledgement variable. Exported so the refusal message and
/// the tests reference the exact same string.
pub const allow_env = "GEODE_ALLOW_INSECURE_TLS";

pub const InsecureTlsGateError = error{InsecureTlsRefused};

/// Pure gate policy. Returns `error.InsecureTlsRefused` when the insecure
/// flag is requested AND a production condition holds AND the explicit
/// override is not set. All other combinations return cleanly.
///
///   * `insecure_requested` — the parsed `--insecure-tls-skip-verify` /
///     `--insecure` flag.
///   * `is_release`         — `builtin.mode != .Debug` at the call site.
///   * `env_production`     — `GEODE_ENV` resolves to "production".
///   * `allow_override`     — `GEODE_ALLOW_INSECURE_TLS` is truthy.
pub fn validateInsecureTls(
    insecure_requested: bool,
    is_release: bool,
    env_production: bool,
    allow_override: bool,
) InsecureTlsGateError!void {
    if (!insecure_requested) return; // flag off — nothing to gate.
    if (allow_override) return; // explicit operator acknowledgement.
    if (is_release or env_production) {
        return error.InsecureTlsRefused;
    }
    // Debug build, non-production env: allowed (dev/test loops).
}

/// "1" / "true" / "yes" / "on" (case-insensitive) are truthy.
pub fn envTruthy(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

// Zig 0.16: std.posix.getenv removed — use libc getenv (same wrapper as
// src/server/cli_args.zig).
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

/// Evaluate the gate against the live process state (build mode + env).
pub fn evaluateLive(insecure_requested: bool) InsecureTlsGateError!void {
    const env_production = if (posixGetenv("GEODE_ENV")) |v|
        std.ascii.eqlIgnoreCase(v, "production")
    else
        false;
    const allow_override = if (posixGetenv(allow_env)) |v| envTruthy(v) else false;
    return validateInsecureTls(
        insecure_requested,
        builtin.mode != .Debug,
        env_production,
        allow_override,
    );
}

/// Call when a CLI parser accepts `--insecure-tls-skip-verify` (or the
/// deprecated `--insecure` alias). Refuses (exit 1) under production posture
/// without the explicit override; otherwise prints a loud warning and
/// returns.
pub fn enforceOrExit() void {
    evaluateLive(true) catch {
        std.debug.print(
            "SECURITY: refusing --insecure-tls-skip-verify — TLS certificate verification " ++
                "cannot be disabled under production conditions (release build or " ++
                "GEODE_ENV=production). Connections without verification are exposed to " ++
                "man-in-the-middle attacks. Use --ca-cert <path> to trust a private CA, or " ++
                "set " ++ allow_env ++ "=1 to explicitly acknowledge the risk.\n",
            .{},
        );
        std.process.exit(1);
    };
    std.debug.print(
        "WARNING: TLS certificate verification DISABLED (--insecure-tls-skip-verify). " ++
            "This connection is exposed to man-in-the-middle attacks. NOT FOR PRODUCTION. " ++
            "Prefer --ca-cert <path> for private CAs.\n",
        .{},
    );
}
