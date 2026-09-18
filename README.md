# GDB build

Reproducible native builds of GNU GDB for Linux, macOS, and Windows. The
result is a relocatable archive suitable for embedding in another application.

The source version and SHA-256 are pinned in `versions.env`. Builds deliberately
disable Python, Guile, source-highlight, and code signing to keep the runtime
small and deterministic. Signing and notarization belong in the downstream
product pipeline.

## Outputs

Each build produces `artifacts/gdb_<platform>_<version>.zip`. Archives have the
same layout on every host:

```
gdb/
  COPYING
  bin/gdb[.exe]
  lib/                 # non-system runtime libraries, when needed
  share/gdb/
  build-manifest.json
```

Supported platform names are `linux`, `linux-arm`, `macosx`, and `win64`.
The macOS archive currently contains an x86_64 executable because upstream GDB
does not support an `aarch64-apple-darwin` host; it runs on Apple Silicon through
Rosetta and remains suitable for MI-based remote debugging.

## Local builds

Linux and macOS:

```sh
./scripts/build-posix.sh linux    # or linux-arm / macosx
```

The POSIX build expects a C/C++ toolchain, GNU make, Python 3, xz, and the GDB
development dependencies (GMP, MPFR, expat, readline, xz, and zstd). Packaging
uses `patchelf` on Linux and the Xcode command-line tools on macOS.

Windows builds run in MSYS2's MINGW64 environment:

```powershell
./scripts/build-windows.ps1
```

The PowerShell entry point locates an existing MSYS2 installation, installs the
required MinGW packages with `pacman`, and invokes the shared build logic. It
does not require or perform code signing.

## Jenkins

`Jenkinsfile` defines a parameterized matrix build. Configure a Pipeline from
SCM pointing at this repository and leave the script path as `Jenkinsfile`.
The job only checks out this public repository, builds on the selected native
workers, verifies the resulting executable with `--version` and a short MI2
smoke test, and archives the platform zip.

GDB itself is licensed under GPLv3; each archive includes GDB's `COPYING` file.
The build orchestration in this repository is MIT licensed.
