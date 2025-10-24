## Research Prompt — “Complete the Client REPL” (Main Branch)

### 0) Objective & Outcomes

**Goal:** Produce a **complete, implementation‑ready specification** for finishing the **Client REPL** in the `geode` codebase (main branch), covering:

1. **Command history** (persistent, searchable).
2. **Auto‑completion** (commands, flags, identifiers, context‑aware).
3. **Multi‑line input** (structured/balanced blocks, indentation, paste mode).
4. **Error handling & reporting** (typed errors, user‑friendly messages, logs, diagnostics).

**Primary artifact:** *Implementation Specification* (≈15–30 pages equivalent), including interfaces, module boundaries, data structures, error codes, UX flows, test plans, and migration steps (see §7).

**Non‑goals (for now):** New language features, network protocol changes, TUI redesign beyond core REPL affordances, telemetry beyond error reporting (unless already present).

---

### 1) Assumptions & Access

* Repo path: `github/spyderorg/geode` (main branch). If private, ensure access or adjust to the correct remote.
* The codebase already contains a “Client” and partial REPL entrypoints (e.g., `client/`, `cli/`, `repl/`, or equivalent).
* Cross‑platform support (Linux/macOS/Windows) is required unless the repository explicitly targets fewer platforms.

> If any assumption fails, **document the variance** inside the final spec and adapt scope accordingly. Do **not** pause work; proceed with best‑effort mapping based on the discovered structure.

---

### 2) Deliverables (What to Produce)

1. **Implementation Specification (primary)**

   * **Architecture**: module diagram; control/data flow for input→parse→dispatch→evaluate→render→persist.
   * **Interfaces & Types**: command registry API, completer SPI, history provider, error taxonomy.
   * **UX/Keybindings**: default bindings, escape hatches, config precedence, non‑interactive fallback.
   * **Storage**: history file format & path (XDG on *nix, `%APPDATA%` on Windows), rotation, privacy knobs.
   * **Completion Model**: lexical vs. semantic sources; dynamic providers; caching & invalidation; snippet support.
   * **Multi‑line Rules**: bracket/quote balancing, continuation prompts, paste‑mode heuristics, indent rules.
   * **Errors & Diagnostics**: error classes, codes, suggestion engine, redaction policy, logging pipeline.
   * **Observability**: log levels, sinks, correlation IDs, structured fields, user‑visible vs. developer logs.
   * **Compatibility**: interaction with existing command handlers, config, logging, and packaging.
   * **Security**: injection surfaces, sandboxing expectations, safe rendering, path traversal mitigations.
   * **Performance**: latency targets (p50/p95 for keystroke→echo, completion list), memory caps.
   * **Test Plan**: unit, integration (pty/e2e), snapshot “goldens,” cross‑platform matrix, fuzz cases.
   * **Migration Plan**: config/data migrations, deprecation notes, rollout flags.
   * **Risks & Mitigations**: terminal quirks, race conditions, corrupted history, locale/IME issues.

2. **Appendices**

   * **API/ABI diffs** (if any), **error code registry**, **keybinding table**, **configuration schema**, **test fixtures**, **mock server/contracts** (if Client dispatches remotely).

---

### 3) Discovery & Codebase Recon (Do This First)

**D1. Repository verification**

* Confirm **default branch** (`main`) and current HEAD commit (hash, date).
* Inventory **languages** (by LOC), build system(s), dependency managers, and runtime(s).
* Identify **terminal/CLI layer** (e.g., readline/prompt toolkit equivalents) and **logging** stack.

**D2. Locate REPL surfaces**

* Grep for keywords: `repl`, `interactive`, `prompt`, `readline`, `history`, `complete`, `lexer`, `parser`, `command`, `dispatch`.
* Map files & packages likely involved (e.g., `client/repl/*.xyz`, `cmd/client`, `src/cli`, `internal/console`, `pkg/repl`).

**D3. Execution path**

* Trace from **binary entrypoint** → **REPL loop** → **input tokenizer/parser** → **dispatcher** → **command handlers** → **output renderer**.
* Note async/concurrency model, cancellation semantics (Ctrl‑C), and resource lifetimes (connections).

**D4. Existing behavior & gaps**

* Run current REPL (if available): record **observed behaviors** for history, completion, multi‑line, errors.
* Capture **known issues** (open/closed) and TODOs in code comments.

**Output of §3:** A one‑page **system map** and a table of **current vs. target** behaviors.

---

### 4) Design Requirements (What “Done” Looks Like)

#### R1. Command History

* **Persistence:** Per‑user history file; default locations:

  * *nix: `${XDG_STATE_HOME:-~/.local/state}/geode/history` (fallback `~/.geode_history`)
  * macOS: `~/Library/Application Support/geode/history`
  * Windows: `%APPDATA%\\Geode\\history`
* **Capacity & Rotation:** Max N entries (default 5k), dedupe sequential duplicates; rotate on file > M MiB.
* **Search:** Arrow navigation, **reverse‑i‑search (Ctrl‑R)** with incremental filtering; case‑insensitive by default.
* **Privacy:** Opt‑out (`GEODE_HISTORY=0`), redact tokens marked “secret” by the parser; safe‑mode disables writes.
* **Locking:** Single‑writer file lock; atomic writes; crash‑safe temp→rename pattern.
* **Import:** Optional migration of existing history file if legacy exists.

#### R2. Auto‑Completion

* **Sources:**

  1. Built‑ins (command names, aliases, subcommands, flags/options).
  2. **Dynamic providers** (e.g., resource names from the connected backend).
  3. **Contextual** tokens (based on AST/parse state); file paths; environment vars.
* **Behavior:** Complete on `Tab`; cycle alternatives; **submenu** details (type, docstring, origin).
* **Scoring:** Prefix first, then subsequence/fuzzy; prioritize **valid in current grammar state**.
* **Rendering:** Paginated lists; horizontal scrolling for long items; **inline hints/ghost text** optional.
* **Extensibility:** Pluggable `Completer` interface with priority & capability flags; time‑budget (e.g., 50–75 ms).
* **Safety:** **Do not execute** side‑effects during completion; rate‑limit backend calls; cache with TTL.

#### R3. Multi‑line Input

* **Rules:** Accept block constructs; commit when **balanced** (quotes, brackets, braces).
* **Continuation Prompt:** Secondary prompt (e.g., `...>`) with contextual indent.
* **Paste Mode:** Detect large pastes; disable auto‑indent & completion during paste; show advisory.
* **Editing:** Select‑and‑indent, bracket matching, move lines, join/split lines; optional `Shift+Enter` to insert newline.
* **Config:** Toggle multi‑line; maximum logical line length; auto‑wrap on terminals with width constraints.

#### R4. Error Handling & Reporting

* **Taxonomy:**

  * `ParseError`, `ValidationError`, `DispatchError`, `BackendError`, `IOError`, `ConfigError`, `InternalError`.
* **Shape:** Each error has **code** (e.g., `GEODE-E1001`), summary, cause chain, hints, docs URL (if applicable).
* **Display:** Friendly single‑line summary by default; **verbose mode** (`--verbose` / env) shows stack & spans.
* **Suggestions:** For unknown commands/options, suggest nearest matches; for missing args, show usage snippet.
* **Logging:** Structured logs (JSON or key=value) with correlation IDs; severe errors mirrored to a rotating file.
* **Redaction:** Never print secrets/credentials; sanitize paths if configured.
* **Crash Shield:** Top‑level panic/exception guard prints stable message + reproduction hint; writes crash report.
* **Integration:** Honor existing logging system and CLI verbosity flags; consistent exit codes in non‑interactive mode.

---

### 5) Architecture & API Sketch (to be specialized to repo language)

> Detect repository language(s) and instantiate the appropriate stack. Below are **language‑agnostic components** and **expected interfaces** (rename/types as appropriate).

**A. Modules**

* `repl/loop`: main input loop, mode switches (normal, search, paste), signal handling (Ctrl‑C, Ctrl‑D).
* `repl/history`: in‑memory ring + persistent store; locking/rotation.
* `repl/complete`: registry + providers; lexer/AST bridge; scoring; pagination.
* `repl/parse`: tokenization + partial AST for context; error‑tolerant incremental parse for completions.
* `repl/dispatch`: command registry; argument binding; sync/async execution; cancellation.
* `repl/render`: prompt theming; help & error formatting; color/TTY detection; no‑color fallback.
* `repl/config`: load/merge precedence (defaults < file < env < flags); schema validation.
* `repl/errors`: error types, codes, display adapters; logging bridge.

**B. Key Interfaces (pseudo)**

```text
interface HistoryStore {
  load(): List<HistoryEntry>
  append(entry: HistoryEntry): void
  search(query: String, direction: Backward|Forward): Iterator<HistoryEntry>
  rotateIfNeeded(): void
}

interface Completer {
  canHandle(ctx: CompletionContext): boolean
  complete(ctx: CompletionContext): List<CompletionItem>   // with kind, detail, score
  budgetMs(): int        // optional time budget for slow providers
}

interface Parser {
  parseIncremental(buffer: String): ParseState           // partial AST + error spans
  isBalanced(state: ParseState): boolean
}

interface ErrorFormatter {
  format(err: GeodeError, verbosity: Normal|Verbose): StyledText
}
```

---

### 6) UX & Configuration Requirements

**Prompts & Theming**

* Primary prompt: `geode> `; continuation prompt: `...> `; show connection context (e.g., `(local)` / `(cluster:foo)`) if available.
* Respect `NO_COLOR`; provide `--color=auto|never|always`.
* Keybindings: Emacs‑style defaults (arrows, `Ctrl‑R` search, `Alt+F/B` word nav), with optional Vi mode.

**Configuration**

* File: `$XDG_CONFIG_HOME/geode/config.(toml|yaml|json)`; Windows: `%APPDATA%\\Geode\\config.(...)`.
* Keys: `repl.history.enabled`, `repl.history.path`, `repl.completion.mode` (`prefix|fuzzy`), `repl.multiline.enabled`, `repl.paste.warn`, `repl.errors.verbosity`, `repl.log.path`.
* Environment overrides: `GEODE_HISTORY`, `GEODE_NO_COLOR`, `GEODE_LOG`.

**Accessibility & Internationalization**

* Proper handling of **Unicode/combining characters**; IME support; right‑to‑left text does not break cursor math.
* Graceful degrade in **dumb terminals** (disable advanced features; fall back to simple line mode).

---

### 7) Test Plan & Acceptance Criteria

**Unit Tests**

* History: append/dedupe/rotation; concurrent open attempts simulate lock contention.
* Completion: grammar‑state filtering; fuzzy scorer ordering; TTL cache invalidation.
* Parser: incremental parse retains state across keystrokes; balance checks for edge cases (quotes, escapes).
* Errors: code assignment uniqueness; redaction; suggestion distance thresholds.

**Integration/E2E (pseudo‑tty)**

* Start REPL in a pty; script keystrokes and validate screen output:

  * **History** persists across sessions; `Ctrl‑R` reverse search returns expected entry.
  * **Completion** offers valid options at different cursor positions; cycling works; accept inserts token.
  * **Multi‑line**: unbalanced input keeps continuation prompt; balanced input executes; paste mode detected.
  * **Errors**: unknown command → helpful suggestion; backend failure → user‑facing hint + log entry; verbose mode shows trace.

**Cross‑platform Matrix**

* Linux (glibc & musl), macOS (Apple silicon & x86_64), Windows (ConHost + Windows Terminal).
* Terminal emulators: xterm‑compatible, iTerm2, Windows Terminal; **non‑TTY** CI fallback mode.

**Performance**

* p95 keystroke‑to‑render < **16 ms**; completion p95 < **100 ms** with warm caches.
* Memory overhead of REPL services < **50 MiB** steady‑state (adjust if repo language/runtime differs).

**Acceptance Criteria (must all pass)**

* All R1–R4 behaviors demonstrably implemented.
* Test suite added to CI; flake‑free on all supported OSes.
* Error code registry documented; no secrets leak in logs; history redaction works.
* Backward‑compatible with existing CLI; non‑interactive scripts unaffected.
* Documentation updated (README/USER‑GUIDE/CHANGELOG).

---

### 8) Research Method & Evidence Rules

**Method**

1. **Map the current implementation** (§3) with code references (file paths, key symbols).
2. **Choose the I/O stack** already used in repo (do not introduce an alien stack unless necessary).
3. **Draft the target design** (sections §4–§6) aligned to constraints discovered in code.
4. **Validate design** by building a small proof (toy command with multline+completion) in a feature branch.
5. **Finalize spec** with exact function signatures, types, configuration keys, and test vectors.

**Evidence Requirements**

* Cite **exact file paths** and **symbol names** for every integration point.
* When recommending dependencies, specify version constraints and license compatibility; justify selection vs. alternatives.
* Include **risk analysis** with known terminal quirks (Windows code pages, macOS IME, Linux terminfo).
* Document **benchmarks** or measurements used to justify performance targets.

---

### 9) Implementation Skeleton (to include in the Spec; adapt names to codebase)

```
/client/repl/
  loop.{ext}          // main loop, modes, signals
  history.{ext}       // ring buffer + file store
  complete/
    registry.{ext}    // provider registration & fan-out
    builtin.{ext}     // commands/flags provider
    filesys.{ext}     // path/env provider
    dynamic.{ext}     // backend-aware provider (time-budgeted)
    scoring.{ext}     // prefix/fuzzy ordering
  parse/
    lexer.{ext}       // tokens, quotes, escapes
    ast.{ext}         // minimal structures for context
    balance.{ext}     // multiline heuristics
  dispatch.{ext}      // command registry & invocation
  render.{ext}        // prompt, lists, help, colors
  errors.{ext}        // types, codes, formatter
  config.{ext}        // schema & merge order
tests/e2e/repl_*.{ext} // pty-driven tests
docs/repl-spec.md      // generated from this spec
```

---

### 10) Error Code Registry Template (include in Spec)

| Code        | Category        | When it occurs              | User message (short)                 | Suggestion/Doc |
| ----------- | --------------- | --------------------------- | ------------------------------------ | -------------- |
| GEODE‑E1001 | ParseError      | Unbalanced quotes/brackets  | “Unfinished input; continue typing…” | link           |
| GEODE‑E1102 | ValidationError | Unknown command/option      | “Unknown command ‘foo’.”             | suggest close  |
| GEODE‑E2001 | DispatchError   | Handler threw               | “Command failed.”                    | `--verbose`    |
| GEODE‑E3001 | BackendError    | Remote call timed out       | “Cluster not responding.”            | retry advice   |
| GEODE‑E4001 | IOError         | History file locked/corrupt | “Couldn’t write history.”            | path/lock tip  |
| GEODE‑E5001 | InternalError   | Unexpected panic/exception  | “Unexpected error.”                  | bug report     |

---

### 11) Security & Privacy Checklist

* [ ] Redact tokens/credentials from prompts, echoes, logs, errors.
* [ ] History redaction for fields tagged as secret by parser/command metadata.
* [ ] Avoid executing shell during completion; sanitize paths and file names in suggestions.
* [ ] Protect history/log files with user‑only permissions; handle symlink attacks on history path.
* [ ] Bound resource usage (completion provider time budget; max history size).

---

### 12) Handoff & Review

* Produce the **Implementation Specification** and a short **Maintainer Review Guide**: what to check, how to test locally, expected diffs.
* Open a draft PR with the spec in `docs/repl-spec.md`; link to issues or TODOs discovered.
* Include a **minimal demo** (feature‑flagged) to validate key paths (history, completion, multi‑line, error formatting).

---

## Notes for the Researcher

* Keep the spec **code‑adjacent**: quote concrete file paths, function names, and types from the repo.
* Prefer reusing the repository’s existing logging/config/CLI stack.
* Where trade‑offs exist (e.g., fuzzy vs. prefix completion), list pros/cons and justify the default.
* If the repo already uses a particular ecosystem (e.g., Rust `tracing`, Python `prompt_toolkit`, Go `cobra`), align with it and detail any necessary shims/adapters.

---

### Submission Checklist (for the Spec)

* [ ] Architecture diagram & control/data flows.
* [ ] Public interfaces + internal types with signatures.
* [ ] Config schema & defaults; file locations per OS.
* [ ] Error taxonomy, codes, and formatting rules.
* [ ] Keybinding map; UX mock screenshots (ASCII ok).
* [ ] Test matrix, fixtures, and golden outputs.
* [ ] Performance targets and measurement plan.
* [ ] Security/privacy analysis & mitigations.
* [ ] Migration/rollout steps & fallback plan.
* [ ] Open questions & decision log.
