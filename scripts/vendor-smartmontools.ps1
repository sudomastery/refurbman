<#
.SYNOPSIS
    Fetch the pinned smartmontools release and place smartctl where RefurbMan
    looks for it.

.DESCRIPTION
    The version and its checksums come from third_party/smartmontools/pinned.env,
    so there is one place to change them and the shell script cannot disagree
    with this one.

    A download whose checksum does not match is deleted rather than used. A
    silently substituted smartctl would report drive health nobody could account
    for, which is the one thing this project must never do.

    The source tarball is always fetched, because that is what satisfies the
    GPL-2.0 written offer. See third_party/smartmontools/SOURCE-OFFER.md.

.PARAMETER SourceOnly
    Fetch only the source tarball, not the binaries.

.EXAMPLE
    .\scripts\vendor-smartmontools.ps1
#>

[CmdletBinding()]
param([switch]$SourceOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vendor = Join-Path $root 'third_party/smartmontools'
$pinned = Join-Path $vendor 'pinned.env'

if (-not (Test-Path $pinned)) { throw "missing $pinned" }

# pinned.env is shell syntax, but it is deliberately plain KEY=VALUE so that
# both scripts can read the same file without either owning the format.
$pin = @{}
foreach ($line in (Get-Content $pinned)) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $pin[$k.Trim()] = $v.Trim()
}

$version = $pin['SMARTMONTOOLS_VERSION']
$base    = "$($pin['SMARTMONTOOLS_BASE_URL'])/$version"
$src     = Join-Path $vendor 'src'
$bin     = Join-Path $vendor 'bin/windows-x86_64'
New-Item -ItemType Directory -Force -Path $src, $bin | Out-Null

function Get-Verified {
    param([string]$Url, [string]$Dest, [string]$Expected)

    if (Test-Path $Dest) {
        $have = (Get-FileHash $Dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($have -eq $Expected) {
            Write-Host "  already have $(Split-Path -Leaf $Dest)"
            return
        }
        Write-Host "  re-downloading $(Split-Path -Leaf $Dest): checksum did not match"
        Remove-Item $Dest -Force
    }

    Write-Host "  downloading $(Split-Path -Leaf $Dest)"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    } catch {
        if (Test-Path $Dest) { Remove-Item $Dest -Force }
        throw "could not download $Url : $($_.Exception.Message)"
    }

    $got = (Get-FileHash $Dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $Expected) {
        Remove-Item $Dest -Force
        throw "checksum mismatch for $(Split-Path -Leaf $Dest)`n  expected $Expected`n  got      $got"
    }
    Write-Host "  verified $(Split-Path -Leaf $Dest)"
}

Write-Host ''
Write-Host "smartmontools $version"
Write-Host ''

# --- source, always ----------------------------------------------------------
$srcTgz = Join-Path $src "smartmontools-$version.tar.gz"
Get-Verified "$base/smartmontools-$version.tar.gz/download" $srcTgz $pin['SMARTMONTOOLS_SOURCE_SHA256']

if ($SourceOnly) {
    Write-Host ''
    Write-Host "Source is at $srcTgz"
    return
}

# --- Windows binary ----------------------------------------------------------
$winExe = Join-Path $src "smartmontools-$version.win32-setup.exe"
Get-Verified "$base/smartmontools-$version.win32-setup.exe/download" $winExe $pin['SMARTMONTOOLS_WIN32_SHA256']

Write-Host '  unpacking the Windows build'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # The installer is NSIS. /S installs silently; /D sets the target and must
    # be last and unquoted, which is an NSIS convention rather than a typo.
    $p = Start-Process -FilePath $winExe -ArgumentList '/S', "/D=$tmp" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "the installer exited with $($p.ExitCode)" }

    # drivedb.h has to travel with smartctl: without it, vendor-specific SMART
    # attributes lose their meaning and health figures go subtly wrong.
    foreach ($file in @('smartctl.exe', 'drivedb.h')) {
        $found = Get-ChildItem -Path $tmp -Filter $file -Recurse -File |
                 Where-Object { $_.DirectoryName -notmatch 'bin32' } |
                 Select-Object -First 1
        if (-not $found) { throw "the installer did not contain $file" }
        Copy-Item $found.FullName (Join-Path $bin $file) -Force
    }
    Write-Host '  placed smartctl.exe and drivedb.h in bin/windows-x86_64'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Source for the GPL offer: $srcTgz"
Write-Host "Licence and offer:        $(Join-Path $vendor 'SOURCE-OFFER.md')"
Write-Host ''
