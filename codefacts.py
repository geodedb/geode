#!/usr/bin/env python3
"""
Code facts scanner for Zig, Go, Python, and Shell files.
Extracts symbols, versions, endpoints, and flags from source code.
"""

import re
import json
from pathlib import Path
from typing import Dict, Any


class CodeFactsScanner:
    """Scans code files to extract facts about symbols, versions, endpoints, and flags."""
    
    def __init__(self, repo_root: Path):
        self.repo_root = Path(repo_root)
        self.facts = {
            "symbols": set(),
            "versions": set(),
            "endpoints": set(),
            "flags": set()
        }
    
    def scan_all(self) -> Dict[str, Any]:
        """Scan all supported code files and return facts index."""
        # Scan Zig files
        zig_files = list(self.repo_root.rglob("*.zig"))
        for zig_file in zig_files:
            self._scan_zig_file(zig_file)
        
        # Scan Go files
        go_files = list(self.repo_root.rglob("*.go"))
        for go_file in go_files:
            self._scan_go_file(go_file)
        
        # Scan Python files
        py_files = list(self.repo_root.rglob("*.py"))
        for py_file in py_files:
            self._scan_python_file(py_file)
        
        # Scan Shell files
        sh_files = list(self.repo_root.rglob("*.sh"))
        for sh_file in sh_files:
            self._scan_shell_file(sh_file)
        
        # Also check build.zig for feature flags
        build_zig = self.repo_root / "build.zig"
        if build_zig.exists():
            self._scan_build_zig(build_zig)
        
        # Convert sets to lists for JSON serialization
        return {
            "symbols": list(self.facts["symbols"]),
            "versions": list(self.facts["versions"]),
            "endpoints": list(self.facts["endpoints"]),
            "flags": list(self.facts["flags"])
        }
    
    def _scan_zig_file(self, file_path: Path):
        """Scan Zig file for pub functions, const versions, and other symbols."""
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Find pub fn declarations
            pub_fn_pattern = r'pub\s+fn\s+(\w+)'
            for match in re.finditer(pub_fn_pattern, content):
                self.facts["symbols"].add(f"pub fn {match.group(1)}")
            
            # Find pub const declarations
            pub_const_pattern = r'pub\s+const\s+(\w+)'
            for match in re.finditer(pub_const_pattern, content):
                self.facts["symbols"].add(f"pub const {match.group(1)}")
            
            # Find version strings
            version_pattern = r'pub\s+const\s+VERSION\s*=\s*"([^"]+)"'
            for match in re.finditer(version_pattern, content):
                self.facts["versions"].add(match.group(1))
            
            # Find version patterns in comments or strings
            semver_pattern = r'\b\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?\b'
            for match in re.finditer(semver_pattern, content):
                self.facts["versions"].add(match.group(0))
        
        except Exception:
            # Skip files that can't be read
            pass
    
    def _scan_go_file(self, file_path: Path):
        """Scan Go file for exported functions, types, and version constants."""
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Find exported function declarations
            func_pattern = r'func\s+([A-Z]\w*)'
            for match in re.finditer(func_pattern, content):
                self.facts["symbols"].add(match.group(1))
            
            # Find exported type declarations
            type_pattern = r'type\s+([A-Z]\w*)'
            for match in re.finditer(type_pattern, content):
                self.facts["symbols"].add(match.group(1))
            
            # Find version constants
            version_const_pattern = r'const\s+\w*[Vv]ersion\w*\s*=\s*"([^"]+)"'
            for match in re.finditer(version_const_pattern, content):
                self.facts["versions"].add(match.group(1))
            
            # Find HTTP routes/endpoints
            route_pattern = r'["\'](/v\d+/[^"\']*)["\']'
            for match in re.finditer(route_pattern, content):
                self.facts["endpoints"].add(match.group(1))
            
            # Find route handlers
            handler_pattern = r'["\']([^"\']*\.Handle|[^"\']*\.GET|[^"\']*\.POST)["\']'
            for match in re.finditer(handler_pattern, content):
                endpoint = match.group(1)
                if "/v" in endpoint:
                    self.facts["endpoints"].add(endpoint)
        
        except Exception:
            pass
    
    def _scan_python_file(self, file_path: Path):
        """Scan Python file for functions, classes, and argparse flags."""
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Find function definitions
            func_pattern = r'def\s+(\w+)'
            for match in re.finditer(func_pattern, content):
                self.facts["symbols"].add(f"def {match.group(1)}")
            
            # Find class definitions
            class_pattern = r'class\s+(\w+)'
            for match in re.finditer(class_pattern, content):
                self.facts["symbols"].add(f"class {match.group(1)}")
            
            # Find version assignments
            version_pattern = r'VERSION\s*=\s*["\']([^"\']+)["\']'
            for match in re.finditer(version_pattern, content):
                self.facts["versions"].add(match.group(1))
            
            # Find argparse flags
            argparse_pattern = r'add_argument\s*\(\s*["\'](-[-\w]+)["\']'
            for match in re.finditer(argparse_pattern, content):
                self.facts["flags"].add(match.group(1))
            
            # Find CLI flags in help strings or usage
            flag_pattern = r'--[\w-]+'
            for match in re.finditer(flag_pattern, content):
                self.facts["flags"].add(match.group(0))
        
        except Exception:
            pass
    
    def _scan_shell_file(self, file_path: Path):
        """Scan shell file for getopts patterns and CLI flags."""
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Find getopts patterns
            getopts_pattern = r'getopts\s+["\']([^"\']+)["\']'
            for match in re.finditer(getopts_pattern, content):
                opts = match.group(1)
                for char in opts:
                    if char.isalnum():
                        self.facts["flags"].add(f"-{char}")
            
            # Find long options
            long_opt_pattern = r'--[\w-]+'
            for match in re.finditer(long_opt_pattern, content):
                self.facts["flags"].add(match.group(0))
            
            # Find case statements for options
            case_pattern = r'-([a-zA-Z])\)'
            for match in re.finditer(case_pattern, content):
                self.facts["flags"].add(f"-{match.group(1)}")
        
        except Exception:
            pass
    
    def _scan_build_zig(self, file_path: Path):
        """Scan build.zig for feature flags and build options."""
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Find feature flags
            feature_pattern = r'addFeature\s*\(\s*["\']([^"\']+)["\']'
            for match in re.finditer(feature_pattern, content):
                self.facts["flags"].add(f"--feature-{match.group(1)}")
            
            # Find build options
            option_pattern = r'addOption\s*\(\s*\w+,\s*["\']([^"\']+)["\']'
            for match in re.finditer(option_pattern, content):
                self.facts["flags"].add(f"--{match.group(1)}")
            
            # Find standard build flags
            std_flags = ["--release-safe", "--release-fast", "--release-small", "--verbose"]
            for flag in std_flags:
                if flag.replace("--", "") in content or flag in content:
                    self.facts["flags"].add(flag)
        
        except Exception:
            pass
    
    def get_facts_json(self) -> str:
        """Return facts as JSON string."""
        facts = self.scan_all()
        return json.dumps(facts, indent=2, sort_keys=True)