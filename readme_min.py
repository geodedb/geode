#!/usr/bin/env python3
"""
Minimal README enforcement.
Ensures root README.md stays minimal with links to docs/.
"""

from pathlib import Path


class ReadmeMinimizer:
    """Enforces minimal README policy."""
    
    def __init__(self, repo_root: Path):
        self.repo_root = Path(repo_root)
        self.readme_path = self.repo_root / "README.md"
    
    def is_minimal(self) -> bool:
        """Check if current README is already minimal."""
        if not self.readme_path.exists():
            return False
        
        try:
            with open(self.readme_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Consider minimal if it's short and contains key links
            lines = content.strip().split('\n')
            non_empty_lines = [line for line in lines if line.strip()]
            
            # Minimal criteria: < 50 non-empty lines and contains docs/ links
            if len(non_empty_lines) > 50:
                return False
            
            # Must contain links to docs/
            has_docs_links = any("docs/" in line for line in lines)
            return has_docs_links
            
        except Exception:
            return False
    
    def get_project_name(self) -> str:
        """Extract project name from current README or use directory name."""
        project_name = self.repo_root.name.title()
        
        if self.readme_path.exists():
            try:
                with open(self.readme_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # Look for first heading
                lines = content.split('\n')
                for line in lines:
                    if line.startswith('# '):
                        project_name = line[2:].strip()
                        break
                        
            except Exception:
                pass
        
        return project_name
    
    def generate_minimal_readme(self) -> str:
        """Generate minimal README template."""
        project_name = self.get_project_name()
        
        template = f"""# {project_name}

Minimal overview. Full documentation lives in [`docs/`](./docs/).

- [Getting Started](./docs/index.md)
- [API Reference](./docs/api/index.md)
- [Changelog](./docs/changelog.md)
"""
        return template
    
    def enforce_minimal(self, apply: bool = False) -> dict:
        """Enforce minimal README policy."""
        result = {
            "is_minimal": self.is_minimal(),
            "readme_minimized": False,
            "project_name": self.get_project_name()
        }
        
        if not result["is_minimal"] and apply:
            minimal_content = self.generate_minimal_readme()
            try:
                with open(self.readme_path, 'w', encoding='utf-8') as f:
                    f.write(minimal_content)
                result["readme_minimized"] = True
            except Exception as e:
                result["error"] = str(e)
        
        return result