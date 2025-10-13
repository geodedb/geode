#!/usr/bin/env python3
"""
Documentation consolidation CLI tool.

Consolidates documentation into docs/, archives outdated docs to docs/archive/,
and determines accuracy using code-aware checks plus canary definitions.

Usage: python consolidate_docs.py [--apply] [--repo ROOT] [--verbose] [--config CONFIG]
"""

import sys
import json
import argparse
import logging
import shutil
from pathlib import Path
from typing import Dict, List, Any, Optional

# Import our modules
from doccanary import CanaryLoader
from codefacts import CodeFactsScanner
from docscan import DocScanner, DocClassifier
from readme_min import ReadmeMinimizer


def setup_logging(verbose: bool = False):
    """Setup JSON Line logging."""
    level = logging.DEBUG if verbose else logging.INFO
    
    # Configure JSON formatter
    class JSONFormatter(logging.Formatter):
        def format(self, record):
            log_data = {
                "level": record.levelname,
                "message": record.getMessage(),
                "timestamp": self.formatTime(record),
                "module": record.module
            }
            if hasattr(record, 'extra_data'):
                log_data.update(record.extra_data)
            return json.dumps(log_data)
    
    # Setup logger
    logger = logging.getLogger()
    logger.setLevel(level)
    
    # Only send logs to stderr to keep stdout clean for final JSON
    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(level)
    stderr_handler.setFormatter(JSONFormatter())
    logger.addHandler(stderr_handler)
    
    return logger


def safe_path_join(base_path: Path, relative_path: Path) -> Path:
    """Safely join paths preventing directory traversal."""
    base_path = base_path.resolve()
    full_path = (base_path / relative_path).resolve()
    
    # Ensure the resolved path is within base_path
    try:
        full_path.relative_to(base_path)
        return full_path
    except ValueError:
        raise ValueError(f"Path traversal detected: {relative_path}")


def redact_secrets(text: str) -> str:
    """Redact potential secrets from text."""
    import re
    
    # Common secret patterns
    patterns = [
        r'[A-Za-z0-9+/]{40,}',  # Base64-like tokens
        r'[a-fA-F0-9]{32,}',    # Hex tokens
        r'sk_[A-Za-z0-9]{20,}', # Stripe-like keys
        r'pk_[A-Za-z0-9]{20,}', # Public keys
        r'AIza[A-Za-z0-9_-]{35}', # Google API keys
    ]
    
    for pattern in patterns:
        text = re.sub(pattern, '[REDACTED]', text)
    
    return text


class DocConsolidator:
    """Main documentation consolidation engine."""
    
    def __init__(self, repo_root: Path, config_path: Optional[Path] = None):
        self.repo_root = Path(repo_root).resolve()
        self.config = self._load_config(config_path)
        self.logger = logging.getLogger(__name__)
        
        # Initialize components
        self.canary_loader = CanaryLoader(self.repo_root)
        self.code_scanner = CodeFactsScanner(self.repo_root)
        self.doc_scanner = DocScanner(self.repo_root)
        self.readme_minimizer = ReadmeMinimizer(self.repo_root)
        
        # Stats
        self.stats = {
            "docs_seen": 0,
            "accurate": 0,
            "outdated": 0,
            "dry_run": True
        }
    
    def _load_config(self, config_path: Optional[Path]) -> Dict[str, Any]:
        """Load configuration file if provided."""
        if not config_path:
            return {}
        
        try:
            import yaml
            with open(config_path, 'r') as f:
                return yaml.safe_load(f) or {}
        except Exception as e:
            self.logger.error(f"Failed to load config: {e}")
            return {}
    
    def validate_setup(self) -> bool:
        """Validate that we can proceed with consolidation."""
        try:
            # Check that canaries exist
            canaries = self.canary_loader.load_canaries()
            if not canaries:
                self.logger.error("NO_CANARIES_FOUND")
                return False
            
            self.logger.info(f"Loaded {len(canaries)} canary rules", 
                           extra={'extra_data': {'canaries': list(canaries.keys())}})
            
            return True
            
        except Exception as e:
            self.logger.error(f"Setup validation failed: {e}")
            return False
    
    def scan_and_classify(self) -> Dict[str, List]:
        """Scan code and docs, then classify documents."""
        
        # 1. Scan code for facts
        self.logger.info("Scanning code for facts...")
        code_facts = self.code_scanner.scan_all()
        self.logger.info(f"Found {len(code_facts['symbols'])} symbols, "
                        f"{len(code_facts['endpoints'])} endpoints, "
                        f"{len(code_facts['flags'])} flags")
        
        # 2. Find and scan documentation files
        self.logger.info("Scanning documentation files...")
        doc_files = self.doc_scanner.find_doc_files()
        self.stats["docs_seen"] = len(doc_files)
        
        docs = []
        for doc_file in doc_files:
            doc_meta = self.doc_scanner.scan_doc_file(doc_file)
            docs.append(doc_meta)
        
        # 3. Classify documents
        self.logger.info("Classifying documents...")
        classifier = DocClassifier(self.canary_loader, code_facts)
        classified = classifier.classify_all_docs(docs)
        
        self.stats["accurate"] = len(classified["ACCURATE"])
        self.stats["outdated"] = len(classified["OUTDATED"])
        
        self.logger.info(f"Classification complete: {self.stats['accurate']} accurate, "
                        f"{self.stats['outdated']} outdated")
        
        return classified
    
    def consolidate_docs(self, classified: Dict[str, List], apply: bool = False) -> Dict[str, Any]:
        """Consolidate documentation based on classification."""
        
        self.stats["dry_run"] = not apply
        
        results = {
            "latest_versions": self.canary_loader.get_latest_versions(),
            "retained": [],
            "moved_to_archive": [],
            "moved_to_docs": [],
            "stats": self.stats.copy()
        }
        
        docs_dir = self.repo_root / "docs"
        archive_dir = docs_dir / "archive"
        
        # Ensure directories exist
        if apply:
            docs_dir.mkdir(exist_ok=True)
            archive_dir.mkdir(exist_ok=True)
        
        # Process ACCURATE docs - ensure they're in docs/
        for doc in classified["ACCURATE"]:
            rel_path = doc.file_path.relative_to(self.repo_root)
            
            if str(rel_path).startswith("docs/") and "archive" not in str(rel_path):
                # Already in docs/ and not archived
                results["retained"].append(str(rel_path))
            else:
                # Move to docs/
                target_path = docs_dir / rel_path.name
                if apply:
                    try:
                        target_path.parent.mkdir(parents=True, exist_ok=True)
                        shutil.move(str(doc.file_path), str(target_path))
                        self.logger.info(f"Moved {rel_path} to docs/")
                    except Exception as e:
                        self.logger.error(f"Failed to move {rel_path}: {e}")
                        continue
                
                results["moved_to_docs"].append(str(rel_path))
        
        # Process OUTDATED docs - move to archive
        for doc in classified["OUTDATED"]:
            rel_path = doc.file_path.relative_to(self.repo_root)
            
            if "archive" in str(rel_path):
                # Already archived
                continue
            
            # Determine archive path preserving structure
            if str(rel_path).startswith("docs/"):
                archive_rel_path = rel_path.relative_to("docs")
            else:
                archive_rel_path = rel_path
            
            archive_path = archive_dir / archive_rel_path
            
            if apply:
                try:
                    archive_path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(doc.file_path), str(archive_path))
                    self.logger.info(f"Archived {rel_path} to {archive_path.relative_to(self.repo_root)}")
                except Exception as e:
                    self.logger.error(f"Failed to archive {rel_path}: {e}")
                    continue
            
            results["moved_to_archive"].append(str(rel_path))
        
        return results
    
    def enforce_minimal_readme(self, apply: bool = False) -> Dict[str, Any]:
        """Enforce minimal README policy."""
        return self.readme_minimizer.enforce_minimal(apply)
    
    def run(self, apply: bool = False) -> Dict[str, Any]:
        """Run the full consolidation process."""
        
        # 1. Validate setup
        if not self.validate_setup():
            return {"error": "Setup validation failed", "exit_code": 2}
        
        try:
            # 2. Scan and classify
            classified = self.scan_and_classify()
            
            # 3. Consolidate docs
            results = self.consolidate_docs(classified, apply)
            
            # 4. Enforce minimal README
            readme_result = self.enforce_minimal_readme(apply)
            if readme_result.get("readme_minimized"):
                results["readme_minimized"] = True
            
            # 5. Final summary
            self.logger.info("Consolidation complete", 
                           extra={'extra_data': {'summary': results["stats"]}})
            
            return results
            
        except Exception as e:
            self.logger.error(f"Consolidation failed: {e}")
            return {"error": str(e), "exit_code": 1}


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Consolidate documentation based on code-aware checks and canary definitions",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument(
        "--apply", 
        action="store_true",
        help="Perform file moves; otherwise dry-run (default)"
    )
    
    parser.add_argument(
        "--repo", 
        type=Path,
        default=Path("."),
        help="Repository root directory (default: .)"
    )
    
    parser.add_argument(
        "--config",
        type=Path,
        help="Optional configuration file (docconsolidator.yaml)"
    )
    
    parser.add_argument(
        "--verbose",
        action="store_true", 
        help="Enable DEBUG logging"
    )
    
    args = parser.parse_args()
    
    # Setup logging
    logger = setup_logging(args.verbose)
    
    # Validate repo path
    if not args.repo.exists() or not args.repo.is_dir():
        logger.error(f"Repository path does not exist: {args.repo}")
        sys.exit(3)
    
    # Validate config if provided
    if args.config and not args.config.exists():
        logger.error(f"Configuration file does not exist: {args.config}")
        sys.exit(3)
    
    # Run consolidation
    try:
        consolidator = DocConsolidator(args.repo, args.config)
        results = consolidator.run(args.apply)
        
        if "error" in results:
            logger.error(f"Consolidation failed: {results['error']}")
            sys.exit(results.get("exit_code", 1))
        
        # Output final summary as clean JSON
        summary = {k: v for k, v in results.items() if k != "error"}
        print(json.dumps(summary, indent=2, sort_keys=True))
        
        sys.exit(0)
        
    except KeyboardInterrupt:
        logger.info("Consolidation interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {redact_secrets(str(e))}")
        sys.exit(1)


if __name__ == "__main__":
    main()