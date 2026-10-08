#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'Universal macOS builds require an Apple Silicon worker with Rosetta.' >&2
    exit 1
fi
GDB_MACOS_ARCH=arm64 /bin/bash "$repo_root/scripts/build-posix.sh" macosx
GDB_MACOS_ARCH=x86_64 /bin/bash "$repo_root/scripts/build-posix.sh" macosx
python3 "$repo_root/scripts/merge-macos.py"
