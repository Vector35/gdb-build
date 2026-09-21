#!/usr/bin/env bash
set -euo pipefail

platform_name="${1:-}"
case "$platform_name" in
    linux|linux-arm|macosx|win64) ;;
    *) echo "usage: $0 {linux|linux-arm|macosx|win64}" >&2; exit 2 ;;
esac

if [[ "$platform_name" == "macosx" && "$(uname -m)" == "arm64" && "${GDB_BUILD_UNDER_ROSETTA:-0}" != "1" ]]; then
    # Configure must be able to execute its host probes. Re-exec the complete build under
    # Rosetta instead of attempting an Autoconf cross-build from arm64 to x86_64.
    exec /usr/bin/env GDB_BUILD_UNDER_ROSETTA=1 /usr/bin/arch -x86_64 /bin/bash "$0" "$@"
fi

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
dependencies_prefix="$build_dir/dependencies"

if [[ "$platform_name" == "win64" ]]; then
    # The pinned MSYS2 environment provides a matched MinGW toolchain and development
    # packages. Reuse those packages instead of rebuilding GMP/MPFR with a compiler
    # newer than their configure-time compiler probes understand.
    dependencies_prefix="/mingw64"
fi

make_args=()
if [[ "$platform_name" == "win64" ]]; then
    # GDB's generated makefiles otherwise replace these with plain -l options,
    # which select the MSYS2 import libraries even when LDFLAGS contains -static.
    make_args+=(
        "GMPLIBS=/mingw64/lib/libmpfr.a /mingw64/lib/libgmp.a"
        "PTHREAD_LIBS=/mingw64/lib/libwinpthread.a"
        "READLINE=../readline/readline/libreadline.a /mingw64/lib/libtermcap.a"
        "ZLIB=/mingw64/lib/libz.a"
    )
fi

rm -rf "$build_dir" "$stage_dir"
mkdir -p "$download_dir" "$source_dir" "$obj_dir" "$prefix" "$dependencies_prefix"

sha256_file() {
    python3 - "$1" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open('rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
print(h.hexdigest())
PY
}

download_and_verify() {
    local url="$1" archive_path="$2" expected_sha="$3"
    if [[ ! -f "$archive_path" ]]; then
        curl --fail --location --retry 3 --output "$archive_path" "$url"
    fi
    local actual_sha
    actual_sha="$(sha256_file "$archive_path")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "Source SHA-256 mismatch for $archive_path: expected $expected_sha, got $actual_sha" >&2
        exit 1
    fi
}

download_and_verify "https://ftp.gnu.org/gnu/gdb/gdb-$GDB_VERSION.tar.xz" "$archive" "$GDB_SHA256"

tar -xf "$archive" --strip-components=1 -C "$source_dir"

if [[ "$platform_name" == "macosx" ]]; then
    # Upstream GDB does not support an aarch64-apple-darwin host. Build the supported
    # x86_64 host executable on Apple Silicon; downstream macOS systems run it via Rosetta.
    # Avoid inheriting Homebrew's native-arm compiler and library flags in the Rosetta process.
    unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    unset PKG_CONFIG_PATH
    patch -d "$source_dir" -p1 < "$repo_root/patches/gdb-17.2-darwin-common-inferior.patch"
fi

jobs="${GDB_BUILD_JOBS:-}"
if [[ -z "$jobs" ]]; then
    if command -v nproc >/dev/null 2>&1; then jobs="$(nproc)"; else jobs="$(sysctl -n hw.logicalcpu)"; fi
fi

build_dependency() {
    local name="$1" version="$2" sha="$3" configure_extra="${4:-}"
    local dep_archive="$download_dir/$name-$version.tar.xz"
    local dep_source="$build_dir/$name-source"
    local dep_obj="$build_dir/$name-obj"
    download_and_verify "https://ftp.gnu.org/gnu/$name/$name-$version.tar.xz" "$dep_archive" "$sha"
    mkdir -p "$dep_source" "$dep_obj"
    tar -xf "$dep_archive" --strip-components=1 -C "$dep_source"
    # configure_extra is controlled by this script and intentionally split into arguments.
    # shellcheck disable=SC2086
    if [[ "$platform_name" == "win64" ]]; then
        (cd "$dep_obj" && "$dep_source/configure" \
            --build=x86_64-w64-mingw32 --host=x86_64-w64-mingw32 \
            --prefix="$dependencies_prefix" --disable-shared --enable-static $configure_extra \
            && make -j"$jobs" && make install)
    elif [[ "$platform_name" == "macosx" ]]; then
        # Shared prerequisites record their dependency install names on Darwin and avoid
        # static-link probe failures; package.py relocates both dylibs beside GDB.
        (cd "$dep_obj" && "$dep_source/configure" \
            --prefix="$dependencies_prefix" --enable-shared --disable-static $configure_extra \
            && make -j"$jobs" && make install)
    else
        (cd "$dep_obj" && "$dep_source/configure" \
            --prefix="$dependencies_prefix" --disable-shared --enable-static $configure_extra \
            && make -j"$jobs" && make install)
    fi
}

if [[ "$platform_name" != "win64" ]]; then
    build_dependency gmp "$GMP_VERSION" "$GMP_SHA256"
    build_dependency mpfr "$MPFR_VERSION" "$MPFR_SHA256" "--with-gmp=$dependencies_prefix"
fi

export CPPFLAGS="-I$dependencies_prefix/include ${CPPFLAGS:-}"
export LDFLAGS="-L$dependencies_prefix/lib ${LDFLAGS:-}"

if [[ "$platform_name" == "win64" ]]; then
    # MinGW provides static archives for the runtime and all selected GDB
    # prerequisites. Keep the embedded Windows payload to one executable.
    export LDFLAGS="-static -static-libgcc -static-libstdc++ $LDFLAGS"
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
    --disable-tui
    --disable-werror
    --with-python=no
    --with-guile=no
    --without-babeltrace
    "--with-gmp=$dependencies_prefix"
    "--with-mpfr=$dependencies_prefix"
)

if [[ "$platform_name" == "win64" ]]; then
    configure_args+=(
        --build=x86_64-w64-mingw32
        --host=x86_64-w64-mingw32
        --with-static-standard-libraries
    )
fi

(
    cd "$obj_dir"
    if ! "$source_dir/configure" "${configure_args[@]}"; then
        echo "GDB configure failed; final config.log diagnostics follow:" >&2
        tail -200 config.log >&2 || true
        exit 1
    fi
    make -j"$jobs"
    if [[ "$platform_name" == "win64" ]]; then
        # The top-level recursive make supplies its configured dependency values
        # explicitly to the GDB submake. Relink in that subdirectory so these
        # full static-archive paths cannot be replaced by import-library flags.
        rm -f "$obj_dir/gdb/gdb.exe"
        make -C "$obj_dir/gdb" -j"$jobs" V=1 "${make_args[@]}" gdb.exe
    fi
    make "${make_args[@]}" install-strip
)

# Keep the embedded payload runtime-only. The build produces several development libraries,
# headers, manuals, and helper scripts that are not used by the MI adapter.
rm -rf "$prefix/include" "$prefix/share/info" "$prefix/share/man"
find "$prefix/lib" -type f \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true
if [[ "$platform_name" == "win64" ]]; then
    find "$prefix/bin" -maxdepth 1 -type f ! -name 'gdb.exe' -delete
else
    find "$prefix/bin" -maxdepth 1 -type f ! -name 'gdb' -delete
fi

cp "$source_dir/COPYING" "$prefix/COPYING"
python3 "$repo_root/scripts/package.py" \
    --platform "$platform_name" \
    --version "$GDB_VERSION" \
    --source-sha256 "$GDB_SHA256" \
    --root "$prefix" \
    --output "$repo_root/artifacts/gdb_${platform_name}_${GDB_VERSION}.zip"
