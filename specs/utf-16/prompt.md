### **T — Task & Role**

You are a senior **Zig 0.15.1** engineer. Implement **Unicode‑correct text handling** for Geode: **UTF‑8 internal + NFC normalization + Unicode case‑fold** (for FTS/CI ops), and **UTF‑16 edges** (Windows & optional I/O). **Use only Zig stdlib** and **build what stdlib lacks** (normalization + folding) from vendored UCD files. Apply changes at the **specific files/functions below** (anchors), with API/behavior changes allowed. Ground truth and hotspots come from **“Design: Unicode UTF‑16 Support in Geode (Zig 0.15.1)”**. 

---

### **A — Action Steps**

#### A1) Unicode Data & Codegen (pure Zig; no network)

* **Vendor UCD 15.x** files under `third_party/unicode/ucd/` (text files committed):
  `UnicodeData.txt`, `CaseFolding.txt` (Full), `DerivedNormalizationProps.txt`, `CompositionExclusions.txt`, `NormalizationTest.txt`.
* **Add generator** `tools/gen_unicode_tables.zig` to parse UCD and emit **compact tables** to `src/unicode/generated/{decomp.zig, ccc.zig, comp.zig, casefold.zig}`:

  * Canonical Decomposition map (code point → sequence) + **Hangul SBase/LBase/VBase** fast‑path.
  * Canonical Combining Class (CCC) lookup (dense range‑compressed).
  * Composition map (pair→code point) excluding composition exclusions.
  * **Full** Unicode Case‑Fold map (code point → sequence).
* **Wire build**: in `build.zig`, add a step that regenerates tables when UCD inputs change, else use pre‑generated files; **no network**.
* **License note**: include Unicode data notice in `THIRD_PARTY.md`.

#### A2) Core Unicode module (new)

Create `src/unicode/geode_unicode.zig` providing **stdlib‑only** APIs (names fixed for callers):

```zig
pub const NormalizationMode = enum { nfc };

pub fn nfcNormalizeAlloc(ally: *std.mem.Allocator, s: []const u8) ![]u8
pub fn caseFoldAlloc(ally: *std.mem.Allocator, s: []const u8) ![]u8

pub fn utf8ToUtf16LeAlloc(ally: *std.mem.Allocator, s: []const u8) ![]u16
pub fn utf16LeToUtf8Alloc(ally: *std.mem.Allocator, u: []const u16) ![]u8

/// Windows-only: round-trip WTF-8 <-> UTF-16LE with safe pre-sizing.
pub fn wtf8ToUtf16LeAlloc(ally: *std.mem.Allocator, w: []const u8) ![]u16
pub fn utf16LeToWtf8Alloc(ally: *std.mem.Allocator, w: []const u16) ![]u8
```

**Rules**:

* Use **std.unicode** for UTF‑8/16 conversions/iteration; build NFC + fold using the **generated tables**.
* **NFC** algorithm: decompose to **NFD**, **stable sort** by CCC, **recompose** (skip composition‑excluded).
* **Folding**: Unicode **Full** case‑fold sequences (not locale‑tailored).
* All functions **fail‑closed** on invalid encodings (`error.InvalidUtf8/Utf16`) or **replace with U+FFFD** behind an explicit flag (implement `NormalizeOptions` if needed later).
* Memory: linear O(n); avoid quadratic concatenations (use `ArrayList`).

#### A3) Replace ASCII‑only logic at **specific files/functions**

> Use the **exact anchor identifiers** below. If line numbers drift, **locate by the signature/comment** and replace the function bodies as specified. (Anchors come from the design’s repo reconnaissance.) 

* **`src/index/fulltext.zig`**

  1. **Anchor:** `fn normalize` in `FullTextIndex` (currently bytewise `std.ascii.toLower`).
     **Change:** Replace body with **NFC → caseFold** pipeline via `geode_unicode.*Alloc`. Ensure capacity for expansions (e.g., `ß→ss`). **Return NFC+folded UTF‑8.** 
  2. **Anchor:** tokenization loop using `std.ascii.isAlphanumeric`.
     **Change:** Iterate with `std.unicode.Utf8View`; treat delimiters = ASCII whitespace/punct **plus** Unicode spaces (NBSP U+00A0; U+2000–U+200B; U+3000) and General Punctuation ranges. **Never split inside a code point.** 

* **`src/fts/advanced.zig`**
  3) **Anchor:** search/query term normalization (uses `lower_content`, `highlight`).
  **Change:** Build `folded_content = caseFold(NFC(content))`; likewise fold/NFC query terms. For **highlight** windows, compute by **code points**; when slicing bytes, **backtrack off continuation bytes** (0x80..0xBF) to nearest lead byte. 

* **`src/eval.zig`**
  4) **Anchor:** helpers for `StartsWith`, `EndsWith`, `Contains`.
  **Change:** Normalize **both operands to NFC** first, then use bytewise ops on normalized slices; add **CI variants** (explicit) that also **case‑fold** both sides. **API‑breaking OK**: expose `startsWithNfc`, `startsWithFold`, etc. 

* **`src/exec.zig`**
  5) **Anchor:** string compare path used by `ORDER BY`.
  **Change:** Compare **NFC** forms with `std.mem.order(u8, a, b)`; **do not** fold by default (binary code‑point collation). Stable on ties. 

* **`src/schema/constraint_manager.zig`**
  6) **Anchor:** unique key hashing/equality for strings.
  **Change:** Hash/compare **NFC** keys so canonically‑equivalent strings collide (enforce uniqueness). **API change**: store normalized key. Add targeted tests. 

#### A4) Input & OS edges (UTF‑16)

* Normalize **on ingress** (data & literals) to NFC.
* Windows: path/env/FFI use **UTF‑16LE** via module APIs above; internally keep **UTF‑8/WTF‑8**. 

#### A5) Docs (update)

* Document **NFC storage**, FTS **Unicode folding**, and **binary code‑point** ordering; note **API/behavior changes** (equality & uniqueness on NFC). 

---

### **R — Result Format (strict, in order)**

1. **`files:`** final tree.
2. **Code blocks per file** (full contents).
3. **`tests:`** Zig tests (unit + integration).
4. **`readme:`** usage + build/test commands, API changes summary.
5. **`rationale:`** ≤7 bullets (no chain‑of‑thought).

---

### **S — Standards & Constraints**

* **Language/Version**: Zig **0.15.1**; **OS**: POSIX‑like + Windows.
* **Deps**: **No external libraries**; **vendored UCD text files only**; tables generated by `tools/gen_unicode_tables.zig`.
* **Style**: `zig fmt` clean; structured logs (JSON Lines).
* **Performance**: Normalization/fold **O(n)**; tokenization linear; no quadratic joins.
* **Security**: fail‑closed decoding; bounds‑safe slicing; never log string contents.
* **License**: project **MIT**; include Unicode data notice.
* **Repro**: deterministic codegen from **pinned UCD version**; no network at build time.

---

### **Interfaces & I/O (precise signatures + examples)**

**Unicode module** (see A2):

```zig
// NFC normalize: "Cafe\u{301}" -> "Café"
const out = try geode_unicode.nfcNormalizeAlloc(ally, "Cafe\xCC\x81");

// Full case-fold: "Straße"/"STRASSE" -> "strasse"
const f = try geode_unicode.caseFoldAlloc(ally, "Straße");

// UTF-8 <-> UTF-16LE
const u16 = try geode_unicode.utf8ToUtf16LeAlloc(ally, "𝄞");
const u8  = try geode_unicode.utf16LeToUtf8Alloc(ally, u16);
```

**Predicate semantics**

* Default ops (`=`, `CONTAINS`, `STARTS WITH`, `ENDS WITH`): operate on **NFC**.
* **CI variants** (new): operate on **NFC + case‑fold**.
* **ORDER BY**: **binary code‑point** over **NFC** (no folding). 

**Hotspot anchors to edit (exact files/functions):**

* `src/index/fulltext.zig`: `fn normalize` & tokenizer loop using `std.ascii.isAlphanumeric`.
* `src/fts/advanced.zig`: term normalization and `highlight(...)` slicing logic.
* `src/eval.zig`: `StartsWith/EndsWith/Contains` helpers.
* `src/exec.zig`: string compare path used by `ORDER BY`.
* `src/schema/constraint_manager.zig`: unique string key hashing/equality.
  (Use these **anchors** to find/replace; they are the exact hotspots called out in the design.) 

---

### **Tests (Acceptance) — exact commands & expected outputs**

**Cmd:** `zig build test -Doptimize=ReleaseSafe`

1. **NFC round‑trip**
   Input: `"Cafe\u{301}"` → `nfcNormalizeAlloc` → bytes `43 61 66 C3 A9` (`"Café"`). **Expect:** equality on bytes.

2. **Case‑fold multi‑char**
   Inputs: `"Straße"`, `"STRASSE"` → `caseFoldAlloc` → both `"strasse"`. **Expect:** `std.mem.eql(u8, a, b) == true`.

3. **FTS tokenize & search (Unicode)**
   Content: `"Überraschung — 世界, café"`; Query: `"über"`.
   **Expect:** folded tokens include `"überraschung"`; search hits doc; Unicode punctuation/whitespace split correctly.

4. **Predicates use NFC**
   Data: `"e\u{301}cole"`; Query: `"école"`.
   **Expect:** `=` true; `CONTAINS("é")` true; `STARTS WITH("é")` true.

5. **Uniqueness on NFC**
   Insert `"É"` then `"E\u{301}"` under unique(name).
   **Expect:** second insert **errors** (same NFC key).

6. **Windows WTF‑8 path (simulated)**
   Craft WTF‑8 bytes for lone surrogate; `wtf8ToUtf16LeAlloc` round‑trips without overflow.
   **Expect:** conversion succeeds; round‑trip equals original bytes.

7. **Invalid UTF‑16 strict**
   Dangling high surrogate → `utf16LeToUtf8Alloc`
   **Expect:** returns `error.InvalidUtf16`; process **exit code 1**; stderr includes `"SCHEMA_ERROR: InvalidUtf16"`.

---

### **Run Instructions**

* **Generate tables & build:** `zig build -Doptimize=ReleaseSafe`
* **Run tests:** `zig build test -Doptimize=ReleaseSafe`
* **Format:** `zig fmt src/ tests/ tools/ build.zig`

---

### **Assumptions (final)**

* **A1**: Internal strings are **UTF‑8**; **NFC** applied on ingress & literals.
* **A2**: FTS and explicit CI ops use **Unicode case‑fold**; **ORDER BY** stays **binary on NFC**.
* **A3**: Windows paths use **WTF‑8 internally**, **UTF‑16LE** at OS boundary.
* **A4**: **No external libraries**; **vendored UCD** + **Zig codegen** only.
* **A5**: **API‑breaking is allowed**; no legacy migration or toggles. 

---

## Sufficiency Status

**Ready** — Score **9.4/10**. All specs pinned; I/O contracts precise; hotspots enumerated; tests include invalid/edge with exact outcomes; no external deps; security & determinism addressed. Minor residual risk: scope of Unicode word boundaries (UAX#29) is simplified (documented).

---

## Changelog (vs v1)

* **Removed external utf8proc**; added **UCD‑driven pure‑Zig** normalization + folding plan and codegen.
* **Locked assumptions B2–B4** per your directive; **formalized API‑breaking** stance (no legacy/migration).
* Tightened **hotspot instructions** to **specific files/functions** and **std‑only** calls.
* Kept acceptance tests; clarified **byte‑safe slicing** and **Windows WTF‑8** round‑trip. 
