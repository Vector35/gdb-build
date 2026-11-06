#!/usr/bin/env bash
set -euo pipefail

if [[ "${MSYSTEM:-}" != "MINGW64" ]]; then
    exec /usr/bin/env MSYSTEM=MINGW64 CHERE_INVOKING=1 /usr/bin/bash -l "$0" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pacman_config="$repo_root/build/pacman-official.conf"
mkdir -p "$(dirname "$pacman_config")"
# Use the official server directly rather than the geo-redirector or third-party
# mirrors. Keep the installation's signature policy and other settings intact,
# and do not modify a potentially shared MSYS2 installation's configuration.
sed -E \
    -e 's@^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/pacman.d/mirrorlist.mingw[[:space:]]*$@Server = https://repo.msys2.org/mingw/$repo/@' \
    -e 's@^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/pacman.d/mirrorlist.msys[[:space:]]*$@Server = https://repo.msys2.org/msys/$arch/@' \
    /etc/pacman.conf > "$pacman_config"
if grep -Eq '^[[:space:]]*Include[[:space:]]*=' "$pacman_config" \
    || grep -E '^[[:space:]]*(CacheServer|Server)[[:space:]]*=' "$pacman_config" \
        | grep -Eqv '^[[:space:]]*(CacheServer|Server)[[:space:]]*=[[:space:]]*https://repo\.msys2\.org/'; then
    echo "Unexpected package source in MSYS2 configuration; refusing non-official mirrors." >&2
    exit 1
fi
echo "Installing MSYS2 dependencies from https://repo.msys2.org only."
pacman --config "$pacman_config" --noconfirm --needed -S \
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

export PATH="/mingw64/bin:$PATH"
exec "$repo_root/scripts/build-posix.sh" win64
