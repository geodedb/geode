#!/usr/bin/env python3
"""
Canary loader and validation for documentation consolidation.
Loads canary YAML files and provides ground truth for version/feature validation.
"""

import yaml
from pathlib import Path
from typing import Dict, List, Any
import semver


class CanaryRule:
    """Represents a single canary rule from YAML."""
    
    def __init__(self, data: Dict[str, Any], file_path: str):
        self.file_path = file_path
        self.version = data.get("version", "1")
        self.subsystem = data.get("subsystem", "unknown")
        self.latest = data.get("latest", "0.0.0")
        self.deprecated = data.get("deprecated", {})
        self.allowed_legacy_refs = data.get("allowed_legacy_refs", False)
        self.endpoints = data.get("endpoints", [])
        self.symbols = data.get("symbols", [])
        self.flags = data.get("flags", [])
        
        # Validate required fields
        if not self.subsystem or self.subsystem == "unknown":
            raise ValueError(f"Missing or invalid subsystem in {file_path}")
        
        # Validate semver
        try:
            semver.Version.parse(self.latest)
        except ValueError:
            raise ValueError(f"Invalid semver '{self.latest}' in {file_path}")


class CanaryLoader:
    """Loads and manages canary rules from YAML files."""
    
    def __init__(self, repo_root: Path):
        self.repo_root = Path(repo_root)
        self.rules: Dict[str, CanaryRule] = {}
        self.global_latest = "0.0.0"
        
    def load_canaries(self) -> Dict[str, CanaryRule]:
        """Load all canary YAML files from agents/canaries/*.yaml"""
        canaries_dir = self.repo_root / "agents" / "canaries"
        
        if not canaries_dir.exists():
            raise FileNotFoundError(f"Canaries directory not found: {canaries_dir}")
        
        yaml_files = list(canaries_dir.glob("*.yaml")) + list(canaries_dir.glob("*.yml"))
        
        if not yaml_files:
            raise ValueError("NO_CANARIES_FOUND")
        
        for yaml_file in yaml_files:
            try:
                with open(yaml_file, 'r') as f:
                    data = yaml.safe_load(f)
                
                if not data:
                    continue
                    
                rule = CanaryRule(data, str(yaml_file))
                self.rules[rule.subsystem] = rule
                
                # Track global latest version
                try:
                    rule_version = semver.Version.parse(rule.latest)
                    global_version = semver.Version.parse(self.global_latest)
                    if rule_version > global_version:
                        self.global_latest = rule.latest
                except ValueError:
                    # Skip invalid semver in global calculation
                    pass
                    
            except Exception as e:
                raise ValueError(f"Error loading {yaml_file}: {e}")
        
        return self.rules
    
    def get_latest_versions(self) -> Dict[str, str]:
        """Get latest versions per subsystem plus global latest."""
        versions = {}
        for subsystem, rule in self.rules.items():
            versions[subsystem] = rule.latest
        versions["global"] = self.global_latest
        return versions
    
    def get_deprecated_symbols(self, subsystem: str = None) -> List[str]:
        """Get deprecated symbols for subsystem or all."""
        symbols = []
        if subsystem and subsystem in self.rules:
            symbols.extend(self.rules[subsystem].deprecated.get("symbols", []))
        else:
            for rule in self.rules.values():
                symbols.extend(rule.deprecated.get("symbols", []))
        return symbols
    
    def get_deprecated_endpoints(self, subsystem: str = None) -> List[str]:
        """Get deprecated endpoints for subsystem or all."""
        endpoints = []
        if subsystem and subsystem in self.rules:
            endpoints.extend(self.rules[subsystem].deprecated.get("endpoints", []))
        else:
            for rule in self.rules.values():
                endpoints.extend(rule.deprecated.get("endpoints", []))
        return endpoints
    
    def allows_legacy_refs(self, subsystem: str) -> bool:
        """Check if subsystem allows legacy references."""
        if subsystem in self.rules:
            return self.rules[subsystem].allowed_legacy_refs
        return False
    
    def get_valid_symbols(self, subsystem: str = None) -> List[str]:
        """Get valid (non-deprecated) symbols."""
        symbols = []
        if subsystem and subsystem in self.rules:
            symbols.extend([s["name"] for s in self.rules[subsystem].symbols])
        else:
            for rule in self.rules.values():
                symbols.extend([s["name"] for s in rule.symbols])
        return symbols
    
    def get_valid_endpoints(self, subsystem: str = None) -> List[str]:
        """Get valid (non-deprecated) endpoints."""
        endpoints = []
        if subsystem and subsystem in self.rules:
            endpoints.extend([e["path"] for e in self.rules[subsystem].endpoints])
        else:
            for rule in self.rules.values():
                endpoints.extend([e["path"] for e in rule.endpoints])
        return endpoints
    
    def get_valid_flags(self, subsystem: str = None) -> List[str]:
        """Get valid flags."""
        flags = []
        if subsystem and subsystem in self.rules:
            flags.extend([f["name"] for f in self.rules[subsystem].flags])
        else:
            for rule in self.rules.values():
                flags.extend([f["name"] for f in rule.flags])
        return flags