# Geode REPL Usage Guide

## Starting the REPL

```bash
./zig-out/bin/geode shell
```

## Meta Commands

Meta commands start with a backslash (`\`), NOT a forward slash (`/`).

### Available Meta Commands

- `\help` or `\h` or `\?` - Show help for meta commands
- `\quit` or `\q` - Exit the shell
- `\history [n]` - Show last n history entries
- `\history -c` - Clear history
- `\clear` - Clear screen
- `\connect <addr>` - Connect to server
- `\disconnect` - Disconnect from server
- `\begin` - Start transaction
- `\commit` - Commit transaction
- `\rollback` - Rollback transaction
- `\timing on|off` - Toggle query timing
- `\format <fmt>` - Set output format (table|csv|json)
- `\set <opt> <val>` - Set option (e.g., `\set keymap vi`)
- `\echo <text>` - Echo text

## GQL Queries

Type GQL queries directly. For single-line queries, press Enter to execute.
For multi-line queries, end with a semicolon (`;`).

### Examples

```gql
geode> RETURN 1 AS x;
{"columns":["a"],"data":[[1]]}

geode> MATCH (n:Person)
geode> RETURN n.name
geode> LIMIT 10;
```

## Keyboard Shortcuts

### Emacs Mode (default)

- `Ctrl+A` - Move to beginning of line
- `Ctrl+E` - Move to end of line
- `Ctrl+K` - Kill to end of line
- `Ctrl+U` - Kill to beginning of line
- `Ctrl+W` - Kill word backward
- `Ctrl+Y` - Yank from kill ring
- `Ctrl+P` - Previous history
- `Ctrl+N` - Next history
- `Ctrl+R` - Reverse search history
- `Ctrl+L` - Clear screen
- `Ctrl+C` - Cancel current input
- `Ctrl+D` - Delete character or exit on empty line

### Vi Mode

Switch with `\set keymap vi`

## Configuration

History is saved to:

- Linux: `~/.local/share/geode/history`
- macOS: `~/Library/Application Support/geode/history`
- Windows: `%APPDATA%\geode\history`

Or set `GEODE_HISTORY` environment variable to a custom path.

## Troubleshooting

If you see "REPL error: FileNotFound", the REPL may be having trouble creating the history directory.
This should be automatically fixed now, but if issues persist, manually create the directory:

```bash
mkdir -p ~/.local/share/geode  # Linux
mkdir -p ~/Library/Application\ Support/geode  # macOS
```
