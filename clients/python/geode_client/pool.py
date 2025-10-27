"""
Connection pooling for Geode connections.
"""

import asyncio
from typing import AsyncIterator, Optional

from .client import Client, Connection


class ConnectionPool:
    """
    Asynchronous connection pool for Geode.

    Example:
        pool = ConnectionPool(
            dsn="quic:localhost:8443",
            min_size=2,
            max_size=10,
        )
        await pool.initialize()

        async with pool.acquire() as conn:
            page, _ = await conn.query("RETURN 1")

        await pool.close()
    """

    def __init__(
        self,
        dsn: str = "",
        min_size: int = 2,
        max_size: int = 10,
        timeout: float = 30.0,
    ):
        """
        Initialize connection pool.

        Args:
            dsn: Data source name
            min_size: Minimum number of connections to maintain
            max_size: Maximum number of connections
            timeout: Timeout for acquiring a connection (seconds)
        """
        self.client = Client(dsn)
        self.min_size = min_size
        self.max_size = max_size
        self.timeout = timeout

        self._pool: asyncio.Queue[Connection] = asyncio.Queue(maxsize=max_size)
        self._size = 0
        self._lock = asyncio.Lock()
        self._closed = False

    async def initialize(self) -> None:
        """Initialize the pool by creating minimum connections."""
        for _ in range(self.min_size):
            conn = await self._create_connection()
            await self._pool.put(conn)

    async def _create_connection(self) -> Connection:
        """Create a new connection."""
        async with self._lock:
            if self._size >= self.max_size:
                raise RuntimeError("Connection pool is full")
            self._size += 1

        try:
            conn = await self.client.connect()
            return conn
        except Exception:
            async with self._lock:
                self._size -= 1
            raise

    async def acquire(self) -> Connection:
        """
        Acquire a connection from the pool.

        Returns:
            Connection from pool

        Raises:
            asyncio.TimeoutError: If timeout is reached
            RuntimeError: If pool is closed
        """
        if self._closed:
            raise RuntimeError("Connection pool is closed")

        try:
            # Try to get an existing connection
            conn = self._pool.get_nowait()
            return conn
        except asyncio.QueueEmpty:
            pass

        # No connection available, try to create a new one
        if self._size < self.max_size:
            return await self._create_connection()

        # Wait for a connection to become available
        return await asyncio.wait_for(self._pool.get(), timeout=self.timeout)

    async def release(self, conn: Connection) -> None:
        """
        Release a connection back to the pool.

        Args:
            conn: Connection to release
        """
        if self._closed:
            await conn.close()
            async with self._lock:
                self._size -= 1
            return

        try:
            self._pool.put_nowait(conn)
        except asyncio.QueueFull:
            # Pool is full, close the connection
            await conn.close()
            async with self._lock:
                self._size -= 1

    async def close(self) -> None:
        """Close all connections in the pool."""
        if self._closed:
            return

        self._closed = True

        # Close all connections
        connections = []
        while not self._pool.empty():
            try:
                conn = self._pool.get_nowait()
                connections.append(conn)
            except asyncio.QueueEmpty:
                break

        # Close all connections concurrently
        await asyncio.gather(
            *[conn.close() for conn in connections],
            return_exceptions=True,
        )

        self._size = 0

    async def __aenter__(self) -> 'ConnectionPool':
        """Async context manager entry."""
        await self.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        await self.close()

    def connection(self) -> 'PoolConnection':
        """
        Get a connection context manager.

        Example:
            async with pool.connection() as conn:
                page, _ = await conn.query("RETURN 1")
        """
        return PoolConnection(self)


class PoolConnection:
    """Context manager for pool connections."""

    def __init__(self, pool: ConnectionPool):
        self.pool = pool
        self.conn: Optional[Connection] = None

    async def __aenter__(self) -> Connection:
        """Acquire connection from pool."""
        self.conn = await self.pool.acquire()
        return self.conn

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Release connection back to pool."""
        if self.conn:
            await self.pool.release(self.conn)
            self.conn = None
