#requires -Version 7
# Merges the Side Rail hooks into your Claude Code user settings.json (backup + validate + auto-restore on failure).
#   pwsh -NoProfile -File install-hook.ps1              install (idempotent)
#   pwsh -NoProfile -File install-hook.ps1 -Uninstall   remove only the rail-hook.ps1 entries
# settings.json is taken from claudeHome in rail.config.json, else CLAUDE_CONFIG_DIR, else ~/.claude.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rail-config.ps1')
$cfg = Get-RailConfig
$settingsPath = Join-Path $cfg.claudeHome 'settings.json'
if (-not (Test-Path $settingsPath)) { Write-Host "settings.json not found: $settingsPath" -ForegroundColor Red; exit 1 }

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
$hookScript = Join-Path $PSScriptRoot 'rail-hook.ps1'
$cmd = '"' + $pwsh + '" -NoProfile -File "' + $hookScript + '"'

$before = Get-Content $settingsPath -Raw | ConvertFrom-Json
$hadStatusLine = [bool]$before.statusLine
$hadPermissions = [bool]$before.permissions

$bak = "$settingsPath.railbak"
Copy-Item $settingsPath $bak -Force
Write-Host "backup -> $bak"

$s = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $s.ContainsKey('hooks') -or -not $s.hooks) { $s.hooks = @{} }

$entry = @{ type = 'command'; command = $cmd; timeout = 10 }
$events = [ordered]@{ PreToolUse = 'Skill'; PostToolUse = 'Skill'; Notification = $null; Stop = $null; SessionEnd = $null }
function Remove-RailHook {
    param([string]$evt)
    if (-not $s.hooks.ContainsKey($evt) -or -not $s.hooks[$evt]) { return }
    $s.hooks[$evt] = @($s.hooks[$evt] | Where-Object {
            $keep = $true
            if ($_.hooks) { foreach ($h in $_.hooks) { if ("$($h.command)" -like '*rail-hook.ps1*') { $keep = $false } } }
            $keep
        })
    if ($s.hooks[$evt].Count -eq 0) { $s.hooks.Remove($evt) }
}
function Add-RailHook {
    param([string]$evt, [string]$matcher)
    Remove-RailHook $evt
    if (-not $s.hooks.ContainsKey($evt) -or -not $s.hooks[$evt]) { $s.hooks[$evt] = @() }
    $grp = @{ hooks = @($entry) }
    if ($matcher) { $grp.matcher = $matcher }
    $s.hooks[$evt] = @($s.hooks[$evt]) + $grp
}
foreach ($e in $events.Keys) { if ($Uninstall) { Remove-RailHook $e } else { Add-RailHook $e $events[$e] } }

$s | ConvertTo-Json -Depth 30 | Set-Content $settingsPath -Encoding utf8

try {
    $after = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $ok = $true
    if ($hadStatusLine -and -not $after.statusLine) { $ok = $false }
    if ($hadPermissions -and -not $after.permissions) { $ok = $false }
    if (-not $Uninstall -and -not $after.hooks.PreToolUse) { $ok = $false }
    if (-not $ok) { throw 'validation failed (a key setting went missing)' }
    if ($Uninstall) { Write-Host 'OK: rail hooks removed' -ForegroundColor Green }
    else { Write-Host 'OK: rail hooks installed (PreToolUse:Skill, PostToolUse:Skill, Notification, Stop, SessionEnd)' -ForegroundColor Green }
    Write-Host "statusLine preserved: $([bool]$after.statusLine) | permissions preserved: $([bool]$after.permissions)"
    Write-Host 'RESTART Claude Code sessions for the change to take effect.'
} catch {
    Copy-Item $bak $settingsPath -Force
    Write-Host "RESTORED backup (no changes applied): $_" -ForegroundColor Red
    exit 1
}
