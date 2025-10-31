#!/usr/bin/env python3
"""
Minimal QUIC test to verify basic connectivity
"""
import asyncio
import ssl
from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent, StreamDataReceived


class SimpleProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._response_received = asyncio.Event()
        self._response_data = b""

    def quic_event_received(self, event: QuicEvent):
        if isinstance(event, StreamDataReceived):
            print(f"[CLIENT] Received {len(event.data)} bytes on stream {event.stream_id}")
            self._response_data += event.data
            if event.end_stream:
                self._response_received.set()

    async def send_hello(self):
        """Send a HELLO message."""
        stream_id = self._quic.get_next_available_stream_id()
        hello_msg = '{"type":"HELLO","client_name":"test-python","client_ver":"0.1.0","wanted_conformance":"min"}\n'
        print(f"[CLIENT] Sending on stream {stream_id}: {hello_msg.strip()}")
        self._quic.send_stream_data(stream_id, hello_msg.encode(), end_stream=False)
        self.transmit()

    async def wait_for_response(self, timeout=5.0):
        """Wait for a response."""
        try:
            await asyncio.wait_for(self._response_received.wait(), timeout=timeout)
            return self._response_data
        except asyncio.TimeoutError:
            print(f"[CLIENT] Timeout waiting for response")
            return None


async def main():
    print("="*60)
    print("QUIC Connectivity Test")
    print("="*60)

    # Configure QUIC with correct ALPN
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=["geode/1"],  # IMPORTANT: Must match server
        verify_mode=ssl.CERT_NONE,   # Skip verification for self-signed certs
    )

    host = "127.0.0.1"
    port = 3141

    try:
        print(f"\n1. Connecting to {host}:{port}...")
        async with connect(
            host,
            port,
            configuration=configuration,
            create_protocol=SimpleProtocol,
        ) as protocol:
            protocol = protocol  # type: SimpleProtocol

            print("   ✓ QUIC connection established!")
            print("   ✓ TLS handshake complete!")

            # Send HELLO
            print("\n2. Sending HELLO message...")
            await protocol.send_hello()

            # Wait for response
            print("\n3. Waiting for HELLO response...")
            response = await protocol.wait_for_response()

            if response:
                print(f"   ✓ Received response: {response.decode('utf-8', errors='replace').strip()}")
                print("\n" + "="*60)
                print("✅ SUCCESS: QUIC connectivity test passed!")
                print("="*60)
                return 0
            else:
                print("\n" + "="*60)
                print("⚠️  WARNING: Connection established but no HELLO response")
                print("="*60)
                return 1

    except Exception as e:
        print(f"\n❌ FAILED: {e}")
        import traceback
        traceback.print_exc()
        print("="*60)
        return 1


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    exit(exit_code)
