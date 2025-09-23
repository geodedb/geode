# Interactive Shell Mode for Geode (`geodec`) – Specification

## Overview

The goal is to enhance the `geodec` client with an interactive REPL shell, similar to PostgreSQL’s `psql` or MySQL’s CLI. Instead of requiring a query on the command line, running `geodec` with no arguments will launch an interactive prompt (currently it just prints usage and exits). In this interactive mode, users can enter Graph Query Language (GQL) commands and special shell commands in a convenient environment.

Key features include:

- Multi-line input editing
- Command history (saved to `~/.geode_history`)
- Tab-completion for GQL and schema elements
- Syntax highlighting
- Session context (like current graph and output format)
- Multiple output formats
- Meta-commands (prefixed with `\`) for common tasks

The shell will maintain a persistent connection to a Geode server (or an embedded `geoded` process) and handle sending queries and receiving results incrementally. This specification details the functional behavior, user experience, implementation approach, and considerations for each aspect of the interactive shell mode.

---

## Multiline GQL Input and Editing

- **Free-form Multi-Line Input:** Users can press Enter without executing if the GQL statement is incomplete (missing semicolon or closing quote/parenthesis).
  Example:

  ```text
  geode> CREATE GRAPH social_network (
  geode(>   -- properties or options here
  geode-> ;
  ```

- **Continuation Detection:** Client determines if a GQL command is complete. If not, buffer accumulates lines until ready.

- **Inline Editing:** Full line-editing across lines (arrow keys, wrapping, history navigation).

- **Cancellation:** `Ctrl+C` cancels the current buffer without exiting the shell. If query is running, attempts cancel.

- **External Editor Support (`\e`):** Opens the current buffer in `$EDITOR` (default `vi`). Mirrors `psql` behavior.

- **Prompt Customization:** Default `geode>`; continuation prompts like `geode->`. Configurable via session variables.

---

## Command History and Reverse Search

- **History Navigation:** Commands saved in memory and persistent file `~/.geode_history`.
- **Persistent History File:** Loaded on startup, saved on exit. Configurable path via `GEODE_HISTORY`.
- **Reverse Search:** `Ctrl+R` (reverse-i-search). If unsupported in library, fallback via custom implementation or `\search`.
- **History Limit:** Default 500–1000 entries. Avoid whitespace-only or sensitive commands.
- **Meta-commands:**

  - `\history` — display recent commands
  - `\history -c` — clear

---

## Autocompletion of Keywords and Schema Names

- **Triggers:** `<TAB>` completes current word.
- **Supported:**

  - GQL keywords (`MATCH`, `CREATE`, `RETURN`, …)
  - Graph names (`USE GRAPH …`)
  - Node labels, edge types, property names (optional future enhancement)
  - Meta-commands (`\help`, `\connect`, …)

- **Context Awareness:** Parsing detects strings/comments, suggests completions accordingly.
- **Implementation:** `linenoize` completion hook + schema cache from server (`SHOW GRAPHS`, catalog queries).

---

## Syntax Highlighting for GQL

- **Keywords:** Bold blue/magenta
- **Strings:** Green
- **Numbers/Booleans:** Cyan
- **Comments:** Grey/green
- **Meta-commands:** Distinct (e.g., yellow)
- **Implementation:** Tokenizer + ANSI codes integrated into line editor refresh cycle.
- **Disable Option:** `\set highlight off` or `GEODE_NO_COLOR`.

---

## Session-Scoped Variables and Environment

- **Current Graph:** Set via `USE GRAPH` or `\connect graphname`. Reflected in prompt.
- **Output Format:** `\set format table|csv|json|text`.
- **Display Settings:**

  - `\t` — tuples only
  - `\x` — expanded mode
  - `\timing` — toggle query timing

- **Transaction Indicator:** Prompt changes (`geode*>`) inside transaction. Warns on exit with uncommitted transaction.

---

## Configurable Output Formats

- **Aligned Table:** Human-readable with borders (`border=0|1|2`).
- **Plain Text (Unaligned):** Tab- or user-specified delimiter.
- **JSON:** Raw server JSON or pretty-printed.
- **CSV:** RFC 4180 compliant quoting and headers.

Users switch with `\set format …` or shortcuts (`\csv`, `\json`, `\a`).

---

## CLI Meta-Commands

- `\help` / `\?` — List meta-commands
- `\exit` / `\quit` — Exit shell
- `\connect [host:port[/graph]]` — Change server/graph
- `\list graphs` / `\lg` — List available graphs
- `\describe` / `\d` — Describe schema (graphs, labels, relationships)
- `\set` — Adjust session settings
- `\history` — View history
- `\edit` / `\e` — Edit buffer in `$EDITOR`
- `\source` / `\i` — Run script file
- `\timing` — Toggle query timing
- `\pager` — Toggle pager (future)
- `\o [filename]` — Redirect output to file
- `\!` — Run shell command

---

## Dependencies and Library Support

- **Line Editing:** [linenoize (Zig port of linenoise)](https://github.com/joachimschmidt557/linenoize)
- **Networking:** Geode’s existing QUIC/TCP client
- **JSON Parsing:** Zig stdlib JSON parser
- **Editor Integration:** `$EDITOR` or platform defaults (`vi`, `notepad`).

---

## Integration with Geode Server

- **Connection:** QUIC (default) or stdio to embedded `geoded`.
- **Protocol:** HELLO handshake, `RUN_GQL`, `PULL`, `BEGIN`, `COMMIT`, `ROLLBACK`.
- **Query Execution:** Detects completion; sends queries; formats results.
- **Transactions:** Tracks open state, updates prompt.
- **Errors:** Display gracefully, don’t exit.

---

## Internal Architecture

- **State Struct:** Tracks connection, graph, settings, history, transaction state.
- **Connection Abstraction:** `Network` vs `Process`.
- **REPL Loop:** Handles input, meta-commands, queries, history.
- **Error Handling:** Clear error messages, graceful exit.

---

## Security Considerations

- History file permissions (`0600`)
- Option to skip history (commands starting with space)
- Input sanitization (prevent query injection in meta-commands)
- Output sanitization (strip ANSI escapes from DB data)
- Shell escapes (`\!`) run under user privileges
- Signal handling for cancel (Ctrl+C → cancel query or reset connection)

---

## Logging and Diagnostics

- **Debug Logging:** `--verbose` or `\set verbose on`. Logs connection and protocol events.
- **Error Messages:** Clear user-friendly messages.
- **Diagnostics Commands:** `\conninfo`, `\status`.
- **Testing Hooks:** Possible batch/script execution (`-f file`).
- **Error Handling:** Fail loudly but safely, log raw responses on parse errors.
