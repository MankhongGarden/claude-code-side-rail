#requires -Version 7
# Loads rail.config.json (or rail.config.example.json when you have not made one yet),
# fills defaults and expands %ENV_VARS% / a leading ~ in paths.
function Expand-RailPath([string]$p) {
    if (-not $p) { return $p }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq '~' -or $p.StartsWith('~\') -or $p.StartsWith('~/')) { $p = Join-Path $HOME $p.Substring([Math]::Min(2, $p.Length)) }
    return $p.TrimEnd('\', '/')
}

function Get-RailConfig {
    $file = Join-Path $PSScriptRoot 'rail.config.json'
    if (-not (Test-Path $file)) { $file = Join-Path $PSScriptRoot 'rail.config.example.json' }
    $c = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $defaults = [ordered]@{
        claudeHome = ''; launchCmd = 'claude'; widthTarget = 38; usageRefreshSec = 180; liveWindowMin = 30
        watchFile = ''; watchLabel = 'watch'; infraRecencyMin = 15; vercelAccountsFile = ''; projects = @()
    }
    foreach ($k in $defaults.Keys) { if ($null -eq $c.$k) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force } }
    $home2 = Expand-RailPath $c.claudeHome
    if (-not $home2) { $home2 = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' } }
    $c.claudeHome = $home2
    $c.watchFile = Expand-RailPath $c.watchFile
    $c.vercelAccountsFile = Expand-RailPath $c.vercelAccountsFile
    $c.projects = @($c.projects | Where-Object { $_ } | ForEach-Object { $_.path = Expand-RailPath $_.path; $_ })
    return $c
}
