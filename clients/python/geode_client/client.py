"""
Geode Python Client - Core client implementation with QUIC and process modes.
"""

import asyncio
import json
import os
import ssl
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

try:
    from aioquic.asyncio import connect
    from aioquic.quic.configuration import QuicConfiguration
    HAS_QUIC = True
except ImportError:
    HAS_QUIC = False

from .types import Value, decode_value


@dataclass
class Column:
    """Represents a column in the result set."""
    name: str
    type: str


@dataclass
class Page:
    """Represents a page of query results."""
    columns: List[Column]
    rows: List[Dict[str, Value]]
    ordered: bool = False
    order_keys: List[str] = None
    final: bool = False

    def __post_init__(self):
        if self.order_keys is None:
            self.order_keys = []


class GeodeError(Exception):
    """Base exception for Geode client errors."""
    pass


class ConnectionError(GeodeError):
    """Raised when connection fails."""
    pass


class QueryError(GeodeError):
    """Raised when query execution fails."""
    pass


class Connection:
    """
    A single connection to Geode server.

    Supports both QUIC network mode and process (stdio) mode.
    Not thread-safe - use one connection per async task or thread.
    """

    def __init__(
        self,
        *,
        mode: str = "process",
        path: Optional[str] = None,
        addr: Optional[str] = None,
        page_size: int = 1000,
        hello_name: str = "geode-python",
        hello_ver: str = "0.1",
        conformance: str = "min",
        ca_cert: Optional[str] = None,
        client_cert: Optional[str] = None,
        client_key: Optional[str] = None,
        skip_verify: bool = False,
    ):
        self.mode = mode
        self.path = path or os.getenv("GEODE_SERVER_PATH", "./zig-out/bin/geode")
        self.addr = addr or "127.0.0.1:8443"
        self.page_size = page_size
        self.hello_name = hello_name
        self.hello_ver = hello_ver
        self.conformance = conformance
        self.ca_cert = ca_cert
        self.client_cert = client_cert
        self.client_key = client_key
        self.skip_verify = skip_verify

        # Connection state
        self._process: Optional[subprocess.Popen] = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._connected = False
        self._lock = asyncio.Lock()

    async def __aenter__(self) -> 'Connection':
        """Async context manager entry."""
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        await self.close()

    async def connect(self) -> None:
        """Establish connection to Geode server."""
        if self._connected:
            return

        if self.mode == "quic":
            await self._connect_quic()
        else:
            await self._connect_process()

        # Send HELLO message
        hello = {
            "type": "HELLO",
            "client_name": self.hello_name,
            "client_ver": self.hello_ver,
            "wanted_conformance": self.conformance,
        }
        await self._write_json(hello)
        # Read and discard HELLO response
        await self._read_line()
        self._connected = True

    async def _connect_process(self) -> None:
        """Connect in process mode (stdio)."""
        path = Path(self.path)
        if not path.is_absolute():
            path = Path.cwd() / path

        # Check if executable exists, try to build if not
        if not path.exists():
            build_result = subprocess.run(
                ["zig", "build"],
                cwd=path.parent.parent.parent,
                capture_output=True,
            )
            if build_result.returncode != 0 or not path.exists():
                raise ConnectionError(f"Geode executable not found: {path}")

        # Start process with stdio
        self._process = await asyncio.create_subprocess_exec(
            str(path),
            "serve",
            "--stdio",
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._reader = self._process.stdout
        self._writer = self._process.stdin

    async def _connect_quic(self) -> None:
        """Connect in QUIC mode."""
        if not HAS_QUIC:
            raise ConnectionError(
                "QUIC support requires aioquic library. "
                "Install with: pip install aioquic"
            )

        # Parse address
        if "://" not in self.addr:
            addr = f"quic://{self.addr}"
        else:
            addr = self.addr

        parsed = urlparse(addr)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 8443

        # Configure TLS
        config = QuicConfiguration(
            is_client=True,
            alpn_protocols=["geode/1"],
        )

        if self.ca_cert:
            config.load_verify_locations(self.ca_cert)
        if self.client_cert and self.client_key:
            config.load_cert_chain(self.client_cert, self.client_key)
        if self.skip_verify:
            config.verify_mode = ssl.CERT_NONE

        # Connect via QUIC
        async with connect(host, port, configuration=config) as protocol:
            # Open bidirectional stream
            reader, writer = await protocol.create_stream()
            self._reader = reader
            self._writer = writer

    async def _write_json(self, obj: Dict[str, Any]) -> None:
        """Write JSON object as a line."""
        if not self._writer:
            raise ConnectionError("Not connected")

        line = json.dumps(obj) + "\n"
        self._writer.write(line.encode("utf-8"))
        await self._writer.drain()

    async def _read_line(self) -> bytes:
        """Read a single line from the connection."""
        if not self._reader:
            raise ConnectionError("Not connected")

        line = await self._reader.readline()
        return line.rstrip(b"\n")

    async def _read_json(self) -> Dict[str, Any]:
        """Read and parse JSON line."""
        line = await self._read_line()
        return json.loads(line)

    async def begin(self) -> None:
        """Begin a transaction."""
        async with self._lock:
            await self._write_json({"type": "BEGIN"})
            await self._read_line()

    async def commit(self) -> None:
        """Commit the current transaction."""
        async with self._lock:
            await self._write_json({"type": "COMMIT"})
            await self._read_line()

    async def rollback(self) -> None:
        """Rollback the current transaction."""
        async with self._lock:
            await self._write_json({"type": "ROLLBACK"})
            await self._read_line()

    async def query(
        self,
        text: str,
        params: Optional[Dict[str, Any]] = None,
        page_size: Optional[int] = None,
    ) -> Tuple[Page, Callable[[], AsyncIterator[Page]]]:
        """
        Execute a GQL query and return the first page and a pager function.

        Args:
            text: GQL query text
            params: Query parameters
            page_size: Page size for results (default: connection page_size)

        Returns:
            Tuple of (first_page, pager_function)

        Example:
            page, pager = await conn.query("MATCH (n) RETURN n LIMIT 100")
            # Process first page
            for row in page.rows:
                print(row)
            # Get more pages
            async for next_page in pager():
                for row in next_page.rows:
                    print(row)
        """
        async with self._lock:
            if page_size is None:
                page_size = self.page_size

            # Send RUN_GQL message
            run_msg = {"type": "RUN_GQL", "text": text}
            if params:
                run_msg["params"] = params

            await self._write_json(run_msg)

            # Read schema frame
            schema_frame = await self._read_json()
            result = schema_frame.get("result", {})

            if result.get("type") == "ERROR":
                code = result.get("code", "UNKNOWN")
                message = result.get("message", "Query failed")
                raise QueryError(f"{code}: {message}")

            if result.get("type") != "SCHEMA":
                raise QueryError(f"Unexpected frame type: {result.get('type')}")

            # Parse columns
            columns = [
                Column(name=col["name"], type=col["type"])
                for col in result.get("columns", [])
            ]
            type_map = {col.name: col.type for col in columns}

            # Send PULL to get first page
            await self._write_json({
                "type": "PULL",
                "request_id": 1,
                "page_size": page_size,
            })

            bindings_frame = await self._read_json()
            bindings_result = bindings_frame.get("result", {})

            if bindings_result.get("type") == "PROFILE":
                # Empty result set when profiling
                first_page = Page(
                    columns=columns,
                    rows=[],
                    ordered=False,
                    final=True,
                )
                async def empty_pager():
                    return
                    yield  # Make it a generator

                return first_page, empty_pager

            if bindings_result.get("type") != "BINDINGS":
                raise QueryError(f"Unexpected frame type: {bindings_result.get('type')}")

            # Parse first page
            rows = self._parse_rows(bindings_result.get("rows", []), type_map)
            first_page = Page(
                columns=columns,
                rows=rows,
                ordered=bindings_result.get("ordered", False),
                order_keys=bindings_result.get("order_keys", []),
                final=bindings_result.get("final", False),
            )

            # Create pager function
            async def pager():
                nonlocal first_page
                while not first_page.final:
                    async with self._lock:
                        await self._write_json({
                            "type": "PULL",
                            "request_id": 1,
                            "page_size": page_size,
                        })
                        frame = await self._read_json()
                        result = frame.get("result", {})

                        if result.get("type") == "ERROR":
                            break

                        if result.get("type") != "BINDINGS":
                            break

                        rows = self._parse_rows(result.get("rows", []), type_map)
                        page = Page(
                            columns=columns,
                            rows=rows,
                            ordered=result.get("ordered", False),
                            order_keys=result.get("order_keys", []),
                            final=result.get("final", False),
                        )

                        if page.final:
                            first_page.final = True

                        yield page

            return first_page, pager

    def _parse_rows(
        self,
        raw_rows: List[Dict[str, Any]],
        type_map: Dict[str, str],
    ) -> List[Dict[str, Value]]:
        """Parse raw JSON rows into typed Value objects."""
        rows = []
        for raw_row in raw_rows:
            row = {}
            for col_name, raw_value in raw_row.items():
                col_type = type_map.get(col_name, "")
                row[col_name] = decode_value(raw_value, col_type)
            rows.append(row)
        return rows

    async def close(self) -> None:
        """Close the connection."""
        if not self._connected:
            return

        try:
            if self._writer:
                self._writer.close()
                await self._writer.wait_closed()
        except Exception:
            pass

        if self._process:
            try:
                self._process.terminate()
                await asyncio.wait_for(self._process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                self._process.kill()
                await self._process.wait()

        self._connected = False
        self._reader = None
        self._writer = None
        self._process = None


class Client:
    """
    Geode database client factory.

    Use this to create connections to Geode server.
    """

    def __init__(self, dsn: str = ""):
        """
        Initialize client with DSN.

        DSN formats:
            - process:<path>?page_size=1000
            - quic:<host:port>?page_size=1000&ca_cert=path

        Args:
            dsn: Data source name
        """
        self.config = self._parse_dsn(dsn)

    def _parse_dsn(self, dsn: str) -> Dict[str, Any]:
        """Parse DSN into configuration."""
        config = {
            "mode": "process",
            "path": "./zig-out/bin/geode",
            "addr": "127.0.0.1:8443",
            "page_size": 1000,
            "hello_name": "geode-python",
            "hello_ver": "0.1",
            "conformance": "min",
            "skip_verify": False,
        }

        if not dsn:
            if path := os.getenv("GEODE_SERVER_PATH"):
                config["path"] = path
            return config

        # Parse DSN
        if dsn.startswith("process:"):
            config["mode"] = "process"
            rest = dsn[8:]
            if "?" in rest:
                path, query = rest.split("?", 1)
                config["path"] = path
                self._apply_query_params(config, query)
            else:
                config["path"] = rest

        elif dsn.startswith("quic:"):
            config["mode"] = "quic"
            rest = dsn[5:].lstrip("/")
            if "?" in rest:
                addr, query = rest.split("?", 1)
                config["addr"] = addr or "127.0.0.1:8443"
                self._apply_query_params(config, query)
            else:
                config["addr"] = rest or "127.0.0.1:8443"

        return config

    def _apply_query_params(self, config: Dict[str, Any], query: str) -> None:
        """Apply query parameters to config."""
        params = parse_qs(query)

        if "page_size" in params:
            config["page_size"] = int(params["page_size"][0])
        if "hello_name" in params:
            config["hello_name"] = params["hello_name"][0]
        if "hello_ver" in params:
            config["hello_ver"] = params["hello_ver"][0]
        if "conformance" in params:
            config["conformance"] = params["conformance"][0]
        if "ca_cert" in params:
            config["ca_cert"] = params["ca_cert"][0]
        if "client_cert" in params:
            config["client_cert"] = params["client_cert"][0]
        if "client_key" in params:
            config["client_key"] = params["client_key"][0]
        if "skip_verify" in params:
            config["skip_verify"] = params["skip_verify"][0].lower() in ("1", "true")

    async def connect(self) -> Connection:
        """Create and connect a new connection."""
        conn = Connection(**self.config)
        await conn.connect()
        return conn

    def connection(self) -> Connection:
        """
        Create a connection (not yet connected).

        Use with async context manager:
            async with client.connection() as conn:
                page, _ = await conn.query("RETURN 1")
        """
        return Connection(**self.config)


def open_database(dsn: str = "") -> Client:
    """
    Open a database client.

    Args:
        dsn: Data source name

    Returns:
        Client instance

    Example:
        client = open_database("quic:localhost:8443")
        async with client.connection() as conn:
            page, _ = await conn.query("MATCH (n) RETURN n LIMIT 10")
    """
    return Client(dsn)
