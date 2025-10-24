You are upgrading a Zig 0.15.1 codebase to unify multiple CLIs into a single binary named `geode` with cohesive subcommands and consistent UX. Implement the changes below EXACTLY, with zero external deps (std only), and preserve compatibility via argv[0] aliasing.

Context & SPECIFIC ANCHORS TO EDIT

1. src/client/main.zig — lines 43–47 currently show the `geodec` one-line usage fallback:

   - Replace the current `if (argv.len < 2) { std.debug.print("usage: geodec <GQL text> ..."); return; }` path with:
     a) Proper `-h/--help` handling that prints detailed usage and exits 0.
     b) A thin wrapper that maps legacy `geodec "<query>"` into `geode query "<query>"`.
   - Ensure data outputs use `stdout` (`std.io.getStdOut().writer()`) and all usage/errors go to `stderr` (`std.io.getStdErr().writer()`).

2. src/tools/user_auth.zig — find the dispatch block starting with:
   const command = args[1];
   if (std.mem.eql(u8, command, "user")) { ... } else if ...

   - Move this functionality under the unified CLI as:
     geode user [create|delete|disable|enable|password|list|show] ...
     geode role [create|delete|list|show] ...
     geode policy [create|delete|enable|disable|list] ...
     geode grant role <role> to <user> | permission <perm> to <role>
     geode revoke role <role> from <user> | permission <perm> from <role>
   - Normalize flag names: `--server`, `-U|--user`, `--format json|table|csv`, `--yes`, `--no-prompt`.
   - For primary outputs (lists, object info), write to stdout. Errors/usage to stderr.

3. src/server/main.zig — server entry (`geoded`) becomes `geode serve`:

   - Introduce `geode serve` with flags: `--data-dir`, `--listen <addr:port>`, `--cert`, `--key`, `--log-level`, `--stdio` (explicit).
   - Ensure all logs (startup/listening, warnings, errors) print to stderr so piping from other subcommands isn’t polluted.

4. New unified frontend (new file): src/cli/main.zig

   - Implement a single entry that:
     a) Inspects argv[0] to support legacy aliases:
     - If argv[0] ends with "geoded" → behave as `geode serve ...` and emit one-time deprecation warning to stderr.
     - If "geodec" → behave as `geode query ...` with deprecation warning.
     - If "geode-auth" → translate to appropriate `geode user|role|policy|grant|revoke ...` and warn.
       b) Parses top-level subcommands with a small hand-rolled parser:
       Subcommands: `serve`, `shell`, `query`, `backup`, `restore`,
       `auth [login|logout]`,
       `user`, `role`, `policy`, `grant`, `revoke`, `migrate`.
       c) Global flags: `-h|--help`, `-v|--verbose`, `--config <path>`, `--json` (forces JSON output for any subcommand).
   - Add per-subcommand `--help` printers with succinct usage + examples.

5. Secrets & prompting (security-critical):

   - Implement `readPasswordNoEcho(prompt: []const u8) ![]u8`:
     - On Unix: use termios via `std.os.tcgetattr/tcsetattr` to disable echo.
     - On Windows: use `std.os.windows` to flip console mode echo.
   - `geode auth login`:
     - Read user via `-U|--user` or prompt.
     - If `--password` absent and TTY attached, prompt with echo disabled; if not a TTY, support `--password-file` or read from stdin when `--password -`.
     - Store token under XDG: `${XDG_CONFIG_HOME:-~/.config}/geode/credentials.json` with mode 0600. Refuse to write if unsafe perms.
   - History for `geode shell` at `${XDG_DATA_HOME:-~/.local/share}/geode/history` with mode 0600. Provide `--no-history` to disable.

6. Exit codes:

   - 0 = success; 1 = general error; 2 = usage/validation error; 3 = authz/authn failure.
   - Catch and pretty-print common errors (e.g., connection refused → “unable to connect to <host:port>; is the server running?”) and exit with the mapped code.
   - Never emit Zig stack traces on user-facing errors in release-safe; keep them behind `-v/--verbose` only.

7. Output format & pipes:

   - Default `query` output: JSON (machine-friendly) unless `--format table|csv` selected or stdout is a TTY (then favor table).
   - Ensure all tabular modes never write to stderr. Only diagnostics go to stderr.

8. Migrations & backup:

   - `geode migrate <dir|files...>`: execute `.gql` files lexicographically; stop on first failure; summarize statuses to stdout; errors to stderr.
   - `geode backup --dest <URI> [--mode full|incremental] [--parent <id>]` and `geode restore ...`: print structured progress/status to stdout; non-interleaved logs to stderr.

9. Build system:

   - Update `build.zig` to produce a single `geode` binary.
   - Optionally install symlinks `geoded`, `geodec`, `geode-auth` → `geode` (handled by packaging), or support argv[0] aliasing as above.
   - Strip symbols in release modes; keep `-Drelease-safe=true` as default.

10. Tests (Zig `test` blocks and lightweight integ scripts):

- Unit: subcommand parsing, global flag precedence, exit-code mapping.
- Integ (spawn-with-argv): `geode --help`, `geode query --help`, legacy alias `geodec --help` emits deprecation to stderr and exits 0.
- Secrets: confirm password prompt off-echo on both Unix/Windows (mockable abstraction).
- Stream discipline: verify primary outputs never touch stderr (capture FDs).

Constraints

- Zig 0.15.1 std only. No third-party libs.
- POSIX + Windows supported.
- Be ruthless about UX consistency: same flag names and help patterns everywhere.

Deliverables

- New `src/cli/main.zig` + edits to existing sources to route into unified subcommands.
- Updated `build.zig` that builds `geode`.
- Inline usage and examples for every subcommand, discoverable via `-h/--help`.
- A short MIGRATION.md mapping:
  geoded → geode serve
  geodec → geode query
  geode-auth → geode user|role|policy|grant|revoke
