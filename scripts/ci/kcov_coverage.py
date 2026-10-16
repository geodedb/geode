#!/usr/bin/env python3
"""kcov coverage lane bookkeeping for Geode CI (SRE-187).

`zig build test -Dtest-coverage=true -Dtest-shard-total=N -Dtest-shard-index=I`
runs every Run step of shard I under kcov and installs a deterministic manifest
(zig-out/coverage/manifest-shard-I.tsv) listing every Run step the shard
executes:

    id <TAB> shard <TAB> status <TAB> kcov_out_dir <TAB> source

status is `instrumented` or `uninstrumented:<reason>`.

Subcommands:

  shard   After the instrumented run: check that every instrumented manifest
          entry produced kcov data, merge the shard's runs into
          coverage/shard-I/merged (HTML stripped, merge data kept) and write
          coverage/shard-I/status.json. Exits 1 with an explicit
          "COVERAGE INCOMPLETE" line when the build failed, kcov is absent or
          any entry has no data.

  report  Merge all shards into coverage/merged, write the combined manifest
          coverage/coverage-manifest.tsv, and print `coverage: <pct>%` ONLY when
          every shard is complete. Otherwise move the merged Cobertura file
          aside so no partial or zero number is published, print
          "COVERAGE UNAVAILABLE" / "COVERAGE INCOMPLETE" with the reasons and
          exit 1.

There is deliberately no stub/zero Cobertura report anywhere: missing coverage
is reported as missing, never as 0%.

  --self-test  exercises the bookkeeping without kcov.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

STRIP_SUFFIXES = (".html", ".js", ".png", ".css")


def parse_manifest(path: str) -> list[dict]:
    entries = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 5:
                raise ValueError(f"{path}:{lineno}: expected 5 tab-separated fields, got {len(parts)}")
            ident, shard, status, out_dir, source = parts
            entries.append({"id": ident, "shard": int(shard), "status": status, "out": out_dir, "source": source})
    return entries


def run_data_dirs(out_dir: str) -> list[str]:
    """kcov writes <out_dir>/<binary>.<hash>/coverage.json per instrumented run."""
    return sorted(os.path.dirname(p) for p in glob.glob(os.path.join(out_dir, "*", "coverage.json")))


def run_has_lines(data_dir: str) -> bool:
    """A run whose DWARF kcov cannot read reports total_lines == 0."""
    try:
        with open(os.path.join(data_dir, "coverage.json"), encoding="utf-8") as fh:
            return int(json.load(fh).get("total_lines", 0)) > 0
    except (OSError, ValueError):
        return False


def strip_html(root: str) -> None:
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(STRIP_SUFFIXES):
                os.remove(os.path.join(dirpath, name))


def percent_covered(merged_dir: str) -> str | None:
    path = os.path.join(merged_dir, "kcov-merged", "coverage.json")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return str(json.load(fh).get("percent_covered"))


def shard_status(entries: list[dict], build_rc: int, kcov_present: bool) -> dict:
    covered, missing, uninstrumented = [], [], []
    for e in entries:
        if e["status"] != "instrumented":
            uninstrumented.append(f"{e['id']} {e['source']} ({e['status']})")
        elif any(run_has_lines(d) for d in run_data_dirs(e["out"])):
            covered.append(e["id"])
        else:
            missing.append(f"{e['id']} {e['source']}")
    reasons = []
    if not kcov_present:
        reasons.append("kcov not found on PATH")
    if build_rc != 0:
        reasons.append(f"instrumented `zig build test` exited {build_rc}")
    if missing:
        reasons.append(f"{len(missing)} instrumented run(s) produced no kcov line data")
    if not entries:
        reasons.append("manifest is empty")
    return {
        "expected": len(entries),
        "covered": covered,
        "missing": missing,
        "uninstrumented": uninstrumented,
        "build_rc": build_rc,
        "complete": not reasons,
        "reasons": reasons,
    }


def kcov_merge(out: str, inputs: list[str]) -> int:
    if not inputs:
        return 0
    return subprocess.call(["kcov", "--merge", out, *inputs])


def cmd_shard(args: argparse.Namespace) -> int:
    manifest = os.path.join(args.manifest_dir, f"manifest-shard-{args.shard}.tsv")
    out = os.path.join(args.coverage_dir, f"shard-{args.shard}")
    os.makedirs(out, exist_ok=True)
    kcov_present = shutil.which("kcov") is not None
    entries = parse_manifest(manifest) if os.path.isfile(manifest) else []
    if entries:
        shutil.copy(manifest, os.path.join(out, "manifest.tsv"))
    status = shard_status(entries, args.build_rc, kcov_present)
    if not os.path.isfile(manifest):
        status["reasons"].append(f"manifest {manifest} missing")
        status["complete"] = False
    status["shard"] = args.shard
    data = [d for e in entries if e["status"] == "instrumented" for d in run_data_dirs(e["out"])]
    if kcov_present and data:
        rc = kcov_merge(os.path.join(out, "merged"), data)
        if rc != 0:
            status["reasons"].append(f"kcov --merge exited {rc}")
            status["complete"] = False
        strip_html(os.path.join(out, "merged"))
    with open(os.path.join(out, "status.json"), "w", encoding="utf-8") as fh:
        json.dump(status, fh, indent=2, sort_keys=True)
    print(f"shard {args.shard}: {len(status['covered'])}/{status['expected']} manifest entries have kcov line data")
    for m in status["missing"]:
        print(f"  missing: {m}")
    for u in status["uninstrumented"]:
        print(f"  uninstrumented: {u}")
    if not status["complete"]:
        print(f"COVERAGE INCOMPLETE (shard {args.shard}): " + "; ".join(status["reasons"]))
        return 1
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    reasons: list[str] = []
    shard_dirs: list[str] = []
    manifest_lines: list[str] = []
    expected = covered = 0
    kcov_present = shutil.which("kcov") is not None
    if not kcov_present:
        reasons.append("kcov not found on PATH")
    for i in range(args.total):
        sdir = os.path.join(args.coverage_dir, f"shard-{i}")
        spath = os.path.join(sdir, "status.json")
        if not os.path.isfile(spath):
            reasons.append(f"shard {i}: no status.json (job missing, cancelled, timed out or artifacts expired)")
            continue
        with open(spath, encoding="utf-8") as fh:
            st = json.load(fh)
        expected += st["expected"]
        covered += len(st["covered"])
        if not st["complete"]:
            reasons.append(f"shard {i}: " + "; ".join(st["reasons"]))
        mpath = os.path.join(sdir, "manifest.tsv")
        if os.path.isfile(mpath):
            with open(mpath, encoding="utf-8") as fh:
                manifest_lines.extend(line for line in fh if line.strip())
        if os.path.isdir(os.path.join(sdir, "merged")):
            shard_dirs.append(os.path.join(sdir, "merged"))
    manifest_lines.sort()
    os.makedirs(args.coverage_dir, exist_ok=True)
    with open(os.path.join(args.coverage_dir, "coverage-manifest.tsv"), "w", encoding="utf-8") as fh:
        fh.writelines(manifest_lines)
    merged = os.path.join(args.coverage_dir, "merged")
    if shard_dirs and kcov_present:
        rc = kcov_merge(merged, shard_dirs)
        if rc != 0:
            reasons.append(f"kcov --merge exited {rc}")
    pct = percent_covered(merged)
    if pct is None and not reasons:
        reasons.append("merged kcov output has no coverage.json")
    print(f"coverage manifest: {covered}/{expected} runs across {args.total} shards have kcov line data")
    if reasons:
        cobertura = os.path.join(merged, "kcov-merged", "cobertura.xml")
        if os.path.isfile(cobertura):
            # Never publish a partial set as the project's coverage number.
            os.replace(cobertura, cobertura + ".incomplete")
        label = "COVERAGE UNAVAILABLE" if covered == 0 else "COVERAGE INCOMPLETE"
        print(f"{label}: " + "; ".join(reasons))
        if pct is not None:
            print(f"(partial line coverage of the runs that did report: {pct} percent -- not published)")
        return 1
    print(f"coverage: {pct}%")
    return 0


def _write_json(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)


def self_test() -> int:
    global kcov_merge  # noqa: PLW0603 -- swapped for a fake merge below
    real_merge, real_which = kcov_merge, shutil.which
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        os.chdir(tmp)
        try:
            os.makedirs("zig-out/coverage")
            with open("zig-out/coverage/manifest-shard-0.tsv", "w", encoding="utf-8") as fh:
                fh.write("0001\t0\tinstrumented\tcoverage/raw/0001\tsrc/a.zig\n")
                fh.write("0002\t0\tinstrumented\tcoverage/raw/0002\ttests/b.zig\n")
                fh.write("0003\t0\tuninstrumented:not-an-artifact-run\t-\trun x\n")
            _write_json("coverage/raw/0001/test.abcd/coverage.json", {"total_lines": 7})
            # 0002 ran but kcov read no line table (self-hosted backend DWARF).
            _write_json("coverage/raw/0002/test.ef01/coverage.json", {"total_lines": 0})
            entries = parse_manifest("zig-out/coverage/manifest-shard-0.tsv")
            st = shard_status(entries, 0, True)
            assert st["covered"] == ["0001"], st
            assert st["missing"] == ["0002 tests/b.zig"], st
            assert len(st["uninstrumented"]) == 1 and not st["complete"], st
            _write_json("coverage/raw/0002/test.ef01/coverage.json", {"total_lines": 3})
            st = shard_status(entries, 0, True)
            assert st["complete"] and st["covered"] == ["0001", "0002"], st
            assert not shard_status(entries, 1, True)["complete"]
            assert not shard_status(entries, 0, False)["complete"]
            assert not shard_status([], 0, True)["complete"]

            def fake_merge(out: str, inputs: list[str]) -> int:
                _write_json(os.path.join(out, "kcov-merged", "coverage.json"), {"percent_covered": "42.00"})
                with open(os.path.join(out, "kcov-merged", "cobertura.xml"), "w", encoding="utf-8") as fh:
                    fh.write("<coverage/>")
                return 0

            kcov_merge = fake_merge
            shutil.which = lambda name, *a, **k: "/bin/true" if name == "kcov" else real_which(name, *a, **k)
            assert (
                cmd_shard(
                    argparse.Namespace(shard=0, build_rc=0, manifest_dir="zig-out/coverage", coverage_dir="coverage")
                )
                == 0
            )
            # Two shards expected, one present: fail and publish nothing.
            assert cmd_report(argparse.Namespace(total=2, coverage_dir="coverage")) == 1
            assert not os.path.exists("coverage/merged/kcov-merged/cobertura.xml")
            assert os.path.exists("coverage/merged/kcov-merged/cobertura.xml.incomplete")
            shutil.rmtree("coverage/merged")
            assert cmd_report(argparse.Namespace(total=1, coverage_dir="coverage")) == 0
            assert os.path.exists("coverage/merged/kcov-merged/cobertura.xml")
            with open("coverage/coverage-manifest.tsv", encoding="utf-8") as fh:
                assert len(fh.readlines()) == 3
            # kcov absent: explicit unavailability, never a zero report.
            shutil.which = lambda name, *a, **k: None if name == "kcov" else real_which(name, *a, **k)
            assert (
                cmd_shard(argparse.Namespace(shard=0, build_rc=0, manifest_dir="zig-out/coverage", coverage_dir="cov2"))
                == 1
            )
            assert cmd_report(argparse.Namespace(total=1, coverage_dir="cov2")) == 1
        finally:
            kcov_merge, shutil.which = real_merge, real_which
            os.chdir(cwd)
    print("kcov_coverage self-test: OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="cmd")
    p_shard = sub.add_parser("shard")
    p_shard.add_argument("--shard", type=int, required=True)
    p_shard.add_argument("--build-rc", type=int, required=True)
    p_shard.add_argument("--manifest-dir", default="zig-out/coverage")
    p_shard.add_argument("--coverage-dir", default="coverage")
    p_report = sub.add_parser("report")
    p_report.add_argument("--total", type=int, required=True)
    p_report.add_argument("--coverage-dir", default="coverage")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.cmd == "shard":
        return cmd_shard(args)
    if args.cmd == "report":
        return cmd_report(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
