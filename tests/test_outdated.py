#!/usr/bin/env python3
"""Test outdated documentation scenarios."""

import pytest
import tempfile
import shutil
from pathlib import Path
import json
import sys

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from consolidate_docs import DocConsolidator


class TestOutdatedDocs:
    """Test scenarios with outdated documentation."""
    
    def setup_method(self):
        """Setup test environment."""
        self.temp_dir = Path(tempfile.mkdtemp())
        self.setup_test_repo()
    
    def teardown_method(self):
        """Cleanup test environment."""
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
    
    def setup_test_repo(self):
        """Create a test repository with outdated docs."""
        
        # Create directories
        (self.temp_dir / "agents" / "canaries").mkdir(parents=True)
        (self.temp_dir / "docs").mkdir(parents=True)
        (self.temp_dir / "src").mkdir(parents=True)
        
        # Create canary file
        core_canary = {
            "version": "1",
            "subsystem": "core",
            "latest": "0.15.1",
            "deprecated": {
                "symbols": ["OldType"],
                "endpoints": ["/v1/alpha"]
            },
            "allowed_legacy_refs": False,
            "symbols": [
                {"name": "pub fn compute", "since": "0.15.0"}
            ]
        }
        
        import yaml
        with open(self.temp_dir / "agents" / "canaries" / "core.yaml", 'w') as f:
            yaml.dump(core_canary, f)
        
        # Create source file
        src_content = '''
pub const VERSION = "0.15.1";
pub fn compute() {}
'''
        with open(self.temp_dir / "src" / "main.zig", 'w') as f:
            f.write(src_content)
    
    def test_version_stale_doc(self):
        """Test doc with stale version is moved to archive."""
        
        # Create old version doc
        old_doc_content = '''---
version: "0.14.0"
subsystem: "core"
---

# Old Guide

This is an old version of the documentation.
'''
        with open(self.temp_dir / "docs" / "old_guide.md", 'w') as f:
            f.write(old_doc_content)
        
        consolidator = DocConsolidator(self.temp_dir)
        results = consolidator.run(apply=False)
        
        assert "error" not in results
        assert results["stats"]["outdated"] == 1
        assert len(results["moved_to_archive"]) == 1
        assert "docs/old_guide.md" in results["moved_to_archive"]
    
    def test_symbol_mismatch(self):
        """Test doc mentioning deprecated symbols."""
        
        # Create doc with deprecated symbol
        deprecated_doc = '''---
version: "0.15.1"
subsystem: "core"
---

# Deprecated API Guide

Use the `OldType` for legacy operations.
'''
        with open(self.temp_dir / "docs" / "deprecated_api.md", 'w') as f:
            f.write(deprecated_doc)
        
        consolidator = DocConsolidator(self.temp_dir)
        results = consolidator.run(apply=False)
        
        assert "error" not in results
        assert results["stats"]["outdated"] == 1
        assert "docs/deprecated_api.md" in results["moved_to_archive"]
    
    def test_unversioned_doc(self):
        """Test doc without version header."""
        
        # Create unversioned doc
        unversioned_doc = '''
# Unversioned Guide

This document has no version information.
'''
        with open(self.temp_dir / "docs" / "unversioned.md", 'w') as f:
            f.write(unversioned_doc)
        
        consolidator = DocConsolidator(self.temp_dir)
        results = consolidator.run(apply=False)
        
        assert "error" not in results
        assert results["stats"]["outdated"] == 1
        assert "docs/unversioned.md" in results["moved_to_archive"]
    
    def test_apply_moves_files(self):
        """Test that --apply actually moves files."""
        
        # Create outdated doc
        old_doc = '''---
version: "0.14.0"
---

# Old Doc
'''
        old_doc_path = self.temp_dir / "docs" / "old.md"
        with open(old_doc_path, 'w') as f:
            f.write(old_doc)
        
        # Create archive directory
        archive_dir = self.temp_dir / "docs" / "archive"
        archive_dir.mkdir(exist_ok=True)
        
        consolidator = DocConsolidator(self.temp_dir)
        results = consolidator.run(apply=True)
        
        # Check file was actually moved
        assert not old_doc_path.exists()
        assert (archive_dir / "old.md").exists()
        assert results["stats"]["dry_run"] is False