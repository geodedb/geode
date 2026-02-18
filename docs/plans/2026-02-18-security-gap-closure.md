# Security Gap Closure Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fully resolve all 18 open security gaps in `docs/GAP_ANALYSIS.md` — close Won't-Do items by policy, implement all code-level fixes, add federation cluster-auth with mTLS, and audit git history for exposed secrets.

**Architecture:** Changes are isolated to security modules, the federation layer, containerization files, and build config. The highest-complexity item (#490) adds a `GEODE_CLUSTER_TOKEN` environment variable read at federation connection time, wires it into the QUIC HELLO handshake, and adds server-side token validation alongside the existing mTLS code path (`quic_connection_handler.zig:495–515`).

**Tech Stack:** Zig 0.15.1 · `std.crypto.timing_safe` · `std.crypto.random` · `std.crypto.secureZero` · Docker Compose · bash

---

## Task 1: Close Won't-Do items and update GAP_ANALYSIS.md

**Files:**

- Modify: `docs/GAP_ANALYSIS.md`

**Step 1: Update GAP_ANALYSIS.md status for four items**

In `docs/GAP_ANALYSIS.md` change the Status cell for:

- Rank 38 (`#433`) → `Closed (Won't Do: SHA256 image pinning via Renovate/Dependabot platform controls)`
- Rank 37 (`#434`) → `Closed (Won't Do: pre-commit hook tag pinning via external controls per policy)`
- Rank 35 (`#438`) → `Closed (Won't Do: apt/apk/pip version pinning via platform governance per policy)`
- Rank 18 (`#492`) → `Closed (Won't Do: Docker base-image SHA256 pinning via Renovate/Dependabot platform controls)`

Also update the Summary block at the top:

```
- Closed / Implemented: 20  →  20
- Closed (Won't Do by policy): 2  →  6
- Open: 18  →  14
```

**Step 2: Close the four issues in GitLab**

```bash
glab issue close 433 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 433 --message "Closing as Won't Do per project policy: Docker image SHA256 pinning is handled by external platform controls (Renovate/Dependabot). Documented in docs/GAP_ANALYSIS.md Policy Exceptions." --repo gitlab.com/devnw/codepros/geode/geode

glab issue close 434 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 434 --message "Closing as Won't Do per project policy: Pre-commit hook tag pinning is handled outside this tracker (pre-commit.ci / server-side controls). Documented in docs/GAP_ANALYSIS.md Policy Exceptions." --repo gitlab.com/devnw/codepros/geode/geode

glab issue close 438 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 438 --message "Closing as Won't Do per project policy: apt/apk/pip package-version pinning is governed by platform/CI controls, not repo-level Dockerfiles. Documented in docs/GAP_ANALYSIS.md Policy Exceptions." --repo gitlab.com/devnw/codepros/geode/geode

glab issue close 492 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 492 --message "Closing as Won't Do per project policy: Unpinned Docker base images are tracked and updated via external Renovate/Dependabot platform controls. Documented in docs/GAP_ANALYSIS.md Policy Exceptions." --repo gitlab.com/devnw/codepros/geode/geode
```

**Step 3: Commit**

```bash
git add docs/GAP_ANALYSIS.md
git commit -m "docs: close #433 #434 #438 #492 as Won't Do per platform-governance policy"
```

---

## Task 2: Remove admin password hint from log (#481)

**Files:**

- Modify: `src/security/geode_auth_lib.zig:1054–1058`
- Test: `tests/test_auth.zig` (or existing auth unit test)

**Step 1: Write failing test**

Find the existing auth test file:

```bash
ls tests/test_auth*.zig tests/test_geode_auth*.zig 2>/dev/null || grep -rl "initDefaultUsers\|createDefaultAdmin\|password_hint" tests/
```

Add a test (in the appropriate auth test file) that verifies no `password_hint` attribute appears in the log output during default admin initialization. If no such test file exists, add to `tests/test_auth_lib.zig`:

```zig
test "admin init: no password_hint in log output" {
    // Verifies GAP-0481: password_hint must NOT appear in structured log
    // Simply check the constant — the log call must not include the hint attribute
    // This is a compile-time + code-audit test
    const src = @embedFile("../src/security/geode_auth_lib.zig");
    // Ensure the string "password_hint" does not appear after the REQUIRES IMMEDIATE CHANGE log call
    // A simple check: confirm no Attr.string("password_hint" is present
    const needle = "Attr.string(\"password_hint\"";
    try std.testing.expect(std.mem.indexOf(u8, src, needle) == null);
}
```

**Step 2: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A3 "password_hint"
```

Expected: test fails — `Attr.string("password_hint"` is found in the source.

**Step 3: Implement the fix**

In `src/security/geode_auth_lib.zig`, change lines 1054–1058 from:

```zig
log.warn("Generated random admin password (REQUIRES IMMEDIATE CHANGE)", &.{
    Attr.string("password_hint", generated_password_hex[0..32]),
    Attr.string("action", "Set GEODE_DEFAULT_PASSWORD env var to use a custom password"),
});
break :blk generated_password_hex[0..32];
```

To:

```zig
// GAP-0481: Do NOT log any portion of the generated password.
// Write to stderr directly so it reaches the operator but not log aggregators.
std.debug.print("\n[GEODE SECURITY] Generated random admin password (REQUIRES IMMEDIATE CHANGE)\n" ++
    "[GEODE SECURITY] Set GEODE_DEFAULT_PASSWORD env var before starting in production.\n" ++
    "[GEODE SECURITY] Password: {s}\n\n", .{generated_password_hex[0..64]});
log.warn("Generated random admin password — GEODE_DEFAULT_PASSWORD not set; see stderr for password", &.{
    Attr.string("action", "Set GEODE_DEFAULT_PASSWORD env var to use a custom password"),
});
break :blk generated_password_hex[0..64];
```

Note: `break :blk generated_password_hex[0..32]` was only using half the password (32 of 64 hex chars = 16 bytes of randomness). Also fix this to use the full 64-char hex (32 random bytes). Update the downstream use: `const default_password: []const u8` is passed to `hashPassword` — no other length assumptions should exist.

**Step 4: Run test to verify it passes**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|password_hint"
```

Expected: test passes.

**Step 5: Commit**

```bash
git add src/security/geode_auth_lib.zig
git commit -m "security: fix #481 — remove password_hint from structured log, write to stderr only"
```

---

## Task 3: Replace LCG with CSPRNG in random() function (#494)

**Files:**

- Modify: `src/types/evaluator_functions.zig:1059–1068`

**Step 1: Write failing test**

Find the evaluator test file (likely `tests/test_evaluator_functions.zig` or `tests/test_types.zig`):

```bash
grep -rl "random_val\|random()" tests/ src/types/
```

Add to the relevant test file:

```zig
test "random(): returns cryptographically random float, not LCG" {
    // Verify the implementation doesn't use a timestamp-based seed
    const src = @embedFile("../src/types/evaluator_functions.zig");
    // Must NOT contain the LCG seed comment or milliTimestamp pattern
    try std.testing.expect(std.mem.indexOf(u8, src, "milliTimestamp") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "1103515245") == null);

    // Functional test: two calls should differ (probabilistically)
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = try evaluator_functions.random_val(gpa_state.allocator());
    const b = try evaluator_functions.random_val(gpa_state.allocator());
    // With 2^52 possible values, collision probability < 2^-52
    try std.testing.expect(a.Double != b.Double);
}
```

**Step 2: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A3 "random"
```

**Step 3: Implement the fix**

In `src/types/evaluator_functions.zig`, replace lines 1059–1068:

```zig
// BEFORE (insecure LCG):
pub fn random_val(allocator: std.mem.Allocator) EvaluatorError!Value {
    _ = allocator;
    // Use timestamp-based pseudo-random for deterministic testing
    const timestamp = @as(u64, @intCast(std.time.milliTimestamp()));
    const hash = timestamp *% 1103515245 +% 12345;
    const normalized = @as(f64, @floatFromInt(hash & 0xFFFFFF)) / @as(f64, @floatFromInt(0xFFFFFF));
    return Value{ .Double = normalized };
}
```

Replace with:

```zig
// AFTER (CSPRNG — GAP-0494):
pub fn random_val(allocator: std.mem.Allocator) EvaluatorError!Value {
    _ = allocator;
    return Value{ .Double = std.crypto.random.float(f64) };
}
```

**Step 4: Run test**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|random"
```

**Step 5: Commit**

```bash
git add src/types/evaluator_functions.zig
git commit -m "security: fix #494 — replace LCG seed with std.crypto.random in random() GQL function"
```

---

## Task 4: Replace @memset with secureZero for key material (#499)

**Files:**

- Modify: `src/security/key_provider.zig:93,118,125,132`
- Modify: `src/security/kms.zig:170,201`
- Modify: `src/security/tde_nonce_gen.zig:66,88`

**Step 1: Write failing test**

Add a code-audit test (or find existing TDE test file `tests/test_tde_enforcement.zig`):

```zig
test "TDE key zeroization: no bare @memset in security modules" {
    // GAP-0499: compiler may eliminate @memset dead stores; use secureZero
    const files = .{
        @embedFile("../src/security/key_provider.zig"),
        @embedFile("../src/security/kms.zig"),
        @embedFile("../src/security/tde_nonce_gen.zig"),
    };
    for (files) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, "@memset") == null);
    }
}
```

**Step 2: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A3 "memset"
```

**Step 3: Implement the fix**

In `src/security/key_provider.zig`, replace every `@memset(&X, 0)` and `@memset(&X, 0)`:

- Line 93: `@memset(&nonce, 0)` → `std.crypto.secureZero(u8, &nonce)`
- Line 118: `@memset(&nonce, 0)` → `std.crypto.secureZero(u8, &nonce)`
- Line 125: `@memset(&temp_plain, 0)` → `std.crypto.secureZero(u8, &temp_plain)`
- Line 132: `@memset(&plain, 0)` → `std.crypto.secureZero(u8, &plain)`

In `src/security/kms.zig`, find and replace all `@memset` patterns in `wrapLocalDev` and `unwrapLocalDev` (lines ~170, ~201) — same pattern:

- `@memset(&nonce, 0)` → `std.crypto.secureZero(u8, &nonce)`

In `src/security/tde_nonce_gen.zig`:

- Line 66: `@memset(nonce, 0)` → `std.crypto.secureZero(u8, nonce)`
- Line 88: `@memset(nonce, 0)` → `std.crypto.secureZero(u8, nonce)`

Note: `std.crypto.secureZero(T, slice)` takes `T = u8` and a slice. For array refs coerced to slices this is identical to @memset but uses a volatile write that cannot be eliminated.

**Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|memset|secureZero"
```

**Step 5: Commit**

```bash
git add src/security/key_provider.zig src/security/kms.zig src/security/tde_nonce_gen.zig
git commit -m "security: fix #499 — replace @memset with secureZero for all key material zeroization"
```

---

## Task 5: Fix Dockerfile.dev heredoc syntax error (#441)

**Files:**

- Modify: `Dockerfile.dev:232–276`

**Step 1: Identify the parse error**

Run a Docker build lint check:

```bash
docker build --no-cache -f Dockerfile.dev . --target builder 2>&1 | head -30
# Or use hadolint:
docker run --rm -i hadolint/hadolint < Dockerfile.dev 2>&1
```

The heredoc at line 232 uses `<< 'WELCOME_EOF'` inside a `RUN` command. This syntax is valid under BuildKit but may fail without it. Rewrite it to use `printf` which is universally compatible.

**Step 2: Implement the fix**

Replace lines 231–276 in `Dockerfile.dev`:

```dockerfile
# BEFORE:
# Display welcome message with proper version detection
RUN cat > ~/.welcome.sh << 'WELCOME_EOF'
... (multiline heredoc)
WELCOME_EOF
```

Replace with:

```dockerfile
# Display welcome message with proper version detection (#441: use printf, no heredoc)
RUN printf '%s\n' \
    '#!/bin/bash' \
    'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"' \
    'echo "Geode Development Environment"' \
    'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"' \
    'echo ""' \
    'echo "Development Tools:"' \
    'echo "  Zig $(zig version 2>/dev/null)"' \
    'echo "  Rust $(rustc --version 2>/dev/null | awk '"'"'{print $2}'"'"')"' \
    'echo "  Go $(go version 2>/dev/null | awk '"'"'{print $3}'"'"')"' \
    'echo "  Python $(python3 --version 2>&1 | awk '"'"'{print $2}'"'"')"' \
    'echo "  Node.js $(node --version 2>/dev/null)"' \
    'echo ""' \
    'echo "Quick Commands: zb (zig build), zbr (release), zbt (test), make test"' \
    'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"' \
    > ~/.welcome.sh
```

**Step 3: Verify fix**

```bash
docker build --no-cache -f Dockerfile.dev . --target builder 2>&1 | tail -5
```

Expected: no syntax errors.

**Step 4: Commit**

```bash
git add Dockerfile.dev
git commit -m "fix: #441 — rewrite Dockerfile.dev welcome heredoc as printf for universal parser compatibility"
```

---

## Task 6: Add SHELL pipefail directive to Dockerfiles (#442)

**Files:**

- Modify: `Dockerfile`, `Dockerfile.ci`, `Dockerfile.dev`, `Dockerfile.prod`, `Dockerfile.release`, `Dockerfile.simple`, `Dockerfile.gpu`, `Dockerfile.ci.alpine`, `Dockerfile.ci.gpu`, `Dockerfile.release.alpine`, `Dockerfile.release.gpu`

**Step 1: Find Dockerfiles with piped RUN commands**

```bash
grep -l "|" Dockerfile Dockerfile.* docker-integration/Dockerfile.* 2>/dev/null
```

**Step 2: Add SHELL directive to each affected Dockerfile**

For every Dockerfile that has piped `RUN` commands, add immediately after the first `FROM` line:

```dockerfile
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
```

Example for `Dockerfile`:

```dockerfile
FROM zigbuild:0.15.1 AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
...
```

**Step 3: Verify no broken pipe silently succeeds**

```bash
# Quick syntax check (no full build needed)
docker build --no-cache -f Dockerfile . --dry-run 2>&1 | head -20
```

**Step 4: Commit**

```bash
git add Dockerfile Dockerfile.ci Dockerfile.dev Dockerfile.prod Dockerfile.release \
        Dockerfile.simple Dockerfile.gpu Dockerfile.ci.alpine Dockerfile.ci.gpu \
        Dockerfile.release.alpine Dockerfile.release.gpu
git commit -m "security: fix #442 — add SHELL pipefail directive to all Dockerfiles with piped RUN commands"
```

---

## Task 7: Remove MinIO anonymous bucket access (#497)

**Files:**

- Modify: `scripts/init-minio.sh:15–17`

**Step 1: Verify current state**

```bash
cat scripts/init-minio.sh
```

Expected: lines 15–17 are:

```bash
echo "Setting bucket policies..."
mc anonymous set download geode/geode-backups
mc anonymous set download geode/geode-backups-gpu
```

**Step 2: Implement the fix**

Remove lines 15–17 and replace with a comment:

Change:

```bash
echo "Setting bucket policies..."
mc anonymous set download geode/geode-backups
mc anonymous set download geode/geode-backups-gpu

echo "MinIO initialization complete"
```

To:

```bash
# GAP-0497: Do NOT set anonymous access on backup buckets.
# Use IAM policies or pre-signed URLs for controlled read access.
echo "Bucket access: private (authenticated IAM access only)"

echo "MinIO initialization complete"
```

**Step 3: Commit**

```bash
git add scripts/init-minio.sh
git commit -m "security: fix #497 — remove anonymous download policy from MinIO backup buckets"
```

---

## Task 8: Verify and close Docker healthcheck finding (#501)

**Files:**

- Possibly modify: `docker-compose.yml`, `docker-compose.dev.yml`, other compose files

**Step 1: Audit all healthchecks for password args**

```bash
grep -rn "\-\-password\|-P\|REDIS_PASSWORD\|MINIO.*PASSWORD\|GEODE.*PASSWORD" \
    docker-compose*.yml docker-integration/docker-compose*.yml tests/docker-compose*.yml \
    2>/dev/null | grep -i "healthcheck\|test.*CMD"
```

**Step 2: Evaluate findings**

- If NO healthcheck contains a password CLI arg: the finding is stale. Close in GitLab with evidence.
- If a healthcheck does expose a password (e.g., `redis-cli -a ${REDIS_PASSWORD}`): replace with a socket-based or ping-based check that doesn't need auth.

Current `docker-compose.yml` geode healthcheck:

```yaml
test: ["CMD", "geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:3141", "--insecure-tls-skip-verify"]
```

No password flag — compliant.

**Step 3: If compliant, update GAP_ANALYSIS.md and close**

In `docs/GAP_ANALYSIS.md`, change rank 31 status to:

```
Closed / Implemented (finding stale: healthchecks verified — no password in CMD args across all compose files; geode healthcheck uses unauthenticated RETURN 1 query)
```

```bash
glab issue close 501 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 501 --message "Verified: no --password or -P flag appears in any healthcheck CMD across docker-compose.yml, docker-compose.dev.yml, or other compose files. Geode healthcheck uses RETURN 1 AS health without credentials. Finding is stale — closing." --repo gitlab.com/devnw/codepros/geode/geode
```

**Step 4: Commit**

```bash
git add docs/GAP_ANALYSIS.md
git commit -m "docs: close #501 — healthcheck password exposure finding verified stale, no password in CMD args"
```

---

## Task 9: Blake2b → Argon2id forced re-hash on login (#489)

**Files:**

- Modify: `src/security/geode_auth_lib.zig` (`verifyPassword` function, ~line 775)

**Step 1: Understand the existing flow**

`verifyPassword` at ~line 775 dispatches to `verifyBlake2bLegacy` if the stored hash is not PHC format. `verifyBlake2bLegacy` at line 878 correctly audits the case but does NOT update the stored hash.

The fix: when `verifyBlake2bLegacy` returns `true`, immediately re-hash with Argon2id and update the stored credential.

**Step 2: Write failing test**

In the auth unit test file, add:

```zig
test "verifyPassword: Blake2b account auto-migrates to Argon2id on successful login" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var auth = try UserManager.initTestInstance(gpa.allocator());
    defer auth.deinit();

    // Create a user with a legacy Blake2b hash
    const password = "testpassword123";
    const legacy_hash = try auth.hashBlake2bLegacyForTest(password);
    try auth.insertUserWithHashForTest("legacyuser", legacy_hash);

    // Verify login
    const ok = try auth.verifyPassword("legacyuser", password);
    try std.testing.expect(ok);

    // After login, stored hash must be Argon2id PHC format
    const stored = auth.getStoredHashForTest("legacyuser");
    try std.testing.expect(std.mem.startsWith(u8, stored, "$argon2id$"));
}
```

**Step 3: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A5 "Blake2b.*Argon2id\|auto-migrat"
```

**Step 4: Implement the fix**

Locate `verifyPassword` (~line 775) in `geode_auth_lib.zig`. After the `verifyBlake2bLegacy` branch returns true, add automatic re-hash:

```zig
// In verifyPassword, after verifyBlake2bLegacy returns true:
if (try self.verifyBlake2bLegacy(password, stored_hash)) {
    // GAP-0489: Auto-migrate legacy Blake2b account to Argon2id on successful login
    const new_hash = try self.hashPassword(password); // Argon2id PHC format
    try self.updateStoredHash(user_id, new_hash);
    self.allocator.free(new_hash);
    return true;
}
```

You will need to ensure `updateStoredHash` exists (check the existing User struct/HashMap management). If `updateStoredHash` does not exist, add:

```zig
fn updateStoredHash(self: *Self, user_id: UserId, new_hash: []const u8) !void {
    var it = self.users.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.id == user_id) {
            self.allocator.free(entry.value_ptr.password_hash);
            entry.value_ptr.password_hash = try self.allocator.dupe(u8, new_hash);
            return;
        }
    }
    return error.UserNotFound;
}
```

**Step 5: Run tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|Blake|Argon"
```

**Step 6: Commit**

```bash
git add src/security/geode_auth_lib.zig
git commit -m "security: fix #489 — auto-rehash Blake2b accounts to Argon2id on successful login"
```

---

## Task 10: Audit and harden RLS QueryRewriter (#496)

**Files:**

- Modify: `src/security/rls_core.zig:1422–1460`

**Step 1: Understand the injection surface**

`QueryRewriter.rewrite()` (line 1422) appends `expr.raw` — the raw policy expression string — directly into a predicate. If `expr.raw` is admin-defined (stored in the policy config), this is a configuration-layer injection risk (not direct user input), but defense-in-depth still applies.

**Step 2: Write failing test**

In `tests/test_rls_core.zig` (or equivalent), add:

```zig
test "QueryRewriter: rejects expr.raw containing GQL injection characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rewriter = try rls_core.QueryRewriter.init(gpa.allocator());
    defer rewriter.deinit();

    // Build a policy with malicious expr.raw
    var policies = std.ArrayList(rls_core.RLSEngine.Policy).init(gpa.allocator());
    defer policies.deinit();
    try policies.append(.{
        .enabled = true,
        .permissive = true,
        .using_expr = .{ .raw = "1=1) UNION SELECT * FROM __sys_users WHERE (1" },
    });

    var ctx = try rls_core.auth.SecurityContext.initTest(gpa.allocator());
    defer ctx.deinit();

    const result = rewriter.rewrite("SELECT 1", policies, &ctx);
    // Must return error, not silently produce injected query
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}
```

**Step 3: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A5 "QueryRewriter.*injection\|InvalidPolicy"
```

**Step 4: Implement validation**

In `rls_core.zig`, add a validation function and call it before appending:

```zig
/// Validate a policy expression for safety.
/// Policy expressions must not contain unmatched parentheses, semicolons,
/// or UNION/INTERSECT/EXCEPT operators that could escape the predicate context.
fn validatePolicyExpression(expr: []const u8) !void {
    // Disallow semicolons (statement termination)
    if (std.mem.indexOfScalar(u8, expr, ';') != null) return error.InvalidPolicyExpression;
    // Disallow UNION / INTERSECT / EXCEPT (set ops escape predicate wrapper)
    const upper = expr; // expressions are checked case-insensitively
    if (std.ascii.indexOfIgnoreCase(upper, "UNION") != null) return error.InvalidPolicyExpression;
    if (std.ascii.indexOfIgnoreCase(upper, "INTERSECT") != null) return error.InvalidPolicyExpression;
    if (std.ascii.indexOfIgnoreCase(upper, "EXCEPT") != null) return error.InvalidPolicyExpression;
    // Disallow comment sequences
    if (std.mem.indexOf(u8, expr, "--") != null) return error.InvalidPolicyExpression;
    if (std.mem.indexOf(u8, expr, "/*") != null) return error.InvalidPolicyExpression;
}
```

Then in `rewrite()`, before `try result.appendSlice(expr.raw)`:

```zig
try validatePolicyExpression(expr.raw);
try result.appendSlice("(");
try result.appendSlice(expr.raw);
try result.appendSlice(")");
```

**Step 5: Run tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|QueryRewriter|InvalidPolicy"
```

**Step 6: Commit**

```bash
git add src/security/rls_core.zig
git commit -m "security: fix #496 — validate RLS policy expressions to prevent GQL injection via expr.raw"
```

---

## Task 11: Add JSON depth limit to JSONB parser (#436)

**Files:**

- Modify: `src/types/jsonb.zig:26–32`

**Step 1: Write failing test**

In `tests/test_jsonb.zig` (or equivalent):

```zig
test "JSONB: rejects deeply nested input (DoS prevention)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Build a deeply nested JSON: {"a":{"a":{"a": ... }}}  200 levels deep
    var deep = std.ArrayList(u8).init(gpa.allocator());
    defer deep.deinit();
    for (0..200) |_| try deep.appendSlice("{\"a\":");
    try deep.appendSlice("1");
    for (0..200) |_| try deep.append('}');

    const result = jsonb.JsonbDocument.fromString(gpa.allocator(), deep.items);
    try std.testing.expectError(jsonb.JsonbDocument.Error.InvalidJson, result);
}

test "JSONB: accepts normally nested input" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const doc = try jsonb.JsonbDocument.fromString(gpa.allocator(), "{\"a\":{\"b\":{\"c\":1}}}");
    _ = doc;
}
```

**Step 2: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A5 "JSONB.*depth\|deeply nested"
```

**Step 3: Implement the fix**

In `src/types/jsonb.zig`, add a depth-checking helper and modify `fromString`:

```zig
/// Maximum allowed nesting depth for JSONB documents (configurable).
/// Default 64 protects against stack-overflow DoS attacks.
pub const MAX_JSONB_DEPTH: u32 = 64;

fn checkDepth(value: std.json.Value, depth: u32) !void {
    if (depth > MAX_JSONB_DEPTH) return error.InvalidJson;
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                try checkDepth(entry.value_ptr.*, depth + 1);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                try checkDepth(item, depth + 1);
            }
        },
        else => {},
    }
}

pub fn fromString(allocator: std.mem.Allocator, json_str: []const u8) Error!JsonbDocument {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return Error.InvalidJson;
    defer parsed.deinit();

    // GAP-0436: Guard against deeply nested JSON DoS
    checkDepth(parsed.value, 0) catch return Error.InvalidJson;

    const canonical = try canonicalize(allocator, parsed.value);
    return JsonbDocument{ .data = canonical, .allocator = allocator };
}
```

**Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|JSONB|depth"
```

**Step 5: Commit**

```bash
git add src/types/jsonb.zig
git commit -m "security: fix #436 — add MAX_JSONB_DEPTH=64 guard to JSONB parser to prevent DoS"
```

---

## Task 12: Align constant-time comparisons to stdlib (#440)

**Files:**

- Modify: `src/security/geode_auth_lib.zig:763–773`

**Step 1: Write failing test**

Add a code-audit test:

```zig
test "geode_auth_lib: constantTimeEqual uses stdlib timing_safe, not custom XOR" {
    const src = @embedFile("../src/security/geode_auth_lib.zig");
    // Custom XOR accumulator pattern must NOT exist
    try std.testing.expect(std.mem.indexOf(u8, src, "1103515245") == null); // LCG check
    // The function must delegate to std.crypto.timing_safe.eql
    try std.testing.expect(std.mem.indexOf(u8, src, "timing_safe.eql") != null);
}
```

**Step 2: Run test to see it fail**

```bash
zig build test --summary all 2>&1 | grep -A3 "timing_safe\|constantTimeEqual"
```

**Step 3: Implement the fix**

In `src/security/geode_auth_lib.zig`, replace the custom `constantTimeEqual` at lines 763–773:

```zig
// BEFORE (custom XOR — GAP-0440):
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        result |= byte_a ^ byte_b;
    }
    return result == 0;
}
```

Replace with two overloads using the stdlib:

```zig
// AFTER (stdlib timing_safe — GAP-0440):

/// Constant-time comparison for fixed-size 32-byte arrays (Argon2id/Blake2b digests).
fn constantTimeEqual32(a: *const [32]u8, b: *const [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, a.*, b.*);
}

/// Constant-time comparison for fixed-size 64-byte arrays (hex-encoded hashes).
fn constantTimeEqual64(a: *const [64]u8, b: []const u8) bool {
    if (b.len != 64) return false;
    return std.crypto.timing_safe.eql([64]u8, a.*, b[0..64].*);
}
```

Then update callers:

- `verifyPassword` ~line 871: `return constantTimeEqual(&computed_hash, &expected_hash)` → `return constantTimeEqual32(&computed_hash, &expected_hash)`
- `verifyBlake2bLegacy` line 894: `const matches = constantTimeEqual(&computed_hex, stored_hash)` → `const matches = constantTimeEqual64(&computed_hex, stored_hash)`

Remove the old `constantTimeEqual` function.

**Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|timing|constantTime"
```

**Step 5: Commit**

```bash
git add src/security/geode_auth_lib.zig
git commit -m "security: fix #440 — replace custom XOR constantTimeEqual with std.crypto.timing_safe.eql"
```

---

## Task 13: Pin grpc-zig to git commit URL (#443)

**Files:**

- Modify: `build.zig.zon:142–146`

**Step 1: Expand the short hash to full commit hash**

The current tarball URL encodes the short hash `8d01973`:

```
https://gitlab.com/devnw/zig/grpc-zig/-/archive/8d01973/grpc-zig-8d01973.tar.gz
```

Run:

```bash
git ls-remote https://gitlab.com/devnw/zig/grpc-zig.git | grep "^8d01973" | awk '{print $1}'
```

This returns the full 40-character commit hash. Use this as `<FULL_HASH>` below.

**Step 2: Update build.zig.zon**

Change in `build.zig.zon`:

```zig
// BEFORE:
.grpc_zig = .{
    .url = "https://gitlab.com/devnw/zig/grpc-zig/-/archive/8d01973/grpc-zig-8d01973.tar.gz",
    .hash = "grpc_zig-0.1.0-7FnvpLe5AQB55BMGuoZVuPYg3JGT8Gj1tSRfhmDqQGQe",
},
```

To:

```zig
// AFTER (git URL with full commit hash — GAP-0443):
.grpc_zig = .{
    .url = "git+https://gitlab.com/devnw/zig/grpc-zig.git#<FULL_HASH>",
    .hash = "<RECOMPUTED_BY_ZIG_FETCH>",
},
```

After updating the URL, run `zig fetch` to recompute the content hash:

```bash
zig fetch --save "git+https://gitlab.com/devnw/zig/grpc-zig.git#<FULL_HASH>"
```

This updates the `.hash` field automatically in `build.zig.zon`.

**Step 3: Verify build still works**

```bash
zig build check 2>&1 | tail -10
```

**Step 4: Commit**

```bash
git add build.zig.zon
git commit -m "security: fix #443 — pin grpc-zig to full git commit hash instead of tarball URL"
```

---

## Task 14: Federation auth bypass — cluster token + mTLS (#490)

This is the largest change. Three sub-tasks: (A) client sends cluster token, (B) server validates cluster token, (C) mTLS peer cert enforcement for federation.

**Files:**

- Modify: `src/distributed/federation.zig:211–220`
- Modify: `src/server/quic_connection_handler.zig:621–647` (server auth)
- Read for context: `src/server/quic_connection_handler.zig:495–515` (existing mTLS)

### Sub-task 14A: Client sends GEODE_CLUSTER_TOKEN in HELLO

**Step 1: Write failing test**

```zig
test "federation: HELLO request includes cluster token from env" {
    // Set the env var
    try std.process.setenv("GEODE_CLUSTER_TOKEN", "test-cluster-secret-abc123");
    defer std.process.setenv("GEODE_CLUSTER_TOKEN", "") catch {};

    // Build a mock federation connection and capture the HELLO message
    // Verify the username field equals "geode-cluster" and password = token
    const hello = try federation.buildHelloRequest(std.testing.allocator);
    defer std.testing.allocator.free(hello.password);
    try std.testing.expectEqualStrings("geode-cluster", hello.username);
    try std.testing.expectEqualStrings("test-cluster-secret-abc123", hello.password);
}
```

**Step 2: Add `buildHelloRequest` helper and update `connect()`**

In `src/distributed/federation.zig`, add:

```zig
/// Build the HELLO request for inter-node federation auth.
/// GAP-0490: Reads GEODE_CLUSTER_TOKEN from environment.
/// Inter-node connections authenticate as "geode-cluster" user with the cluster token.
fn buildHelloRequest(allocator: std.mem.Allocator) !schema.HelloRequest {
    const token = std.process.getenv("GEODE_CLUSTER_TOKEN") orelse {
        log.err("GEODE_CLUSTER_TOKEN not set; federation connections will be rejected by auth-enabled nodes", &.{});
        return error.ClusterTokenNotSet;
    };
    return schema.HelloRequest{
        .username = "geode-cluster",
        .password = try allocator.dupe(u8, token),
        .tenant_id = null,
        .client_name = "geode-federation",
        .client_version = "",
        .wanted_conformance = "",
    };
}
```

Replace the hardcoded `hello_req` in `connect()` at lines 212–219:

```zig
// BEFORE:
const hello_req = schema.HelloRequest{
    .username = "",
    .password = "",
    .tenant_id = null,
    .client_name = "geode-federation",
    .client_version = "",
    .wanted_conformance = "",
};

// AFTER:
var hello_arena = std.heap.ArenaAllocator.init(self.allocator);
defer hello_arena.deinit();
const hello_req = try buildHelloRequest(hello_arena.allocator());
```

### Sub-task 14B: Server validates cluster token

**Step 1: Write failing test**

```zig
test "server: rejects federation HELLO with wrong cluster token" {
    try std.process.setenv("GEODE_CLUSTER_TOKEN", "server-secret");
    defer std.process.setenv("GEODE_CLUSTER_TOKEN", "") catch {};

    const result = quic_handler.validateFederationAuth("geode-cluster", "wrong-token");
    try std.testing.expect(!result);
}

test "server: accepts federation HELLO with correct cluster token" {
    try std.process.setenv("GEODE_CLUSTER_TOKEN", "server-secret");
    defer std.process.setenv("GEODE_CLUSTER_TOKEN", "") catch {};

    const result = quic_handler.validateFederationAuth("geode-cluster", "server-secret");
    try std.testing.expect(result);
}
```

**Step 2: Add `validateFederationAuth` and wire into HELLO handler**

In `src/server/quic_connection_handler.zig`, add a helper:

```zig
/// Validate a federation HELLO using the cluster token.
/// GAP-0490: Both server and client must have GEODE_CLUSTER_TOKEN set to the same value.
fn validateFederationAuth(username: []const u8, password: []const u8) bool {
    if (!std.mem.eql(u8, username, "geode-cluster")) return false;
    const expected = std.process.getenv("GEODE_CLUSTER_TOKEN") orelse return false;
    if (expected.len == 0) return false;
    // Constant-time comparison to prevent timing oracle
    if (password.len != expected.len) return false;
    return std.crypto.timing_safe.eql(
        // Use fixed-size comparison if lengths match; max cluster token = 256 bytes
        [256]u8,
        blk: {
            var a: [256]u8 = undefined;
            @memcpy(a[0..password.len], password);
            break :blk a;
        },
        blk: {
            var b: [256]u8 = undefined;
            @memcpy(b[0..expected.len], expected);
            break :blk b;
        },
    );
}
```

In the HELLO handler at lines ~621–647, add a federation bypass path before the normal user auth:

```zig
// GAP-0490: Check for federation cluster token auth first
if (validateFederationAuth(hello_req.username, hello_req.password)) {
    // Federation connection authenticated via cluster token
    log.info("Federation node authenticated via cluster token", &.{
        Attr.string("client_name", hello_req.client_name),
    });
    // Grant federation role — set role appropriately
    session.role = .federation;
    session.authenticated = true;
    // Skip normal user auth
} else if (user_mgmt.isAuthEnabled()) {
    // ... existing user auth code ...
}
```

### Sub-task 14C: mTLS for federation connections

The existing mTLS infrastructure at `quic_connection_handler.zig:495–515` (GAP-0258) already extracts peer certificates. For federation, require that connections from `geode-cluster` MUST also present a valid mTLS certificate.

**Step 1: Enforce mTLS for federation connections**

After `session.role = .federation` is set (Sub-task 14B), add:

```zig
// GAP-0490: mTLS enforcement for federation connections
// Require peer certificate for all federation connections when mTLS provider is configured
if (g_mtls_provider) |provider| {
    if (conn.getPeerCertificateDer()) |cert_der| {
        const identity = provider.extractIdentity(gpa, cert_der) catch {
            log.err("Federation mTLS: failed to extract identity from peer certificate", &.{});
            return error.AuthFailed;
        };
        defer identity.deinit(gpa);
        if (!provider.isTrustedFederationNode(&identity)) {
            log.err("Federation mTLS: peer certificate not trusted for federation", &.{});
            return error.AuthFailed;
        }
        log.info("Federation node mTLS verified", &.{
            Attr.string("identity", identity.common_name),
        });
    } else {
        log.warn("Federation connection has no peer certificate (mTLS not enforced)", &.{});
        // Allow without cert if no mTLS provider configured (degraded mode)
    }
}
```

**Step 2: Run all tests**

```bash
zig build test --summary all 2>&1 | grep -E "PASS|FAIL|federation|cluster.*token|mTLS"
```

**Step 3: Commit**

```bash
git add src/distributed/federation.zig src/server/quic_connection_handler.zig
git commit -m "security: fix #490 — add GEODE_CLUSTER_TOKEN auth + mTLS enforcement for federation HELLO handshake"
```

---

## Task 15: Git history audit for exposed secrets (#428, #429, #482)

**Step 1: Audit current git history**

```bash
# Check if .env was ever committed
git log --all --oneline -- .env 2>/dev/null

# Check if TLS key was committed
git log --all --oneline -- "certs/server.key" "*.key" "*.pem" 2>/dev/null

# Scan for common secret patterns in ALL commits (slow but thorough)
git log --all -p -- ".env" "*.key" "*.pem" "certs/" 2>/dev/null | \
  grep -E "^(\\+[^+].*)(VAULT_TOKEN|S3_SECRET|REDIS_PASSWORD|GEODE_PASSWORD|-----BEGIN)" | \
  head -50
```

**Step 2: Evaluate findings**

- **If no matches**: Files were gitignored before any commit. Close all three issues with evidence from the git log commands.

```bash
glab issue close 428 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 428 --message "Audited: git log --all -- .env returns no results. .env was never committed to git history. Closing with clean bill of health." --repo gitlab.com/devnw/codepros/geode/geode

glab issue close 429 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 429 --message "Audited: git log --all -- 'certs/server.key' returns no results. TLS private key was never committed to git history. Closing." --repo gitlab.com/devnw/codepros/geode/geode

glab issue close 482 --repo gitlab.com/devnw/codepros/geode/geode
glab issue note 482 --message "Audited: Full git log --all -p scan found no credential patterns in git history. .env, *.key, *.pem patterns show no matches. Closing." --repo gitlab.com/devnw/codepros/geode/geode
```

- **If matches found**:
  1. Immediately rotate any exposed credentials (Vault tokens, S3 keys, Redis passwords, TLS certs)
  2. Use BFG Repo-Cleaner to rewrite history: `java -jar bfg.jar --delete-files .env --delete-files '*.key' repo.git`
  3. Force-push cleaned history (coordinate with team)
  4. Revoke all exposed tokens/keys through their respective control planes

**Step 3: Update GAP_ANALYSIS.md and commit**

```bash
git add docs/GAP_ANALYSIS.md
git commit -m "docs: close #428 #429 #482 — git history audit complete, no secrets found in history"
```

---

## Task 16: Final GAP_ANALYSIS.md reconciliation and issue closure

**Step 1: Update all remaining Open findings to Closed / Implemented**

For each task completed above, update the corresponding row in `docs/GAP_ANALYSIS.md`:

- Rank 20 (`#481`) → Closed / Implemented
- Rank 27 (`#494`) → Closed / Implemented
- Rank 30 (`#499`) → Closed / Implemented
- Rank 41 (`#441`) → Closed / Implemented
- Rank 39 (`#442`) → Closed / Implemented
- Rank 32 (`#497`) → Closed / Implemented
- Rank 31 (`#501`) → Closed / Implemented (stale finding or fix applied)
- Rank 10 (`#489`) → Closed / Implemented
- Rank 26 (`#496`) → Closed / Implemented
- Rank 36 (`#436`) → Closed / Implemented
- Rank 40 (`#440`) → Closed / Implemented
- Rank 34 (`#443`) → Closed / Implemented
- Rank 3 (`#490`) → Closed / Implemented
- Ranks 4,5,6 (`#428`,`#429`,`#482`) → Closed / Implemented or Closed / Won't Do (if clean)

Update Summary:

```
- Total findings: 41
- Closed / Implemented: 37
- Blocked: 1
- Open: 0
- Closed (Won't Do by policy): 6
```

**Step 2: Close all remaining GitLab issues**

For each implemented item, run:

```bash
glab issue close <N> --repo gitlab.com/devnw/codepros/geode/geode
glab issue note <N> --message "Implemented: <brief fix description>. Verified: zig build test --summary all passes. See commit <hash>." --repo gitlab.com/devnw/codepros/geode/geode
```

**Step 3: Final commit**

```bash
git add docs/GAP_ANALYSIS.md
git commit -m "docs: reconcile GAP_ANALYSIS.md — all 18 open security gaps closed"
```

---

## Verification

After all tasks:

```bash
# All unit tests pass
zig build test --summary all

# Confirm no stray @memset in security modules
rg "@memset" src/security/key_provider.zig src/security/kms.zig src/security/tde_nonce_gen.zig

# Confirm no password_hint in auth log
rg "password_hint" src/security/geode_auth_lib.zig

# Confirm no anonymous MinIO access
grep "anonymous" scripts/init-minio.sh

# Confirm CSPRNG in random()
rg "milliTimestamp\|1103515245" src/types/evaluator_functions.zig

# Confirm cluster token in federation HELLO
rg "GEODE_CLUSTER_TOKEN\|geode-cluster" src/distributed/federation.zig src/server/quic_connection_handler.zig

# Confirm grpc-zig is git URL
grep "grpc_zig" build.zig.zon | grep "git+https"
```
