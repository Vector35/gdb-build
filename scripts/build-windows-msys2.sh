#!/usr/bin/env bash
set -euo pipefail

if [[ "${MSYSTEM:-}" != "MINGW64" ]]; then
    exec /usr/bin/env MSYSTEM=MINGW64 CHERE_INVOKING=1 /usr/bin/bash -l "$0" "$@"
fi

pacman --noconfirm --needed -S \
    base-devel \
    mingw-w64-x86_64-gcc \
    mingw-w64-x86_64-gmp \
    mingw-w64-x86_64-mpfr \
    mingw-w64-x86_64-expat \
    mingw-w64-x86_64-libiconv \
    mingw-w64-x86_64-python \
    mingw-w64-x86_64-readline \
    mingw-w64-x86_64-xz \
    mingw-w64-x86_64-zstd \
    curl tar xz

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/mingw64/bin:$PATH"
exec "$repo_root/scripts/build-posix.sh" win64
