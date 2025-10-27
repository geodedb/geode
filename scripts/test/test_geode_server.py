#!/usr/bin/env python3

import subprocess
import time
import os
import tempfile
import socket
from pathlib import Path

def find_free_port():
    """Find a free port to use for testing."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port

def test_geode_basic():
    """Test basic Geode server functionality."""
    
    # Find free port
    port = find_free_port()
    
    # Create temporary data directory
    with tempfile.TemporaryDirectory() as temp_dir:
        print(f"Using temporary directory: {temp_dir}")
        print(f"Using port: {port}")
        
        # Start server
        geode_binary = "/home/benji/src/spyder/geode/zig-out/bin/geode"
        server_cmd = [
            geode_binary, "serve",
            "--data-dir", temp_dir,
            "--listen", f"0.0.0.0:{port}",
            "--log-level", "info"
        ]
        
        print(f"Starting server: {' '.join(server_cmd)}")
        server_process = subprocess.Popen(
            server_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        try:
            # Wait for server to start
            time.sleep(3)
            
            # Check if server is still running
            if server_process.poll() is not None:
                stdout, stderr = server_process.communicate()
                print(f"Server failed to start!")
                print(f"STDOUT: {stdout}")
                print(f"STDERR: {stderr}")
                return False
            
            print("Server started successfully!")
            
            # Try to connect with client
            client_cmd = [
                geode_binary, "query",
                "--server", f"localhost:{port}",
                "--format", "json",
                "RETURN 1 AS test"
            ]
            
            print(f"Running query: {' '.join(client_cmd)}")
            try:
                result = subprocess.run(
                    client_cmd,
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                
                print(f"Query exit code: {result.returncode}")
                print(f"Query STDOUT: {result.stdout}")
                print(f"Query STDERR: {result.stderr}")
                
                if result.returncode == 0:
                    print("✅ Basic query test passed!")
                    return True
                else:
                    print("❌ Basic query test failed!")
                    return False
                    
            except subprocess.TimeoutExpired:
                print("❌ Query timed out!")
                return False
            except Exception as e:
                print(f"❌ Query failed with exception: {e}")
                return False
                
        finally:
            # Clean up server
            print("Stopping server...")
            server_process.terminate()
            try:
                server_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server_process.kill()
                server_process.wait()
            
            # Get any final output
            stdout, stderr = server_process.communicate()
            if stdout:
                print(f"Server final STDOUT: {stdout}")
            if stderr:
                print(f"Server final STDERR: {stderr}")

if __name__ == "__main__":
    print("🧪 Testing Geode server functionality...")
    success = test_geode_basic()
    if success:
        print("🎉 All tests passed!")
    else:
        print("💥 Tests failed!")
    exit(0 if success else 1)