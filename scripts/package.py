#!/usr/bin/env python3
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
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


def verify_linux(executable, lib_dir):
    dependencies = run("ldd", str(executable))
    unexpected = []
    for line in dependencies.splitlines():
        if "=> " in line:
            name, path = line.strip().split("=> ", 1)
            if path.startswith("not found") or not SYSTEM_LINUX.search(name.strip()):
                unexpected.append(line.strip())
    if unexpected or any(lib_dir.glob("*.so*")):
        raise SystemExit("Linux GDB must not require bundled shared libraries:\n" + "\n".join(unexpected))


def mac_dependencies(binary):
    deps = []
    for line in run("otool", "-L", str(binary)).splitlines()[1:]:
        if line.endswith(":"):
            continue  # Universal binaries repeat a header for each slice.
        value = line.strip().split(" (compatibility", 1)[0]
        if value.startswith(("/System/", "/usr/lib/", "@")):
            continue
        if value.startswith("/"):
            deps.append(pathlib.Path(value))
    return deps


def bundle_macos(executable, lib_dir):
    if re.search(r"lib(?:gmp|mpfr)[^/\s]*\.dylib", run("otool", "-L", str(executable))):
        raise SystemExit("macOS GDB must link GMP and MPFR statically")
    if any(lib_dir.glob("libgmp*.dylib")) or any(lib_dir.glob("libmpfr*.dylib")):
        raise SystemExit("Remove stale GMP/MPFR dylibs from the macOS staging tree")
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


def sign_macos(executable, lib_dir):
    # Support the standalone archive, the legacy Helpers layout, and MacOS/plugins.
    for library in sorted(lib_dir.glob("*.dylib")):
        subprocess.check_call([
            "install_name_tool", "-change", f"@executable_path/../lib/{library.name}",
            f"@rpath/{library.name}", str(executable),
        ])
    load_commands = run("otool", "-l", str(executable))
    rpaths = ("@executable_path/../lib", "@executable_path/../Frameworks",
              "@executable_path/../../Frameworks") if any(lib_dir.glob("*.dylib")) else ()
    for rpath in rpaths:
        if f"path {rpath} (offset" not in load_commands:
            subprocess.check_call(["install_name_tool", "-add_rpath", rpath, str(executable)])
    identity = os.environ.get("GDB_CODESIGN_IDENTITY", "Developer ID")
    for binary in [*sorted(lib_dir.glob("*.dylib")), executable]:
        command = ["codesign", "--force", "--options", "runtime", "--sign", identity]
        command.append("--timestamp=none" if identity == "-" else "--timestamp")
        subprocess.check_call([*command, str(binary)])
        subprocess.check_call(["codesign", "--verify", "--strict", str(binary)])


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


def verify_relocated_data_directory(archive_path, executable_name, platform):
    # Run the actual packaged executable from a different prefix, without
    # --data-directory, exactly as the Linux and Windows adapters launch it.
    with tempfile.TemporaryDirectory() as directory:
        with zipfile.ZipFile(archive_path) as archive:
            archive.extractall(directory)
        root = pathlib.Path(directory) / "GDB"
        executable = root / "bin" / executable_name
        executable.chmod(0o755)
        data_directory = root / "share" / "gdb"
        commands = ["-ex", "show data-directory"]
        is_linux = platform.startswith("linux")
        arm64 = platform == "linux-arm"
        syscall_table = "aarch64-linux.xml" if arm64 else "amd64-linux.xml"
        if is_linux:
            architecture = "aarch64" if arm64 else "i386:x86-64"
            commands += ["-ex", f"set architecture {architecture}", "-ex", "catch syscall openat"]
        output = run(str(executable), "--nx", "--quiet", "--batch", *commands)
        match = re.search(r'data directory is "([^"]+)"', output)
        if (not (data_directory / "syscalls" / syscall_table).is_file()
                or not match or not pathlib.Path(match[1]).samefile(data_directory)
                or (is_linux and not re.search(r"Catchpoint .*openat", output))):
            raise SystemExit("GDB could not find relocated syscall XML:\n" + output)
        print(output, end="")



def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    executable = args.root / "bin" / ("gdb.exe" if args.platform == "win64" else "gdb")
    if not executable.exists():
        raise SystemExit(f"missing GDB executable: {executable}")

    lib_dir = args.root / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    if args.platform.startswith("linux"):
        verify_linux(executable, lib_dir)
    elif args.platform == "macosx":
        bundle_macos(executable, lib_dir)
    elif args.platform == "win64":
        bundle_windows(executable, executable.parent)

    if args.platform == "macosx":
        sign_macos(executable, lib_dir)

    smoke = subprocess.run(
        [str(executable), "--nx", "--quiet", "--interpreter=mi2"],
        input="-gdb-version\n-gdb-exit\n", text=True, capture_output=True, timeout=30,
    )
    if smoke.returncode != 0 or "^done" not in smoke.stdout or f"GDB) {args.version}" not in smoke.stdout:
        print(smoke.stdout, file=sys.stderr)
        print(smoke.stderr, file=sys.stderr)
        raise SystemExit("GDB MI2 smoke test failed")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    pending = args.output.with_suffix(".zip.tmp")
    with zipfile.ZipFile(pending, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(args.root.rglob("*")):
            if not path.is_file():
                continue
            relative = pathlib.Path("GDB") / path.relative_to(args.root)
            info = zipfile.ZipInfo(relative.as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info.external_attr = mode << 16
            archive.writestr(info, path.read_bytes())
    if args.platform.startswith("linux") or args.platform == "win64":
        verify_relocated_data_directory(pending, executable.name, args.platform)
    pending.replace(args.output)
    print(args.output)


if __name__ == "__main__":
    main()
