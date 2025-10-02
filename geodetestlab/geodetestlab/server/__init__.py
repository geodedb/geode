"""Server lifecycle management for Geode testing.

This package provides utilities for managing Geode server instances during
testing, including starting servers, waiting for readiness, stopping cleanly,
and managing test data directories.
"""

from .simple_manager import ServerManager

__all__ = ["ServerManager"]