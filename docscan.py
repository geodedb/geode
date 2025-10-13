#!/usr/bin/env python3
"""
Documentation scanner and classifier.
Parses doc files, extracts metadata, and classifies as ACCURATE or OUTDATED.
"""

import re
import yaml
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Any
import semver


class DocMetadata:
    """Represents metadata extracted from a documentation file."""
    
    def __init__(self, file_path: Path):
        self.file_path = file_path
        self.version: Optional[str] = None
        self.subsystem: Optional[str] = None
        self.references = {
            "symbols": set(),
            "endpoints": set(),
            "flags": set(),
            "deprecated": set()
        }
    
    def add_reference(self, ref_type: str, value: str):
        """Add a reference of the given type."""
        if ref_type in self.references:
            self.references[ref_type].add(value)


class DocScanner:
    """Scans and classifies documentation files."""
    
    def __init__(self, repo_root: Path):
        self.repo_root = Path(repo_root)
        self.docs: List[DocMetadata] = []
    
    def find_doc_files(self) -> List[Path]:
        """Find all documentation files, excluding archive."""
        doc_patterns = ["**/*.md", "**/*.mdx", "**/*.rst"]
        doc_files = []
        
        for pattern in doc_patterns:
            files = list(self.repo_root.rglob(pattern))
            # Exclude archive directory
            files = [f for f in files if "archive" not in f.parts]
            doc_files.extend(files)
        
        return list(set(doc_files))  # Remove duplicates
    
    def scan_doc_file(self, file_path: Path) -> DocMetadata:
        """Scan a single documentation file and extract metadata."""
        doc = DocMetadata(file_path)
        
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Try to extract YAML front-matter
            front_matter = self._extract_front_matter(content)
            if front_matter:
                doc.version = front_matter.get("version")
                doc.subsystem = front_matter.get("subsystem")
            
            # If no front-matter, try to find version/subsystem in leading lines
            if not doc.version or not doc.subsystem:
                lines = content.split('\n')[:10]  # Check first 10 lines
                for line in lines:
                    if not doc.version:
                        version_match = re.search(r'Version:\s*([^\s]+)', line, re.IGNORECASE)
                        if version_match:
                            doc.version = version_match.group(1)
                    
                    if not doc.subsystem:
                        subsystem_match = re.search(r'Subsystem:\s*([^\s]+)', line, re.IGNORECASE)
                        if subsystem_match:
                            doc.subsystem = subsystem_match.group(1)
            
            # Extract references
            self._extract_references(content, doc)
            
        except Exception:
            # If we can't read the file, leave metadata empty
            pass
        
        return doc
    
    def _extract_front_matter(self, content: str) -> Optional[Dict[str, Any]]:
        """Extract YAML front-matter from document content."""
        if not content.startswith('---'):
            return None
        
        # Find end of front-matter
        lines = content.split('\n')
        end_idx = -1
        for i, line in enumerate(lines[1:], 1):
            if line.strip() == '---':
                end_idx = i
                break
        
        if end_idx == -1:
            return None
        
        front_matter_text = '\n'.join(lines[1:end_idx])
        try:
            return yaml.safe_load(front_matter_text)
        except Exception:
            return None
    
    def _extract_references(self, content: str, doc: DocMetadata):
        """Extract references to symbols, endpoints, flags from content."""
        
        # Find function references - be more specific
        func_patterns = [
            r'`(pub fn \w+)`',
            r'`(def \w+)`',
            r'\b(pub fn \w+)\b',
            r'\b(def \w+)\b'
        ]
        for pattern in func_patterns:
            for match in re.finditer(pattern, content):
                doc.add_reference("symbols", match.group(1))
        
        # Find type/class references - be more specific  
        type_patterns = [
            r'`(class \w+)`',
            r'`(pub const \w+)`',
            r'\b(class \w+)\b',
            r'\b(pub const \w+)\b'
        ]
        for pattern in type_patterns:
            for match in re.finditer(pattern, content):
                doc.add_reference("symbols", match.group(1))
        
        # Find simple symbol references in backticks (more general)
        symbol_pattern = r'`([A-Z]\w+)`'
        for match in re.finditer(symbol_pattern, content):
            symbol = match.group(1)
            # Only add if it looks like a type/class (starts with capital)
            if symbol[0].isupper():
                doc.add_reference("symbols", symbol)
        
        # Find endpoint references
        endpoint_pattern = r'(/v\d+/[^\s\)\]]+)'
        for match in re.finditer(endpoint_pattern, content):
            doc.add_reference("endpoints", match.group(1))
        
        # Find flag references
        flag_pattern = r'(--[\w-]+)'
        for match in re.finditer(flag_pattern, content):
            doc.add_reference("flags", match.group(1))
        
        # Check for deprecated markings
        deprecated_patterns = [
            r'deprecated',
            r'DEPRECATED', 
            r'obsolete',
            r'legacy'
        ]
        for pattern in deprecated_patterns:
            if re.search(pattern, content, re.IGNORECASE):
                doc.add_reference("deprecated", pattern)


class DocClassifier:
    """Classifies documentation as ACCURATE or OUTDATED based on rules."""
    
    def __init__(self, canary_loader, code_facts: Dict[str, Any]):
        self.canary_loader = canary_loader
        self.code_facts = code_facts
        self.latest_versions = canary_loader.get_latest_versions()
    
    def classify_doc(self, doc: DocMetadata) -> Tuple[str, str]:
        """
        Classify document as ACCURATE or OUTDATED.
        Returns (classification, reason).
        """
        
        # Rule 1: If doc has no declared version → OUTDATED
        if not doc.version:
            return ("OUTDATED", "NO_VERSION_DECLARED")
        
        # Rule 2: If doc's version < latest canary for its subsystem → OUTDATED
        if doc.subsystem and doc.subsystem in self.latest_versions:
            latest = self.latest_versions[doc.subsystem]
            try:
                doc_version = semver.Version.parse(doc.version)
                latest_version = semver.Version.parse(latest)
                if doc_version < latest_version:
                    return ("OUTDATED", f"VERSION_STALE_{doc.version}_vs_{latest}")
            except ValueError:
                # Invalid semver, consider outdated
                return ("OUTDATED", "INVALID_VERSION_FORMAT")
        else:
            # Compare against global latest if no specific subsystem
            try:
                global_latest = self.latest_versions.get("global", "0.0.0")
                doc_version = semver.Version.parse(doc.version)
                global_version = semver.Version.parse(global_latest)
                if doc_version < global_version:
                    return ("OUTDATED", f"VERSION_STALE_{doc.version}_vs_global_{global_latest}")
            except ValueError:
                return ("OUTDATED", "INVALID_VERSION_FORMAT")
        
        # Rule 3: If doc references symbols/endpoints not found in facts index 
        # and canary doesn't allow legacy → OUTDATED
        for symbol in doc.references["symbols"]:
            if symbol not in self.code_facts["symbols"]:
                # Check if it's deprecated
                deprecated_symbols = self.canary_loader.get_deprecated_symbols(doc.subsystem)
                if symbol in deprecated_symbols:
                    if not self.canary_loader.allows_legacy_refs(doc.subsystem or ""):
                        return ("OUTDATED", f"DEPRECATED_SYMBOL_{symbol}")
                else:
                    # Symbol not found and not in deprecated list
                    return ("OUTDATED", f"UNKNOWN_SYMBOL_{symbol}")
        
        for endpoint in doc.references["endpoints"]:
            if endpoint not in self.code_facts["endpoints"]:
                deprecated_endpoints = self.canary_loader.get_deprecated_endpoints(doc.subsystem)
                if endpoint in deprecated_endpoints:
                    if not self.canary_loader.allows_legacy_refs(doc.subsystem or ""):
                        return ("OUTDATED", f"DEPRECATED_ENDPOINT_{endpoint}")
                else:
                    return ("OUTDATED", f"UNKNOWN_ENDPOINT_{endpoint}")
        
        # Rule 4: If doc references deprecated items per canary without marking deprecated → OUTDATED
        deprecated_symbols = self.canary_loader.get_deprecated_symbols(doc.subsystem)
        deprecated_endpoints = self.canary_loader.get_deprecated_endpoints(doc.subsystem)
        
        for symbol in doc.references["symbols"]:
            if symbol in deprecated_symbols and not doc.references["deprecated"]:
                return ("OUTDATED", f"UNMARKED_DEPRECATED_SYMBOL_{symbol}")
        
        for endpoint in doc.references["endpoints"]:
            if endpoint in deprecated_endpoints and not doc.references["deprecated"]:
                return ("OUTDATED", f"UNMARKED_DEPRECATED_ENDPOINT_{endpoint}")
        
        # Rule 5: Otherwise → ACCURATE
        return ("ACCURATE", "VALID")
    
    def classify_all_docs(self, docs: List[DocMetadata]) -> Dict[str, List[DocMetadata]]:
        """Classify all docs and group by result."""
        results = {"ACCURATE": [], "OUTDATED": []}
        
        for doc in docs:
            classification, reason = self.classify_doc(doc)
            doc.classification = classification
            doc.classification_reason = reason
            results[classification].append(doc)
        
        return results