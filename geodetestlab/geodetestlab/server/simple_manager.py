"""Simple server lifecycle management for GeodeTestLab.

This module provides functionality to start, manage, and stop Geode server
instances for testing purposes.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional


class ServerManager:
    """Manages a Geode server instance for testing."""

    def __init__(
        self,
        binary_path: str,
        port: Optional[int] = None,
        data_dir: Optional[str] = None,
        startup_timeout_ms: int = 60000,
        cleanup: bool = True,
        args: Optional[list] = None,
        env: Optional[Dict[str, str]] = None,
        verbose: bool = False,
    ):
        """Initialize the server manager.

        Args:
            binary_path: Path to the geode binary
            port: Port to bind the server to (auto-allocated if None)
            data_dir: Data directory for the server (temporary if None)
            startup_timeout_ms: Maximum time to wait for server startup
            cleanup: Whether to cleanup data directory on shutdown
            args: Additional arguments to pass to the server
            env: Environment variables to set for the server process
            verbose: Whether to print server logs
        """
        self.binary_path = binary_path
        self.port = port or self._find_free_port()
        self.data_dir = data_dir
        self.startup_timeout_ms = startup_timeout_ms
        self.cleanup = cleanup
        self.args = args or []
        self.env = env or {}
        self.verbose = verbose
        self.process: Optional[subprocess.Popen] = None
        self._temp_dir: Optional[tempfile.TemporaryDirectory] = None

    def _find_free_port(self) -> int:
        """Find an available port on the system."""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(('', 0))
            s.listen(1)
            port = s.getsockname()[1]
        return port

    def start(self) -> str:
        """Start the Geode server.

        Returns:
            The server address (host:port)

        Raises:
            RuntimeError: If the server fails to start
        """
        # Setup data directory
        if self.data_dir is None:
            self._temp_dir = tempfile.TemporaryDirectory()
            self.data_dir = self._temp_dir.name

        # Prepare server command
        cmd = [
            self.binary_path,
            'serve',
            '--listen', f'0.0.0.0:{self.port}',
            '--data-dir', self.data_dir,
        ] + self.args

        # Prepare environment
        server_env = os.environ.copy()
        server_env.update(self.env)

        # Start the server process
        try:
            stdout = None if self.verbose else subprocess.DEVNULL
            stderr = None if self.verbose else subprocess.DEVNULL

            self.process = subprocess.Popen(
                cmd,
                stdout=stdout,
                stderr=stderr,
                env=server_env,
                preexec_fn=os.setsid if os.name != 'nt' else None,
            )
        except FileNotFoundError:
            raise RuntimeError(f"Geode binary not found: {self.binary_path}")
        except Exception as e:
            raise RuntimeError(f"Failed to start server: {e}")

        # Wait for server to become ready
        server_address = f"127.0.0.1:{self.port}"
        timeout_seconds = self.startup_timeout_ms / 1000
        start_time = time.time()

        while time.time() - start_time < timeout_seconds:
            # Check if process is still running
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"Server process exited with code {self.process.returncode}"
                )

            # Try to connect to the server port
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.settimeout(1)
                    s.sendto(b'', ('127.0.0.1', self.port))
                    # If we can send to the UDP port, assume server is ready
                    # (QUIC servers listen on UDP)
                    time.sleep(0.5)  # Give server a moment to fully initialize
                    return server_address
            except (socket.timeout, OSError):
                pass

            time.sleep(0.1)

        # Timeout reached
        self.stop()
        raise RuntimeError(
            f"Server failed to start within {timeout_seconds}s"
        )

    def stop(self):
        """Stop the Geode server and cleanup resources."""
        if self.process:
            try:
                # Try graceful shutdown first
                if os.name != 'nt':
                    os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
                else:
                    self.process.terminate()

                # Wait for process to exit
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # Force kill if graceful shutdown fails
                    if os.name != 'nt':
                        os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
                    else:
                        self.process.kill()
                    self.process.wait()
            except Exception:
                pass

            self.process = None

        # Cleanup temporary directory
        if self.cleanup and self._temp_dir:
            try:
                self._temp_dir.cleanup()
            except Exception:
                pass
            self._temp_dir = None

    def is_running(self) -> bool:
        """Check if the server is currently running."""
        return self.process is not None and self.process.poll() is None

    def __enter__(self):
        """Context manager entry."""
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.stop()
