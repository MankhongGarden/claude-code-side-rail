#requires -Version 7
# Side Rail event hook. Appends one compact JSON line per event. ALWAYS exit 0 (never blocks).
try {
    $raw = [Console]::In.ReadToEnd()
    $p = $raw | ConvertFrom-Json
    $ev = [ordered]@{
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        event   = $p.hook_event_name
        session = $p.session_id
        cwd     = $p.cwd
    }
    if ($p.tool_name -eq 'Skill' -and $p.tool_input -and $p.tool_input.skill) { $ev.skill = $p.tool_input.skill }
    if ($p.effort -and $p.effort.level) { $ev.effort = $p.effort.level }
    $line = $ev | ConvertTo-Json -Compress
    $file = Join-Path $PSScriptRoot 'rail-events.jsonl'
    try { if ((Get-Item $file -ErrorAction Stop).Length -gt 5MB) { Move-Item $file "$file.1" -Force -ErrorAction Stop } } catch {}
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -Path $file -Value $line -Encoding utf8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 25 }
    }
} catch {}
exit 0
