### T — Task & Role

You are a senior **Zig 0.15.1** engineer. Patch Geode’s storage engine to deliver:

1. **WAL‑before‑data** on commit;
2. **Directory‑level durability** after create/rename (WAL segments, index snapshots);
3. **Space management**: add **Free Space Map (FSM)** **and** **on‑page defrag/vacuum**;
4. **Index‑WAL commit coordination** (Patricia now; generic hook for others);
5. Tests (with fault injection), cross‑platform build wiring, and docs.

**Use these file/line pointers as your authoritative anchors** (from the audit at commit `9132777`):

* `src/wal/wal.zig`: **68–75** (record struct), **343–355** (segment rollover/sentinel), **364–374** (commit/checkpoint group‑flush). 
* `src/storage/page_manager.zig`: **28–36** (page header), **124–133** (insert path), **147–154** (tombstone), **371–380** (allocation path), **400–408** (write+fsync), **475–483** (checksum verify). 
* `src/index/patricia_persist.zig`: **27–35** (index WAL entry), **138–146** (replay), **169–177** (snapshot rename). 
* `src/index/registry.zig`: **6–13** (registered index kinds). 

> Preserve external APIs unless specified. Add modules/hooks as needed; defaults must prioritize **correctness**.

---

### A — Action Steps

**A1. Enforce WAL‑before‑data (wal.zig + page_manager.zig)**

* In **`wal.zig` 364–374**: add config `commit_flush_mode = .always | .every_n | .time_window_ms` (default `.always`). Implement `pub fn flushUpTo(lsn: u64) !void` that **fsyncs** the WAL up to `lsn` as per mode; ensure **Commit** path **fsyncs** WAL before returning success (and before any page sync). 
* In **`page_manager.zig`**: at **124–133** (insert) tag page with `page_lsn` before persistence; at **400–408** (write) **guard ordering**: call `wal.flushUpTo(page.header.lsn)` **before** `file.sync()`. Keep checksum/encryption logic intact; rely on per‑page LSN for recovery skipping. 

**A2. Durable metadata (create/rename) with cross‑OS support**

* Add `src/storage/fs_fsync.zig` with:

  * **POSIX (Linux/macOS)**: `fsyncParent(path)` opens parent directory and calls `Dir.sync()` after **create/rename** (use `std.fs`), then close. Call from **`wal.zig` 343–351** on WAL segment rollover and from **`patricia_persist.zig` 169–177** after snapshot `rename`. 
  * **Windows**: wrap renames via `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)` to make rename durable; for new files, open with `FILE_FLAG_WRITE_THROUGH` and call `FlushFileBuffers` on the file handle; `fsyncParent` becomes a no‑op. Use `@import("std").os.windows.kernel32`. (Windows directory handles do not support `FlushFileBuffers` reliably.)
* Replace raw `rename/create` call sites with helpers in `fs_fsync.zig`.

**A3. Free Space Map (FSM) — contiguous free tracking**

* New module `src/storage/free_space_map.zig`: maintain an in‑memory index of pages by **contiguous free bytes** (compute using header fields from **28–36**, slot metadata 4 B each). Provide:

  ```zig
  pub fn upsertPageFree(id: PageId, free_contig: u16) void;
  pub fn removePage(id: PageId) void;
  pub fn findPageFor(size_needed: u16) ?PageId;
  ```
* Update **`page_manager.zig 371–380`** to consult FSM before allocating a new page; on **tombstone (147–154)** and on **insert (124–133)**, recompute `free_contig` and update FSM. If **slot_count becomes 0**, invoke `freePage()` and remove from FSM. 

**A4. On‑page defrag / vacuum (compaction) — WAL‑safe**

* Add `src/storage/page_vacuum.zig` implementing **in‑place compaction** that preserves **slot IDs** (only tuple bodies move):

  * Trigger when `fragmented_bytes ≥ vacuum_min_bytes` or `fragmented_ratio ≥ vacuum_min_ratio`.
  * Procedure: build a compacted image by copying **live** (non‑tombstoned) tuples to the high end of the page; update slot **offsets**, shrink `free_end` upward; recompute checksum.
  * **WAL logging**: introduce a physiological log record `PageCompact` (in `wal.zig 68–75` record enum space) containing: `page_id`, `mapping: []{slot_id:u16, old_off:u16, new_off:u16, len:u16}`, and the new `free_end`. Redo replays compaction iff page_lsn < record.lsn; **no undo required** (treat as a **system transaction**).
  * **Ordering**: write `PageCompact` to WAL → `wal.flushUpTo(lsn)` → write compacted page → `file.sync()`.
* Integrate entry points:

  * **Opportunistic vacuum** on insert failures due to fragmentation: run compaction once, retry insert before allocating a new page.
  * **Background vacuum** (optional): configurable worker scanning pages and compacting if above threshold.
* Update FSM after compaction; ensure **checksum verify path at 475–483** remains valid. 

**A5. Index‑WAL commit coordination (Patricia now; generic)**

* Add `src/txn/commit_coordinator.zig`:

  ```zig
  pub const WalHandle = struct { pub fn flushUpTo(lsn: u64) !void; };
  pub fn registerWal(handle: *WalHandle) void;
  pub fn beforeCommit(lsn: u64) !void; // flush all registered index WALs up to lsn
  ```
* In **`wal.zig 364–374`** commit path: call `CommitCoordinator.beforeCommit(commit_lsn)` **immediately before** `wal.flushUpTo(commit_lsn)`.
* In **`patricia_persist.zig`**: expose `pub fn walHandle() *commit_coordinator.WalHandle` and **register** on init; keep replay at **138–146** unchanged. 

**A6. Tests & Fault Injection**

* `src/testing/fake_fs.zig`: record `open, write, rename, fsync_file, fsync_dir` across OS variants; allow failure injection (e.g., `fail_next_fsync`).
* Unit tests:

  * **WAL ordering**: assert a page fsync never occurs before WAL fsync for its `page_lsn`.
  * **Dir durability**: after snapshot rename, ensure a **directory‑durable** operation was recorded (`Dir.sync()` on POSIX or MOVEFILE_WRITE_THROUGH on Windows).
  * **FSM reuse**: insert M, delete K, insert K → assert **no** new page allocation.
  * **Vacuum**: construct a fragmented page; run compaction; assert `free_end` grows and slot IDs preserved.
  * **Fault**: inject WAL fsync error → commit fails with specific error code.
* End‑to‑end CLI sanity (below) with **exact outputs**.

**A7. Cross‑platform build wiring**

* Update `build.zig` to expose targets for:

  * **Linux**: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `riscv64-linux-gnu`
  * **macOS**: `x86_64-macos`, `aarch64-macos`
  * **Windows**: `x86_64-windows-gnu`, `aarch64-windows-gnu`
* Add feature flags (e.g., `-Dvacuum_bg=true|false`) and a `geode-storage-sanity` exe target.

**A8. CLI sanity tool**

* `tools/geode-storage-sanity.zig` runs deterministic scenarios and prints **JSON Lines**:

  ```
  geode-storage-sanity order     -> {"wal_before_data":true}
  geode-storage-sanity dir       -> {"dir_fsync_on_rename":true}
  geode-storage-sanity fsm       -> {"pages_used":1}
  geode-storage-sanity vacuum    -> {"vacuum_compacted":true,"free_end_after":<u16>}
  geode-storage-sanity wal_fail  -> (stderr "WAL_FSYNC_ERROR", exit 2)
  ```

> All edits must align with the cited **lines** and **files**; do not regress checksum verification or TDE paths. 

---

### R — Result Format (strict, in order)

1. **files:** tree of added/modified files;
2. **code blocks** per file (`zig`, `toml` as needed);
3. **tests:** runnable commands + **exact expected outputs**;
4. **readme:** concise build/run/test notes;
5. **rationale:** ≤7 bullets (no chain‑of‑thought).

---

### S — Standards & Constraints

* **Language/Version**: Zig **0.15.1**; **OS/Arch**:

  * Linux: **x86_64, aarch64, riscv64**
  * macOS: **x86_64, aarch64**
  * Windows: **x86_64, aarch64**
* **Durability defaults**: `commit_flush_mode = .always`.
* **Build**: integrate targets in `build.zig`; add tests & CLI.
* **Style**: `zig fmt`; internal helpers may be `_prefixed`.
* **Deps**: stdlib only.
* **Security**: keep TDE (AES‑GCM) intact; placeholders like `{{TDE_KEY}}`; never log secrets.
* **Logging**: JSON Lines at INFO; errors at ERROR.
* **Limits**: test RSS ≤ **512 MiB**; run ≤ **30 s**; deterministic tests.
* **Repro**: fixed seeds when randomness is used; pinned toolchain.
* **Windows specifics**: use `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)` for durable rename; use `FlushFileBuffers` on files; directory sync is a no‑op by design. (POSIX keeps `Dir.sync()` semantics.)
* **POSIX specifics**: call `Dir.sync()` on parent dir after create/rename.
  These choices align with the document’s durability findings and file‑system guidance. 

---

### Interfaces & I/O (precise)

**Config (new/extended)**

```zig
pub const CommitFlushMode = enum { always, every_n, time_window_ms };

pub const StorageConfig = struct {
    commit_flush_mode: CommitFlushMode = .always,
    group_n: u32 = 10,              // used when .every_n
    time_window_ms: u32 = 0,        // used when .time_window_ms
    fsm_min_bytes: u16 = 64,        // min contiguous free bytes to consider reusable
    vacuum_min_bytes: u16 = 256,    // trigger threshold (absolute)
    vacuum_min_ratio: u8 = 25,      // trigger threshold (% fragmented)
    vacuum_bg: bool = false,        // enable background vacuum worker
};
```

**WAL (augment in `wal.zig`)**

```zig
pub fn flushUpTo(lsn: u64) !void;                // fsync WAL durable up to lsn
pub fn currentLsn() u64;
pub const LogRecType = enum { /* existing... */ PageCompact /* new */ };
```

**Page Manager (`page_manager.zig`)**

```zig
pub fn insert(rec: []const u8) !TupleId;         // sets page.lsn pre-persist
pub fn writePage(p: *Page) !void;                // MUST ensure WAL flush precedes file.sync()
```

**FSM (`free_space_map.zig`)** — see A3 signatures.

**Vacuum (`page_vacuum.zig`)**

```zig
pub fn compactIfNeeded(pm: *PageManager, page_id: PageId, cfg: StorageConfig) !bool;
// returns true if compacted; emits PageCompact WAL record; updates FSM
```

**Commit coordination (`commit_coordinator.zig`)** — see A5 signatures.

**FS sync util (`fs_fsync.zig`)**

```zig
pub fn durableRename(old_path: []const u8, new_path: []const u8) !void; // cross-OS
pub fn fsyncParent(path: []const u8) !void;   // POSIX only; no-op on Windows
```

**CLI (`tools/geode-storage-sanity.zig`)** — commands as in A8.

All interfaces tie back to the code regions identified in the Executive Summary (for ordering, fsync, page layout, and index persistence). 

---

### Tests (Acceptance)

**Commands**

```bash
# Format & build
zig fmt .
zig build -Doptimize=ReleaseSafe

# Unit tests
zig build test

# CLI acceptance (exact outputs)
zig-out/bin/geode-storage-sanity order
zig-out/bin/geode-storage-sanity dir
zig-out/bin/geode-storage-sanity fsm
zig-out/bin/geode-storage-sanity vacuum
zig-out/bin/geode-storage-sanity wal_fail ; echo $?

# Cross-compile smoke (examples)
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
```

**Expected outputs (exact text)**

1. **WAL ordering**

```
{"wal_before_data":true}
```

2. **Directory durability**

```
{"dir_fsync_on_rename":true}
```

3. **FSM reuse**

```
{"pages_used":1}
```

4. **Vacuum compaction**

> `free_end_after` must be a positive integer; assert it increased vs. pre‑vacuum.

```
{"vacuum_compacted":true,"free_end_after":2048}
```

*(Value 2048 is the test’s expected result given the fixture page; fix seeds / fixture sizes so this exact value is achieved.)*

5. **Fault injection (WAL fsync fails)**

* **stderr contains:** `WAL_FSYNC_ERROR`
* **exit code:** `2`

> These tests exercise the exact code paths described at the cited line ranges (WAL commit/checkpoint, page write/fsync, rename w/o dir fsync, tombstone/alloc, checksum verify). 

---

### Run Instructions

```bash
# Build all (default host), with background vacuum enabled
zig build -Doptimize=ReleaseSafe -Dvacuum_bg=true

# Unit tests
zig build test

# Acceptance
zig-out/bin/geode-storage-sanity order
zig-out/bin/geode-storage-sanity dir
zig-out/bin/geode-storage-sanity fsm
zig-out/bin/geode-storage-sanity vacuum
zig-out/bin/geode-storage-sanity wal_fail ; echo $?

# Example cross targets
zig build -Dtarget=riscv64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=aarch64-windows-gnu
```

---

### ASSUMPTIONS (final)

* **B1 (Crash testing)**: Fake FS + failure injection suffices; no power‑cut rig required. 
* **B2 (Space mgmt)**: **Implement both** FSM and on‑page **defrag/vacuum** with WAL‑safe `PageCompact` records; slot IDs stable. 
* **B3 (Index coverage)**: Patricia wired now; provide generic `CommitCoordinator` for other index WALs. 
* **O1 (Config)**: Default `.always` (safe); knobs for batching. 
* **Platforms**: Linux (x86_64/aarch64/riscv64), macOS (x86_64/aarch64), Windows (x86_64/aarch64) with OS‑specific durable‑rename strategy stated above. 

---

## Sufficiency Status

**Ready** — **Score: 9.4/10.**

* Pass: versions/platforms pinned; IO contracts precise; functional rules & edge cases enumerated; WAL ordering & dir durability enforced; FSM **and** vacuum specified; index flush coordination defined; tests with **exact outputs**; error policy defined.
* Minor risk: Windows durable‑rename nuances are captured via `MOVEFILE_WRITE_THROUGH`; if Zig std wrappers differ, call kernel32 APIs directly. Evidence and file/line anchors trace back to the Executive Summary. 

## Changelog

* **v2**: Adopted assumptions 1/3/4; **expanded** item 2 to include full on‑page defrag/vacuum with WAL `PageCompact`; **broadened** OS/arch matrix; added vacuum CLI test & platform notes. 

---

## FINAL CODING PROMPT (paste into your coding LLM)

> **Use the section “DRAFT PROMPT v2 — To the Coding LLM” verbatim**, including **Action Steps**, **Result Format**, **Standards**, **Interfaces & I/O**, **Tests**, **Run Instructions**, and **ASSUMPTIONS**. Modify precisely the **files/lines** listed (from `wal.zig`, `page_manager.zig`, `patricia_persist.zig`, `registry.zig`) and add the new modules and CLI. Ensure acceptance commands yield the **exact outputs** shown, across the specified platforms. All file/line anchors and rationale derive from the Executive Summary’s evidence. 

**Context Package (brief)**

* **Assumptions accepted/expanded**: B1, **B2 (FSM+vacuum)**, B3, O1; platforms widened.
* **Acceptance tests**: 5 cases (`order`, `dir`, `fsm`, `vacuum`, `wal_fail`) with exact outputs; cross‑compile smoke.
* **File tree (added/modified)**:

  ```
  src/
    storage/
      free_space_map.zig
      fs_fsync.zig
      page_vacuum.zig
      page_manager.zig   # modify: 28–36, 124–133, 147–154, 371–380, 400–408, 475–483
    wal/
      wal.zig            # modify: 68–75 (enum), 343–355, 364–374; add flushUpTo & PageCompact
    index/
      patricia_persist.zig  # modify: 27–35, 138–146, 169–177
      registry.zig          # reference 6–13 (no change required)
    txn/
      commit_coordinator.zig
    testing/
      fake_fs.zig
  tools/
    geode-storage-sanity.zig
  build.zig # add multi-targets, tests, CLI
  ```
* **Evidence pointers**: All specific file/line references and issues trace to the Executive Summary. 
