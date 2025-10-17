# Comprehensive Remediation Plan - October 2025

**Status**: 🔴 **ACTIVE** - Critical fixes in progress
**Target**: Production-ready codebase within 3 months
**Blocking Issues**: 7 critical security vulnerabilities

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Phase 1: Critical Security Fixes (P0)](#phase-1-critical-security-fixes-p0)
3. [Phase 2: Major Issues & Technical Debt (P1)](#phase-2-major-issues--technical-debt-p1)
4. [Phase 3: Code Quality & Architecture (P2)](#phase-3-code-quality--architecture-p2)
5. [Phase 4: Long-term Improvements (P3)](#phase-4-long-term-improvements-p3)
6. [Implementation Timeline](#implementation-timeline)
7. [Success Criteria](#success-criteria)
8. [Risk Management](#risk-management)

---

## Executive Summary

### Remediation Strategy

**Approach**: Phased remediation with **security-first** priority

- **Phase 1** (2-3 weeks): Fix all 7 critical security vulnerabilities
- **Phase 2** (4-6 weeks): Address major technical debt and architecture issues
- **Phase 3** (2-3 months): Code quality improvements and refactoring
- **Phase 4** (3-6 months): Long-term architectural improvements

### Resource Requirements

| Phase | Duration | Team Size | Focus Areas |
|-------|----------|-----------|-------------|
| Phase 1 | 2-3 weeks | 3-4 engineers | Security, crypto, auth |
| Phase 2 | 4-6 weeks | 4-5 engineers | Refactoring, testing |
| Phase 3 | 2-3 months | 3-4 engineers | Code quality, docs |
| Phase 4 | 3-6 months | 2-3 engineers | Architecture |

### Success Metrics

- **Security**: Zero critical vulnerabilities
- **Test Coverage**: Maintain >95% passing rate
- **Code Quality**: All files <1000 lines, functions <50 lines
- **Performance**: No regressions from current benchmarks
- **Memory**: Zero detected leaks in 24-hour stress test

---

## Phase 1: Critical Security Fixes (P0)

**Duration**: 2-3 weeks
**Status**: 🔴 NOT STARTED
**Blocking**: Production deployment

### 1.1 Cryptographic Nonce Reuse (C1)

**Priority**: P0-1 (Highest)
**Owner**: Security Team
**Estimated Effort**: 2 days
**Dependencies**: None

#### Implementation Steps

1. **Day 1: Fix Implementation**
   ```bash
   # Create feature branch
   git checkout -b fix/critical-tde-nonce-reuse
   ```

   **File**: `src/security/tde.zig:88-92`

   **Changes**:
   ```zig
   // BEFORE (INSECURE):
   var nonce: [NonceBytes]u8 = undefined;
   const h = std.hash.Wyhash.hash(0, plaintext[0..@min(plaintext.len, 8)]);
   std.mem.writeInt(u64, nonce[0..8], h, .little);
   std.mem.writeInt(u32, nonce[8..12], @as(u32, @intCast(plaintext.len)), .little);

   // AFTER (SECURE):
   var nonce: [NonceBytes]u8 = undefined;
   std.crypto.random.bytes(&nonce);  // Cryptographically secure random nonce

   // Update CANARY marker:
   // CANARY: REQ=REQ-TDE-NONCE-001; FEATURE="TDE_AES_GCM"; ASPECT=NONCE_GENERATION;
   //         STATUS=IMPL; OWNER=security; UPDATED=2025-10-17;
   //         EVIDENCE="Cryptographically secure random nonces via std.crypto.random"
   ```

2. **Day 1-2: Add Comprehensive Tests**

   **File**: `src/security/test_tde_nonce.zig` (new)
   ```zig
   const std = @import("std");
   const testing = std.testing;
   const tde = @import("tde.zig");

   test "TDE nonce uniqueness - 10000 encryptions" {
       var arena = std.heap.ArenaAllocator.init(testing.allocator);
       defer arena.deinit();
       const ally = arena.allocator();

       var nonce_set = std.AutoHashMap([12]u8, void).init(ally);

       const plaintext = "test data";
       const aad = "test aad";

       var i: usize = 0;
       while (i < 10000) : (i += 1) {
           const ct = try tde.encrypt(ally, plaintext, aad);
           defer ally.free(ct.data);

           const result = try nonce_set.getOrPut(ct.nonce);
           try testing.expect(!result.found_existing); // All nonces must be unique
       }

       try testing.expectEqual(@as(usize, 10000), nonce_set.count());
   }

   test "TDE same plaintext produces different ciphertexts" {
       var arena = std.heap.ArenaAllocator.init(testing.allocator);
       defer arena.deinit();
       const ally = arena.allocator();

       const plaintext = "sensitive data";
       const aad = "context";

       const ct1 = try tde.encrypt(ally, plaintext, aad);
       defer ally.free(ct1.data);

       const ct2 = try tde.encrypt(ally, plaintext, aad);
       defer ally.free(ct2.data);

       // Nonces must differ
       try testing.expect(!std.mem.eql(u8, &ct1.nonce, &ct2.nonce));

       // Ciphertexts must differ (probabilistic check)
       try testing.expect(!std.mem.eql(u8, ct1.data, ct2.data));
   }

   test "TDE concurrent encryption nonce uniqueness" {
       // Stress test: multiple threads encrypting simultaneously
       const ThreadCount = 4;
       const EncryptionsPerThread = 1000;

       var nonce_set = std.AutoHashMap([12]u8, void).init(testing.allocator);
       defer nonce_set.deinit();

       var mutex = std.Thread.Mutex{};

       var threads: [ThreadCount]std.Thread = undefined;
       for (&threads) |*thread| {
           thread.* = try std.Thread.spawn(.{}, encryptWorker, .{&nonce_set, &mutex});
       }

       for (threads) |thread| {
           thread.join();
       }

       try testing.expectEqual(@as(usize, ThreadCount * EncryptionsPerThread),
                               nonce_set.count());
   }
   ```

3. **Day 2: Security Review & Documentation**
   - Update CANARY markers with evidence
   - Add security documentation in `docs/SECURITY.md`
   - Document nonce generation in API reference

4. **Day 2: Create PR & Review**
   ```bash
   git add src/security/tde.zig src/security/test_tde_nonce.zig
   git commit -m "fix(tde): Replace deterministic nonce with crypto-secure random

   CRITICAL SECURITY FIX: Addresses CWE-330, CWE-323

   - Replace Wyhash-based deterministic nonce with std.crypto.random
   - Add comprehensive nonce uniqueness tests (10k encryptions)
   - Add concurrent encryption stress test
   - Update CANARY markers with implementation evidence

   Fixes: #SECURITY-001
   OWASP: A02:2021 (Cryptographic Failures)"

   git push origin fix/critical-tde-nonce-reuse
   # Create PR, assign 2 security reviewers
   ```

#### Verification Checklist

- [ ] All tests pass: `zig build test`
- [ ] Nonce uniqueness test passes (10k iterations)
- [ ] Concurrent encryption test passes
- [ ] Security team code review complete
- [ ] CANARY markers updated with STATUS=IMPL
- [ ] Documentation updated
- [ ] No performance regression (<5% slowdown acceptable)

---

### 1.2 Weak Password Hashing (C2)

**Priority**: P0-2
**Owner**: Security Team
**Estimated Effort**: 3 days
**Dependencies**: None

#### Implementation Steps

1. **Day 1: Implement Argon2id**

   **File**: `src/security/auth.zig:670-692`

   **Changes**:
   ```zig
   // Remove old Blake2b implementation
   pub fn hashPassword(self: *Self, password: []const u8) ![]const u8 {
       try self.validatePasswordAgainstCurrentPolicy(password);

       // Generate cryptographically random 16-byte salt
       var salt: [16]u8 = undefined;
       std.crypto.random.bytes(&salt);

       // Argon2id with OWASP recommended parameters
       const params = std.crypto.pwhash.argon2.Params{
           .t = 2,       // 2 iterations (OWASP minimum)
           .m = 19456,   // 19 MiB memory (OWASP minimum)
           .p = 1,       // 1 parallel lane
       };

       var hash: [32]u8 = undefined;
       try std.crypto.pwhash.argon2.kdf(
           self.allocator,
           &hash,
           password,
           &salt,
           params,
           .argon2id
       );

       // Encode as PHC string format: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
       const salt_b64 = try base64Encode(self.allocator, &salt);
       defer self.allocator.free(salt_b64);

       const hash_b64 = try base64Encode(self.allocator, &hash);
       defer self.allocator.free(hash_b64);

       return try std.fmt.allocPrint(
           self.allocator,
           "$argon2id$v=19$m=19456,t=2,p=1${s}${s}",
           .{salt_b64, hash_b64}
       );
   }

   fn verifyPassword(self: *Self, password: []const u8, phc_string: []const u8) !bool {
       // Parse PHC string
       const parsed = try parsePHC(phc_string);

       // Re-hash with same salt and params
       var hash: [32]u8 = undefined;
       try std.crypto.pwhash.argon2.kdf(
           self.allocator,
           &hash,
           password,
           &parsed.salt,
           parsed.params,
           .argon2id
       );

       // Constant-time comparison
       return std.crypto.utils.timingSafeEql(
           [32]u8,
           hash,
           parsed.hash
       );
   }

   // Helper: PHC string parser
   const PHCParsed = struct {
       salt: [16]u8,
       hash: [32]u8,
       params: std.crypto.pwhash.argon2.Params,
   };

   fn parsePHC(phc_string: []const u8) !PHCParsed {
       // Parse $argon2id$v=19$m=19456,t=2,p=1$salt$hash
       var parts = std.mem.split(u8, phc_string, "$");

       _ = parts.next(); // Empty before first $
       const alg = parts.next() orelse return error.InvalidPHC;
       if (!std.mem.eql(u8, alg, "argon2id")) return error.UnsupportedAlgorithm;

       const version = parts.next() orelse return error.InvalidPHC;
       if (!std.mem.eql(u8, version, "v=19")) return error.UnsupportedVersion;

       const params_str = parts.next() orelse return error.InvalidPHC;
       const params = try parseParams(params_str);

       const salt_b64 = parts.next() orelse return error.InvalidPHC;
       const salt = try base64Decode(salt_b64);

       const hash_b64 = parts.next() orelse return error.InvalidPHC;
       const hash = try base64Decode(hash_b64);

       return PHCParsed{
           .salt = salt,
           .hash = hash,
           .params = params,
       };
   }
   ```

2. **Day 2: Add Comprehensive Tests**

   **File**: `src/security/test_password_hashing.zig` (new)
   ```zig
   test "Argon2id password hashing - unique salts" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       const password = "MySecurePassword123!";

       const hash1 = try manager.hashPassword(password);
       defer testing.allocator.free(hash1);

       const hash2 = try manager.hashPassword(password);
       defer testing.allocator.free(hash2);

       // Same password must produce different hashes (different salts)
       try testing.expect(!std.mem.eql(u8, hash1, hash2));

       // Both must verify correctly
       try testing.expect(try manager.verifyPassword(password, hash1));
       try testing.expect(try manager.verifyPassword(password, hash2));
   }

   test "Argon2id password verification - wrong password fails" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       const correct = "CorrectPassword123!";
       const wrong = "WrongPassword456!";

       const hash = try manager.hashPassword(correct);
       defer testing.allocator.free(hash);

       try testing.expect(try manager.verifyPassword(correct, hash));
       try testing.expect(!try manager.verifyPassword(wrong, hash));
   }

   test "Argon2id PHC string format validation" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       const password = "TestPassword!";
       const hash = try manager.hashPassword(password);
       defer testing.allocator.free(hash);

       // Verify PHC format
       try testing.expect(std.mem.startsWith(u8, hash, "$argon2id$v=19$m=19456,t=2,p=1$"));

       // Verify 5 parts separated by $
       var parts = std.mem.split(u8, hash, "$");
       var count: usize = 0;
       while (parts.next()) |_| count += 1;
       try testing.expectEqual(@as(usize, 6), count); // Empty + 5 parts
   }

   test "Argon2id performance - timing within bounds" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       const password = "BenchmarkPassword!";

       const start = std.time.milliTimestamp();
       const hash = try manager.hashPassword(password);
       const end = std.time.milliTimestamp();

       testing.allocator.free(hash);

       const duration_ms = end - start;

       // OWASP recommends 100-500ms for password hashing
       try testing.expect(duration_ms >= 50);  // At least 50ms
       try testing.expect(duration_ms <= 1000); // At most 1s (CI may be slow)
   }
   ```

3. **Day 2-3: Migration Strategy**

   **File**: `src/security/password_migration.zig` (new)
   ```zig
   // Support gradual migration from Blake2b to Argon2id
   pub fn verifyPasswordWithMigration(
       self: *SecurityManager,
       password: []const u8,
       stored_hash: []const u8,
       user_id: []const u8,
   ) !bool {
       // Check if hash is PHC format (Argon2id)
       if (std.mem.startsWith(u8, stored_hash, "$argon2id$")) {
           return self.verifyPassword(password, stored_hash);
       }

       // Legacy Blake2b hash (64 hex chars)
       if (stored_hash.len == 64 and isHexString(stored_hash)) {
           // Verify using old method
           const is_valid = try self.verifyPasswordLegacy(password, stored_hash);

           if (is_valid) {
               // Auto-migrate to Argon2id
               const new_hash = try self.hashPassword(password);
               try self.updateUserPasswordHash(user_id, new_hash);

               std.log.info("Migrated user {s} from Blake2b to Argon2id", .{user_id});
           }

           return is_valid;
       }

       return error.UnrecognizedHashFormat;
   }
   ```

4. **Day 3: Update Documentation & CANARY Markers**
   ```zig
   // CANARY: REQ=REQ-AUTH-HASH-001; FEATURE="Argon2id Password Hashing";
   //         ASPECT=IMPLEMENTATION; STATUS=IMPL; OWNER=security;
   //         UPDATED=2025-10-18;
   //         EVIDENCE="Full Argon2id implementation with PHC format, OWASP parameters (m=19456,t=2,p=1)"
   ```

#### Verification Checklist

- [ ] All tests pass with Argon2id implementation
- [ ] Performance test: 100-500ms hash time
- [ ] Migration path tested for existing Blake2b hashes
- [ ] PHC string parsing validated
- [ ] Constant-time comparison used
- [ ] CANARY markers updated to STATUS=IMPL
- [ ] Security audit log entry created
- [ ] User documentation updated

---

### 1.3 Timing Attack in Password Verification (C3)

**Priority**: P0-3
**Owner**: Security Team
**Estimated Effort**: 1 day
**Dependencies**: C2 (should be done together)

#### Implementation Steps

1. **Day 1: Fix All Timing-Sensitive Comparisons**

   **Affected Files**:
   - `src/security/auth.zig:694-701`
   - `src/types/hash.zig:165-174`
   - Any other sensitive comparisons

   **Changes**:
   ```zig
   // auth.zig - Already fixed in C2, but verify:
   fn verifyPassword(self: *Self, password: []const u8, stored_hash: []const u8) !bool {
       const computed_hash = try self.hashPassword(password);
       defer self.allocator.free(computed_hash);

       if (computed_hash.len != stored_hash.len) return false;

       return std.crypto.utils.timingSafeEql(
           [computed_hash.len]u8,
           computed_hash[0..computed_hash.len].*,
           stored_hash[0..stored_hash.len].*
       );
   }

   // types/hash.zig - Fix hash comparison
   pub fn equals(a: Hash, b: Hash) bool {
       // Algorithm/length mismatches are not timing-sensitive
       if (a.alg != b.alg or a.digest.len != b.digest.len) {
           return false;
       }

       // Use constant-time comparison for digest
       return std.crypto.utils.timingSafeEql(
           [a.digest.len]u8,
           a.digest[0..a.digest.len].*,
           b.digest[0..b.digest.len].*
       );
   }

   // Audit other sensitive comparisons:
   // - Session token validation
   // - API key comparison
   // - HMAC verification
   // - Signature verification
   ```

2. **Day 1: Add Timing Attack Tests**

   **File**: `src/security/test_timing_attacks.zig` (new)
   ```zig
   test "Password verification - timing resistance" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       const correct = "CorrectPassword123!";
       const hash = try manager.hashPassword(correct);
       defer testing.allocator.free(hash);

       // Test with varying prefix matches
       const test_cases = [_][]const u8{
           "WrongPassword123!",    // No match
           "CorrectPassword456!",  // Prefix match
           "CorrectPassword12!",   // Almost full match
       };

       var timings: [test_cases.len]i64 = undefined;

       for (test_cases, 0..) |wrong_password, i| {
           // Measure timing for 100 attempts
           var total_ns: i64 = 0;
           var attempt: usize = 0;
           while (attempt < 100) : (attempt += 1) {
               const start = std.time.nanoTimestamp();
               _ = manager.verifyPassword(wrong_password, hash) catch false;
               const end = std.time.nanoTimestamp();
               total_ns += (end - start);
           }
           timings[i] = @divTrunc(total_ns, 100);
       }

       // Verify all timings are within 10% of each other
       const min_time = std.mem.min(i64, &timings);
       const max_time = std.mem.max(i64, &timings);
       const variance = @as(f64, @floatFromInt(max_time - min_time)) / @as(f64, @floatFromInt(min_time));

       try testing.expect(variance < 0.10); // Less than 10% variance
   }

   test "Hash comparison - timing resistance" {
       const hash1 = Hash{
           .alg = .sha256,
           .digest = &[_]u8{0xAA} ** 32,
       };

       const test_hashes = [_]Hash{
           .{ .alg = .sha256, .digest = &[_]u8{0xBB} ** 32 },      // No match
           .{ .alg = .sha256, .digest = &[_]u8{0xAA, 0xBB} ++ [_]u8{0xAA} ** 30 }, // Prefix match
           .{ .alg = .sha256, .digest = &([_]u8{0xAA} ** 31 ++ [_]u8{0xBB}) },      // Almost match
       };

       var timings: [test_hashes.len]i64 = undefined;

       for (test_hashes, 0..) |hash2, i| {
           var total_ns: i64 = 0;
           var attempt: usize = 0;
           while (attempt < 1000) : (attempt += 1) {
               const start = std.time.nanoTimestamp();
               _ = hash1.equals(hash2);
               const end = std.time.nanoTimestamp();
               total_ns += (end - start);
           }
           timings[i] = @divTrunc(total_ns, 1000);
       }

       // Verify constant-time (within measurement noise)
       const min_time = std.mem.min(i64, &timings);
       const max_time = std.mem.max(i64, &timings);
       const variance = @as(f64, @floatFromInt(max_time - min_time)) / @as(f64, @floatFromInt(min_time));

       try testing.expect(variance < 0.05); // Less than 5% variance
   }
   ```

3. **Day 1: Audit All Sensitive Comparisons**
   ```bash
   # Find all potential timing-sensitive comparisons
   grep -r "std.mem.eql" src/security/ src/types/cryptographic.zig src/types/hash.zig

   # Verify each is either:
   # 1. Not timing-sensitive (public data)
   # 2. Uses timingSafeEql for sensitive data
   ```

#### Verification Checklist

- [ ] All password comparisons use timingSafeEql
- [ ] All hash comparisons use timingSafeEql
- [ ] Timing resistance tests pass
- [ ] Statistical analysis shows <5% variance
- [ ] Security audit of all comparisons complete
- [ ] Documentation updated with timing-safety guidelines

---

### 1.4 Memory Leak in Execution Engine (C4)

**Priority**: P0-4
**Owner**: Core Team
**Estimated Effort**: 5 days
**Dependencies**: None (can run in parallel with C1-C3)

#### Implementation Steps

1. **Day 1-2: Refactor Env to Use Arena Allocator**

   **File**: `src/eval.zig:103-119`

   **Strategy**: Add proper cleanup or use arena allocators

   **Option A: Add deinit() method**
   ```zig
   pub const Env = struct {
       names: [][]const u8,
       values: []Value,
       allocator: Allocator,  // Store allocator for cleanup

       pub fn init(allocator: Allocator) Env {
           return .{
               .names = &[_][]const u8{},
               .values = &[_]Value{},
               .allocator = allocator,
           };
       }

       pub fn deinit(self: Env) void {
           self.allocator.free(self.names);
           self.allocator.free(self.values);
       }

       pub fn withBinding(self: Env, name: []const u8, value: Value) !Env {
           var new_names = try self.allocator.alloc([]const u8, self.names.len + 1);
           errdefer self.allocator.free(new_names);

           var new_values = try self.allocator.alloc(Value, self.values.len + 1);
           errdefer self.allocator.free(new_values);

           @memcpy(new_names[0..self.names.len], self.names);
           @memcpy(new_values[0..self.values.len], self.values);

           new_names[self.names.len] = name;
           new_values[self.values.len] = value;

           // Free old arrays
           if (self.names.len > 0) {
               self.allocator.free(self.names);
               self.allocator.free(self.values);
           }

           return Env{
               .names = new_names,
               .values = new_values,
               .allocator = self.allocator,
           };
       }
   };
   ```

   **Option B: Use ArenaAllocator (RECOMMENDED)**
   ```zig
   // In execution.zig
   pub fn executeQuery(self: *Self, allocator: Allocator, query: Query) !Result {
       // Create arena for all temporary query allocations
       var arena = std.heap.ArenaAllocator.init(allocator);
       defer arena.deinit();  // Free everything at once

       const arena_alloc = arena.allocator();

       // Pass arena_alloc to all sub-functions
       var env = eval.Env.init(arena_alloc);
       // No need to manually free - arena.deinit() handles it

       return try self.executeQueryInternal(arena_alloc, query, env);
   }
   ```

2. **Day 2-3: Update execution.zig to Use Arena Pattern**

   **File**: `src/execution.zig` (multiple locations)

   ```zig
   // Pattern: One arena per query execution
   pub fn executeStatement(self: *Self, allocator: Allocator, stmt: Statement) !Result {
       var query_arena = std.heap.ArenaAllocator.init(allocator);
       defer query_arena.deinit();

       const qa = query_arena.allocator();

       // All temporary allocations use qa
       // Result data uses original allocator (caller's responsibility)

       return switch (stmt) {
           .query => |q| try self.executeQuery(allocator, qa, q),
           .create => |c| try self.executeCreate(allocator, qa, c),
           // ...
       };
   }
   ```

3. **Day 3-4: Add Memory Leak Tests**

   **File**: `src/test_memory_leaks.zig` (new)
   ```zig
   test "Execution - no memory leaks in simple query" {
       var executor = try Executor.init(testing.allocator);
       defer executor.deinit();

       const query = "MATCH (n) RETURN n.name LIMIT 10";

       var i: usize = 0;
       while (i < 1000) : (i += 1) {
           const result = try executor.execute(testing.allocator, query);
           defer result.deinit();
       }

       // testing.allocator will detect leaks automatically
   }

   test "Execution - no leaks with nested pattern comprehensions" {
       var executor = try Executor.init(testing.allocator);
       defer executor.deinit();

       const query =
           \\MATCH (a)
           \\RETURN [x IN [y IN [z IN [1,2,3] | z*2] | y+1] | x*3]
       ;

       var i: usize = 0;
       while (i < 100) : (i += 1) {
           const result = try executor.execute(testing.allocator, query);
           defer result.deinit();
       }
   }

   test "Execution - memory baseline with 24-hour simulation" {
       // Simulate 24 hours of queries (1 per second = 86400 queries)
       // Should complete in ~1 minute with leak-free code

       var executor = try Executor.init(testing.allocator);
       defer executor.deinit();

       const queries = [_][]const u8{
           "MATCH (n) RETURN n LIMIT 1",
           "CREATE (n:Test {id: 1})",
           "MATCH (a)-[r]->(b) RETURN a, r, b LIMIT 10",
       };

       var i: usize = 0;
       while (i < 10000) : (i += 1) { // Reduced for CI
           const query = queries[i % queries.len];
           const result = try executor.execute(testing.allocator, query);
           defer result.deinit();
       }
   }
   ```

4. **Day 4-5: Run Valgrind/ASAN Analysis**
   ```bash
   # Build with AddressSanitizer
   zig build -Doptimize=Debug -fsanitize=address

   # Run test suite
   ASAN_OPTIONS=detect_leaks=1:log_path=asan.log ./zig-out/bin/geode_test

   # Run extended tests
   python3 extended_test_runner.py

   # Analyze results
   cat asan.log* | grep "LeakSanitizer"

   # Also run Valgrind (slower but more thorough)
   valgrind --leak-check=full --show-leak-kinds=all \
            --log-file=valgrind.log \
            ./zig-out/bin/geode_test
   ```

#### Verification Checklist

- [ ] Env struct properly tracks allocator
- [ ] All query executions use arena allocator
- [ ] Memory leak tests pass (1000+ iterations)
- [ ] ASAN reports zero leaks
- [ ] Valgrind reports zero leaks
- [ ] 24-hour simulation test passes
- [ ] Memory usage stays constant over time
- [ ] Performance regression <5%

---

### 1.5 Default Credentials Without Forced Reset (C5)

**Priority**: P0-5
**Owner**: Security Team
**Estimated Effort**: 2 days
**Dependencies**: None

#### Implementation Steps

1. **Day 1: Fix Default User Creation Logic**

   **File**: `src/security/auth.zig:815-843`

   ```zig
   fn initializeDefaultUser(self: *Self) !void {
       const admin_username_env = std.process.getEnvVarOwned(
           self.allocator,
           "GEODE_ADMIN_USERNAME"
       ) catch null;
       const admin_username = admin_username_env orelse "geode";
       defer if (admin_username_env) |u| self.allocator.free(u);

       const default_password_env = std.process.getEnvVarOwned(
           self.allocator,
           "GEODE_DEFAULT_PASSWORD"
       ) catch null;
       const password_from_env = default_password_env != null;
       const default_password = default_password_env orelse "geodesic";
       defer if (default_password_env) |p| self.allocator.free(p);

       // CRITICAL: ALWAYS require password reset for default user
       // Even if password is from environment, it may be in git/logs
       const needs_reset = true;  // ALWAYS true for default user

       // Hash the initial password
       const password_hash = try self.hashPassword(default_password);

       // Create user with special flags
       const id = try self.generateUserId();
       const user = User{
           .id = id,
           .username = try self.allocator.dupe(u8, admin_username),
           .email = try self.allocator.dupe(u8, "admin@localhost"),
           .password_hash = password_hash,
           .password_reset_required = true,  // Force reset
           .is_default_user = true,          // Flag as default user
           .password_set_by_env = password_from_env,  // Track source
           .created_at = std.time.milliTimestamp(),
           .updated_at = std.time.milliTimestamp(),
           .roles = try self.allocator.dupe([]const u8, &[_][]const u8{"admin"}),
           .mfa_enabled = false,
           .mfa_secret = null,
           .recovery_codes = null,
       };

       try self.users.put(id, user);

       // Log with HIGH severity
       try self.audit_log.append(
           .user_created,
           id,
           "DEFAULT_USER_CREATED username={s} password_source={s} REQUIRES_IMMEDIATE_RESET",
           .{admin_username, if (password_from_env) "environment" else "hardcoded"}
       );

       if (password_from_env) {
           std.log.warn(
               "Default user created with env password. " ++
               "SECURITY: Ensure GEODE_DEFAULT_PASSWORD is not in git/logs. " ++
               "Password reset required on first login.",
               .{}
           );
       }
   }
   ```

2. **Day 1: Block Authentication for Default Users**

   **File**: `src/security/auth.zig` - Update authenticate()

   ```zig
   pub fn authenticate(self: *Self, username: []const u8, password: []const u8) ![]const u8 {
       // Find user
       var it = self.users.iterator();
       const user_entry = while (it.next()) |entry| {
           if (std.mem.eql(u8, entry.value_ptr.username, username)) {
               break entry;
           }
       } else {
           // Log failed attempt
           try self.audit_log.append(.auth_failed, "", "Unknown username: {s}", .{username});
           return error.InvalidCredentials;
       };

       const user = user_entry.value_ptr;

       // CRITICAL: Block default users until password changed
       if (user.is_default_user and user.password_reset_required) {
           try self.audit_log.append(
               .auth_failed,
               user.id,
               "Authentication blocked: default user must change password",
               .{}
           );
           return error.DefaultPasswordMustBeChanged;
       }

       // Verify password
       const is_valid = try self.verifyPassword(password, user.password_hash);
       if (!is_valid) {
           try self.audit_log.append(.auth_failed, user.id, "Invalid password", .{});
           return error.InvalidCredentials;
       }

       // Check if password reset required
       if (user.password_reset_required) {
           try self.audit_log.append(
               .auth_failed,
               user.id,
               "Authentication blocked: password reset required",
               .{}
           );
           return error.PasswordResetRequired;
       }

       // ... rest of authentication logic
   }
   ```

3. **Day 1-2: Add Password Change Endpoint**

   **File**: `src/security/auth.zig`

   ```zig
   pub fn changePassword(
       self: *Self,
       user_id: []const u8,
       old_password: []const u8,
       new_password: []const u8,
   ) !void {
       const user = self.users.getPtr(user_id) orelse return error.UserNotFound;

       // Verify old password
       const is_valid = try self.verifyPassword(old_password, user.password_hash);
       if (!is_valid) {
           try self.audit_log.append(
               .password_change_failed,
               user_id,
               "Invalid old password",
               .{}
           );
           return error.InvalidCredentials;
       }

       // Validate new password
       try self.validatePasswordAgainstCurrentPolicy(new_password);

       // Ensure new != old
       const old_hash_matches = try self.verifyPassword(new_password, user.password_hash);
       if (old_hash_matches) {
           return error.NewPasswordSameAsOld;
       }

       // Hash new password
       const new_hash = try self.hashPassword(new_password);

       // Update user
       self.allocator.free(user.password_hash);
       user.password_hash = new_hash;
       user.password_reset_required = false;
       user.is_default_user = false;  // Clear default user flag
       user.updated_at = std.time.milliTimestamp();

       try self.audit_log.append(
           .password_changed,
           user_id,
           "Password successfully changed{s}",
           .{if (user.password_set_by_env) " (was from environment)" else ""}
       );
   }
   ```

4. **Day 2: Add Tests**

   **File**: `src/security/test_default_credentials.zig` (new)
   ```zig
   test "Default user authentication blocked until password changed" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       try manager.initializeDefaultUser();

       // Attempt to authenticate with default credentials
       const result = manager.authenticate("geode", "geodesic");
       try testing.expectError(error.DefaultPasswordMustBeChanged, result);
   }

   test "Default user can change password and then authenticate" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       try manager.initializeDefaultUser();

       // Get user ID
       const user_id = blk: {
           var it = manager.users.iterator();
           while (it.next()) |entry| {
               if (std.mem.eql(u8, entry.value_ptr.username, "geode")) {
                   break :blk entry.key_ptr.*;
               }
           }
           return error.TestFailed;
       };

       // Change password
       try manager.changePassword(user_id, "geodesic", "NewSecurePassword123!");

       // Now authentication should work
       const session = try manager.authenticate("geode", "NewSecurePassword123!");
       defer manager.allocator.free(session);

       try testing.expect(session.len > 0);
   }

   test "Environment password still requires reset" {
       var manager = try SecurityManager.init(testing.allocator);
       defer manager.deinit();

       // Simulate GEODE_DEFAULT_PASSWORD=StrongPass123!
       try std.process.setEnvVar("GEODE_DEFAULT_PASSWORD", "StrongPass123!");
       defer std.process.unsetEnvVar("GEODE_DEFAULT_PASSWORD");

       try manager.initializeDefaultUser();

       // Even with strong env password, auth should be blocked
       const result = manager.authenticate("geode", "StrongPass123!");
       try testing.expectError(error.DefaultPasswordMustBeChanged, result);
   }
   ```

#### Verification Checklist

- [ ] Default user authentication blocked until password changed
- [ ] Password change endpoint implemented
- [ ] Password change clears is_default_user flag
- [ ] Environment password still requires reset
- [ ] Audit logs capture all attempts
- [ ] Tests pass for all scenarios
- [ ] Documentation updated with password change flow

---

### 1.6 Silent Error Swallowing (C6)

**Priority**: P0-6
**Owner**: All Teams (distributed work)
**Estimated Effort**: 1 week
**Dependencies**: None

#### Implementation Steps

1. **Day 1: Audit All Empty Catch Blocks**
   ```bash
   # Find all instances
   grep -rn "catch {}" src/ > empty_catch_blocks.txt
   grep -rn "catch |_|" src/ >> empty_catch_blocks.txt

   # Count: 44+ occurrences
   wc -l empty_catch_blocks.txt
   ```

2. **Day 1-5: Fix Each Instance (Distributed)**

   **Categories**:

   **A. Critical Path Errors (MUST propagate)**
   ```zig
   // BEFORE:
   loadCatalog() catch {};

   // AFTER:
   loadCatalog() catch |err| {
       std.log.err("Failed to load catalog: {}", .{err});
       return err;  // Fail-fast for data integrity
   };
   ```

   **B. Optional Features (Log and continue)**
   ```zig
   // BEFORE:
   const stats_enabled = std.process.getEnvVarOwned(alloc, "GEODE_STATS") catch |_| null;

   // AFTER:
   const stats_enabled = std.process.getEnvVarOwned(alloc, "GEODE_STATS") catch |err| blk: {
       std.log.debug("Stats registry disabled (env var error): {}", .{err});
       break :blk null;
   };
   ```

   **C. Cleanup Code (Log but don't propagate)**
   ```zig
   // BEFORE:
   defer {
       cleanup() catch {};
   }

   // AFTER:
   defer {
       cleanup() catch |err| {
           std.log.warn("Cleanup failed (non-fatal): {}", .{err});
       };
   }
   ```

3. **Day 5: Add Linter Rule**

   **File**: `.github/workflows/lint.yml` (new)
   ```yaml
   name: Code Quality Checks

   on: [push, pull_request]

   jobs:
     lint:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v3

         - name: Check for empty catch blocks
           run: |
             # Fail if empty catch blocks found (with exceptions)
             EMPTY_CATCHES=$(grep -rn "catch {}" src/ || true)
             if [ -n "$EMPTY_CATCHES" ]; then
               echo "❌ Empty catch blocks found:"
               echo "$EMPTY_CATCHES"
               exit 1
             fi

         - name: Check for ignored errors
           run: |
             # Warn on catch |_| (may be intentional)
             IGNORED_ERRORS=$(grep -rn "catch |_|" src/ || true)
             if [ -n "$IGNORED_ERRORS" ]; then
               echo "⚠️ Ignored errors found (verify intentional):"
               echo "$IGNORED_ERRORS"
             fi
   ```

4. **Day 5: Update Coding Standards**

   **File**: `docs/CODING_STANDARDS.md` (new)
   ```markdown
   ## Error Handling

   ### Rule: Never Silently Ignore Errors

   **Prohibited**:
   ```zig
   loadData() catch {};  // ❌ Silent failure
   ```

   **Required**:
   ```zig
   // Option 1: Propagate (preferred for critical paths)
   loadData() catch |err| {
       std.log.err("Failed to load data: {}", .{err});
       return err;
   };

   // Option 2: Log and continue (for non-critical)
   loadData() catch |err| {
       std.log.warn("Data load failed, using defaults: {}", .{err});
       data = getDefaults();
   };

   // Option 3: Defer cleanup (only in defer blocks)
   defer {
       cleanup() catch |err| {
           std.log.warn("Cleanup failed: {}", .{err});
       };
   }
   ```
   ```

#### Verification Checklist

- [ ] All 44+ empty catch blocks reviewed
- [ ] Critical path errors now propagate
- [ ] Optional features log failures
- [ ] Linter rule prevents new violations
- [ ] Coding standards document created
- [ ] All tests still pass
- [ ] No new silent failures introduced

---

### 1.7 Insecure TLS Fallback (C7)

**Priority**: P0-7
**Owner**: Transport Team
**Estimated Effort**: 2 days
**Dependencies**: None

#### Implementation Steps

1. **Day 1: Remove Insecure Fallback**

   **File**: `src/transport/quic.zig:122-194`

   ```zig
   pub fn listen(self: *QuicTransport) !void {
       // ... cert path checks ...

       var use_tls = cert_exists and key_exists;

       if (!use_tls) {
           // CRITICAL: Never fall back to insecure mode
           std.log.err(
               "TLS certificates not found:\n" ++
               "  cert_path: {s}\n" ++
               "  key_path: {s}\n" ++
               "SECURITY: Refusing to start without TLS.\n" ++
               "Generate certificates with: openssl req -x509 -newkey rsa:2048 ...",
               .{self.cert_path, self.key_path}
           );
           return QuicError.CertificateError;
       }

       // ... rest of setup ...

       const cfg = try self.allocator.create(quic_lib.QuicConfig);
       cfg.* = .{
           .version = .v1,
           .allow_insecure = false,  // NEVER allow insecure
           .alpn = &[_][]const u8{"geode/1"},
           .cert_path = if (use_tls) self.cert_path else null,
           .key_path = if (use_tls) self.key_path else null,
           // ...
       };
   }
   ```

2. **Day 1: Add Certificate Generation Helper**

   **File**: `src/transport/cert_gen.zig` (new)
   ```zig
   // Fallback cert generation using Zig crypto (no OpenSSL dependency)
   pub fn generateSelfSignedCert(
       allocator: Allocator,
       cert_path: []const u8,
       key_path: []const u8,
   ) !void {
       // Generate Ed25519 keypair
       const keypair = try std.crypto.sign.Ed25519.KeyPair.create(null);

       // Write private key (PEM format)
       const key_file = try std.fs.cwd().createFile(key_path, .{});
       defer key_file.close();

       try key_file.writeAll("-----BEGIN PRIVATE KEY-----\n");
       const key_b64 = try base64Encode(allocator, &keypair.secret_key);
       defer allocator.free(key_b64);
       try key_file.writeAll(key_b64);
       try key_file.writeAll("\n-----END PRIVATE KEY-----\n");

       // Generate self-signed certificate (X.509)
       const cert = try generateX509Cert(allocator, keypair);
       defer allocator.free(cert);

       // Write certificate (PEM format)
       const cert_file = try std.fs.cwd().createFile(cert_path, .{});
       defer cert_file.close();

       try cert_file.writeAll("-----BEGIN CERTIFICATE-----\n");
       try cert_file.writeAll(cert);
       try cert_file.writeAll("\n-----END CERTIFICATE-----\n");

       std.log.info("Generated self-signed certificate: {s}", .{cert_path});
   }
   ```

3. **Day 2: Add Tests**

   **File**: `src/transport/test_tls_enforcement.zig` (new)
   ```zig
   test "QUIC transport - refuses to start without TLS" {
       var transport = try QuicTransport.init(testing.allocator, .{
           .listen_addr = "127.0.0.1:0",
           .cert_path = "/nonexistent/cert.pem",
           .key_path = "/nonexistent/key.pem",
       });
       defer transport.deinit();

       // Should fail with CertificateError
       const result = transport.listen();
       try testing.expectError(QuicError.CertificateError, result);
   }

   test "QUIC transport - allow_insecure always false" {
       var transport = try QuicTransport.init(testing.allocator, .{
           .listen_addr = "127.0.0.1:0",
           .cert_path = "test_cert.pem",
           .key_path = "test_key.pem",
       });
       defer transport.deinit();

       // Verify config
       try testing.expect(!transport.config.allow_insecure);
   }

   test "Certificate generation - creates valid PEM files" {
       const cert_path = "test_generated_cert.pem";
       const key_path = "test_generated_key.pem";
       defer std.fs.cwd().deleteFile(cert_path) catch {};
       defer std.fs.cwd().deleteFile(key_path) catch {};

       try cert_gen.generateSelfSignedCert(
           testing.allocator,
           cert_path,
           key_path
       );

       // Verify files exist
       try testing.expect(try fileExists(cert_path));
       try testing.expect(try fileExists(key_path));

       // Verify PEM format
       const cert_content = try std.fs.cwd().readFileAlloc(
           testing.allocator,
           cert_path,
           1024 * 1024
       );
       defer testing.allocator.free(cert_content);

       try testing.expect(std.mem.startsWith(u8, cert_content, "-----BEGIN CERTIFICATE-----"));
   }
   ```

4. **Day 2: Update Documentation**

   **File**: `docs/DEPLOYMENT.md`
   ```markdown
   ## TLS Certificate Setup

   Geode requires TLS certificates for all connections. There is **no insecure fallback mode**.

   ### Option 1: Let Geode Generate Self-Signed Cert
   ```bash
   # Certificates will be auto-generated on first startup
   ./zig-out/bin/geode serve --listen 0.0.0.0:3141
   # Cert saved to: certs/geode.crt
   # Key saved to: certs/geode.key
   ```

   ### Option 2: Provide Your Own Certificate
   ```bash
   ./zig-out/bin/geode serve \
     --listen 0.0.0.0:3141 \
     --cert-path /etc/geode/cert.pem \
     --key-path /etc/geode/key.pem
   ```

   ### Option 3: Generate with OpenSSL
   ```bash
   openssl req -x509 -newkey rsa:4096 -nodes \
     -keyout geode.key \
     -out geode.crt \
     -days 365 \
     -subj "/CN=geode.local"
   ```

   ### Security Note

   **Geode will refuse to start without valid TLS certificates.** This is a security feature, not a bug.
   If you encounter certificate errors, generate proper certificates using one of the methods above.
   ```

#### Verification Checklist

- [ ] Server refuses to start without certs
- [ ] allow_insecure hardcoded to false
- [ ] Auto-generation creates valid PEM files
- [ ] Tests verify TLS enforcement
- [ ] Documentation updated
- [ ] Integration tests pass with generated certs
- [ ] No fallback to insecure mode possible

---

## Phase 1 Summary

**Total Estimated Time**: 2-3 weeks
**Parallelization**: C1-C3 (security team), C4 (core team), C5-C7 (can overlap)

### Week 1
- Days 1-2: C1 (Nonce Reuse) + C3 (Timing Attacks)
- Days 1-3: C2 (Password Hashing)
- Days 1-2: C5 (Default Credentials)
- Days 1-2: C7 (TLS Fallback)

### Week 2
- Days 1-5: C4 (Memory Leaks) - core team
- Days 1-5: C6 (Error Swallowing) - distributed across teams
- Code reviews and testing

### Week 3
- Integration testing
- Security audit
- Performance regression testing
- Documentation finalization
- **GO/NO-GO Decision for Phase 2**

---

## Phase 2: Major Issues & Technical Debt (P1)

**Duration**: 4-6 weeks
**Status**: 🟡 PLANNED
**Dependencies**: Phase 1 complete

### 2.1 Refactor Massive execution.zig

**Priority**: P1-1
**Owner**: Core Team
**Estimated Effort**: 3 weeks

#### Refactoring Strategy

**Target Structure**:
```
src/execution/
├── mod.zig                  (Main module, 200 lines)
├── catalog.zig              (Catalog operations, 400 lines)
├── pattern_matcher.zig      (Graph pattern matching, 800 lines)
├── fle_hooks.zig            (Field-level encryption, 300 lines)
├── query_executor.zig       (Core execution, 600 lines)
├── result_formatter.zig     (Result formatting, 200 lines)
├── variable_binding.zig     (Env management, 200 lines)
└── helpers.zig              (Utilities, 300 lines)
```

**Total**: ~3000 lines (from 11,163 - 70% reduction)

#### Implementation Plan

**Week 1: Preparation & Analysis**
- Map all function dependencies
- Identify circular dependencies
- Create module dependency graph
- Write refactoring design doc

**Week 2-3: Incremental Refactoring**
- Extract catalog.zig (standalone, no deps)
- Extract fle_hooks.zig (minimal deps)
- Extract result_formatter.zig
- Extract variable_binding.zig (fix circular dep with eval.zig)

**Week 3-4: Core Refactoring**
- Extract pattern_matcher.zig (largest piece)
- Extract query_executor.zig
- Create mod.zig with public API
- Update all imports across codebase

**Week 4: Testing & Validation**
- Run full test suite
- Performance regression tests
- Memory leak tests
- Code review

#### Success Metrics
- [ ] All files <1000 lines
- [ ] No circular dependencies
- [ ] All tests pass
- [ ] No performance regression
- [ ] Improved test coverage

---

### 2.2 Fix Global Mutable State (M2)

**Priority**: P1-2
**Owner**: Core Team
**Estimated Effort**: 1 week

See detailed plan in Phase 1 documentation.

---

### 2.3 Eliminate Page Allocator Usage (M3)

**Priority**: P1-3
**Owner**: All Teams
**Estimated Effort**: 1 week

**Strategy**: Systematic replacement across 40+ files

**Pattern**:
```zig
// BEFORE:
pub fn init() !Self {
    const allocator = std.heap.page_allocator;
    // ...
}

// AFTER:
pub fn init(allocator: Allocator) !Self {
    return Self{
        .allocator = allocator,
        // ...
    };
}
```

---

### 2.4-2.13 Additional Major Issues

[Detailed plans for M4-M13 omitted for brevity - follow similar structure]

---

## Phase 3: Code Quality & Architecture (P2)

**Duration**: 2-3 months
**Status**: 🟢 FUTURE

### Focus Areas
1. Code quality improvements
2. Documentation enhancements
3. Test coverage improvements
4. Performance optimizations
5. Developer experience

---

## Phase 4: Long-term Improvements (P3)

**Duration**: 3-6 months
**Status**: 🟢 FUTURE

### Focus Areas
1. Repository pattern for storage
2. Plugin architecture
3. Advanced monitoring
4. Performance profiling infrastructure

---

## Implementation Timeline

### Gantt Chart Overview

```
Month 1       Month 2       Month 3       Month 4       Month 5       Month 6
|-------------|-------------|-------------|-------------|-------------|-------------|
Phase 1: Critical Security Fixes
[==========]
    Phase 2: Major Issues & Technical Debt
    [=====================]
                Phase 3: Code Quality
                [=============================]
                            Phase 4: Long-term Improvements
                            [=====================================]
```

### Detailed Schedule

| Week | Phase | Deliverables | Team |
|------|-------|--------------|------|
| 1-2 | Phase 1 | C1-C3 fixes | Security (3) |
| 1-2 | Phase 1 | C4 fix | Core (2) |
| 2-3 | Phase 1 | C5-C7 fixes | Security (2), Transport (1) |
| 3 | Phase 1 | Integration testing | All (5) |
| 4-7 | Phase 2 | M1-M3 fixes | Core (4) |
| 7-10 | Phase 2 | M4-M13 fixes | All (5) |
| 11-18 | Phase 3 | Code quality | All (3-4) |
| 19-30 | Phase 4 | Architecture | All (2-3) |

---

## Success Criteria

### Phase 1 (Critical Security Fixes)

✅ **Security**:
- [ ] Zero critical vulnerabilities (CVSS >= 7.0)
- [ ] All OWASP A02:2021, A07:2021 issues resolved
- [ ] Security audit by external firm (optional)

✅ **Testing**:
- [ ] All security tests pass
- [ ] No detected memory leaks (ASAN/Valgrind)
- [ ] Timing attack resistance verified

✅ **Performance**:
- [ ] <5% performance regression
- [ ] Argon2id hash time 100-500ms

✅ **Documentation**:
- [ ] All CANARY markers updated to STATUS=IMPL
- [ ] Security documentation complete
- [ ] Deployment guide updated

### Phase 2 (Major Issues)

✅ **Code Quality**:
- [ ] All files <1000 lines
- [ ] execution.zig refactored into modules
- [ ] No global mutable state

✅ **Memory**:
- [ ] Zero page_allocator usage in production code
- [ ] 24-hour stress test with constant memory

✅ **Testing**:
- [ ] Test coverage >95%
- [ ] All integration tests pass

### Phase 3 (Code Quality)

✅ **Standards**:
- [ ] Coding standards document published
- [ ] All functions <50 lines (95% compliance)
- [ ] Cyclomatic complexity <10

✅ **Documentation**:
- [ ] API documentation complete
- [ ] Architecture diagrams created
- [ ] Contribution guide published

### Phase 4 (Long-term)

✅ **Architecture**:
- [ ] Repository pattern implemented
- [ ] Plugin system designed
- [ ] Performance monitoring integrated

---

## Risk Management

### High-Risk Items

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Phase 1 introduces regressions | Medium | High | Comprehensive testing, gradual rollout |
| Refactoring breaks functionality | Medium | High | Feature flags, incremental changes |
| Performance degradation | Low | Medium | Continuous benchmarking |
| Team capacity constraints | Medium | High | Flexible timeline, prioritization |

### Contingency Plans

**If Phase 1 takes longer than 3 weeks**:
- Extend timeline by 1-2 weeks
- Prioritize C1-C3 (crypto issues) first
- Delay C6 (error swallowing) if needed

**If refactoring introduces bugs**:
- Revert to pre-refactoring state
- Implement feature flags for gradual rollout
- Increase test coverage before continuing

**If performance regresses >10%**:
- Profile and identify bottlenecks
- Consider arena allocator tuning
- May need to accept 5-10% regression for security

---

## Communication Plan

### Weekly Status Updates

**Format**: Markdown document in `docs/status/YYYY-WW.md`

**Content**:
- Completed items
- In-progress items
- Blockers
- Next week's plan
- Metrics (tests passing, files refactored, etc.)

### Monthly Reviews

**Attendees**: Engineering team, stakeholders

**Agenda**:
1. Phase completion status
2. Metrics review
3. Risk assessment
4. Timeline adjustments
5. Next month's priorities

---

## Conclusion

This remediation plan addresses all critical security vulnerabilities and technical debt in a phased, systematic approach. The **security-first** strategy ensures production blockers are resolved within 2-3 weeks, while the longer-term phases improve maintainability and architecture.

**Next Steps**:
1. Review and approve this plan
2. Allocate team resources
3. Create tracking issues in GitHub
4. Begin Phase 1 implementation

**Estimated Timeline to Production-Ready**: 3 months (Phase 1-2 complete)
**Estimated Timeline to Best-in-Class**: 6 months (all phases complete)

---

*Last Updated: October 16, 2025*
*Document Owner: Engineering Leadership*
*Review Schedule: Weekly during Phase 1, Bi-weekly thereafter*
