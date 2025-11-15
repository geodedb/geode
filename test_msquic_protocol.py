#!/usr/bin/env python3
"""Test msquic server with simple protocol exchange."""

import asyncio
import json
import sys
import argparse
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration

async def test_connection(port=3141):
    """Test basic QUIC connection and HELLO exchange."""
    
    # Create QUIC configuration
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=["geode/1"],
    )
    # Skip certificate verification for self-signed certs
    configuration.verify_mode = False
    
    try:
        print(f"Connecting to localhost:{port}...")
        async with connect(
            "localhost",
            port,
            configuration=configuration,
        ) as client:
            print(f"✅ Connected to server")
            print(f"   Local address: {client._quic.host_cid}")
            
            # Give connection a moment to fully establish
            await asyncio.sleep(0.5)
            
            # Open a bidirectional stream
            print(f"Opening bidirectional stream...")
            try:
                reader, writer = await client.create_stream()
                print(f"✅ Stream opened")
                print(f"   Stream ID: {writer._stream_id if hasattr(writer, '_stream_id') else 'unknown'}")
            except Exception as e:
                print(f"❌ Failed to open stream: {e}")
                return False
            
            # Send HELLO message
            hello_msg = json.dumps({"type": "HELLO", "client_name": "test", "client_ver": "1.0"}) + "\n"
            print(f"Sending: {hello_msg.strip()}")
            writer.write(hello_msg.encode())
            
            try:
                await asyncio.wait_for(writer.drain(), timeout=2.0)
                print(f"✅ HELLO sent and drained")
            except asyncio.TimeoutError:
                print(f"❌ Timeout draining write")
                return False
            
            # Wait for response with timeout
            print(f"Waiting for response...")
            try:
                response = await asyncio.wait_for(reader.read(4096), timeout=5.0)
                if response:
                    print(f"✅ Received {len(response)} bytes")
                    print(f"   Raw bytes: {response[:20]}")  # First 20 bytes
                    try:
                        decoded = response.decode()
                        print(f"✅ Decoded: {decoded}")
                    except Exception as e:
                        print(f"❌ Decode error: {e}")
                        print(f"   Full raw: {response}")
                    return True
                else:
                    print(f"❌ Empty response")
                    return False
            except asyncio.TimeoutError:
                print(f"❌ Timeout waiting for response")
                return False
                
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test QUIC connection")
    parser.add_argument("--port", type=int, default=3141, help="Server port")
    args = parser.parse_args()
    
    result = asyncio.run(test_connection(args.port))
    sys.exit(0 if result else 1)
