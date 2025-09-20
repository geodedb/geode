package gql

import (
	"flag"
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	// Parse flags to ensure proper test setup
	flag.Parse()
	
	// Run tests
	code := m.Run()
	
	// Ensure clean exit
	os.Exit(code)
}
