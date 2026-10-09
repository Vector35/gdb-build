#!/usr/bin/env bash
set -euo pipefail

platform_name="${1:-}"
case "$platform_name" in
    linux|linux-arm|macosx|win64) ;;
    *) echo "usage: $0 {linux|linux-arm|macosx|win64}" >&2; exit 2 ;;
esac

if [[ "$platform_name" == "macosx" && -z "${GDB_MACOS_ARCH:-}" ]]; then
    exec /bin/bash "$(dirname "$0")/build-macos-universal.sh"
fi

if [[ "$platform_name" == "macosx" && "$(uname -m)" == "arm64" && "${GDB_MACOS_ARCH:-x86_64}" != "arm64" && "${GDB_BUILD_UNDER_ROSETTA:-0}" != "1" ]]; then
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
if [[ "$platform_name" == "macosx" && "${GDB_MACOS_ARCH:-}" == "arm64" ]]; then
    build_dir="$repo_root/build/macosx-arm64"
    stage_dir="$repo_root/stage/macosx-arm64"
fi
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

rm -rf "$build_dir" "$stage_dir"
mkdir -p "$download_dir" "$source_dir" "$obj_dir" "$prefix" "$dependencies_prefix"

if [[ "$platform_name" == "win64" ]]; then
    # This MSYS2 installation lives only inside the Jenkins workspace. Hide the
    # import libraries for dependencies that provide static archives, ensuring
    # Autoconf probes and recursive makefiles consistently resolve -lfoo to the
    # static implementation. Hide termcap entirely so GDB selects its MinGW
    # stub, avoiding GNU termcap's conflicting global and DLL annotations.
    for hidden_library in \
        libgmp.dll.a libmpfr.dll.a libtermcap.a libtermcap.dll.a libz.dll.a \
        libtinfow.a libtinfow.dll.a libtinfo.a libtinfo.dll.a \
        libcurses.a libcurses.dll.a libncursesw.a libncursesw.dll.a \
        libncurses.a libncurses.dll.a libpthread.dll.a libwinpthread.dll.a; do
        if [[ -f "/mingw64/lib/$hidden_library" ]]; then
            mv "/mingw64/lib/$hidden_library" "/mingw64/lib/$hidden_library.disabled"
        fi
    done
fi

make_args=()
if [[ "$platform_name" == "win64" ]]; then
    # Keep Readline's objects but let GDB's MinGW termcap stub provide the small
    # API surface needed by the non-TUI MI build. GNU termcap's static archive
    # conflicts with Readline's PC global, while its headers make some GDB
    # translation units expect DLL-imported functions.
    make_args+=("READLINE=../readline/readline/libreadline.a")
fi

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
        local candidate temporary_path
        temporary_path="$(mktemp "$archive_path.partial.XXXXXX")"
        for candidate in "$url" "${url/ftp.gnu.org/mirrors.kernel.org}"; do
            if curl --fail --silent --show-error --location \
                --connect-timeout 10 --max-time 180 --retry 2 \
                --output "$temporary_path" "$candidate"; then
                if [[ "$(sha256_file "$temporary_path")" != "$expected_sha" ]]; then
                    rm -f "$temporary_path"
                    echo "Source SHA-256 mismatch from $candidate" >&2
                    exit 1
                fi
                mv "$temporary_path" "$archive_path"
                break
            fi
            echo "Source download failed from $candidate; trying fallback if available." >&2
        done
        if [[ ! -f "$archive_path" ]]; then
            rm -f "$temporary_path"
            echo "All source download locations failed for $url" >&2
            exit 1
        fi
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
    # Explicit compiler architectures are needed even under Rosetta: recent
    # Xcode tools can otherwise execute their ARM64 slice and emit ARM objects.
    export CC="clang -arch ${GDB_MACOS_ARCH:-x86_64}"
    export CXX="clang++ -arch ${GDB_MACOS_ARCH:-x86_64}"
    export CFLAGS="-arch ${GDB_MACOS_ARCH:-x86_64}"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="$CFLAGS"
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
    if [[ "$platform_name" == "macosx" ]]; then
        # Portable C avoids GMP's older x86 assembly relocation assumptions
        # rejected by recent Apple linkers; GDB does not need tuned arithmetic.
        build_dependency gmp "$GMP_VERSION" "$GMP_SHA256" "--disable-assembly"
    else
        build_dependency gmp "$GMP_VERSION" "$GMP_SHA256"
    fi
    build_dependency mpfr "$MPFR_VERSION" "$MPFR_SHA256" "--with-gmp=$dependencies_prefix"
fi

export CPPFLAGS="-I$dependencies_prefix/include ${CPPFLAGS:-}"
export LDFLAGS="-L$dependencies_prefix/lib ${LDFLAGS:-}"

if [[ "$platform_name" == "win64" ]]; then
    # MinGW provides static archives for the runtime and all selected GDB
    # prerequisites. Keep the embedded Windows payload to one executable.
    export LDFLAGS="-static -static-libgcc -static-libstdc++ $LDFLAGS"
    # The MI build uses GDB's console termcap stub. Library detection alone
    # is insufficient: installed ncurses headers declare tgetnum as dllimport,
    # leaving __imp_tgetnum references even when stub-termcap.o is linked.
    # Keep both configure's library and header decisions consistent with the
    # stub. Export the cache values for GDB's recursive configure invocation.
    export ac_cv_search_tgetent=no
    export ac_cv_header_ncursesw_ncurses_h=no
    export ac_cv_header_ncurses_ncurses_h=no
    export ac_cv_header_ncurses_h=no
    export ac_cv_header_cursesX_h=no
    export ac_cv_header_curses_h=no
    export ac_cv_header_ncurses_term_h=no
    export ac_cv_header_term_h=no
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

if [[ "$platform_name" == "macosx" && "${GDB_MACOS_ARCH:-}" == "arm64" ]]; then
    # Darwin ARM64 has no upstream native backend. A distinct remote target
    # permits a native ARM64 host executable while retaining all remote targets.
    configure_args+=(--target=aarch64-unknown-linux-gnu --program-prefix=)
fi

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
    # Bash 3.2 (Apple's system Bash) treats an empty array as unset under -u.
    make -j"$jobs" ${make_args[@]+"${make_args[@]}"}
    make ${make_args[@]+"${make_args[@]}"} install-strip
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
    --output "$repo_root/artifacts/gdb_${platform_name}${GDB_MACOS_ARCH:+-$GDB_MACOS_ARCH}_${GDB_VERSION}.zip"
