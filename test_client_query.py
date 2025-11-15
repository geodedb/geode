#!/usr/bin/env python3
"""Test Python client with actual query."""

import asyncio
import sys
from pathlib import Path

# Add Python client to path
sys.path.insert(0, str(Path(__file__).parent / "clients" / "python"))

from geode_client import Client

async def test_query():
    """Test simple query."""
    
    client = Client(
        host="localhost",
        port=9999,
        skip_verify=True
    )
    
    try:
        print("Connecting...")
        connection = await client.connect()
        print("✓ Connected")
        
        print("Running query: RETURN 1 AS x")
        page, _ = await connection.query("RETURN 1 AS x")
        
        print(f"✓ Got {len(page.rows)} row(s)")
        print(f"  Columns: {[col.name for col in page.columns]}")
        for row in page.rows:
            print(f"  Data: {dict((col.name, row[col.name].raw_value) for col in page.columns)}")
        
        await connection.close()
        print("✓ Test passed")
        return True
        
    except Exception as e:
        print(f"✗ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    result = asyncio.run(test_query())
    sys.exit(0 if result else 1)
