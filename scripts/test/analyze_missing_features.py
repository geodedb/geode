#!/usr/bin/env python3
"""Analyze all geodetestlab specs to find missing CLI features."""

import yaml
from pathlib import Path
from collections import defaultdict

def analyze_specs():
    specs_dir = Path("/home/benji/src/geode/geode/geodetestlab/specs")
    
    # Track all commands and subcommands used
    commands = defaultdict(set)
    args_patterns = defaultdict(set)
    
    for spec_file in specs_dir.glob("*.yml"):
        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except Exception as e:
            print(f"Skipping {spec_file.name}: {e}")
            continue
        
        for test in spec.get("tests", []):
            args = test.get("args", [])
            if not args:
                continue
            
            # First arg is usually the command
            if args[0].startswith("--"):
                # Global option
                commands["global_options"].add(args[0])
            else:
                # Subcommand
                cmd = args[0]
                commands[cmd].add("(base command)")
                
                # Check for subcommands
                for i, arg in enumerate(args[1:], 1):
                    if not arg.startswith("-"):
                        commands[cmd].add(arg)
                        break
                    else:
                        args_patterns[cmd].add(arg)
    
    # Print analysis
    print("Commands and subcommands used in all tests:")
    print("=" * 60)
    
    for cmd, subcmds in sorted(commands.items()):
        print(f"\n{cmd}:")
        for subcmd in sorted(subcmds):
            print(f"  - {subcmd}")
    
    print("\n\nCommand options used:")
    print("=" * 60)
    
    for cmd, opts in sorted(args_patterns.items()):
        if opts:
            print(f"\n{cmd}:")
            for opt in sorted(opts):
                print(f"  - {opt}")

if __name__ == "__main__":
    analyze_specs()