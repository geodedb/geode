#!/bin/bash
# Regression test for #748 — `geode audit verify` with an empty default-path
# audit log drops the `"records verified"` phrase from its success summary.
#
# CANARY: REQ=REQ-AUDIT-VERIFY-001; FEATURE="Audit Verification"; ASPECT=EmptyFileSummaryPhrase; STATUS=IMPL; OWNER=security; UPDATED=2026-04-16
#
# See docs/audit/bugfix-harness-failures-triage.md §4 issue #5.
# Harness spec: geode-test-harness/geodetestlab-cli/specs/gap_150_151_152_security_regression.yml
#   test case: gap-0151-audit-verify-default-path
#   expects: stderr_contains: ["0 records verified"]
#
# Symptom (pre-fix):
#   When `./audit.jsonl` exists in cwd but is 0 bytes, the code falls through
#   to the success-path formatter at `src/cli/geode_audit_verify.zig:247-260`
#   and prints:
#     OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100
#   — which contains `records=0` but NOT the expected `"0 records verified"`
#   substring.  The FileNotFound branch at line 54 already emits the
#   spec-compatible phrase: `audit log not found: ... (0 records verified)`.
#
# Expected (post-fix):
#   Either the success-empty branch emits `"0 records verified"` (or at
#   minimum the substring `"records verified"`), matching the phrase the
#   FNF branch uses, so the harness test `gap-0151-audit-verify-default-path`
#   passes uniformly whether or not the default path exists.
#
# Test strategy:
#   Run in a temp cwd with `audit.jsonl` touched to 0 bytes, invoke the
#   real `geode audit verify` subcommand (no --file, so default path
#   resolution applies), and grep the combined stdout+stderr for the
#   required phrase.  No mocks: the real binary, the real code path.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-${REPO_ROOT}/zig-out/bin/geode}"

if [ ! -x "${GEODE_BIN}" ]; then
    echo "FAIL: geode binary not found at ${GEODE_BIN}" >&2
    exit 2
fi

# Real temp dir, real empty file.  The default path `geode audit verify`
# resolves is `audit.jsonl` relative to cwd, so we run the binary with the
# temp dir as cwd.
WORK_DIR="$(mktemp -d /tmp/geode-audit-verify-empty-XXXXXX)"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# 0-byte audit log.  File exists, so the FNF branch is NOT taken — we
# exercise the success-path formatter at geode_audit_verify.zig:247.
: > "${WORK_DIR}/audit.jsonl"
if [ ! -f "${WORK_DIR}/audit.jsonl" ] || [ -s "${WORK_DIR}/audit.jsonl" ]; then
    echo "FAIL: could not create a 0-byte audit.jsonl in ${WORK_DIR}" >&2
    exit 2
fi

OUT_FILE="${WORK_DIR}/out.txt"
ERR_FILE="${WORK_DIR}/err.txt"

echo "[audit-verify-empty] invoking: ${GEODE_BIN} audit verify  (cwd=${WORK_DIR})"
( cd "${WORK_DIR}" && "${GEODE_BIN}" audit verify ) > "${OUT_FILE}" 2> "${ERR_FILE}"
RC=$?

echo "[audit-verify-empty] exit=${RC}"
echo "[audit-verify-empty] stdout:"
sed 's/^/  | /' "${OUT_FILE}" || true
echo "[audit-verify-empty] stderr:"
sed 's/^/  | /' "${ERR_FILE}" || true

FAIL=0

# Pass condition B1: exit 0 (empty file is not an error — the chain is
# trivially valid).  This is the same expectation as the harness spec.
if [ "${RC}" -ne 0 ]; then
    echo "FAIL: exit=${RC} (expected 0); empty audit log should verify cleanly." >&2
    FAIL=1
fi

# Pass condition B2 — THE #748 assertion:
# Either stdout or stderr must contain the phrase `records verified`
# (the harness spec asserts the stronger `"0 records verified"`; we
# accept the weaker substring since a well-formed post-fix message
# might phrase it as `(0 records verified)` or `0 records verified.`
# — what matters is that the phrase appears at all, which it does NOT
# today on the empty-default-path branch).
if ! grep -q "records verified" "${OUT_FILE}" "${ERR_FILE}"; then
    echo "FAIL: output missing 'records verified' phrase — #748." >&2
    echo "      The FNF branch at src/cli/geode_audit_verify.zig:54 emits" >&2
    echo "      '(0 records verified)'; the empty-file success branch at" >&2
    echo "      src/cli/geode_audit_verify.zig:247-260 must emit the same." >&2
    FAIL=1
fi

# Pass condition B3 (stronger, matches the harness spec exactly):
# At least one of stdout/stderr must contain '0 records verified' — with
# the actual record count prepended.  A post-fix implementation may
# reasonably choose other phrasings (e.g. "verified 0 records"), so we
# keep B2 as the minimum bar and B3 as a soft-pass diagnostic.
if ! grep -q "0 records verified" "${OUT_FILE}" "${ERR_FILE}"; then
    # Do not fail on B3 alone — B2 already enforces the minimum.  Emit an
    # informational note so post-fix authors can decide whether to tighten.
    echo "NOTE: output does not contain the exact harness-spec phrase '0 records verified'." >&2
fi

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi

echo "PASS: audit verify on empty default-path file emits 'records verified' phrase"
exit 0
