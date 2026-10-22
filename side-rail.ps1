#requires -Version 7
param(
    [string]$Project = '',
    [string]$Cwd = '',
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ESC = [char]27
. (Join-Path $PSScriptRoot 'rail-config.ps1')
$cfg = Get-RailConfig

$script:vaccts = $null
if ($cfg.vercelAccountsFile) { try { $script:vaccts = Get-Content $cfg.vercelAccountsFile -Raw | ConvertFrom-Json } catch {} }
$script:showVercel = [bool]$script:vaccts

$DIM = '90'; $CYAN = '36'; $GREEN = '32'; $YEL = '33'; $RED = '31'

$script:blink = $false
$script:pulseUntil = $null
$script:prevModel = $null
$script:prevEffort = $null
$script:activeEffort = $null
$script:firstRender = $true
$script:curr = $null
$script:skillLog = @()
$script:projStatus = @()
$script:projAt = [datetime]::MinValue

function C { param([string]$code, [string]$text) "$ESC[${code}m$text$ESC[0m" }

function Get-Width {
    try { $w = [Console]::WindowWidth; if ($w -gt 1) { return $w } } catch {}
    if ($cfg.widthTarget) { return [int]$cfg.widthTarget }
    return 38
}

function Resolve-Project {
    if ($Project) {
        $m = $cfg.projects | Where-Object { $_.name -eq $Project } | Select-Object -First 1
        if ($m) { return $m }
    }
    if ($script:sessions -and $script:sessions.Count -gt 0) {
        $newest = $script:sessions | Sort-Object ts -Descending | Select-Object -First 1
        if ($newest.cwd) { foreach ($p in $cfg.projects) { if ($newest.cwd -like ($p.path + '*')) { return $p } } }
    }
    $probe = if ($Cwd) { $Cwd } else { (Get-Location).Path }
    foreach ($p in $cfg.projects) {
        if ($probe -like ($p.path + '*')) { return $p }
    }
    $projRoot = Join-Path $cfg.claudeHome 'projects'
    if (Test-Path $projRoot) {
        $files = Get-ChildItem $projRoot -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30
        foreach ($f in $files) {
            $tail = @(Get-Content $f.FullName -Tail 20 -ErrorAction SilentlyContinue)
            for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                $o = $null; try { $o = $tail[$i] | ConvertFrom-Json } catch { continue }
                if ($o.type -ne 'assistant' -or -not $o.cwd) { continue }
                foreach ($p in $cfg.projects) { if ($o.cwd -like ($p.path + '*')) { return $p } }
                break
            }
        }
    }
    if ($script:sessions -and $script:sessions.Count -gt 0) {
        $n2 = $script:sessions | Sort-Object ts -Descending | Select-Object -First 1
        if ($n2.cwd) {
            $leaf = Split-Path $n2.cwd -Leaf
            return @{ name = $leaf; short = $leaf; path = $n2.cwd; vercel = $null; untracked = $true }
        }
    }
    return $null
}

function Get-Branch {
    param($path)
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $b = git -C $path rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b) { return ([string]$b).Trim() }
    } catch {}
    return ''
}

function Get-Usage {
    # Shared cache across all rail instances -> ~1 real call per refresh window, 429-safe.
    $cacheFile = Join-Path $PSScriptRoot 'usage-cache.json'
    $iv = if ($cfg.usageRefreshSec) { [int]$cfg.usageRefreshSec } else { 180 }
    $cached = $null
    if (Test-Path $cacheFile) {
        try {
            $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $cached = $c.data
            $cAge = ((Get-Date) - ([datetime]$c.ts)).TotalSeconds
            if ($cAge -lt ($iv - 5)) { return $c.data }
        } catch {}
    }
    try {
        $cred = Get-Content (Join-Path $cfg.claudeHome '.credentials.json') -Raw | ConvertFrom-Json
        $tok = $cred.claudeAiOauth.accessToken
        if (-not $tok) { return $cached }
        if (-not $script:ccVersion) {
            $script:ccVersion = '2.1.0'
            try { $vo = & claude --version 2>$null | Select-Object -First 1; if ("$vo" -match '^(\d+\.\d+\.\d+)') { $script:ccVersion = $Matches[1] } } catch {}
        }
        $h = @{ 'Authorization' = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = "claude-code/$($script:ccVersion)" }
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -Method Get -TimeoutSec 15
        try { (@{ ts = (Get-Date).ToString('o'); data = $r } | ConvertTo-Json -Depth 8) | Set-Content $cacheFile -Encoding utf8 } catch {}
        return $r
    } catch { return $cached }
}

function Bar {
    param([double]$pct, [int]$cells = 7)
    $f = [int][Math]::Round($pct / 100 * $cells)
    if ($f -gt $cells) { $f = $cells }; if ($f -lt 0) { $f = 0 }
    ('▓' * $f) + ('░' * ($cells - $f))
}

function PctColor {
    param([double]$pct)
    if ($pct -ge 90) { $RED } elseif ($pct -ge 70) { $YEL } else { $GREEN }
}

function ResetStr {
    param($iso)
    try {
        $dt = if ($iso -is [datetime]) {
            if ($iso.Kind -eq 'Utc') { $iso.ToLocalTime() } else { $iso }
        } else { [datetimeoffset]::Parse([string]$iso).LocalDateTime }
        if ($dt.Date -eq (Get-Date).Date) { return $dt.ToString('HH:mm') }
        return $dt.ToString('ddd HH:mm')
    } catch { return '' }
}

function ModelShort {
    param($m)
    if (-not $m) { return '—' }
    $n = if ($m -match 'opus') { 'Opus' } elseif ($m -match 'sonnet') { 'Sonnet' } elseif ($m -match 'haiku') { 'Haiku' } else { return $m }
    $v = if ($m -match '(\d+)-(\d+)') { "$($Matches[1]).$($Matches[2])" } else { '' }
    return ("$n $v").Trim()
}

$script:activeModel = $null
function Get-CacheAge {
    $script:activeModel = $null
    if (-not $curr) { return $null }
    $projRoot = Join-Path $cfg.claudeHome 'projects'
    if (-not (Test-Path $projRoot)) { return $null }
    $files = Get-ChildItem $projRoot -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12
    foreach ($f in $files) {
        $tail = @(Get-Content $f.FullName -Tail 25 -ErrorAction SilentlyContinue)
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $o = $null; try { $o = $tail[$i] | ConvertFrom-Json } catch { continue }
            if ($o.type -ne 'assistant' -or -not $o.cwd) { continue }
            if (-not ($o.cwd -like ($curr.path + '*'))) { break }
            try {
                $tsv = $o.timestamp
                $ts = if ($tsv -is [datetime]) {
                    if ($tsv.Kind -eq 'Local') { $tsv } else { [datetime]::SpecifyKind($tsv, 'Utc').ToLocalTime() }
                } else { [datetimeoffset]::Parse([string]$tsv).LocalDateTime }
                $age = [int]((Get-Date) - $ts).TotalMinutes
                $ttl = 60
                $cc = $o.message.usage.cache_creation
                if ($cc -and [double]$cc.ephemeral_5m_input_tokens -gt 0 -and [double]$cc.ephemeral_1h_input_tokens -le 0) { $ttl = 5 }
                $script:activeModel = $o.message.model
                return @{ ageMin = $age; ttlMin = $ttl }
            } catch { return $null }
        }
    }
    return $null
}

$script:usage = $null
$script:usageOk = $false
$script:cache = $null
$script:slowAt = [datetime]::MinValue
$script:medAt = [datetime]::MinValue
$script:fastAt = [datetime]::MinValue

# SLOW (~90s): the only network call — usage % endpoint
function Update-Slow {
    param([switch]$Force)
    $iv = if ($cfg.usageRefreshSec) { [int]$cfg.usageRefreshSec } else { 180 }
    if (-not $Force -and ((Get-Date) - $script:slowAt).TotalSeconds -lt $iv) { return $false }
    $script:slowAt = Get-Date
    $u = Get-Usage
    $script:usage = $u
    $script:usageOk = [bool]$u
    return $true
}

# MED (~6s): transcript scan for cache-age + active model (local files)
function Update-Med {
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:medAt).TotalSeconds -lt 6) { return $false }
    $script:medAt = Get-Date
    $script:cache = Get-CacheAge
    return $true
}

# FAST (~1.5s): events + live project detection + boundary + infra (all local, cheap)
function Update-Fast {
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:fastAt).TotalMilliseconds -lt 1500) { return $false }
    $script:fastAt = Get-Date
    Get-Events
    $script:curr = Resolve-Project
    $script:boundary = Get-Boundary
    Get-Infra
    $me = @($script:sessions | Where-Object { $script:curr -and $_.cwd -like ($script:curr.path + '*') } | Sort-Object ts -Descending)
    $script:activeEffort = ($me | Where-Object { $_.effort } | Select-Object -First 1).effort
    if (($script:activeModel -ne $script:prevModel) -or ($script:activeEffort -ne $script:prevEffort)) {
        if ($null -ne $script:prevModel -or $null -ne $script:prevEffort) { $script:pulseUntil = (Get-Date).AddSeconds(2.5) }
        $script:prevModel = $script:activeModel
        $script:prevEffort = $script:activeEffort
    }
    return $true
}

function Resolve-VAccount {
    param($orgId)
    if (-not $orgId -or -not $script:vaccts) { return $null }
    $p = $script:vaccts.teams.PSObject.Properties[$orgId]
    if ($p) { return $p.Value.account }
    return $null
}

$script:boundary = $null
function Get-Boundary {
    if (-not $curr) { return @{ state = 'unknown' } }
    if ($curr.untracked) { return @{ state = 'untracked' } }
    $expected = $curr.vercel
    $primary = if ($script:vaccts) { $script:vaccts.primary } else { $null }
    $linked = $null
    $pj = Join-Path $curr.path '.vercel\project.json'
    if (Test-Path $pj) {
        try { $o = Get-Content $pj -Raw | ConvertFrom-Json; $linked = Resolve-VAccount $o.orgId } catch {}
    }
    if (-not $expected) { return @{ state = 'unknown' } }
    if ($linked -and $linked -ne $expected) { return @{ state = 'wrong'; expected = $expected; linked = $linked } }
    if ($expected -eq $primary) { return @{ state = 'ok'; expected = $expected } }
    return @{ state = 'warn'; expected = $expected }
}

$script:infraMtime = $null
$script:infraSnip = ''
function Get-Infra {
    $inf = $cfg.watchFile
    if (-not $inf) { $script:infraMtime = $null; $script:infraSnip = ''; return }
    if (-not (Test-Path $inf)) { $script:infraMtime = $null; $script:infraSnip = ''; return }
    $script:infraMtime = (Get-Item $inf).LastWriteTime
    $last = Get-Content $inf -Tail 8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1
    $s = ([string]$last).TrimStart('-', ' ').Trim()
    if ($s.Length -gt 28) { $s = $s.Substring(0, 28) }
    $script:infraSnip = $s
}

function ProjName {
    param($cwd)
    if (-not $cwd) { return '?' }
    foreach ($p in $cfg.projects) { if ($cwd -like ($p.path + '*')) { return $p.short } }
    return (Split-Path $cwd -Leaf)
}

$script:hookOk = $false
$script:eventsFresh = $false
$script:sessions = @()
function Get-Events {
    $script:hookOk = $false; $script:eventsFresh = $false; $script:sessions = @(); $script:skillLog = @()
    $file = Join-Path $PSScriptRoot 'rail-events.jsonl'
    if (-not (Test-Path $file)) { return }
    $lines = Get-Content $file -Tail 200 -ErrorAction SilentlyContinue
    $evs = @()
    foreach ($l in $lines) {
        $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
        if (-not $o.session) { continue }
        $t = $null
        try {
            $t = if ($o.ts -is [datetime]) {
                if ($o.ts.Kind -eq 'Local') { $o.ts } else { [datetime]::SpecifyKind($o.ts, 'Utc').ToLocalTime() }
            } else { [datetimeoffset]::Parse([string]$o.ts).LocalDateTime }
        } catch { continue }
        $evs += [pscustomobject]@{ ts = $t; event = $o.event; session = $o.session; cwd = $o.cwd; skill = $o.skill; effort = $o.effort }
    }
    if ($evs.Count -eq 0) { return }
    $script:hookOk = $true
    $script:skillLog = @($evs | Where-Object { $_.event -eq 'PreToolUse' -and $_.skill } | Sort-Object ts -Descending | Select-Object -First 8)
    $newest = ($evs | Sort-Object ts -Descending | Select-Object -First 1).ts
    $script:eventsFresh = (((Get-Date) - $newest).TotalMinutes -lt 120)
    $sess = @()
    foreach ($g in ($evs | Group-Object session)) {
        $latest = $g.Group | Sort-Object ts -Descending | Select-Object -First 1
        $state = switch ($latest.event) {
            'PreToolUse' { if ($latest.skill) { "skill:$($latest.skill)" } else { 'active' } }
            'Notification' { 'needs' }
            'SessionEnd' { 'dead' }
            default { 'idle' }
        }
        $eff = ($g.Group | Where-Object { $_.effort } | Sort-Object ts -Descending | Select-Object -First 1).effort
        $sess += [pscustomobject]@{ session = $g.Name; cwd = $latest.cwd; ts = $latest.ts; state = $state; effort = $eff }
    }
    # liveness: drop sessions that emitted SessionEnd, and any whose newest event aged past the live window
    # (no exit signal until SessionEnd hook is installed -> window is the stopgap against ghost sessions)
    $liveWin = if ($cfg.liveWindowMin) { [int]$cfg.liveWindowMin } else { 30 }
    $nowL = Get-Date
    $script:sessions = @($sess | Where-Object { $_.state -ne 'dead' -and ($nowL - $_.ts).TotalMinutes -le $liveWin })
}

function Get-Projects {
    $res = @()
    foreach ($p in $cfg.projects) {
        $branch = ''; $dirty = 0; $ahead = 0
        if (Test-Path $p.path) {
            try { $b = git -C $p.path rev-parse --abbrev-ref HEAD 2>$null; if ($LASTEXITCODE -eq 0 -and $b) { $branch = ([string]$b).Trim() } } catch {}
            try { $dirty = @(git -C $p.path status --porcelain 2>$null | Where-Object { $_ -notmatch '\.claude[\\/]' }).Count } catch {}
            try { $a = git -C $p.path rev-list --count '@{u}..HEAD' 2>$null; if ($LASTEXITCODE -eq 0 -and $a) { $ahead = [int]([string]$a).Trim() } } catch {}
        }
        $res += [pscustomobject]@{ name = $p.name; short = $p.short; branch = $branch; dirty = $dirty; ahead = $ahead }
    }
    $script:projStatus = $res
}

function Update-Proj {
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:projAt).TotalSeconds -lt 20) { return $false }
    $script:projAt = Get-Date
    Get-Projects
    return $true
}

$script:curr = Resolve-Project

function Render {
    $w = Get-Width
    $iw = [Math]::Min([Math]::Max($w - 1, 28), 46)
    $div = '─' * $iw

    $mine = @()
    $needs = 0
    if ($script:sessions -and $script:sessions.Count -gt 0) {
        if ($curr) { $mine = @($script:sessions | Where-Object { $_.cwd -like ($curr.path + '*') } | Sort-Object ts -Descending) }
        $needs = @($script:sessions | Where-Object { $_.state -eq 'needs' }).Count
    }
    $pulse = [bool]($script:pulseUntil -and ((Get-Date) -lt $script:pulseUntil))
    $rc = if ($script:blink) { '1;37;41' } else { '37;41' }
    $nc = if ($script:blink) { '93' } else { $YEL }

    $projName = if ($curr) { $curr.name } else { '? idle' }
    $projColor = if (-not $curr) { $YEL } elseif ($curr.untracked) { $YEL } else { $CYAN }
    $branch = if ($curr) { Get-Branch $curr.path } else { '' }
    $cwdTail = if ($curr) { '.\' + (Split-Path $curr.path -Leaf) } elseif ($Cwd) { $Cwd } else { '' }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.AppendLine((C $CYAN ' SIDE RAIL ') + (C $DIM ('─' * [Math]::Max($iw - 10, 0))))

    $head = ' ' + (C $projColor "◆ $projName")
    if ($branch) { $head += '  ' + (C $DIM "⎇ $branch") }
    [void]$out.AppendLine($head)
    if ($cwdTail -and $iw -ge 34) { [void]$out.AppendLine((C $DIM "   $cwdTail")) }

    [void]$out.AppendLine((C $DIM " $div"))
    $b = $script:boundary
    if (-not $script:showVercel) {
    } elseif (-not $b) {
        [void]$out.AppendLine((C $DIM ' vc    · …'))
    } elseif ($b.state -eq 'ok') {
        [void]$out.AppendLine(' ' + (C $GREEN ('vc ✓ ' + $b.expected)))
    } elseif ($b.state -eq 'warn') {
        [void]$out.AppendLine(' ' + (C $YEL ('vc ⚠ ' + $b.expected + ' · not primary')))
    } elseif ($b.state -eq 'wrong') {
        [void]$out.AppendLine((C $rc (' ‼ WRONG VERCEL ACCT'.PadRight($iw))))
        [void]$out.AppendLine((C $rc (" folder=$($b.linked) exp=$($b.expected)".PadRight($iw))))
        [void]$out.AppendLine((C $rc (" fix: relink to $($b.expected)".PadRight($iw))))
    } elseif ($b.state -eq 'untracked') {
        [void]$out.AppendLine((C $DIM ' vc · untracked project'))
    } else {
        [void]$out.AppendLine(' ' + (C $YEL 'vc ? unverified'))
    }
    if (-not $script:hookOk) {
        [void]$out.AppendLine((C $DIM ' ▸ (hook not set)'))
    } else {
        $cur = $mine | Select-Object -First 1
        $cl = ' '
        if ($cur -and $cur.state -like 'skill:*') {
            $sk = $cur.state.Substring(6)
            $sage = [int]((Get-Date) - $cur.ts).TotalSeconds
            $cl += (C $CYAN "▸ $sk ${sage}s")
        } else {
            $cl += (C $DIM '· idle')
        }
        if ($needs -gt 0) { $cl += '  ' + (C $nc "● $needs need you") }
        [void]$out.AppendLine($cl)
    }
    [void]$out.AppendLine((C $DIM " $div"))
    if ($script:usage) {
        $u = $script:usage
        $h5 = [double]$u.five_hour.utilization
        $w7 = [double]$u.seven_day.utilization
        [void]$out.AppendLine(' 5h ' + (C (PctColor $h5) ((Bar $h5) + (' {0,3:N0}%' -f $h5))) + (C $DIM ("  ↻" + (ResetStr $u.five_hour.resets_at))))
        [void]$out.AppendLine(' 7d ' + (C (PctColor $w7) ((Bar $w7) + (' {0,3:N0}%' -f $w7))) + (C $DIM ("  ↻" + (ResetStr $u.seven_day.resets_at))))
        if ($u.extra_usage.is_enabled -eq $true) {
            [void]$out.AppendLine(' mode ' + (C $RED '● EXTRA USAGE ON'))
        } else {
            [void]$out.AppendLine(' mode ' + (C $GREEN '● plan only'))
        }
    } else {
        [void]$out.AppendLine((C $DIM ' 5h    · …'))
        [void]$out.AppendLine((C $DIM ' 7d    · …'))
        [void]$out.AppendLine((C $DIM ' mode  · …'))
    }
    if ($script:cache) {
        $age = $script:cache.ageMin; $ttl = $script:cache.ttlMin
        $left = $ttl - $age
        $amberAt = [Math]::Min(10, [Math]::Max(1, [int]($ttl * 0.25)))
        if ($age -ge $ttl) { $cCol = $RED; $cLbl = 'EXPIRED' }
        elseif ($left -le $amberAt) { $cCol = $YEL; $cLbl = 'soon' }
        else { $cCol = $GREEN; $cLbl = 'ok' }
        [void]$out.AppendLine(' cache ' + (C $cCol ("{0}m/{1}m {2}" -f $age, $ttl, $cLbl)))
    } else {
        [void]$out.AppendLine((C $DIM ' cache · —'))
    }
    if ($script:infraMtime) {
        $iage = [int]((Get-Date) - $script:infraMtime).TotalMinutes
        $iwin = if ($cfg.infraRecencyMin) { [int]$cfg.infraRecencyMin } else { 15 }
        if ($iage -le $iwin) {
            [void]$out.AppendLine(' ' + (C $YEL "▸ NEW $($cfg.watchLabel.ToUpper()) ${iage}m"))
            if ($script:infraSnip) { [void]$out.AppendLine((C $YEL ('   ' + $script:infraSnip))) }
        } else {
            [void]$out.AppendLine((C $DIM " $($cfg.watchLabel) ✓ ${iage}m"))
        }
    }
    [void]$out.AppendLine((C $DIM " $div"))
    $ml = ModelShort $script:activeModel
    $mc = if ($script:activeModel -match 'opus') { $YEL } elseif ($script:activeModel -match 'sonnet') { $CYAN } elseif ($script:activeModel -match 'haiku') { $GREEN } else { $DIM }
    $eff = if ($script:activeEffort) { "eff:$($script:activeEffort)" } else { 'eff ?' }
    if ($pulse) {
        [void]$out.AppendLine((C '7' " ◆ $ml  $eff"))
    } else {
        [void]$out.AppendLine(' ◆ ' + (C $mc $ml) + '  ' + (C $DIM $eff))
    }
    $rs = @($script:skillLog | Where-Object { -not $script:curr -or $_.cwd -like ($script:curr.path + '*') } | Select-Object -First 3)
    if ($rs.Count -gt 0) {
        $names = (($rs | ForEach-Object { $_.skill }) -join ' · ')
        $maxn = [Math]::Max(0, $iw - 9)
        if ($names.Length -gt $maxn) { $names = $names.Substring(0, $maxn) }
        [void]$out.AppendLine((C $DIM (' recent ' + $names)))
    }
    if (-not $script:hookOk) {
        [void]$out.AppendLine((C $DIM ' sess · (hook not set)'))
    } else {
        [void]$out.AppendLine((C $DIM (' sess · ' + $script:sessions.Count + ' live')))
        $ranked = $script:sessions | ForEach-Object {
            $rank = if ($_.state -eq 'needs') { 0 } elseif ($_.state -like 'skill:*') { 1 } else { 2 }
            $_ | Add-Member -NotePropertyName _rank -NotePropertyValue $rank -PassThru -Force
        }
        $all = @($ranked | Sort-Object _rank, @{ Expression = 'ts'; Descending = $true } | Select-Object -First 6)
        foreach ($o2 in $all) {
            $pn = ProjName $o2.cwd
            $age = [int]((Get-Date) - $o2.ts).TotalMinutes
            if ($o2.state -eq 'needs') {
                [void]$out.AppendLine((C $nc (" ‼ $pn NEEDS YOU ${age}m")))
            } elseif ($o2.state -like 'skill:*') {
                $sk = $o2.state.Substring(6)
                $row = (C '0' " ● $pn ") + (C $DIM "$sk ${age}m")
                [void]$out.AppendLine($row)
            } else {
                [void]$out.AppendLine((C $DIM " ⏸ $pn idle ${age}m"))
            }
        }
    }
    [void]$out.AppendLine((C $DIM " $div"))
    [void]$out.AppendLine((C $DIM ' PROJECTS'))
    foreach ($ps in $script:projStatus) {
        $pl = ' ' + (C $DIM ("{0,-7}" -f $ps.short)) + (C $DIM ("{0,-8}" -f $ps.branch))
        if ($ps.dirty -gt 0) { $pl += (C $YEL ('*' + $ps.dirty)) } else { $pl += (C $GREEN '✓') }
        if ($ps.ahead -gt 0) { $pl += (C $CYAN (' ↑' + $ps.ahead)) }
        [void]$out.AppendLine($pl)
    }
    [void]$out.AppendLine((C $DIM " $div"))

    $hDot = if ($script:hookOk -and $script:eventsFresh) { (C $GREEN '●') } else { (C $DIM '○') }
    $uDot = if ($script:usageOk) { (C $GREEN '●') } else { (C $DIM '○') }
    $vDot = if ($script:boundary -and $script:boundary.state -ne 'unknown') { (C $GREEN '●') } else { (C $DIM '○') }
    $dots = ' ' + (C $DIM 'hook ') + $hDot + (C $DIM '  usage ') + $uDot
    if ($script:showVercel) { $dots += (C $DIM '  vercel ') + $vDot }
    [void]$out.AppendLine($dots)
    [void]$out.AppendLine((C $DIM (' ⟳ ' + (Get-Date).ToString('HH:mm:ss'))))

    $sw = ' '
    foreach ($p in $cfg.projects) {
        $col = if ($curr -and $p.name -eq $curr.name) { $CYAN } else { '0' }
        $sw += (C $col "[$($p.key)]$($p.short) ")
    }
    [void]$out.AppendLine($sw)
    [void]$out.AppendLine((C $DIM ' [+]new  [r]refresh  [q]quit'))

    $prefix = if ($script:firstRender) { "$ESC[2J$ESC[H" } else { "$ESC[H" }
    $script:firstRender = $false
    $body = $out.ToString() -replace "`r?`n", "$ESC[K`r`n"
    Write-Host ($prefix + $body + "$ESC[K$ESC[0J") -NoNewline
}

function Get-Pwsh {
    $s = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($s) { return $s }
    return 'C:\Program Files\PowerShell\7\pwsh.exe'
}

function Launch-Project {
    param($p)
    if (-not $p) { return }
    $launcher = Join-Path $PSScriptRoot 'claude-w.ps1'
    $pwsh = Get-Pwsh
    Start-Process $pwsh -ArgumentList '-NoExit', '-NoProfile', '-File', $launcher -WorkingDirectory $p.path
}

if ($Once) { [void](Update-Slow -Force); [void](Update-Med -Force); [void](Update-Fast -Force); [void](Update-Proj -Force); Render; Write-Host "$ESC[0m"; return }

[Console]::CursorVisible = $false
try {
    [void](Update-Slow -Force); [void](Update-Med -Force); [void](Update-Fast -Force); [void](Update-Proj -Force)
    Render
    $lw = Get-Width
    $lastAnim = Get-Date
    $running = $true
    while ($running) {
        if ([Console]::KeyAvailable) {
            $ch = [string]([Console]::ReadKey($true).KeyChar)
            if ($ch -ceq 'q') { $running = $false }
            elseif ($ch -ceq 'r') { [void](Update-Slow -Force); [void](Update-Med -Force); [void](Update-Fast -Force); [void](Update-Proj -Force); Render }
            elseif ($ch -ceq '+') { Launch-Project $script:curr; Render }
            else {
                $hit = $cfg.projects | Where-Object { $_.key -eq $ch } | Select-Object -First 1
                if ($hit) { Launch-Project $hit; Render }
            }
        }
        $cw = Get-Width
        if ($cw -ne $lw) { $lw = $cw; Render }
        $changed = $false
        if (Update-Slow) { $changed = $true }
        if (Update-Med) { $changed = $true }
        if (Update-Proj) { $changed = $true }
        if (Update-Fast) { $changed = $true }
        if ($changed) { Render }
        else {
            $alertActive = ($script:boundary -and $script:boundary.state -eq 'wrong') -or (@($script:sessions | Where-Object { $_.state -eq 'needs' }).Count -gt 0)
            $pulseActive = $script:pulseUntil -and ((Get-Date) -lt $script:pulseUntil)
            if ($alertActive -or $pulseActive) {
                if (((Get-Date) - $lastAnim).TotalMilliseconds -ge 650) { $script:blink = -not $script:blink; $lastAnim = Get-Date; Render }
            } elseif ($script:blink) { $script:blink = $false; Render }
            elseif ($script:pulseUntil -and ((Get-Date) -ge $script:pulseUntil)) { $script:pulseUntil = $null; Render }
        }
        Start-Sleep -Milliseconds 100
    }
}
finally {
    [Console]::CursorVisible = $true
    Write-Host "$ESC[0m"
}
