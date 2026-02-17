#!/usr/bin/env python3
"""Generate and validate release target artifacts from a single manifest."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any

BEGIN_MARKER = "# BEGIN GENERATED ZIG TARGETS (tools/release_target_manifest.py)"
END_MARKER = "# END GENERATED ZIG TARGETS"


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data.get("zig_targets"), list):
        raise ValueError("manifest missing zig_targets list")
    if not isinstance(data.get("release_assets"), list):
        raise ValueError("manifest missing release_assets list")
    return data


def render_target_lines(targets: list[str], indent: str) -> list[str]:
    lines = [f"{indent}- {target}" for target in targets]
    return lines


def sync_goreleaser(manifest: dict[str, Any], goreleaser_path: pathlib.Path, check_only: bool) -> int:
    text = goreleaser_path.read_text(encoding="utf-8")
    pattern = re.compile(
        f"(?P<prefix>^[ \\t]*{re.escape(BEGIN_MARKER)}\\n)(?P<body>.*?)(?P<suffix>^[ \\t]*{re.escape(END_MARKER)}$)",
        re.DOTALL | re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        print(
            f"error: could not find generated target markers in {goreleaser_path}",
            file=sys.stderr,
        )
        return 1

    target_indent = detect_target_indent(match.group("body"), text, match.start())
    replacement_body = "\n".join(render_target_lines(manifest["zig_targets"], target_indent)) + "\n"
    replacement = f"{match.group('prefix')}{replacement_body}{match.group('suffix')}"
    new_text = text[: match.start()] + replacement + text[match.end() :]

    if check_only:
        if new_text != text:
            print(f"error: {goreleaser_path} is out of sync with release/target_manifest.json", file=sys.stderr)
            print("run: python3 tools/release_target_manifest.py sync-goreleaser", file=sys.stderr)
            return 1
        print("goreleaser target block is in sync")
        return 0

    goreleaser_path.write_text(new_text, encoding="utf-8")
    print(f"synced {goreleaser_path} from release target manifest")
    return 0


def detect_target_indent(existing_body: str, source_text: str, block_start: int) -> str:
    for line in existing_body.splitlines():
        stripped = line.lstrip(" \t")
        if stripped.startswith("- "):
            return line[: len(line) - len(stripped)]

    prior_lines = source_text[:block_start].splitlines()
    if prior_lines:
        match = re.search(r"^([ \t]*)targets:\s*$", prior_lines[-1])
        if match:
            return match.group(1)

    return "  "


def list_zig_targets(manifest: dict[str, Any]) -> int:
    for target in manifest["zig_targets"]:
        print(target)
    return 0


def render_release_cli_assets(manifest: dict[str, Any], version: str, project_url: str, tag: str) -> int:
    base_artifact_url = f"{project_url}/-/jobs/artifacts/{tag}/raw/dist"
    for asset in manifest["release_assets"]:
        name = asset["name"]
        link_type = asset["link_type"]

        if "filename" in asset:
            filename = asset["filename"].format(version=version)
            url = f"{base_artifact_url}/{filename}?job=build-release"
        elif "url" in asset:
            url = asset["url"].format(project_url=project_url, version=version, tag=tag)
        else:
            raise ValueError(f"release asset {name!r} must have filename or url")

        print(json.dumps({"name": name, "url": url, "link_type": link_type}, separators=(",", ":")))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()

    sub = parser.add_subparsers(dest="cmd", required=True)

    list_parser = sub.add_parser("list-zig-targets", help="Print zig release targets from manifest")
    list_parser.add_argument(
        "--manifest", default="release/target_manifest.json", help="Path to release target manifest"
    )

    sync_parser = sub.add_parser("sync-goreleaser", help="Sync .goreleaser.yaml target block from manifest")
    sync_parser.add_argument(
        "--manifest", default="release/target_manifest.json", help="Path to release target manifest"
    )
    sync_parser.add_argument("--goreleaser", default=".goreleaser.yaml", help="GoReleaser config path")
    sync_parser.add_argument("--check", action="store_true", help="Check only; fail if out of sync")

    assets_parser = sub.add_parser("render-release-cli-assets", help="Render release-cli --assets-link JSON lines")
    assets_parser.add_argument(
        "--manifest", default="release/target_manifest.json", help="Path to release target manifest"
    )
    assets_parser.add_argument("--version", required=True, help="Release version without leading v")
    assets_parser.add_argument("--project-url", required=True, help="CI project URL")
    assets_parser.add_argument("--tag", required=True, help="Git tag")

    args = parser.parse_args()

    manifest = load_manifest(pathlib.Path(args.manifest))

    if args.cmd == "list-zig-targets":
        return list_zig_targets(manifest)
    if args.cmd == "sync-goreleaser":
        return sync_goreleaser(manifest, pathlib.Path(args.goreleaser), args.check)
    if args.cmd == "render-release-cli-assets":
        return render_release_cli_assets(manifest, args.version, args.project_url, args.tag)

    print(f"error: unknown command {args.cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
