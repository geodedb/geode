#!/usr/bin/env python3
"""Simple QUIC client test for debugging TLS handshake issues"""

import asyncio
import ssl
from pathlib import Path
import logging

try:
    from aioquic.asyncio import connect
    from aioquic.quic.configuration import QuicConfiguration
except ImportError:
    print("Installing aioquic...")
    import subprocess
    subprocess.check_call(["pip", "install", "aioquic"])
    from aioquic.asyncio import connect
    from aioquic.quic.configuration import QuicConfiguration

# Enable debug logging
logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    level=logging.DEBUG,
)


async def test_connection():
    """Test QUIC connection to Geode server"""

    # Configure QUIC client
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=["h3", "hq-interop", "hq-29"],
    )

    # Allow self-signed certificates for testing
    configuration.verify_mode = ssl.CERT_NONE

    print("Connecting to localhost:7567...")

    try:
        async with connect(
            "localhost",
            7567,
            configuration=configuration,
            create_protocol=lambda *args: QuicProtocol(*args),
        ) as protocol:
            print("Connected! Handshake completed.")

            # Try to open a stream
            stream_id = protocol._quic.get_next_available_stream_id()
            print(f"Opened stream {stream_id}")

            # Send a simple message
            data = b"RETURN 1 AS test"
            protocol._quic.send_stream_data(stream_id, data, end_stream=True)

            # Wait for response
            await asyncio.sleep(2)

            print("Test completed successfully!")

    except Exception as e:
        print(f"Connection failed: {e}")
        import traceback
        traceback.print_exc()


class QuicProtocol(asyncio.DatagramProtocol):
    """Simple QUIC protocol handler"""

    def __init__(self, *args, **kwargs):
        super().__init__()
        self._quic = None

    def connection_made(self, transport):
        print("UDP connection established")

    def datagram_received(self, data, addr):
        print(f"Received {len(data)} bytes from {addr}")

    def error_received(self, exc):
        print(f"Error: {exc}")


if __name__ == "__main__":
    asyncio.run(test_connection())