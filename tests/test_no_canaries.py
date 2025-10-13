#!/usr/bin/env python3
"""Test error scenarios for documentation consolidation."""

import pytest
import tempfile
import shutil
from pathlib import Path
import subprocess
import sys

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from consolidate_docs import DocConsolidator


class TestErrorScenarios:
    """Test error handling and edge cases."""
    
    def setup_method(self):
        """Setup test environment."""
        self.temp_dir = Path(tempfile.mkdtemp())
    
    def teardown_method(self):
        """Cleanup test environment."""
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
    
    def test_no_canaries_available(self):
        """Test handling when no canaries are found."""
        
        # Create empty repo without canaries
        (self.temp_dir / "docs").mkdir(parents=True)
        
        consolidator = DocConsolidator(self.temp_dir)
        
        # Should fail validation
        assert not consolidator.validate_setup()
        
        # Run should return error
        results = consolidator.run()
        assert "error" in results
        assert results["exit_code"] == 2
    
    def test_no_canaries_cli(self):
        """Test CLI exits with code 2 when no canaries."""
        
        # Create empty directory
        (self.temp_dir / "docs").mkdir(parents=True)
        
        result = subprocess.run([
            sys.executable,
            str(Path(__file__).parent.parent / "consolidate_docs.py"),
            "--repo", str(self.temp_dir)
        ], capture_output=True, text=True)
        
        assert result.returncode == 2
        assert "NO_CANARIES_FOUND" in result.stderr or "Setup validation failed" in result.stderr
    
    def test_invalid_repo_path(self):
        """Test CLI handles invalid repo path."""
        
        nonexistent_path = self.temp_dir / "nonexistent"
        
        result = subprocess.run([
            sys.executable,
            str(Path(__file__).parent.parent / "consolidate_docs.py"),
            "--repo", str(nonexistent_path)
        ], capture_output=True, text=True)
        
        assert result.returncode == 3
        assert "does not exist" in result.stderr
    
    def test_invalid_config_path(self):
        """Test CLI handles invalid config path."""
        
        (self.temp_dir / "docs").mkdir(parents=True)
        nonexistent_config = self.temp_dir / "nonexistent.yaml"
        
        result = subprocess.run([
            sys.executable,
            str(Path(__file__).parent.parent / "consolidate_docs.py"),
            "--repo", str(self.temp_dir),
            "--config", str(nonexistent_config)
        ], capture_output=True, text=True)
        
        assert result.returncode == 3
        assert "Configuration file does not exist" in result.stderr
    
    def test_malformed_canary_yaml(self):
        """Test handling of malformed canary YAML."""
        
        # Create directories
        (self.temp_dir / "agents" / "canaries").mkdir(parents=True)
        
        # Create malformed YAML
        with open(self.temp_dir / "agents" / "canaries" / "bad.yaml", 'w') as f:
            f.write("invalid: yaml: content: [unclosed")
        
        consolidator = DocConsolidator(self.temp_dir)
        assert not consolidator.validate_setup()
    
    def test_canary_missing_required_fields(self):
        """Test canary with missing required fields."""
        
        # Create directories
        (self.temp_dir / "agents" / "canaries").mkdir(parents=True)
        
        # Create canary missing subsystem
        import yaml
        bad_canary = {
            "version": "1",
            "latest": "1.0.0"
            # Missing subsystem
        }
        
        with open(self.temp_dir / "agents" / "canaries" / "bad.yaml", 'w') as f:
            yaml.dump(bad_canary, f)
        
        consolidator = DocConsolidator(self.temp_dir)
        assert not consolidator.validate_setup()
    
    def test_root_readme_enforcement(self):
        """Test root README enforcement creates minimal template."""
        
        # Create test repo with canaries
        (self.temp_dir / "agents" / "canaries").mkdir(parents=True)
        (self.temp_dir / "docs").mkdir(parents=True)
        
        # Create minimal canary
        import yaml
        canary = {
            "version": "1",
            "subsystem": "core",
            "latest": "1.0.0"
        }
        
        with open(self.temp_dir / "agents" / "canaries" / "core.yaml", 'w') as f:
            yaml.dump(canary, f)
        
        # Create verbose README
        verbose_readme = """# Project
        
""" + "\n".join([f"Line {i}" for i in range(100)])  # 100+ lines
        
        with open(self.temp_dir / "README.md", 'w') as f:
            f.write(verbose_readme)
        
        consolidator = DocConsolidator(self.temp_dir)
        results = consolidator.run(apply=True)
        
        # Should minimize README
        assert results.get("readme_minimized") is True
        
        # Check README was rewritten
        with open(self.temp_dir / "README.md", 'r') as f:
            new_content = f.read()
        
        assert len(new_content.split('\n')) < 20  # Much shorter now
        assert "docs/" in new_content  # Contains docs links