"""Simple server manager that bypasses QUIC issues."""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional, List, Dict, Any

import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from core.utils import find_geode_binary, get_free_port


class ServerManager:
    """Server manager that starts real geode server."""
    
    def __init__(
        self,
        geode_binary: Optional[str] = None,
        port: Optional[int] = None,
        data_dir: Optional[Path] = None,
        timeout_ms: int = 60000,
        verbose: bool = False,
    ):
        """Initialize the server manager."""
        self.binary = find_geode_binary(geode_binary)
        # Use port 8443 by default to match client expectations
        self.port = port or 8443
        self.timeout_ms = timeout_ms
        self.verbose = verbose
        
        # Always start a real server; do not rely on embedded fallback
        self._use_embedded = False
        self.process = None
        self.temp_dir = None
        
        if not data_dir:
            self.temp_dir = tempfile.mkdtemp(prefix="geode-test-")
            self.data_dir = Path(self.temp_dir)
        else:
            self.data_dir = Path(data_dir)
    
    def start(self) -> None:
        """Start the geode server."""
        if self._use_embedded:
            # For embedded mode, we don't need to start a separate server
            # The client will start its own embedded server
            if self.verbose:
                print(f"[Embedded] Server configured for embedded mode on port {self.port}")
            return
        
        # Start actual QUIC server
        cmd = [
            str(self.binary),
            "serve",
            "--listen-quic", f"0.0.0.0:{self.port}",
            "--data-dir", str(self.data_dir),
            "--log-level", "info"
        ]
        
        if self.verbose:
            print(f"Starting server: {' '.join(cmd)}")
        
        try:
            self.process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            
            # Wait a bit for server to start
            time.sleep(2)
            
            if self.process.poll() is not None:
                stdout, stderr = self.process.communicate()
                raise RuntimeError(f"Server failed to start: {stderr}")
            
            if self.verbose:
                print(f"Server started on port {self.port}")
                
        except Exception as e:
            if self.verbose:
                print(f"Failed to start server: {e}")
            raise
    
    def stop(self) -> None:
        """Stop the server."""
        if self._use_embedded:
            if self.verbose:
                print(f"[Embedded] Server stopped")
            # Cleanup temp dir for embedded mode
            if self.temp_dir:
                import shutil
                try:
                    shutil.rmtree(self.temp_dir)
                except:
                    pass
                self.temp_dir = None
            return
        
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=5)
            except:
                if self.process:
                    self.process.kill()
            self.process = None
        
        # Cleanup temp dir
        if self.temp_dir:
            import shutil
            try:
                shutil.rmtree(self.temp_dir)
            except:
                pass
            self.temp_dir = None
    
    def wait(self) -> None:
        """Wait for server to exit."""
        if self._use_embedded:
            # Just sleep forever until interrupted
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
            return
        
        if self.process:
            self.process.wait()
    
    def is_running(self) -> bool:
        """Check if server is running."""
        if self._use_embedded:
            return True
        return self.process is not None and self.process.poll() is None
    
    @staticmethod
    def stop_by_port(port: int, force: bool = False) -> bool:
        """Stop a server on the given port."""
        # For simulated servers, just return True
        return True
    
    @staticmethod
    def list_servers(port: Optional[int] = None) -> List[Dict[str, Any]]:
        """List running servers."""
        # Return empty list for simulated mode
        return []
