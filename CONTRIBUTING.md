# Contributing to Geode

Thank you for your interest in contributing to Geode! This document provides guidelines and best practices for contributing to the project.

## Code Standards

### Memory Management (Critical)

Geode has **zero tolerance** for memory leaks. All code must follow proper memory management practices.

#### ❌ NEVER use `std.heap.page_allocator` in production code

The `page_allocator` never frees memory, causing unbounded growth (CWE-401). This has been completely eliminated from the `src/` directory and is **forbidden in all production code**.

Our CI will **reject any PR** that introduces `page_allocator` into `src/`.

#### ✅ Proper Allocator Patterns

**1. Function Parameters**
```zig
// ✅ GOOD: Thread allocator as first parameter
pub fn processData(allocator: std.mem.Allocator, value: []const u8) !Result {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit(allocator);
    // Use allocator for temporary allocations
}

// ❌ BAD: Using page_allocator
pub fn processData(value: []const u8) !Result {
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);  // FORBIDDEN!
}
```

**2. Struct Methods**
```zig
// ✅ GOOD: Store allocator in struct
pub const Processor = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Processor {
        return .{
            .allocator = allocator,
            .data = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Processor) void {
        self.data.deinit(self.allocator);
    }

    pub fn process(self: *Processor, input: []const u8) !void {
        // Use self.allocator for owned data
        try self.data.appendSlice(self.allocator, input);
    }
};
```

**3. Main Functions**
```zig
// ✅ GOOD: Use GeneralPurposeAllocator
pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    // Use gpa throughout function
    var data = std.ArrayList(u8).init(gpa);
    defer data.deinit(gpa);
    // ...
}

// ❌ BAD: Using page_allocator
pub fn main() !void {
    const gpa = std.heap.page_allocator;  // FORBIDDEN!
}
```

**4. Global Functions (Without Context)**
```zig
// ✅ GOOD: Static GPA with init flag
var global_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var global_gpa_init = false;

pub fn globalUtility() !bool {
    if (!global_gpa_init) {
        global_gpa_init = true;
    }
    return std.process.hasEnvVar(global_gpa.allocator(), "VAR") catch false;
}
```

**5. Test Code**
```zig
// ✅ GOOD: Use testing.allocator
test "example test" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
}

// Note: Tests can use page_allocator if needed, but testing.allocator is preferred
// for automatic leak detection
```

### Zig 0.15.1 API Notes

**ArrayList/HashMap require explicit allocator parameters:**

```zig
var list = std.ArrayList(u8).init(allocator);
try list.append(allocator, item);      // ✅ Requires allocator
try list.appendSlice(allocator, data); // ✅ Requires allocator
list.deinit(allocator);                // ✅ Requires allocator
```

### Code Review Checklist

Before submitting a PR, verify:

- [ ] **No `page_allocator` in `src/`** - Use `rg 'std\.heap\.page_allocator' src/` to check
- [ ] **All ArrayList/HashMap have allocator parameters**
- [ ] **All allocations have matching `deinit()` or `defer` cleanup**
- [ ] **Main functions use `GeneralPurposeAllocator`**
- [ ] **Struct methods use `self.allocator` for owned data**
- [ ] **Test code uses `std.testing.allocator`**

### CANARY System

All significant features and implementations must include CANARY markers for governance tracking:

```zig
// CANARY: REQ=REQ-XXX-NNN; FEATURE="Feature Name"; ASPECT=Category; STATUS=TESTED; TEST=TestName; OWNER=team; UPDATED=YYYY-MM-DD
```

**Status values:**
- `STUB` - Initial implementation
- `TESTED` - Has test coverage
- `BENCHED` - Has performance benchmarks
- `COMPLETE` - Fully implemented with tests

### GQL Compliance

Geode targets 98%+ compliance with ISO/IEC 39075:2024 (GQL standard). Always verify against the authoritative specification (`docs/kb/gql/ISO_IEC_39075_2024(en).pdf`) before making architectural changes.

### Testing Requirements

- **Unit Tests**: All new code must have test coverage
- **Integration Tests**: Add to `geodetestlab/specs/` for black-box testing
- **No Regressions**: CI must pass with no test failures
- **Geodetestlab**: Maintain >90% pass rate

Run tests with:
```bash
make test                    # Unit tests
python3 extended_test_runner.py  # Integration tests
```

### Documentation

- **API Changes**: Update `docs/API_REFERENCE.md`
- **New Features**: Update `docs/FEATURES_OVERVIEW.md` and `docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md`
- **Breaking Changes**: Update `docs/GAP.md` (Geode Advancement Proposals)

### Commit Messages

Follow conventional commits format:

```
<type>(<scope>): <subject>

<body>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

**Types:** `feat`, `fix`, `docs`, `refactor`, `test`, `ci`, `perf`, `chore`

### Pull Request Process

1. **Branch Naming**: Use descriptive names (`feature/vector-search`, `fix/memory-leak`)
2. **Small PRs**: Keep changes focused and reviewable
3. **Tests Pass**: All CI checks must pass
4. **Documentation Updated**: Include relevant docs updates
5. **GAP.md Updated**: Required for code changes (`.zig`, `.zon`, `.yml` files)

### Security

- **No Hardcoded Secrets**: Use environment variables
- **Use Standard Library Crypto**: Never roll your own crypto
- **Input Validation**: Validate all external inputs
- **Memory Safety**: Follow allocator guidelines above

Report security vulnerabilities privately to the maintainers.

## Getting Started

1. **Setup Development Environment:**
   ```bash
   # Install Zig 0.15.1
   # Clone repository
   git clone https://gitlab.com/devnw/geode/geode.git
   cd geode

   # Build
   make build

   # Run tests
   make test
   ```

2. **Make Changes:**
   - Create feature branch
   - Implement changes following code standards
   - Add tests
   - Update documentation

3. **Submit PR:**
   - Ensure all checks pass
   - Write clear commit messages
   - Update GAP.md for code changes
   - Request review

## Resources

- **Documentation**: `docs/` directory
- **API Reference**: `docs/API_REFERENCE.md`
- **Quick Reference**: `docs/QUICK_REFERENCE.md`
- **GQL Spec**: `docs/kb/gql/ISO_IEC_39075_2024(en).pdf`

## Questions?

Open an issue or discussion on GitHub for questions about contributing.

---

**P2-3 Remediation**: This project has **zero** `page_allocator` usage in production code. Let's keep it that way! 🎯
