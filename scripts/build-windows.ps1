$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Versions = @{}
Get-Content (Join-Path $RepoRoot "versions.env") | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.+)$') { $Versions[$Matches[1]] = $Matches[2] }
}
$Candidates = @(
    $env:MSYS2_ROOT,
    "C:\msys64",
    "C:\tools\msys64"
) | Where-Object { $_ }

$MsysRoot = $Candidates | Where-Object { Test-Path (Join-Path $_ "usr\bin\bash.exe") } | Select-Object -First 1
if (-not $MsysRoot) {
    $BootstrapParent = Join-Path $RepoRoot "build"
    $MsysRoot = Join-Path $BootstrapParent "msys64"
    $DownloadDir = Join-Path $RepoRoot "downloads"
    $ReleaseCompact = $Versions.MSYS2_RELEASE.Replace("-", "")
    $ArchiveName = "msys2-base-x86_64-$ReleaseCompact.sfx.exe"
    $Archive = Join-Path $DownloadDir $ArchiveName
    New-Item -ItemType Directory -Force -Path $BootstrapParent, $DownloadDir | Out-Null
    if (-not (Test-Path $Archive)) {
        $Url = "https://github.com/msys2/msys2-installer/releases/download/$($Versions.MSYS2_RELEASE)/$ArchiveName"
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive
    }
    $ActualSha = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
    if ($ActualSha -ne $Versions.MSYS2_SHA256) {
        throw "MSYS2 archive SHA-256 mismatch: expected $($Versions.MSYS2_SHA256), got $ActualSha"
    }
    & $Archive -y "-o$BootstrapParent"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $MsysRoot "usr\bin\bash.exe"))) {
        throw "Failed to extract the pinned MSYS2 environment."
    }
}

$Bash = Join-Path $MsysRoot "usr\bin\bash.exe"
$RepoForMsys = (& $Bash -lc "cygpath -u `"$RepoRoot`"").Trim()
if ($LASTEXITCODE -ne 0) { throw "Failed to translate the workspace path for MSYS2." }

& $Bash -lc "cd '$RepoForMsys' && exec ./scripts/build-windows-msys2.sh"
if ($LASTEXITCODE -ne 0) { throw "GDB build failed with exit code $LASTEXITCODE." }
