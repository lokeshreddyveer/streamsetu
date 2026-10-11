#!/bin/bash
# Writes SHA-256 checksums next to the release artifacts.
set -euo pipefail
cd "$(dirname "$0")/../dist"
shasum -a 256 *.dmg > SHA256SUMS.txt
cat SHA256SUMS.txt
