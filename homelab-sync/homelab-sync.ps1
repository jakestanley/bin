[CmdletBinding()]
param(
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "[homelab-sync] $Message" -ForegroundColor DarkGray
}

function Throw-Error {
  param([Parameter(Mandatory)][string]$Message)
  throw "[homelab-sync] ERROR: $Message"
}

function Require-Command {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Throw-Error "missing command: $Name"
  }
}

function Import-DotEnv {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    Throw-Error "missing $Path (copy .env.example -> .env and fill it in)"
  }

  $map = @{}
  foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
    $t = $line.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t.StartsWith("#")) { continue }

    $idx = $t.IndexOf("=")
    if ($idx -lt 1) { continue }

    $key = $t.Substring(0, $idx).Trim()
    $value = $t.Substring($idx + 1).Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    } elseif ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $map[$key] = $value
  }
  return $map
}

function Invoke-Run {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter()][string[]]$Args = @(),
    [Parameter()][string]$WorkingDirectory = ""
  )

  $display = @($FilePath) + $Args
  if ($WorkingDirectory) {
    Write-Log ("+ (cd {0}) {1}" -f $WorkingDirectory, ($display -join " "))
  } else {
    Write-Log ("+ {0}" -f ($display -join " "))
  }

  if ($DryRun) { return }

  if ($WorkingDirectory) {
    Push-Location -LiteralPath $WorkingDirectory
    try {
      & $FilePath @Args
    } finally {
      Pop-Location
    }
  } else {
    & $FilePath @Args
  }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string[]]$Args
  )
  Invoke-Run -FilePath "git" -Args (@("-C", $RepoDir) + $Args)
  if (-not $DryRun -and $LASTEXITCODE -ne 0) {
    Throw-Error ("git failed in {0}: git {1}" -f $RepoDir, ($Args -join " "))
  }
}

function Git-Output {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string[]]$Args
  )
  $out = & git -C $RepoDir @Args 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($out | Out-String).TrimEnd()
}

function GitPathExists {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string]$GitPath
  )
  $p = Git-Output -RepoDir $RepoDir -Args @("rev-parse", "--git-path", $GitPath)
  if (-not $p) { return $false }
  return (Test-Path -LiteralPath $p)
}

function Ensure-RepoReady {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string]$RepoName,
    [Parameter(Mandatory)][string]$Remote
  )

  $inside = Git-Output -RepoDir $RepoDir -Args @("rev-parse", "--is-inside-work-tree")
  if (-not $inside) { Throw-Error "$RepoName is not a git repository: $RepoDir" }

  $remoteUrl = Git-Output -RepoDir $RepoDir -Args @("remote", "get-url", $Remote)
  if (-not $remoteUrl) { Throw-Error "${RepoName}: missing git remote '$Remote'" }

  $headRef = Git-Output -RepoDir $RepoDir -Args @("symbolic-ref", "-q", "HEAD")
  if (-not $headRef) { Throw-Error "${RepoName}: detached HEAD (check out a branch first)" }

  if ((GitPathExists -RepoDir $RepoDir -GitPath "rebase-apply") -or
      (GitPathExists -RepoDir $RepoDir -GitPath "rebase-merge") -or
      (GitPathExists -RepoDir $RepoDir -GitPath "MERGE_HEAD") -or
      (GitPathExists -RepoDir $RepoDir -GitPath "CHERRY_PICK_HEAD") -or
      (GitPathExists -RepoDir $RepoDir -GitPath "REVERT_HEAD")) {
    Throw-Error "${RepoName}: repository has an in-progress operation (rebase/merge/cherry-pick/revert)"
  }

  $dirty = Git-Output -RepoDir $RepoDir -Args @("status", "--porcelain")
  if ($dirty -and $dirty.Trim().Length -gt 0) {
    Write-Log "${RepoName}: uncommitted changes detected:"
    Write-Host $dirty
    Throw-Error "${RepoName}: commit/stash/clean changes and retry"
  }
}

function Sync-Repo {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string]$RepoName,
    [Parameter(Mandatory)][string]$Remote
  )

  $branch = Git-Output -RepoDir $RepoDir -Args @("rev-parse", "--abbrev-ref", "HEAD")
  if (-not $branch -or $branch -eq "HEAD") { Throw-Error "${RepoName}: detached HEAD (check out a branch first)" }
  $upstream = Git-Output -RepoDir $RepoDir -Args @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
  $upstreamRemote = $null
  if ($upstream -and $upstream.Contains("/")) {
    $upstreamRemote = $upstream.Split("/")[0]
  }

  Write-Log "${RepoName}: fetch"
  Invoke-Git -RepoDir $RepoDir -Args @("fetch", $Remote, "--prune")

  Write-Log "${RepoName}: pull (--ff-only)"
  if ($upstream -and $upstreamRemote -eq $Remote) {
    Invoke-Git -RepoDir $RepoDir -Args @("pull", "--ff-only")
  } else {
    Invoke-Git -RepoDir $RepoDir -Args @("pull", "--ff-only", $Remote, $branch)
  }

  Write-Log "${RepoName}: push"
  if ($upstream -and $upstreamRemote -eq $Remote) {
    Invoke-Git -RepoDir $RepoDir -Args @("push")
  } else {
    Invoke-Git -RepoDir $RepoDir -Args @("push", $Remote, "HEAD:$branch")
  }
}

function Find-RepoPython {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string[]]$VenvDirs,
    [Parameter(Mandatory)][string]$FallbackPython
  )

  foreach ($venvDir in $VenvDirs) {
    if (-not $venvDir) { continue }
    $py = Join-Path $RepoDir (Join-Path $venvDir "Scripts\\python.exe")
    if (Test-Path -LiteralPath $py) { return $py }
  }

  if (-not (Get-Command $FallbackPython -ErrorAction SilentlyContinue)) {
    Throw-Error "missing command: $FallbackPython"
  }
  return $FallbackPython
}

function Run-ImportSync {
  param(
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)][string]$RepoName,
    [Parameter(Mandatory)][string]$ImportsRel,
    [Parameter(Mandatory)][string]$PythonExec,
    [Parameter(Mandatory)][string]$Remote
  )

  $importsPath = Join-Path $RepoDir $ImportsRel
  if (-not (Test-Path -LiteralPath $importsPath)) {
    Throw-Error "${RepoName}: missing $ImportsRel"
  }

  Write-Log "${RepoName}: sync imports ($ImportsRel)"
  Invoke-Run -FilePath $PythonExec -Args @($ImportsRel) -WorkingDirectory $RepoDir
}

Require-Command "git"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = if ($env:ENV_FILE) { $env:ENV_FILE } else { Join-Path $scriptDir ".env" }
$vars = Import-DotEnv -Path $envFile

foreach ($k in @(
  "HOMELAB_SYNC_ROOT",
  "HOMELAB_SYNC_REQUIRED_REPOS",
  "HOMELAB_SYNC_IMPORTS_SCRIPT",
  "HOMELAB_SYNC_VENV_DIR_CANDIDATES",
  "HOMELAB_SYNC_GIT_REMOTE",
  "HOMELAB_SYNC_PYTHON"
)) {
  if (-not $vars.ContainsKey($k) -or -not $vars[$k]) { Throw-Error "$k not set" }
}

$root = $vars["HOMELAB_SYNC_ROOT"]
$requiredRepos = @($vars["HOMELAB_SYNC_REQUIRED_REPOS"].Trim() -split "\s+")
$optionalRepos = @()
if ($vars.ContainsKey("HOMELAB_SYNC_OPTIONAL_REPOS") -and $vars["HOMELAB_SYNC_OPTIONAL_REPOS"]) {
  $optionalRepos = @($vars["HOMELAB_SYNC_OPTIONAL_REPOS"].Trim() -split "\s+")
}
$venvDirs = @($vars["HOMELAB_SYNC_VENV_DIR_CANDIDATES"].Trim() -split "\s+")
$importsRel = $vars["HOMELAB_SYNC_IMPORTS_SCRIPT"]
$remote = $vars["HOMELAB_SYNC_GIT_REMOTE"]
$pythonFallback = $vars["HOMELAB_SYNC_PYTHON"]

if ($requiredRepos.Count -eq 0) { Throw-Error "HOMELAB_SYNC_REQUIRED_REPOS is empty" }
if ($venvDirs.Count -eq 0) { Throw-Error "HOMELAB_SYNC_VENV_DIR_CANDIDATES is empty" }

if (-not (Test-Path -LiteralPath $root)) { Throw-Error "not a directory: $root" }
$rootAbs = (Resolve-Path -LiteralPath $root).Path

$repos = New-Object System.Collections.Generic.List[string]
foreach ($r in $requiredRepos) {
  if (-not $r) { continue }
  $p = Join-Path $rootAbs $r
  if (-not (Test-Path -LiteralPath $p)) { Throw-Error "missing required repo: $p" }
  $repos.Add($r)
}
foreach ($r in $optionalRepos) {
  if (-not $r) { continue }
  $p = Join-Path $rootAbs $r
  if (Test-Path -LiteralPath $p) {
    $repos.Add($r)
  } else {
    Write-Log "skip optional repo (not found): $p"
  }
}

foreach ($repoName in $repos) {
  $repoDir = Join-Path $rootAbs $repoName
  Ensure-RepoReady -RepoDir $repoDir -RepoName $repoName -Remote $remote
}

foreach ($repoName in $repos) {
  $repoDir = Join-Path $rootAbs $repoName
  Sync-Repo -RepoDir $repoDir -RepoName $repoName -Remote $remote
  $py = Find-RepoPython -RepoDir $repoDir -VenvDirs $venvDirs -FallbackPython $pythonFallback
  Run-ImportSync -RepoDir $repoDir -RepoName $repoName -ImportsRel $importsRel -PythonExec $py -Remote $remote
}

Write-Log "done"
