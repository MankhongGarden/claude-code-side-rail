#requires -Version 7
# Starts Claude Code (launchCmd from rail.config.json) in the current folder.
# Before that it clears the ReadOnly attribute on .claude and .claude\worktrees: inside some cloud-synced folders
# (seen with Google Drive for desktop) Windows marks them ReadOnly and creating a worktree then fails with EEXIST.
. (Join-Path $PSScriptRoot 'rail-config.ps1')
$cfg = Get-RailConfig

$claudeDir = Join-Path (Get-Location).Path '.claude'
if (Test-Path $claudeDir) {
    attrib -R $claudeDir /D 2>$null
    $wtDir = Join-Path $claudeDir 'worktrees'
    if (Test-Path $wtDir) { attrib -R $wtDir /S /D 2>$null }
}

$cmd = if ($cfg.launchCmd) { $cfg.launchCmd } else { 'claude' }
Invoke-Expression $cmd
