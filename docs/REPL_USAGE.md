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

```text
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

History is saved to `GEODE_HISTORY` when it is set, else to
`$HOME/.geode_history` (SONNY-6551). Either must be an absolute path: with
a relative or unset HOME (or a relative `GEODE_HISTORY`) the shell says
`Note: shell history is not saved to a file: ...` and keeps history for the
session only; it never writes `.geode_history` into the working directory.
The file is mode 0600, and an existing one with group or other access is
tightened.

Lines that carry a credential are not recorded, in the file or in the
session (the rule of the mysql client, which keeps `*IDENTIFIED*` and
`*PASSWORD*` lines out of its history): any line containing `password`,
`identified` or `secret` (any case), or calling `geode.auth.user_create`,
`geode.auth.user_import` or `geode.auth.mfa_*`. So `CREATE USER ... SET
PASSWORD '...'` and `ALTER USER ... SET PASSWORD '...'` are not saved.
`\connect <address>` is saved without the address's `user:password@` part,
and with secret query values shown as `***`. Lines saved by an older geode
are not rewritten: clear them with `\history -c` or edit the file.

## Troubleshooting

If you see "REPL error: FileNotFound", the directory of `GEODE_HISTORY`
could not be created; point `GEODE_HISTORY` at a writable absolute path.
