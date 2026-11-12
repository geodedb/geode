#!/usr/bin/env bash
# SONNY-6359: the admin password the scripts seed is a passphrase (the
# password policy requires space-separated words), so a command string such
# as QUERY_CMD="geode query ... --password ${ADMIN_PASS}" no longer keeps it
# one argument when the string is expanded unquoted or run under `timeout`.
# `geode_cli_wrapper <command> [args...]` prints the path of an executable
# that runs the command with those arguments, each kept whole, followed by
# its own arguments; use the path where the string was used. The wrappers
# live in GEODE_CLI_WRAPPER_DIR, which the caller removes on exit.
#
# Source this file; it creates GEODE_CLI_WRAPPER_DIR in the sourcing shell.

GEODE_CLI_WRAPPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/geode-cli-wrapper.XXXXXX")"
chmod 700 "${GEODE_CLI_WRAPPER_DIR}"

geode_cli_wrapper() {
    local wrapper
    wrapper="$(mktemp "${GEODE_CLI_WRAPPER_DIR}/cmd.XXXXXX")" || return 1
    {
        printf '#!/usr/bin/env bash\nexec'
        printf ' %q' "$@"
        printf ' "$@"\n'
    } > "${wrapper}"
    chmod 700 "${wrapper}"
    printf '%s\n' "${wrapper}"
}
