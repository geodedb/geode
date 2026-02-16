#!/usr/bin/env bash
# Install Zig via zvm using the official bootstrap flow from https://zig.sh.

set -euo pipefail

ZIG_VERSION="${1:-0.15.1}"
ARCH="${2:-}"
OS="${3:-}"
LINK_DIR="${4:-/usr/local/bin}"

if [[ -n "${ARCH}" || -n "${OS}" ]]; then
    echo "info: arch/os arguments are ignored when using zvm (host architecture is auto-detected)." >&2
fi

for cmd in curl jq tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required dependency '$cmd' is missing" >&2
        exit 1
    fi
done

export ZVM_NO_MODIFY=1
export PATH="${HOME}/bin:${PATH}"

curl -fsSL https://zig.sh/install.sh | bash

eval "$(zvm env)"
zvm install "${ZIG_VERSION}"
zvm use "${ZIG_VERSION}"

ZIG_BIN="$(command -v zig || true)"
if [[ -z "${ZIG_BIN}" ]]; then
    echo "error: zig not found after zvm installation" >&2
    exit 1
fi

if [[ -d "${LINK_DIR}" ]]; then
    if [[ -w "${LINK_DIR}" ]]; then
        ln -sf "${ZIG_BIN}" "${LINK_DIR}/zig"
    else
        echo "warning: ${LINK_DIR} is not writable; skipping symlink" >&2
    fi
fi

zig version
echo "Zig ${ZIG_VERSION} installed successfully via zvm (${ZIG_BIN})"
