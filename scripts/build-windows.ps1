$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Candidates = @(
    $env:MSYS2_ROOT,
    "C:\msys64",
    "C:\tools\msys64"
) | Where-Object { $_ }

$MsysRoot = $Candidates | Where-Object { Test-Path (Join-Path $_ "usr\bin\bash.exe") } | Select-Object -First 1
if (-not $MsysRoot) {
    throw "MSYS2 was not found. Set MSYS2_ROOT or install it in C:\msys64."
}

$Bash = Join-Path $MsysRoot "usr\bin\bash.exe"
$RepoForMsys = (& $Bash -lc "cygpath -u `"$RepoRoot`"").Trim()
if ($LASTEXITCODE -ne 0) { throw "Failed to translate the workspace path for MSYS2." }

& $Bash -lc "cd '$RepoForMsys' && exec ./scripts/build-windows-msys2.sh"
if ($LASTEXITCODE -ne 0) { throw "GDB build failed with exit code $LASTEXITCODE." }
