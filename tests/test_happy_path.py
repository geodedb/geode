#!/usr/bin/env python3
"""Test happy path scenarios for documentation consolidation."""

import pytest
import tempfile
import shutil
from pathlib import Path
import json
import subprocess
import sys
import os

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from consolidate_docs import DocConsolidator
from doccanary import CanaryLoader
from codefacts import CodeFactsScanner
from docscan import DocScanner, DocClassifier


class TestHappyPath:
    """Test successful consolidation scenarios."""
    
    def setup_method(self):
        """Setup test environment."""
        self.temp_dir = Path(tempfile.mkdtemp())
        self.setup_test_repo()
    
    def teardown_method(self):
        """Cleanup test environment."""
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
    
    def setup_test_repo(self):
        """Create a test repository structure."""
        
        # Create directories
        (self.temp_dir / "agents" / "canaries").mkdir(parents=True)
        (self.temp_dir / "docs").mkdir(parents=True)
        (self.temp_dir / "src").mkdir(parents=True)
        
        # Create canary files
        core_canary = {
            "version": "1",
            "subsystem": "core", 
            "latest": "0.15.1",
            "deprecated": {
                "symbols": ["OldType", "old_func"],
                "endpoints": ["/v1/alpha"]
            },
            "allowed_legacy_refs": False,
            "endpoints": [
                {"path": "/v2/compute", "since": "0.15.0"}
            ],
            "symbols": [
                {"name": "pub fn compute", "since": "0.15.0"},
                {"name": "pub const VERSION", "since": "0.15.1"}
            ],
            "flags": [
                {"name": "--fast", "since": "0.14.0"}
            ]
        }
        
        import yaml
        with open(self.temp_dir / "agents" / "canaries" / "core.yaml", 'w') as f:
            yaml.dump(core_canary, f)
        
        # Create source file with symbols
        src_content = '''
pub const VERSION = "0.15.1";

pub fn compute() {
    // Implementation
}

pub fn query() {
    // Implementation  
}
'''
        with open(self.temp_dir / "src" / "main.zig", 'w') as f:
            f.write(src_content)
        
        # Create current doc with correct version and symbols
        doc_content = '''---
version: "0.15.1"
subsystem: "core"
---

# Quickstart Guide

This guide shows how to use the `pub fn compute` function.

## Example

```zig
pub fn compute();
```

Use the `--fast` flag for better performance.
'''
        with open(self.temp_dir / "docs" / "quickstart.md", 'w') as f:
            f.write(doc_content)
    
    def test_valid_current_doc(self):
        """Test that current valid docs are retained."""
        
        consolidator = DocConsolidator(self.temp_dir)
        
        # Should validate successfully
        assert consolidator.validate_setup()
        
        # Run consolidation
        results = consolidator.run(apply=False)
        
        assert "error" not in results
        assert results["stats"]["accurate"] == 1
        assert results["stats"]["outdated"] == 0
        assert len(results["retained"]) == 1
        assert "docs/quickstart.md" in results["retained"]
        
        # Check latest versions
        assert "core" in results["latest_versions"]
        assert results["latest_versions"]["core"] == "0.15.1"
        assert results["latest_versions"]["global"] == "0.15.1"
    
    def test_cli_integration(self):
        """Test CLI integration."""
        
        # Run via CLI
        result = subprocess.run([
            sys.executable, 
            str(Path(__file__).parent.parent / "consolidate_docs.py"),
            "--repo", str(self.temp_dir)
        ], capture_output=True, text=True)
        
        assert result.returncode == 0
        
        # Parse JSON output
        output_data = json.loads(result.stdout)
        
        assert "latest_versions" in output_data
        assert "stats" in output_data
        assert output_data["stats"]["dry_run"] is True
        assert output_data["stats"]["accurate"] >= 1