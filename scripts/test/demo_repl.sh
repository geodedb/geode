#!/bin/bash

# Demo script showing REPL usage
echo "==================================="
echo "Geode REPL Demo"
echo "==================================="
echo ""
echo "Starting the Geode shell..."
echo ""
echo "When the shell opens, you'll see:"
echo "1. A welcome banner with version info"
echo "2. Quick commands to get started"
echo "3. Tips for using the shell"
echo ""
echo "Try these commands:"
echo "  \\help     - Show all available commands"
echo "  RETURN 1; - Execute a simple GQL query"
echo "  \\quit     - Exit the shell"
echo ""
echo "Press Enter to start the shell..."
read

./zig-out/bin/geode shell