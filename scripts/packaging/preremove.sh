#!/bin/sh
# Pre-removal script for Geode
# This script runs before the package is uninstalled

set -e

echo "Geode is being removed..."
echo "Note: Data in /var/lib/geode will be preserved."
echo "      Remove manually if no longer needed."
