[CmdletBinding()]
param(
  [string]$Prefix = $env:PREFIX,
  [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "[install.ps1] $Message" -ForegroundColor DarkGray
}

function Throw-Error {
  param([Parameter(Mandatory)][string]$Message)
  throw "[install.ps1] ERROR: $Message"
}

function Get-RepoRoot {
  return $PSScriptRoot
}

function Test-WritableDirectory {
  param([Parameter(Mandatory)][string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $test = Join-Path $Path (".bin-install-write-test-{0}.tmp" -f $PID)
    New-Item -ItemType File -Path $test -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $test -Force -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Get-PathEntries {
  $entries = @()
  $sep = [System.IO.Path]::PathSeparator
  foreach ($p in ($env:PATH -split [Regex]::Escape($sep))) {
    $t = $p.Trim()
    if (-not $t) { continue }
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $entries += $t
  }
  return $entries | Select-Object -Unique
}

function Get-DefaultPrefix {
  $pathEntries = Get-PathEntries
  foreach ($candidate in $pathEntries) {
    if (Test-WritableDirectory -Path $candidate) { return $candidate }
  }
  return $null
}

function Get-WindowsCommandScripts {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $scripts = @()
  foreach ($dir in (Get-ChildItem -LiteralPath $RepoRoot -Directory -ErrorAction Stop)) {
    foreach ($f in (Get-ChildItem -LiteralPath $dir.FullName -File -Filter "*.ps1" -ErrorAction Stop)) {
      if ($f.Name.StartsWith(".")) { continue }
      $scripts += $f
    }
  }
  return $scripts
}

function Get-WrapperContent {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$TargetPs1
  )

  $marker = "rem managed by jakestanley/bin install.ps1"
  $escaped = $TargetPs1.Replace('"', '""')
  @(
    "@echo off"
    $marker
    "setlocal"
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"$escaped`" %*"
  ) -join "`r`n"
}

function Install-Wrappers {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Prefix
  )

  if (-not (Test-Path -LiteralPath $Prefix)) {
    New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
  }

  $scripts = @(Get-WindowsCommandScripts -RepoRoot $RepoRoot)
  if ($scripts.Count -eq 0) {
    Write-Log "no Windows command scripts found under $RepoRoot\\*\\*.ps1"
    return
  }

  $seen = @{}
  foreach ($s in $scripts) {
    $cmd = [System.IO.Path]::GetFileNameWithoutExtension($s.Name)
    if ($seen.ContainsKey($cmd)) { Throw-Error "duplicate command name detected: $cmd" }
    $seen[$cmd] = $true

    $dest = Join-Path $Prefix ("{0}.cmd" -f $cmd)
    $content = Get-WrapperContent -RepoRoot $RepoRoot -TargetPs1 $s.FullName

    if (Test-Path -LiteralPath $dest) {
      $existing = Get-Content -LiteralPath $dest -Raw -ErrorAction SilentlyContinue
      if ($existing -and ($existing -like "*managed by jakestanley/bin install.ps1*")) {
        Set-Content -LiteralPath $dest -Value $content -NoNewline -Encoding Ascii
        Write-Log ("updated: {0} -> {1}" -f $dest, $s.FullName)
      } else {
        Write-Log ("skip (not managed): {0}" -f $dest)
      }
    } else {
      Set-Content -LiteralPath $dest -Value $content -NoNewline -Encoding Ascii
      Write-Log ("installed: {0} -> {1}" -f $dest, $s.FullName)
    }
  }
}

function Uninstall-Wrappers {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Prefix
  )

  if (-not (Test-Path -LiteralPath $Prefix)) { return }

  foreach ($f in (Get-ChildItem -LiteralPath $Prefix -File -Filter "*.cmd" -ErrorAction Stop)) {
    $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    if ($content -notlike "*managed by jakestanley/bin install.ps1*") { continue }
    if ($content -notlike "*$RepoRoot*") { continue }
    Remove-Item -LiteralPath $f.FullName -Force
    Write-Log ("removed: {0}" -f $f.FullName)
  }
}

$repoRoot = $PSScriptRoot

if (-not $Prefix) {
  $Prefix = Get-DefaultPrefix
}
if (-not $Prefix) {
  Throw-Error "no writable directory found in PATH; pass -Prefix (a writable directory already on PATH)"
}

if ($Uninstall) {
  Uninstall-Wrappers -RepoRoot $repoRoot -Prefix $Prefix
  exit 0
}

Install-Wrappers -RepoRoot $repoRoot -Prefix $Prefix
