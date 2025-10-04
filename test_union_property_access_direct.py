#!/usr/bin/env python3
"""Direct test runner for UNION property access functionality."""

import subprocess
import json
import os
import time

class UnionPropertyAccessTester:
    def __init__(self):
        self.binary = "/home/benji/src/spyder/geode/zig-out/bin/geodec"
        self.passed = 0
        self.failed = 0
        self.results = []
        
    def run_query(self, query, timeout=10):
        """Execute a query and return the result."""
        try:
            result = subprocess.run(
                [self.binary, query, "--no-quic", "--format", "json"],
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "Query timed out"
        except Exception as e:
            return -1, "", str(e)
    
    def parse_json_response(self, stdout):
        """Parse JSON response from stdout."""
        try:
            lines = stdout.strip().split('\n')
            json_lines = []
            for line in lines:
                line = line.strip()
                if line.startswith('{') and line.endswith('}'):
                    json_lines.append(json.loads(line))
            return json_lines
        except Exception as e:
            return None
    
    def test(self, name, query, expected_status="00000", assertions=None):
        """Run a test case."""
        print(f"\n🧪 Running test: {name}")
        print(f"Query: {query}")
        
        start_time = time.time()
        returncode, stdout, stderr = self.run_query(query)
        execution_time = time.time() - start_time
        
        if returncode != 0:
            print(f"❌ Query failed with return code {returncode}")
            print(f"Stderr: {stderr}")
            self.failed += 1
            self.results.append({"name": name, "status": "FAILED", "reason": f"Return code {returncode}"})
            return False
        
        # Parse JSON response
        json_responses = self.parse_json_response(stdout)
        if not json_responses:
            print(f"❌ Failed to parse JSON response")
            print(f"Stdout: {stdout[:200]}...")
            self.failed += 1
            self.results.append({"name": name, "status": "FAILED", "reason": "Invalid JSON response"})
            return False
        
        # Find BINDINGS response
        bindings_response = None
        schema_response = None
        for response in json_responses:
            if response.get("result", {}).get("type") == "BINDINGS":
                bindings_response = response
            elif response.get("result", {}).get("type") == "SCHEMA":
                schema_response = response
        
        if not bindings_response:
            print(f"❌ No BINDINGS response found")
            self.failed += 1
            self.results.append({"name": name, "status": "FAILED", "reason": "No BINDINGS response"})
            return False
        
        # Check status
        status = bindings_response.get("status_class", "unknown")
        if status != expected_status:
            print(f"❌ Unexpected status: {status} (expected {expected_status})")
            self.failed += 1
            self.results.append({"name": name, "status": "FAILED", "reason": f"Status {status}"})
            return False
        
        # Run custom assertions
        if assertions:
            for assertion in assertions:
                if not assertion(bindings_response, schema_response):
                    print(f"❌ Assertion failed")
                    self.failed += 1
                    self.results.append({"name": name, "status": "FAILED", "reason": "Assertion failed"})
                    return False
        
        print(f"✅ Test passed (executed in {execution_time:.3f}s)")
        print(f"Response: {json.dumps(bindings_response['result'], indent=2)[:200]}...")
        self.passed += 1
        self.results.append({"name": name, "status": "PASSED", "execution_time": execution_time})
        return True
    
    def assert_has_property_values(self, bindings_response, schema_response):
        """Assert that response contains actual property values, not null."""
        rows = bindings_response.get("result", {}).get("rows", [])
        if not rows:
            return False
        
        for row in rows:
            if isinstance(row, list) and len(row) > 0:
                for item in row:
                    if isinstance(item, dict):
                        for key, value in item.items():
                            if value is not None and value != "":
                                return True
        return False
    
    def assert_contains_names(self, bindings_response, schema_response):
        """Assert that response contains actual names like Alice or Bob."""
        rows = bindings_response.get("result", {}).get("rows", [])
        found_names = set()
        
        for row in rows:
            if isinstance(row, list) and len(row) > 0:
                for item in row:
                    if isinstance(item, dict):
                        for key, value in item.items():
                            if isinstance(value, str) and value in ["Alice", "Bob"]:
                                found_names.add(value)
        
        return len(found_names) >= 1
    
    def assert_node_has_properties_field(self, bindings_response, schema_response):
        """Assert that node serialization includes properties field."""
        rows = bindings_response.get("result", {}).get("rows", [])
        
        for row in rows:
            if isinstance(row, list) and len(row) > 0:
                for item in row:
                    if isinstance(item, dict):
                        for key, value in item.items():
                            if isinstance(value, dict) and "properties" in value:
                                return True
        return False
    
    def assert_schema_has_correct_type(self, expected_type):
        """Return a function that asserts schema has correct type."""
        def assertion(bindings_response, schema_response):
            if not schema_response:
                return False
            columns = schema_response.get("result", {}).get("columns", [])
            if not columns:
                return False
            return columns[0].get("type") == expected_type
        return assertion
    
    def run_all_tests(self):
        """Run all UNION property access tests."""
        print("🚀 Starting UNION Property Access Test Suite")
        print("=" * 60)
        
        # Setup data
        print("\n📊 Setting up test data...")
        self.run_query("CREATE (alice:Person {name: 'Alice', age: 30})")
        self.run_query("CREATE (bob:Person {name: 'Bob', age: 25})")
        time.sleep(0.1)  # Brief pause for data to settle
        
        # Test 1: Basic property access
        self.test(
            "basic_property_access",
            "MATCH (n:Person) RETURN n.name",
            assertions=[self.assert_has_property_values, self.assert_contains_names]
        )
        
        # Test 2: Multiple property access
        self.test(
            "multiple_property_access", 
            "MATCH (n:Person) RETURN n.name, n.age",
            assertions=[self.assert_has_property_values]
        )
        
        # Test 3: Full node serialization
        self.test(
            "full_node_serialization",
            "MATCH (n:Person) RETURN n LIMIT 1",
            assertions=[self.assert_node_has_properties_field]
        )
        
        # Test 4: Basic UNION with property access
        self.test(
            "union_property_access",
            "MATCH (n:Person) RETURN n.name UNION MATCH (m:Person) RETURN m.name",
            assertions=[self.assert_has_property_values, self.assert_contains_names]
        )
        
        # Test 5: UNION with aliases
        self.test(
            "union_with_aliases",
            "MATCH (n:Person) RETURN n.name AS person_name UNION MATCH (m:Person) RETURN m.name AS person_name",
            assertions=[self.assert_has_property_values]
        )
        
        # Test 6: UNION multiple properties
        self.test(
            "union_multiple_properties",
            "MATCH (n:Person) RETURN n.name, n.age UNION MATCH (m:Person) RETURN m.name, m.age",
            assertions=[self.assert_has_property_values]
        )
        
        # Test 7: UNION with literals
        self.test(
            "union_with_literals",
            "MATCH (n:Person) RETURN n.name, 'person' AS type UNION MATCH (m:Person) RETURN m.name, 'individual' AS type",
            assertions=[self.assert_has_property_values]
        )
        
        # Test 8: Type inference - STRING
        self.test(
            "string_type_inference",
            "MATCH (n:Person) RETURN n.name AS value UNION MATCH (m:Person) RETURN m.name AS value",
            assertions=[self.assert_schema_has_correct_type("STRING")]
        )
        
        # Test 9: Performance test
        self.test(
            "performance_test",
            "MATCH (a:Person) RETURN a.name UNION MATCH (b:Person) RETURN b.name UNION MATCH (c:Person) RETURN c.name",
            assertions=[self.assert_has_property_values]
        )
        
        # Summary
        print("\n" + "=" * 60)
        print(f"🏁 Test Summary:")
        print(f"✅ Passed: {self.passed}")
        print(f"❌ Failed: {self.failed}")
        print(f"📊 Success Rate: {(self.passed / (self.passed + self.failed) * 100):.1f}%")
        
        if self.failed == 0:
            print("\n🎉 ALL TESTS PASSED! UNION property access is working correctly.")
        else:
            print(f"\n⚠️  {self.failed} tests failed. Details:")
            for result in self.results:
                if result["status"] == "FAILED":
                    print(f"  - {result['name']}: {result['reason']}")
        
        return self.failed == 0

if __name__ == "__main__":
    tester = UnionPropertyAccessTester()
    success = tester.run_all_tests()
    exit(0 if success else 1)