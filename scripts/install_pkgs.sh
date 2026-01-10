#!/usr/bin/env bash
# Install Nix and direnv (idempotent; resilient on WSL/containers/non-systemd)
# Usage: ./install_pkgs.sh
set -euo pipefail

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

is_wsl()         { [[ -f /proc/version ]] && grep -qi microsoft /proc/version; }
has_systemd()    { [ -d /run/systemd/system ] && have systemctl; }
in_container()   { grep -qaE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; }
ensure_line()    { local f="$1" line="$2"; mkdir -p "$(dirname "$f")"; touch "$f"; grep -Fqx "$line" "$f" || printf "%s\n" "$line" >> "$f"; }

install_prereqs() {
  if have apt-get;   then sudo apt-get update -y && sudo apt-get install -y curl ca-certificates xz-utils git
  elif have dnf;     then sudo dnf -y install curl ca-certificates xz git
  elif have yum;     then sudo yum -y install curl ca-certificates xz git
  elif have pacman;  then sudo pacman -Sy --noconfirm curl ca-certificates xz git
  elif have zypper;  then sudo zypper -n install curl ca-certificates xz git
  elif have apk;     then sudo apk add --no-cache curl ca-certificates xz git
  else warn "Unknown package manager; ensure curl, xz, git present."
  fi
}

source_nix_env() {
  for p in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    /etc/profile.d/nix.sh
  do
    [ -r "$p" ] && . "$p" && return 0
  done
  return 1
}

install_nix() {
  if have nix; then log "Nix already present: $(nix --version)"; return 0; fi
  # Only install prereqs if curl/git not available (avoids unnecessary sudo)
  if ! have curl || ! have git; then
    install_prereqs
  fi

  local installer=/tmp/nix-install.sh
  curl -fsSL https://nixos.org/nix/install -o "$installer"

  # Decide mode: prefer multi-user only when systemd/sudo likely works
  local want_multi=1
  if is_wsl || in_container || ! has_systemd || ! have sudo; then
    want_multi=0
  fi

  if (( want_multi )); then
    log "Installing Nix (multi-user)…"
    if ! sudo sh "$installer" --daemon; then
      warn "Multi-user install failed; falling back to single-user."
      sh "$installer" --no-daemon || die "Nix installation failed (single-user fallback)."
    fi
  else
    log "Installing Nix (single-user)…"
    sh "$installer" --no-daemon || die "Nix installation failed (single-user)."
  fi

  log "Loading Nix profile into this session…"
  source_nix_env || die "Nix installed but profile scripts not found."
  have nix || die "Nix installation did not complete properly."
}

install_direnv() {
  if have direnv; then log "direnv already present: $(direnv version)"; return 0; fi
  log "Installing direnv + nix-direnv via Nix…"
  if ! nix profile install nixpkgs#direnv nixpkgs#nix-direnv; then
    warn "nix profile failed; bootstrapping channel + nix-env fallback."
    nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs || true
    nix-channel --update
    nix-env -iA nixpkgs.direnv nixpkgs.nix-direnv
  fi
  log "direnv: $(~/.nix-profile/bin/direnv version || direnv version)"
}

wire_shells() {
  # Hooks
  ensure_line "$HOME/.bashrc" 'eval "$(direnv hook bash)"'
  ensure_line "$HOME/.zshrc"  'eval "$(direnv hook zsh)"'
  ensure_line "$HOME/.config/fish/config.fish" 'direnv hook fish | source'

  # Only source nix-direnv if it exists (prevents the non-blocking startup error)
  mkdir -p "$HOME/.config/direnv"
  local nd_line='if [ -f "$HOME/.nix-profile/share/nix-direnv/direnvrc" ]; then source "$HOME/.nix-profile/share/nix-direnv/direnvrc"; fi'
  ensure_line "$HOME/.config/direnv/direnvrc" "$nd_line"
}

main() {
  install_nix
  install_direnv
  wire_shells

  log "Success."
  echo "Open a new shell (or: exec \"\$SHELL\" -l) and run: direnv version; nix --version"
}
main "$@"

