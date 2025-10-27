"""
Geode Python Client - Full QUIC implementation.

This client uses QUIC+TLS for all connections to Geode server.
"""

import asyncio
import json
import ssl
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent, StreamDataReceived

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


class AuthError(GeodeError):
    """Raised when authentication fails."""
    pass


class GeodeProtocol(QuicConnectionProtocol):
    """
    QUIC protocol handler for Geode.

    Manages bidirectional streams for query execution.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._stream_readers: Dict[int, asyncio.Queue] = {}
        self._stream_futures: Dict[int, asyncio.Future] = {}
        self._closed = False

    def quic_event_received(self, event: QuicEvent) -> None:
        """Handle QUIC events."""
        if isinstance(event, StreamDataReceived):
            stream_id = event.stream_id

            # Create queue if not exists
            if stream_id not in self._stream_readers:
                self._stream_readers[stream_id] = asyncio.Queue()

            # Put data in queue
            if event.data:
                self._stream_readers[stream_id].put_nowait(event.data)

            # Mark end of stream
            if event.end_stream:
                self._stream_readers[stream_id].put_nowait(None)

    async def create_bidirectional_stream(self) -> Tuple[int, asyncio.Queue]:
        """
        Create a new bidirectional stream.

        Returns:
            Tuple of (stream_id, reader_queue)
        """
        stream_id = self._quic.get_next_available_stream_id()
        reader_queue = asyncio.Queue()
        self._stream_readers[stream_id] = reader_queue
        return stream_id, reader_queue

    def write_to_stream(self, stream_id: int, data: bytes, end_stream: bool = False) -> None:
        """Write data to a stream."""
        self._quic.send_stream_data(stream_id, data, end_stream)
        self.transmit()

    async def read_from_stream(self, stream_id: int) -> Optional[bytes]:
        """Read data from a stream."""
        if stream_id not in self._stream_readers:
            raise ConnectionError(f"Stream {stream_id} not found")

        data = await self._stream_readers[stream_id].get()
        return data

    def close_stream(self, stream_id: int) -> None:
        """Close a stream."""
        if stream_id in self._stream_readers:
            del self._stream_readers[stream_id]


class Connection:
    """
    A single QUIC connection to Geode server.

    Provides async interface for executing queries, managing transactions,
    and authentication.
    """

    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        port: int = 8443,
        page_size: int = 1000,
        hello_name: str = "geode-python",
        hello_ver: str = "0.1.0",
        conformance: str = "min",
        ca_cert: Optional[str] = None,
        client_cert: Optional[str] = None,
        client_key: Optional[str] = None,
        skip_verify: bool = False,
        server_name: Optional[str] = None,
    ):
        """
        Initialize connection parameters.

        Args:
            host: Server hostname or IP
            port: Server port (default 8443)
            page_size: Default page size for results
            hello_name: Client name for HELLO handshake
            hello_ver: Client version
            conformance: GQL conformance level (min/full)
            ca_cert: Path to CA certificate for server verification
            client_cert: Path to client certificate for mTLS
            client_key: Path to client key for mTLS
            skip_verify: Skip TLS verification (insecure, dev only)
            server_name: SNI server name (defaults to host)
        """
        self.host = host
        self.port = port
        self.page_size = page_size
        self.hello_name = hello_name
        self.hello_ver = hello_ver
        self.conformance = conformance
        self.ca_cert = ca_cert
        self.client_cert = client_cert
        self.client_key = client_key
        self.skip_verify = skip_verify
        self.server_name = server_name or host

        # Connection state
        self._protocol: Optional[GeodeProtocol] = None
        self._stream_id: Optional[int] = None
        self._reader_queue: Optional[asyncio.Queue] = None
        self._connected = False
        self._lock = asyncio.Lock()
        self._buffer = b""

    async def __aenter__(self) -> 'Connection':
        """Async context manager entry."""
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        await self.close()

    async def connect(self) -> None:
        """Establish QUIC connection to Geode server."""
        if self._connected:
            return

        # Configure QUIC
        configuration = QuicConfiguration(
            is_client=True,
            alpn_protocols=["geode/1"],
        )

        # Configure TLS
        if self.ca_cert:
            configuration.load_verify_locations(self.ca_cert)

        if self.skip_verify:
            configuration.verify_mode = ssl.CERT_NONE

        if self.client_cert and self.client_key:
            configuration.load_cert_chain(self.client_cert, self.client_key)

        # Connect
        async with connect(
            self.host,
            self.port,
            configuration=configuration,
            create_protocol=GeodeProtocol,
            server_name=self.server_name,
        ) as protocol:
            self._protocol = protocol

            # Create bidirectional stream
            self._stream_id, self._reader_queue = await protocol.create_bidirectional_stream()

            # Send HELLO
            hello = {
                "type": "HELLO",
                "client_name": self.hello_name,
                "client_ver": self.hello_ver,
                "wanted_conformance": self.conformance,
            }
            await self._write_json(hello)

            # Read HELLO response
            response = await self._read_json()
            if not response:
                raise ConnectionError("No HELLO response from server")

            self._connected = True

            # Keep connection alive
            while self._connected:
                await asyncio.sleep(0.1)

    async def _write_json(self, obj: Dict[str, Any]) -> None:
        """Write JSON object as a line."""
        if not self._protocol or self._stream_id is None:
            raise ConnectionError("Not connected")

        line = json.dumps(obj) + "\n"
        self._protocol.write_to_stream(self._stream_id, line.encode("utf-8"))

    async def _read_line(self) -> bytes:
        """Read a single line from the stream."""
        if not self._protocol or self._stream_id is None:
            raise ConnectionError("Not connected")

        while True:
            # Check if we have a complete line in buffer
            newline_idx = self._buffer.find(b"\n")
            if newline_idx != -1:
                line = self._buffer[:newline_idx]
                self._buffer = self._buffer[newline_idx + 1:]
                return line

            # Read more data
            data = await self._protocol.read_from_stream(self._stream_id)
            if data is None:
                # End of stream
                if self._buffer:
                    line = self._buffer
                    self._buffer = b""
                    return line
                raise ConnectionError("Stream closed")

            self._buffer += data

    async def _read_json(self) -> Dict[str, Any]:
        """Read and parse JSON line."""
        line = await self._read_line()
        if not line:
            return {}
        return json.loads(line)

    async def begin(self) -> None:
        """Begin a transaction."""
        async with self._lock:
            await self._write_json({"type": "BEGIN"})
            await self._read_json()

    async def commit(self) -> None:
        """Commit the current transaction."""
        async with self._lock:
            await self._write_json({"type": "COMMIT"})
            await self._read_json()

    async def rollback(self) -> None:
        """Rollback the current transaction."""
        async with self._lock:
            await self._write_json({"type": "ROLLBACK"})
            await self._read_json()

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

    async def execute(self, text: str, params: Optional[Dict[str, Any]] = None) -> None:
        """
        Execute a query without returning results.

        Useful for CREATE, DELETE, SET operations.

        Args:
            text: GQL query text
            params: Query parameters
        """
        page, _ = await self.query(text, params, page_size=0)

    async def close(self) -> None:
        """Close the connection."""
        if not self._connected:
            return

        self._connected = False

        if self._protocol:
            self._protocol.close()
            self._protocol = None

        self._stream_id = None
        self._reader_queue = None


class Client:
    """
    Geode database client factory.

    Use this to create connections to Geode server.
    """

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 8443,
        **kwargs
    ):
        """
        Initialize client.

        Args:
            host: Server hostname or IP
            port: Server port (default 8443)
            **kwargs: Additional connection parameters
        """
        self.host = host
        self.port = port
        self.config = {
            "host": host,
            "port": port,
            **kwargs
        }

    @classmethod
    def from_url(cls, url: str) -> 'Client':
        """
        Create client from URL.

        URL format: quic://host:port?param=value

        Args:
            url: Connection URL

        Returns:
            Client instance
        """
        parsed = urlparse(url)

        # Extract host and port
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 8443

        # Parse query parameters
        config = {}
        if parsed.query:
            params = parse_qs(parsed.query)

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
            if "server_name" in params:
                config["server_name"] = params["server_name"][0]

        return cls(host, port, **config)

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


def open_database(url: str) -> Client:
    """
    Open a database client from URL.

    Args:
        url: Connection URL (quic://host:port?options)

    Returns:
        Client instance

    Example:
        client = open_database("quic://localhost:8443")
        async with client.connection() as conn:
            page, _ = await conn.query("MATCH (n) RETURN n LIMIT 10")
    """
    return Client.from_url(url)
