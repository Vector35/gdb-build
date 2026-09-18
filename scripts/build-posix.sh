#!/usr/bin/env bash
set -euo pipefail

platform_name="${1:-}"
case "$platform_name" in
    linux|linux-arm|macosx|win64) ;;
    *) echo "usage: $0 {linux|linux-arm|macosx|win64}" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$repo_root/versions.env"

download_dir="$repo_root/downloads"
build_dir="$repo_root/build/$platform_name"
stage_dir="$repo_root/stage/$platform_name"
archive="$download_dir/gdb-$GDB_VERSION.tar.xz"
source_dir="$build_dir/source"
obj_dir="$build_dir/obj"
prefix="$stage_dir/gdb"

rm -rf "$build_dir" "$stage_dir"
mkdir -p "$download_dir" "$source_dir" "$obj_dir" "$prefix"

if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 3 \
        --output "$archive" "https://ftp.gnu.org/gnu/gdb/gdb-$GDB_VERSION.tar.xz"
fi

actual_sha="$(python3 - "$archive" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open('rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
print(h.hexdigest())
PY
)"
if [[ "$actual_sha" != "$GDB_SHA256" ]]; then
    echo "GDB source SHA-256 mismatch: expected $GDB_SHA256, got $actual_sha" >&2
    exit 1
fi

tar -xf "$archive" --strip-components=1 -C "$source_dir"

if [[ "$platform_name" == "macosx" ]] && command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix)"
    export CPPFLAGS="-I$brew_prefix/include ${CPPFLAGS:-}"
    export LDFLAGS="-L$brew_prefix/lib ${LDFLAGS:-}"
    export PKG_CONFIG_PATH="$brew_prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

jobs="${GDB_BUILD_JOBS:-}"
if [[ -z "$jobs" ]]; then
    if command -v nproc >/dev/null 2>&1; then jobs="$(nproc)"; else jobs="$(sysctl -n hw.logicalcpu)"; fi
fi

configure_args=(
    "--prefix=$prefix"
    --enable-targets=all
    --disable-binutils
    --disable-gas
    --disable-gprof
    --disable-ld
    --disable-sim
    --disable-gdbserver
    --disable-nls
    --disable-source-highlight
    --disable-werror
    --with-python=no
    --with-guile=no
    --without-babeltrace
)

if [[ "$platform_name" == "win64" ]]; then
    configure_args+=(--build=x86_64-w64-mingw32 --host=x86_64-w64-mingw32)
fi

(
    cd "$obj_dir"
    "$source_dir/configure" "${configure_args[@]}"
    make -j"$jobs"
    make install-strip
)

cp "$source_dir/COPYING" "$prefix/COPYING"
python3 "$repo_root/scripts/package.py" \
    --platform "$platform_name" \
    --version "$GDB_VERSION" \
    --source-sha256 "$GDB_SHA256" \
    --root "$prefix" \
    --output "$repo_root/artifacts/gdb_${platform_name}_${GDB_VERSION}.zip"
