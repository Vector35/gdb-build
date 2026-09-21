#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile


SYSTEM_LINUX = re.compile(r"(^|/)(ld-linux|libc\.|libdl\.|libm\.|libpthread\.|libresolv\.|librt\.)")


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def copy_once(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        shutil.copy2(source, destination)
        return True
    return False


def bundle_linux(executable, lib_dir):
    if not shutil.which("patchelf"):
        raise SystemExit("patchelf is required to create a relocatable Linux archive")
    queue = [executable]
    seen = set()
    while queue:
        binary = queue.pop(0)
        for line in run("ldd", str(binary)).splitlines():
            match = re.search(r"=>\s+(/\S+)", line)
            if not match:
                continue
            dep = pathlib.Path(match.group(1))
            if SYSTEM_LINUX.search(str(dep)) or dep in seen:
                continue
            seen.add(dep)
            bundled = lib_dir / dep.name
            if copy_once(dep, bundled):
                queue.append(bundled)
        rpath = "$ORIGIN/../lib" if binary == executable else "$ORIGIN"
        subprocess.check_call(["patchelf", "--set-rpath", rpath, str(binary)])


def mac_dependencies(binary):
    deps = []
    for line in run("otool", "-L", str(binary)).splitlines()[1:]:
        value = line.strip().split(" (compatibility", 1)[0]
        if value.startswith(("/System/", "/usr/lib/", "@")):
            continue
        if value.startswith("/"):
            deps.append(pathlib.Path(value))
    return deps


def bundle_macos(executable, lib_dir):
    queue = [executable]
    seen = set()
    while queue:
        binary = queue.pop(0)
        for dep in mac_dependencies(binary):
            bundled = lib_dir / dep.name
            subprocess.check_call([
                "install_name_tool", "-change", str(dep),
                f"@executable_path/../lib/{dep.name}" if binary == executable else f"@loader_path/{dep.name}",
                str(binary),
            ])
            if dep not in seen:
                seen.add(dep)
                if copy_once(dep, bundled):
                    subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{dep.name}", str(bundled)])
                    queue.append(bundled)


def find_windows_dll(name):
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidate = pathlib.Path(entry) / name
        if candidate.exists():
            return candidate
    return None


def is_windows_system_dll(path):
    windows_dir = os.environ.get("WINDIR")
    if not windows_dir:
        return False
    try:
        path.resolve().relative_to(pathlib.Path(windows_dir).resolve())
        return True
    except ValueError:
        return False


def bundle_windows(executable, bin_dir):
    system = {
        "advapi32.dll", "bcrypt.dll", "kernel32.dll", "kernelbase.dll",
        "msvcrt.dll", "ntdll.dll", "shell32.dll", "ucrtbase.dll", "user32.dll",
        "ws2_32.dll",
    }
    external = []
    output = run("objdump", "-p", str(executable))
    for name in re.findall(r"DLL Name:\s*(\S+)", output, re.IGNORECASE):
        lower = name.lower()
        if lower in system or lower.startswith(("api-ms-win-", "ext-ms-win-")):
            continue
        source = find_windows_dll(name)
        if source is not None and is_windows_system_dll(source):
            continue
        external.append(name)
    if external:
        raise SystemExit(
            "Windows GDB is not fully runtime-static; external DLL imports: "
            + ", ".join(sorted(external, key=str.lower))
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    executable = args.root / "bin" / ("gdb.exe" if args.platform == "win64" else "gdb")
    if not executable.exists():
        raise SystemExit(f"missing GDB executable: {executable}")

    lib_dir = args.root / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    if args.platform.startswith("linux"):
        bundle_linux(executable, lib_dir)
    elif args.platform == "macosx":
        bundle_macos(executable, lib_dir)
    elif args.platform == "win64":
        bundle_windows(executable, executable.parent)

    version_output = run(str(executable), "--version").splitlines()[0]
    manifest = {
        "gdb_version": args.version,
        "platform": args.platform,
        "source_sha256": args.source_sha256,
        "version_output": version_output,
    }
    (args.root / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    smoke = subprocess.run(
        [str(executable), "--nx", "--quiet", "--interpreter=mi2"],
        input="-gdb-version\n-gdb-exit\n", text=True, capture_output=True, timeout=30,
    )
    if smoke.returncode != 0 or "^done" not in smoke.stdout:
        print(smoke.stdout, file=sys.stderr)
        print(smoke.stderr, file=sys.stderr)
        raise SystemExit("GDB MI2 smoke test failed")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(args.root.rglob("*")):
            if not path.is_file():
                continue
            relative = pathlib.Path("gdb") / path.relative_to(args.root)
            info = zipfile.ZipInfo(relative.as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info.external_attr = mode << 16
            archive.writestr(info, path.read_bytes())
    print(args.output)


if __name__ == "__main__":
    main()
