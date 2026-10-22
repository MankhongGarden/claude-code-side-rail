#requires -Version 7
# Opens a new Windows Terminal window: the rail on the left, Claude Code (launchCmd) on the right, in the project's folder.
#   pwsh -File start-rail.ps1 [-Project <name from rail.config.json>]   (default: first project)
param([string]$Project = '')

. (Join-Path $PSScriptRoot 'rail-config.ps1')
$cfg = Get-RailConfig
$p = if ($Project) { $cfg.projects | Where-Object { $_.name -eq $Project } | Select-Object -First 1 } else { $cfg.projects | Select-Object -First 1 }
if (-not $p) {
    Write-Error "Unknown project '$Project'. Options: $($cfg.projects.name -join ', ') (add projects to rail.config.json)"
    exit 1
}

$rail = Join-Path $PSScriptRoot 'side-rail.ps1'
$launcher = Join-Path $PSScriptRoot 'claude-w.ps1'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }

$wtArgs = @(
    '-w', 'new',
    'new-tab', '-d', $PSScriptRoot, $pwsh, '-NoExit', '-NoProfile', '-File', $rail, '-Project', $p.name,
    ';',
    'split-pane', '-V', '-s', '0.72', '-d', $p.path, $pwsh, '-NoExit', '-NoProfile', '-File', $launcher
)

& wt @wtArgs
