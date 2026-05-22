# Cluster A: Audit verifier prev_hash mismatch (#828)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `geode audit verify` so it returns exit 0 on a well-formed audit log instead of always returning exit 3 (`TAMPER chain`).

**Architecture:** The writer (`src/security/audit.zig:467-469` in `appendEventLocked`) stores `prev_hash = SHA256(last_hash)`. The verifier (`src/cli/geode_audit_verify.zig:123`) compares `prev_hash == last_hash` directly without the same SHA256 step. Every record mismatches. **Fix the verifier** (not the writer) — preserves on-disk format so existing audit logs in `~/.geode/audit_*.jsonl` and any production deployment remain verifiable. The fix is one block in `verifyFile`.

**Tech Stack:** Zig 0.16.0+, `std.crypto.hash.sha2.Sha256`, geode-test-harness YAML specs.

---

## Files

- **Modify:** `src/cli/geode_audit_verify.zig:121-131` — add SHA256 step before comparing
- **Modify:** `tests/test_audit_chain.zig` — extend `AuditLogger chaining verification` test with a real round-trip (no current test catches the bug)
- **Create:** `tests/test_audit_verify_chain_roundtrip.zig` — dedicated round-trip regression test for the verifier
- **Modify:** `build.zig` — register the new test file in the test suite
- **Modify:** `../geode-test-harness/geodetestlab-cli/specs/audit_ed25519_verification.yml` — flip BUG_CONFIRMED branch (around lines 165-178) to assert exit 0
- **Modify:** `../geode-test-harness/geodetestlab-cli/specs/audit_hmac_chain_restart.yml` — flip `hmac-phase2-chain-verify-full` step (lines 184-220) to assert exit 0
- **Update:** CANARY token on `src/cli/geode_audit_verify.zig:13` — bump `UPDATED=2026-05-21`

---

## Task 1: Add failing round-trip test

**Files:**
- Create: `tests/test_audit_verify_chain_roundtrip.zig`
- Modify: `build.zig` (register test)

- [ ] **Step 1: Write the failing round-trip test**

```zig
const std = @import("std");
const testing = std.testing;
const audit = @import("audit");
const rls = @import("rls");
const verify = @import("geode_audit_verify");

const AuditLogger = audit.AuditLogger;
const Config = AuditLogger.Config;
const AuditEvent = rls.AuditLogger.AuditEvent;

// Helper: build an absolute path inside the per-test tmp dir.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Bug #828: writer at audit.zig:467-469 stores prev_hash = SHA256(last_hash);
// verifier at geode_audit_verify.zig:123 compares prev_hash == last_hash directly.
// Every record mismatches. This test reproduces the bug end-to-end.
test "verifier accepts a freshly-written 3-event chain (round-trip)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, "roundtrip.jsonl" });
    defer allocator.free(full_path);

    // Writer: emit 3 events.
    {
        const config = Config{ .enabled = true, .file_path = full_path };
        var logger = try AuditLogger.init(allocator, config);
        defer logger.deinit();

        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            var ev = AuditEvent{
                .timestamp = 1000 + @as(i64, i),
                .event_type = .data_access,
                .severity = .info,
                .user_id = @as(u32, i) + 1,
                .resource = .{ .type = "node", .id = "1", .name = "n", .graph = null, .table = null },
                .action = "read",
                .result = .success,
                .session_id = null,
                .details = null,
            };
            try logger.appendAuditEvent(&ev);
        }
    }

    // Verifier: must return OK (no error) on the well-formed chain.
    // Before fix: returns immediately via std.process.exit(3) on first record.
    // We run the verifier in-process; on the bug it will call std.process.exit
    // which terminates the test runner. To make the failure observable as a
    // test failure rather than a process kill, we cannot directly invoke
    // verifyFile yet — instead we assert the round-trip via a refactored
    // entry point that returns errors instead of exiting. See Task 2 for
    // the refactor that makes this assertion possible.
    //
    // For Task 1 the test calls verifyFile directly; on the bug the test
    // process exits with code 3 and the test runner reports it as a fatal
    // crash, which fulfills "test fails before fix".
    try verify.verifyFile(allocator, full_path, .sha256, 0, false, null, false);
}
```

- [ ] **Step 2: Register the test in build.zig**

Locate the existing test additions block (search for `addTest` calls in `build.zig`) and add a sibling entry. Pattern matches the existing `tests/test_audit_chain.zig` registration; copy that block's shape exactly.

Run: `grep -n "test_audit_chain" build.zig`
Expected: a few lines showing how the existing audit test is wired. Mirror the same pattern for `tests/test_audit_verify_chain_roundtrip.zig`.

If the build uses a glob of `tests/test_*.zig`, no edit needed — just confirm.

- [ ] **Step 3: Run the new test and confirm it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: the new test either:
- fails with `error.Invalid` / `error.ReadError`, OR
- crashes the test runner via `std.process.exit(3)` (visible as `exit code 3` or `unexpected exit`).

Either is acceptable as the "failing test" signal. Record the exact output for the fix-report Evidence section.

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/test_audit_verify_chain_roundtrip.zig build.zig
git commit -m "test(audit): add round-trip regression for #828 verifier prev_hash mismatch

Reproduces the writer/verifier disagreement on prev_hash. Writer at
src/security/audit.zig:467-469 stores prev_hash = SHA256(last_hash);
verifier at src/cli/geode_audit_verify.zig:123 compares prev_hash ==
last_hash directly. Every record mismatches.

This test fails before the fix (Task 2 makes it pass)."
```

---

## Task 2: Fix the verifier to match writer semantics

**Files:**
- Modify: `src/cli/geode_audit_verify.zig:121-131`

- [ ] **Step 1: Replace the chain-integrity check**

Find this block at `src/cli/geode_audit_verify.zig:121-131`:

```zig
        // Verify chain integrity (prev_hash must match last event_hash)
        const prev_buf = try hex32(prev_hex);
        if (!std.mem.eql(u8, &prev_buf, &last_hash)) {
            std.debug.print("TAMPER chain ❌  at_seq={} reason=PREV_HASH_MISMATCH expected=", .{seq + 1});
            for (last_hash) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print(" got=", .{});
            for (prev_buf) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
            std.process.exit(3);
        }
        last_hash = try hex32(ev_hex);
```

Replace with:

```zig
        // Verify chain integrity. Bug #828 / GAP-0305: the writer at
        // src/security/audit.zig:467-469 stores prev_hash = SHA256(last_hash);
        // it is NOT the bare previous event_hash. Reproduce the same SHA256
        // step here so the comparison matches the on-disk format.
        const prev_buf = try hex32(prev_hex);
        var expected_prev: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&last_hash, &expected_prev, .{});
        if (!std.mem.eql(u8, &prev_buf, &expected_prev)) {
            std.debug.print("TAMPER chain ❌  at_seq={} reason=PREV_HASH_MISMATCH expected=", .{seq + 1});
            for (expected_prev) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print(" got=", .{});
            for (prev_buf) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
            std.process.exit(3);
        }
        last_hash = try hex32(ev_hex);
```

The diagnostic output now reports the SHA256-hashed expected value (what the writer would emit), not the raw `last_hash`. This is more faithful: when a real tamper happens, the operator sees the value that *should* be in `prev_hash`, not an intermediate.

- [ ] **Step 2: Update the CANARY token timestamp**

Find at `src/cli/geode_audit_verify.zig:13`:

```zig
// CANARY: REQ=REQ-AUDIT-VERIFY-001; FEATURE="Audit Verification"; ASPECT=ChainVerification; STATUS=TESTED; TEST=tests/geodetestlab/specs/geode_auth.yml; OWNER=security; UPDATED=2026-01-15
```

Replace `UPDATED=2026-01-15` with `UPDATED=2026-05-21`. Append the new test path to `TEST=`:

```zig
// CANARY: REQ=REQ-AUDIT-VERIFY-001; FEATURE="Audit Verification"; ASPECT=ChainVerification; STATUS=TESTED; TEST=tests/geodetestlab/specs/geode_auth.yml,tests/test_audit_verify_chain_roundtrip.zig; OWNER=security; UPDATED=2026-05-21
```

- [ ] **Step 3: Run the new round-trip test — should now PASS**

Run: `zig build test 2>&1 | grep -E "test_audit_verify_chain_roundtrip|OK chain|fail" | tail -10`
Expected: the round-trip test passes; you should see `OK chain ✅` from the verifier and no `exit 3`.

- [ ] **Step 4: Run the full Zig test suite — confirm no regressions**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests pass; the audit-related tests in particular (`test_audit_chain`, `test_audit_verify_seq_no`, `test_audit_tenant_enrichment`) remain green.

- [ ] **Step 5: Commit the fix**

```bash
git add src/cli/geode_audit_verify.zig
git commit -m "fix(audit): #828 verifier now reproduces writer SHA256 step on prev_hash

The writer at src/security/audit.zig:467-469 stores
prev_hash = SHA256(last_hash). The verifier was comparing
prev_hash == last_hash directly, so every well-formed chain failed
with TAMPER on the first record.

Verifier now computes SHA256(last_hash) and compares against the
on-disk prev_hash. Preserves the existing on-disk format — any
existing audit logs in ~/.geode/audit_*.jsonl or in production
deployments remain verifiable without migration.

Closes #828."
```

---

## Task 3: Flip the harness spec assertions

**Files:**
- Modify: `../geode-test-harness/geodetestlab-cli/specs/audit_ed25519_verification.yml`
- Modify: `../geode-test-harness/geodetestlab-cli/specs/audit_hmac_chain_restart.yml`

- [ ] **Step 1: Flip `audit_ed25519_verification.yml` chain-verify step**

Open `../geode-test-harness/geodetestlab-cli/specs/audit_ed25519_verification.yml`. Find the test step around lines 130–178 that contains `BUG_PINNED (GAP-0305)` and the `BUG_CONFIRMED`/`BUG_FIXED` branches. Replace the BUG-pinned step with an assertive step that runs `geode audit verify` and asserts exit 0 + `OK chain` in output:

```yaml
- name: ed25519-chain-verify-full
  description: |
    GAP-0305 / #828 RESOLVED — `geode audit verify` now correctly verifies
    the SHA256(last_hash) prev_hash chain. Asserts exit 0 and OK chain
    output on a well-formed audit log.
  type: bash
  command: |
    LOG="${GEODE_STATE_DIR}/audit.jsonl"
    GEODE_BIN=""
    for p in \
      "${GEODE_STATE_DIR}/../../zig-out/bin/geode" \
      "$(dirname "$(dirname "$(dirname "$PWD")")")/geode/zig-out/bin/geode" \
      "../../../geode/zig-out/bin/geode" \
      "$(command -v geode 2>/dev/null)"; do
      if [ -x "$p" ]; then GEODE_BIN="$p"; break; fi
    done
    if [ -z "$GEODE_BIN" ]; then
      echo "SKIP: geode binary not found"
      exit 0
    fi
    OUTPUT=$("$GEODE_BIN" audit verify --file "$LOG" 2>&1)
    EXIT=$?
    echo "$OUTPUT"
    if [ "$EXIT" -ne 0 ]; then
      echo "FAIL: expected exit 0, got $EXIT"
      exit 1
    fi
    echo "$OUTPUT" | grep -q "OK chain" || { echo "FAIL: missing 'OK chain' in output"; exit 1; }
    echo "CHAIN_VERIFY_OK"
  expect:
    exit_code: 0
    stdout_contains: [CHAIN_VERIFY_OK]
  tags: [audit, ed25519, chain, gap-0305-resolved]
```

Update the CANARY block at the top of the same file: change any `STATUS=BUG_DETECTED` or `STATUS=BUG_CONFIRMED` for the chain aspect to `STATUS=TESTED`. Keep the date as `UPDATED=2026-05-21`.

- [ ] **Step 2: Flip `audit_hmac_chain_restart.yml` chain-verify-full step**

Open `../geode-test-harness/geodetestlab-cli/specs/audit_hmac_chain_restart.yml`. Find the `hmac-phase2-chain-verify-full` step at lines 184–220. Replace the BUG-pinned body with an assertive version:

```yaml
- name: hmac-phase2-chain-verify-full
  description: |
    GAP-0305 / #828 RESOLVED — full hash-chain verification across the
    pre+post-restart log now passes. Asserts exit 0 and OK chain output.
    Both initFromTail (writer recovery) AND the verifier are now consistent
    about prev_hash = SHA256(previous_event_hash).
  type: bash
  command: |
    LOG="${GEODE_STATE_DIR}/audit.jsonl"
    GEODE_BIN=""
    for p in \
      "${GEODE_STATE_DIR}/../../zig-out/bin/geode" \
      "$(dirname "$(dirname "$(dirname "$PWD")")")/geode/zig-out/bin/geode" \
      "../../../geode/zig-out/bin/geode" \
      "$(command -v geode 2>/dev/null)"; do
      if [ -x "$p" ]; then GEODE_BIN="$p"; break; fi
    done
    if [ -z "$GEODE_BIN" ]; then
      echo "SKIP: geode binary not found"
      exit 0
    fi
    OUTPUT=$("$GEODE_BIN" audit verify --file "$LOG" 2>&1)
    EXIT=$?
    echo "$OUTPUT"
    if [ "$EXIT" -ne 0 ]; then
      echo "FAIL: expected exit 0, got $EXIT (chain should be valid across restart)"
      exit 1
    fi
    echo "$OUTPUT" | grep -q "OK chain" || { echo "FAIL: missing 'OK chain' in output"; exit 1; }
    echo "HMAC_CHAIN_VERIFY_OK"
  expect:
    exit_code: 0
    stdout_contains: [HMAC_CHAIN_VERIFY_OK]
  tags: [audit, hmac, phase2, chain, gap-0305-resolved]
```

Update the spec's CANARY header (line 19) — change `UPDATED=2026-05-21` if needed (it already says 2026-05-21).

- [ ] **Step 3: Build geode and run both specs**

Run from the harness directory:

```bash
cd ../geode-test-harness
GEODE_BINARY=/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/zig-out/bin/geode \
  make test-spec SPEC=geodetestlab-cli/specs/audit_ed25519_verification.yml 2>&1 | tail -40
```

Expected: all steps pass, including the new `ed25519-chain-verify-full` step.

```bash
cd ../geode-test-harness
GEODE_BINARY=/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/zig-out/bin/geode \
  make test-spec SPEC=geodetestlab-cli/specs/audit_hmac_chain_restart.yml 2>&1 | tail -40
```

Expected: all steps pass, including `hmac-phase2-chain-verify-full`.

If geode binary needs rebuilding first:
```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
make build
```

- [ ] **Step 4: Commit the spec flips**

```bash
cd ../geode-test-harness
git add geodetestlab-cli/specs/audit_ed25519_verification.yml geodetestlab-cli/specs/audit_hmac_chain_restart.yml
git commit -m "test(audit): flip #828/GAP-0305 BUG_PINNED to assertive

The geode verifier/writer prev_hash mismatch is fixed upstream
(geode commit <SHA>). Both ed25519 and hmac chain-restart specs
now assert exit 0 + 'OK chain' on a well-formed log.

Aligned with geode #828."
```

(Replace `<SHA>` with the actual commit SHA from Task 2's commit, captured by `git log -1 --format=%H` in the geode worktree.)

---

## Task 4: Run the broader regression pass

**Files:** None modified — verification only.

- [ ] **Step 1: Run all geode Zig tests**

Run from the geode dir:

```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
zig build test 2>&1 | tail -10
```

Expected: all tests pass. Capture pass count for the fix report.

- [ ] **Step 2: Run the full audit-related spec sweep**

Run from the harness dir:

```bash
cd ../geode-test-harness
GEODE_BINARY=/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/zig-out/bin/geode \
  make test SPEC_FILTER='audit_' 2>&1 | tail -30
```

If `SPEC_FILTER` isn't a recognized make var, fall back to running each audit spec individually:

```bash
for spec in geodetestlab-cli/specs/audit_*.yml; do
  GEODE_BINARY=/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/zig-out/bin/geode \
    make test-spec SPEC="$spec" 2>&1 | tail -5
done
```

Expected: all audit specs pass. None of the other specs should be touched by this change.

- [ ] **Step 3: Lint and format check**

Run from the geode dir:

```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
make fmt
```

Expected: no formatting changes (or only formatting on the files we touched, which should already be conformant).

If pre-commit is wired:
```bash
make pre-commit 2>&1 | tail -10
```

Expected: all hooks pass.

---

## Task 5: Push and open MR

**Files:** None modified — git operations only.

- [ ] **Step 1: Confirm we are on the fix branch**

Run: `git branch --show-current`
Expected: a fix branch (e.g. `fix/audit-verifier-prev-hash-828`). If currently on `fix/rbac-grant-chain-and-fle-ddl-audit` from the prior session, create a new branch off main first:

```bash
git checkout main && git pull origin main && git checkout -b fix/audit-verifier-prev-hash-828
git cherry-pick <test-commit-sha> <fix-commit-sha>
```

(Cherry-pick keeps the test-first commit ordering on the new branch.)

- [ ] **Step 2: Push the geode branch**

```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
git push -u origin fix/audit-verifier-prev-hash-828
```

- [ ] **Step 3: Push the harness branch**

```bash
cd ../geode-test-harness
git push -u origin <harness-branch-name>
```

(If the harness uses a different convention, follow it. Some harnesses commit directly to main; check `git log origin/main..HEAD` to see what's outbound.)

- [ ] **Step 4: Open the geode MR**

```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
glab mr create --title "fix(audit): #828 verifier reproduces writer SHA256 step on prev_hash" \
  --description "$(cat <<'EOF'
## Summary
Fixes #828. The audit verifier was comparing on-disk `prev_hash` against the bare `last_hash` instead of against `SHA256(last_hash)` (which is what the writer emits at `src/security/audit.zig:467-469`). Every record mismatched and `geode audit verify` always returned exit 3 on a well-formed log.

Verifier now reproduces the writer's SHA256 step and compares against that. Preserves on-disk format; no migration needed.

## Evidence
- New regression test `tests/test_audit_verify_chain_roundtrip.zig` round-trips writer → verifier; fails on `main`, passes after this change.
- Existing tests: all green (`zig build test`).
- Harness specs: `audit_ed25519_verification.yml` and `audit_hmac_chain_restart.yml` BUG_PINNED branches flipped to assertive; both green against the rebuilt binary.

## Test plan
- [x] `zig build test` clean
- [x] `audit_ed25519_verification.yml` passes (chain-verify step now exit 0)
- [x] `audit_hmac_chain_restart.yml` passes (hmac-phase2-chain-verify-full step now exit 0)
- [x] No other audit specs regress

Closes #828.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Capture the MR URL**

`glab mr create` will print a URL. Capture it for the fix report.

---

## Self-review checklist (run before declaring Cluster A done)

- [ ] `git status` clean in both geode and harness worktrees (no stray files)
- [ ] Both MRs opened, URLs captured
- [ ] #828 referenced in the geode MR description with `Closes #828`
- [ ] Memory write: `project` memory noting `Cluster A closed YYYY-MM-DD, geode MR !X, harness commit <sha>, residuals: none`
- [ ] Master roadmap updated: mark Cluster A as `✅ closed` with date

---

## Notes for the executing agent

- **Do not change the writer.** The writer's `prev_hash = SHA256(last_hash)` pattern is on disk in every existing audit log. Changing it breaks production logs without migration. The verifier-side fix is intentional.
- **Diagnostic output now reports the hashed expected value.** This is a behavioral change visible to operators reading verifier output. The new format is correct (it matches what's on disk); document this in the MR description.
- **The new test will exit-3 the test runner on `main`.** That's the failing-test signal. After the fix lands, the test passes normally. If the test runner aborts on the failing test before reporting other test results, run the new test in isolation first.
- **Spec edits live in a separate git repo** (`../geode-test-harness`). The harness commits as a separate change. Cross-reference the geode commit SHA in the harness commit message.
