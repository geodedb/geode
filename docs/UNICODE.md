# UNICODE.md - Geode Unicode Support

This document describes the current Unicode facilities available inside Geode, their scope, limitations, and governance traceability via CANARY requirements.

## Overview

Geode integrates a _minimal_ Unicode pipeline focused on:

1. NFC normalization (subset; selected decompositions + simple recomposition)
2. Case folding (targeted mappings: sharp S, Greek sigma variants, a few Latin accents) for FTS + comparisons
3. Conversion helpers between UTF-8 and UTF-16 (little-endian) using `std.unicode`
4. Lossy decoding of potentially ill‑formed WTF-8 sequences into valid UTF-8 (replacement character insertion)

The implementation deliberately vendors only a reduced UCD subset sufficient for current normalization/folding coverage. Full canonical combining class and composition tables are **not** yet included (future expansion). A generator tool builds small tables at build time (non-fatal if it fails; promotion to enforced step tracked by REQ-GQL-UNICODE-006).

## Features & Requirement IDs

| REQ                 | Feature           | Aspect            | Status | Notes                                              |
| ------------------- | ----------------- | ----------------- | ------ | -------------------------------------------------- |
| REQ-GQL-UNICODE-004 | Normalization     | NFC Subset        | TESTED | Basic decompositions & recomposition.              |
| REQ-GQL-UNICODE-005 | Case Folding      | Fold Selected     | TESTED | Sharp S, Greek sigma, sample accents.              |
| REQ-GQL-UNICODE-006 | Build Integration | Generator Step    | IMPL   | Non-fatal system command in `build.zig`.           |
| REQ-GQL-UNICODE-008 | FTS Normalization | Analyzer Pipeline | TESTED | Fold + NFC on terms.                               |
| REQ-GQL-UNICODE-009 | Eval Compare      | NFC Compare       | TESTED | Expression comparator normalizes.                  |
| REQ-GQL-UNICODE-010 | ORDER BY Compare  | NFC Ordering      | TESTED | Deterministic ordering via NFC.                    |
| REQ-GQL-UNICODE-011 | Unique Keys       | NFC Key Canon     | TESTED | Constraint normalization.                          |
| REQ-GQL-UNICODE-012 | UTF-8→UTF-16      | Utf8ToUtf16       | IMPL   | Uses `std.unicode.utf8ToUtf16LeAlloc` (validated). |
| REQ-GQL-UNICODE-013 | UTF-16→UTF-8      | Utf16ToUtf8       | IMPL   | Uses `std.unicode.utf16LeToUtf8Alloc`.             |
| REQ-GQL-UNICODE-014 | WTF-8 Lossy       | Wtf8LossyDecode   | IMPL   | Uses `std.unicode.wtf8ToUtf8LossyAlloc`.           |

Promotion of 012–014 to TESTED occurs once CANARY scanner ingests the test names (`tests/canary_unicode_utf16.zig`).

## API Surface

Located in `src/unicode/geode_unicode.zig` (re-exported from `geode.unicode`):

```zig
pub fn nfcNormalize(alloc: std.mem.Allocator, s: []const u8) ![]u8;
pub fn foldCase(alloc: std.mem.Allocator, s: []const u8) ![]u8;
pub fn utf8ToUtf16Alloc(ally: std.mem.Allocator, s: []const u8) ![]u16;
pub fn utf16ToUtf8Alloc(ally: std.mem.Allocator, units: []const u16) ![]u8;
pub fn wtf8LossyToUtf8Alloc(ally: std.mem.Allocator, bytes: []const u8) ![]u8;
```

### Error Modes

- `nfcNormalize` / `foldCase`: May return allocator errors or `error.InvalidUtf8` on decode failures.
- `utf8ToUtf16Alloc`: Returns `error.InvalidUtf8` if validation fails.
- `utf16ToUtf8Alloc`: Propagates allocation failures; invalid surrogate sequences are handled by stdlib conversion.
- `wtf8LossyToUtf8Alloc`: Never fails on decoding ill‑formed sequences (lossy replacement). Only allocation errors may occur.

### Allocation Strategy

All functions allocate fresh buffers owned by the caller; callers must `free` them using the same allocator. No internal global state is retained.

## Limitations & Future Work

- Full canonical combining class ordering and composition are not implemented (subset normalization only).
- No locale-sensitive case folding or collation (binary collation default).
- No grapheme cluster segmentation (needed for precise UI slicing and advanced FTS highlighting).
- Generator step available via `zig build unicode-gen` (GAP-0169 resolved). Run with UnicodeData.txt present.
- UTF-32 operations are not exposed (current needs satisfied by UTF-16 boundary semantics).

## Governance & CANARY Lines (Examples)

Excerpt from `src/unicode/geode_unicode.zig`:

```zig
// CANARY: REQ=REQ-GQL-UNICODE-012; FEATURE="UnicodeUtf16"; ASPECT=Utf8ToUtf16; STATUS=EXEMPT; TEST=TestCANARY_REQ_GQL_UNICODE_012_Utf8ToUtf16RoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-013; FEATURE="UnicodeUtf16"; ASPECT=Utf16ToUtf8; STATUS=EXEMPT; TEST=TestCANARY_REQ_GQL_UNICODE_013_Utf16ToUtf8RoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-014; FEATURE="UnicodeWtf8"; ASPECT=Wtf8LossyDecode; STATUS=EXEMPT; TEST=TestCANARY_REQ_GQL_UNICODE_014_Wtf8Lossy; OWNER=unicode; UPDATED=2025-09-27
```

## Usage Example

```zig
const unicode = @import("geode").unicode;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();
const folded = try unicode.foldCase(alloc, "Straße");
const utf16 = try unicode.utf8ToUtf16Alloc(alloc, folded);
const back = try unicode.utf16ToUtf8Alloc(alloc, utf16);
// back now holds folded form in UTF-8
alloc.free(folded);
alloc.free(utf16);
alloc.free(back);
```

## Testing

`tests/canary_unicode_utf16.zig` contains:

- `TestCANARY_REQ_GQL_UNICODE_012_Utf8ToUtf16RoundTrip`
- `TestCANARY_REQ_GQL_UNICODE_013_Utf16ToUtf8RoundTrip`
- `TestCANARY_REQ_GQL_UNICODE_014_Wtf8Lossy`

These will promote statuses to TESTED once the scanner runs with updated tags referencing the new tests (follow-up patch: adjust STATUS from IMPL → TESTED after evidence ingestion).

## Changelog (Unicode Section)

- Added std.unicode-based UTF-16 / WTF-8 helpers (REQ-GQL-UNICODE-012/013/014)
- Introduced lossy WTF-8 decoding wrapper
- Documented API, limitations, and governance mapping

## Rationale (Summary)

- Keep tables minimal to reduce binary size & build time
- Leverage stdlib for correctness in encoding conversions
- Stage normalization expansion to avoid premature complexity
- Explicit governance via CANARY IDs for incremental promotion

---

MIT License applies. See `LICENSE`.
