#!/usr/bin/env python3
"""Generate/check release Dockerfiles from a single manifest source."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys
from typing import Any

REQUIRED_FIELDS = {
    "path",
    "title",
    "base_image",
    "package_manager",
    "runtime_packages",
    "user_setup",
    "expose_ports",
    "cmd",
}

# Fields required for manually-maintained Dockerfiles (not generated).
# Only "path" and "title" are mandatory; the rest need not be present.
MANUAL_REQUIRED_FIELDS = {"path", "title"}

# SONNY-4884: the glibc each known apt release base ships, and the name its
# OpenSSL 3 runtime package goes by (Ubuntu 24.04 and Debian trixie renamed
# libssl3 -> libssl3t64 in the 64-bit time_t transition). An apt base that
# matches none of these fails closed: add the distro release here, with its
# real glibc version, before shipping a release image on it.
BASE_IMAGE_PROFILES: tuple[tuple[re.Pattern[str], dict[str, Any]], ...] = (
    (re.compile(r"[:\-]bookworm(?:-|$)"), {"glibc": (2, 36), "libssl": "libssl3"}),
    (re.compile(r"[:\-]trixie(?:-|$)"), {"glibc": (2, 41), "libssl": "libssl3t64"}),
    (re.compile(r"ubuntu[:\-]?22\.04(?:-|$)"), {"glibc": (2, 35), "libssl": "libssl3"}),
    (re.compile(r"ubuntu[:\-]?24\.04(?:-|$)"), {"glibc": (2, 39), "libssl": "libssl3t64"}),
)

# The in-build smoke check: execute the copied release binary as the non-root
# runtime user so a dynamic-loader/glibc incompatibility fails the image build
# instead of shipping an image that cannot start (SONNY-4884).
SMOKE_ARGV = ["/usr/local/bin/geode", "--version"]


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    dockerfiles = data.get("dockerfiles")
    if not isinstance(dockerfiles, list) or not dockerfiles:
        raise ValueError("manifest must define non-empty dockerfiles list")
    for index, spec in enumerate(dockerfiles):
        if not isinstance(spec, dict):
            raise ValueError(f"dockerfiles[{index}] must be an object")
        if spec.get("manual"):
            # Manually-maintained Dockerfiles: only path + title required.
            missing = MANUAL_REQUIRED_FIELDS.difference(spec.keys())
            if missing:
                raise ValueError(f"dockerfiles[{index}] (manual) missing fields: {', '.join(sorted(missing))}")
        else:
            missing = REQUIRED_FIELDS.difference(spec.keys())
            if missing:
                raise ValueError(f"dockerfiles[{index}] missing fields: {', '.join(sorted(missing))}")
            if spec["package_manager"] not in {"apt", "apk"}:
                raise ValueError(f"dockerfiles[{index}] package_manager must be apt or apk")
    return data


def base_image_profile(base_image: str) -> dict[str, Any] | None:
    """Return the known glibc/libssl profile for an apt base image, or None."""
    for pattern, profile in BASE_IMAGE_PROFILES:
        if pattern.search(base_image):
            return profile
    return None


def _parse_version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def runtime_compat_errors(manifest: dict[str, Any]) -> list[str]:
    """Check every generated glibc release base can load the release binary.

    The release binary's glibc requirement is recorded once in the manifest's
    release_binary.glibc_required. apk (musl) bases carry the musl build and
    are exempt; manual Dockerfiles are maintained by hand and not checked here.
    """
    errors: list[str] = []
    glibc_specs = [s for s in manifest["dockerfiles"] if not s.get("manual") and s["package_manager"] == "apt"]
    if not glibc_specs:
        return errors

    required_text = manifest.get("release_binary", {}).get("glibc_required")
    if not isinstance(required_text, str) or not re.fullmatch(r"\d+\.\d+", required_text):
        return ['manifest must set release_binary.glibc_required (e.g. "2.36") for glibc release images']
    required = _parse_version(required_text)

    for spec in glibc_specs:
        profile = base_image_profile(spec["base_image"])
        if profile is None:
            errors.append(
                f"{spec['path']}: base {spec['base_image']} has unknown glibc version; "
                "add it to BASE_IMAGE_PROFILES in tools/release_dockerfile_manifest.py"
            )
            continue
        base_glibc = ".".join(str(part) for part in profile["glibc"])
        if profile["glibc"] < required:
            errors.append(
                f"{spec['path']}: base {spec['base_image']} ships glibc {base_glibc}, "
                f"but the release binary requires glibc {required_text}"
            )
        libssl = [p for p in spec["runtime_packages"] if re.fullmatch(r"libssl3(?:t64)?", p)]
        if libssl and libssl != [profile["libssl"]]:
            errors.append(
                f"{spec['path']}: base {spec['base_image']} packages OpenSSL 3 as "
                f"{profile['libssl']}, not {', '.join(libssl)}"
            )
    return errors


def render_install_block(spec: dict[str, Any]) -> list[str]:
    packages = spec["runtime_packages"]
    if not isinstance(packages, list) or not packages:
        raise ValueError(f"{spec['path']} runtime_packages must be a non-empty list")

    lines = ["# Install runtime dependencies"]
    if spec["package_manager"] == "apt":
        lines.append("RUN apt-get update && apt-get install -y --no-install-recommends \\")
        for package in packages:
            lines.append(f"    {package} \\")
        lines.append("    && rm -rf /var/lib/apt/lists/* \\")
    else:
        lines.append("RUN apk add --no-cache \\")
        for package in packages:
            lines.append(f"    {package} \\")
    lines.append(f"    && {spec['user_setup']} \\")
    lines.append("    && mkdir -p /data /certs /var/log/geode \\")
    lines.append("    && chown -R geode:geode /data /certs /var/log/geode")
    return lines


def runtime_uid(spec: dict[str, Any]) -> str:
    """Return the numeric UID that user_setup assigns to the geode user."""
    match = re.search(r"-u\s+(\d+)", spec["user_setup"])
    if match is None:
        raise ValueError(f"{spec['path']} user_setup must set a numeric UID with -u")
    return match.group(1)


def render_dockerfile(spec: dict[str, Any]) -> str:
    lines: list[str] = [f"# {spec['path']} - {spec['title']}"]
    for note in spec.get("notes", []):
        lines.append(f"# {note}")
    lines.extend(
        [
            "# Generated by tools/release_dockerfile_manifest.py from release/dockerfile_manifest.json",
            "# DO NOT EDIT MANUALLY. Update release/dockerfile_manifest.json and re-sync.",
            "",
            f"FROM {spec['base_image']}",
        ]
    )

    shell = spec.get("shell")
    if shell:
        lines.append(f"SHELL {json.dumps(shell)}")

    lines.append("")
    lines.extend(render_install_block(spec))
    lines.extend(
        [
            "",
            "# Copy the binary from the GoReleaser build context",
            "# GoReleaser places the binary at the root of the context",
            "COPY geode /usr/local/bin/geode",
            "",
            "# Copy shared health check script (issue #549: single source of truth)",
            "COPY docker/health-check.sh /usr/local/bin/health-check.sh",
            "",
            "# Set execute permissions",
            "RUN chmod +x /usr/local/bin/geode /usr/local/bin/health-check.sh",
            "",
            "# Switch to non-root user (numeric UID so the runtime can resolve it",
            "# without reading /etc/passwd; hadolint DL3066)",
            f"USER {runtime_uid(spec)}",
            "WORKDIR /home/geode",
            "",
            "# Execute the copied binary as the runtime user so a loader/glibc",
            "# incompatibility fails the image build instead of shipping (SONNY-4884)",
            f"RUN {json.dumps(SMOKE_ARGV)}",
            "",
        ]
    )
    if spec.get("env"):
        for note in spec.get("env_notes", []):
            lines.append(f"# {note}")
        for name, value in spec["env"].items():
            lines.append(f"ENV {name}={value}")
        lines.append("")
    lines.extend(
        [
            "# Expose runtime ports",
            f"EXPOSE {' '.join(spec['expose_ports'])}",
            "",
            "# Health check using shared script (see docker/health-check.sh)",
            "HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \\",
            '    CMD ["/usr/local/bin/health-check.sh"]',
            "",
            "# Default entrypoint",
            'ENTRYPOINT ["/usr/local/bin/geode"]',
            f"CMD {json.dumps(spec['cmd'])}",
            "",
        ]
    )
    return "\n".join(lines)


def sync_or_check(manifest: dict[str, Any], repo_root: pathlib.Path, check_only: bool) -> int:
    out_of_sync: list[str] = []
    missing_manual: list[str] = []
    for spec in manifest["dockerfiles"]:
        path = repo_root / spec["path"]
        if spec.get("manual"):
            # Manual Dockerfiles are not generated; just verify they exist on disk.
            if not path.exists():
                missing_manual.append(spec["path"])
            elif not check_only:
                print(f"skipped (manual) {spec['path']}")
            continue
        rendered = render_dockerfile(spec)
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != rendered:
            if check_only:
                out_of_sync.append(spec["path"])
            else:
                path.write_text(rendered, encoding="utf-8")
                print(f"synced {spec['path']}")

    if check_only and (out_of_sync or missing_manual):
        if out_of_sync:
            print("error: release Dockerfiles are out of sync with release/dockerfile_manifest.json", file=sys.stderr)
            for p in out_of_sync:
                print(f"  - {p}", file=sys.stderr)
            print("run: python3 tools/release_dockerfile_manifest.py sync", file=sys.stderr)
        if missing_manual:
            print("error: manually-maintained Dockerfiles listed in manifest are missing from disk", file=sys.stderr)
            for p in missing_manual:
                print(f"  - {p}", file=sys.stderr)
        return 1
    if check_only:
        print("release Dockerfile manifest check passed")
    return 0


def write_signoff_report(manifest: dict[str, Any], repo_root: pathlib.Path, output: pathlib.Path) -> int:
    lines = [
        "Release Dockerfile Sign-Off",
        f"Date: {datetime.date.today().isoformat()}",
        "Source: release/dockerfile_manifest.json",
        "",
        "SHA256:",
    ]
    for spec in manifest["dockerfiles"]:
        path = repo_root / spec["path"]
        tag = " (manual)" if spec.get("manual") else ""
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {spec['path']}{tag}")
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote sign-off report: {output}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    sync_parser = sub.add_parser("sync", help="Render Dockerfiles from release/dockerfile_manifest.json")
    sync_parser.add_argument("--manifest", default="release/dockerfile_manifest.json")
    sync_parser.add_argument("--repo-root", default=".")

    check_parser = sub.add_parser("check", help="Fail if Dockerfiles drift from release/dockerfile_manifest.json")
    check_parser.add_argument("--manifest", default="release/dockerfile_manifest.json")
    check_parser.add_argument("--repo-root", default=".")

    signoff_parser = sub.add_parser("signoff", help="Check then write release Dockerfile sign-off report")
    signoff_parser.add_argument("--manifest", default="release/dockerfile_manifest.json")
    signoff_parser.add_argument("--repo-root", default=".")
    signoff_parser.add_argument("--output", default="/tmp/release-dockerfile-signoff.txt")

    args = parser.parse_args()
    manifest = load_manifest(pathlib.Path(args.manifest))
    repo_root = pathlib.Path(args.repo_root).resolve()

    compat_errors = runtime_compat_errors(manifest)
    if compat_errors:
        print("error: release images cannot run the release binary", file=sys.stderr)
        for message in compat_errors:
            print(f"  - {message}", file=sys.stderr)
        return 1

    if args.cmd == "sync":
        return sync_or_check(manifest, repo_root, check_only=False)
    if args.cmd == "check":
        return sync_or_check(manifest, repo_root, check_only=True)
    if args.cmd == "signoff":
        rc = sync_or_check(manifest, repo_root, check_only=True)
        if rc != 0:
            return rc
        return write_signoff_report(manifest, repo_root, pathlib.Path(args.output))

    print(f"error: unknown command {args.cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
