#!/usr/bin/env python3
"""Count how many tests we have total."""

from pathlib import Path

import yaml


def main():
    specs_dir = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs")

    total = 0
    by_spec = {}

    for spec_file in sorted(specs_dir.glob("*.yml")):
        try:
            with open(spec_file) as f:
                spec = yaml.safe_load(f)
        except Exception:
            continue

        count = 0
        for test in spec.get("tests", []):
            if test.get("skip", False):
                continue
            # Count parallel/loop tests
            if test.get("parallel") and test.get("instances"):
                count += test["instances"]
            elif test.get("loop"):
                count += test["loop"]
            else:
                count += 1

        by_spec[spec_file.name] = count
        total += count

    print(f"Total tests: {total}")
    print("\nBy spec file (showing non-zero):")
    for spec, count in sorted(by_spec.items(), key=lambda x: -x[1]):
        if count > 0:
            print(f"  {spec}: {count}")


if __name__ == "__main__":
    main()
