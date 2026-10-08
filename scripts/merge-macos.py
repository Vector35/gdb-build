"""Merge tested host slices; ARM64 is remote-only, x86_64 retains Darwin native support."""
import pathlib
import shutil
import subprocess

repo = pathlib.Path(__file__).resolve().parents[1]
arm = repo / 'stage/macosx-arm64/gdb'
x86 = repo / 'stage/macosx/gdb'
destination = repo / 'stage/macosx-universal/gdb'
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(arm, destination)
for relative in [pathlib.Path('bin/gdb'), *[p.relative_to(arm) for p in (arm / 'lib').glob('*.dylib')]]:
    subprocess.run(['/usr/bin/lipo', '-create', str(arm / relative), str(x86 / relative),
                    '-output', str(destination / relative)], check=True)
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(destination / relative)], text=True).split()
    if set(architectures) != {'arm64', 'x86_64'}:
        raise RuntimeError(f'Unexpected slices in {relative}: {architectures}')
for architecture in ('arm64', 'x86_64'):
    result = subprocess.run(['/usr/bin/arch', f'-{architecture}', str(destination / 'bin/gdb'),
                             '-q', '-nx', '--interpreter=mi2'],
                            input='-gdb-version\n-gdb-exit\n', text=True,
                            capture_output=True, timeout=30, check=True)
    if '^done' not in result.stdout or '17.2' not in result.stdout:
        raise RuntimeError(f'{architecture} MI smoke test failed')
versions = dict(line.split('=', 1) for line in (repo / 'versions.env').read_text().splitlines()
                if line and not line.startswith('#') and '=' in line)
subprocess.run(['python3', str(repo / 'scripts/package.py'), '--platform', 'macosx',
                '--version', versions['GDB_VERSION'], '--source-sha256', versions['GDB_SHA256'],
                '--root', str(destination), '--output',
                str(repo / f"artifacts/gdb_macosx_{versions['GDB_VERSION']}.zip")], check=True)
