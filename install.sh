#!/bin/sh
# Installs blackoutd by building from source on the current machine.
# Requires Xcode Command Line Tools: xcode-select --install

set -e
cd "$(dirname "$0")"
make reinstall
echo "==> Done. Use 'blackoutd status' to verify."
