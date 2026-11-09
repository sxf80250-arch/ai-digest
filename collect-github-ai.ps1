#requires -Version 5
<#
  Collect AI-related GitHub repositories and emit structured JSON for the daily digest.

  Design notes borrowed from a news-curation engine:
   - heat: rank by recent star growth with time decay (the last 24h counts fully,
     the 24h before it counts half), instead of lifetime stars / project age
   - tiers: repositories owned by organizations and repositories owned by
     individuals use different star floors
   - resurface: a repository that was pushed before can come back when there is
     real news (a release published after the last push, or a large recent surge)

  Settings live in digest-config.json; changing them needs no code edit.
  This source is deliberately pure ASCII: PowerShell 5.1 reads BOM-less files as
  ANSI/GBK, which corrupts non-ASCII source text.

  Output: <OutputDir>\data\candidates-<date>.json
          <OutputDir>\data\history.json   star snapshots over time
          <OutputDir>\data\reported.json  repositories already pushed, with dates
#>
[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$ConfigPath = '',
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$SkipReleaseCheck,
    [switch]$NoMark,
    [switch]$Force,
    [string]$CommitFrom = '',
    [string]$Date = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $OutputDir 'digest-config.json' }

$dataDir = Join-Path $OutputDir 'data'
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

# UTF-8 with BOM on write: PowerShell 5.1 otherwise reads BOM-less files as
# ANSI/GBK and mangles non-ASCII text such as Chinese project descriptions.
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Get-Prop {
    param($Obj, [string]$Name, $Default)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# ---------------------------------------------------------------- configuration
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

$perPage          = [int](Get-Prop $cfg 'perPage' 50)
$starFloor        = [int](Get-Prop $cfg 'starFloor' 50)
$emergingFloor    = [int](Get-Prop $cfg 'emergingFloor' 100)
$pushedWithinDays = [int](Get-Prop $cfg 'pushedWithinDays' 45)
$emergingDays     = [int](Get-Prop $cfg 'emergingWithinDays' 25)

$tierMinStars = Get-Prop $cfg 'tierMinStars' $null
$minOrg       = [int](Get-Prop $tierMinStars 'org' 200)
$minIndividual = [int](Get-Prop $tierMinStars 'individual' 60)

$velocity     = Get-Prop $cfg 'velocity' $null
$shortHours   = [int](Get-Prop $velocity 'shortHours' 24)
$longHours    = [int](Get-Prop $velocity 'longHours' 48)
$decay        = [double](Get-Prop $velocity 'decay' 0.5)

$reporting    = Get-Prop $cfg 'reporting' $null
$maxNew       = [int](Get-Prop $reporting 'maxNew' 12)
$maxGrowing   = [int](Get-Prop $reporting 'maxGrowing' 8)
$popularCount = [int](Get-Prop $reporting 'popularCount' 5)
$resurfaceMinDays  = [int](Get-Prop $reporting 'resurfaceMinDays' 7)
$resurfaceMinDelta = [int](Get-Prop $reporting 'resurfaceMinDelta' 150)
$releaseMinDelta   = [int](Get-Prop $reporting 'releaseCheckMinDelta' 20)
$maxReleaseChecks  = [int](Get-Prop $reporting 'maxReleaseChecks' 12)

if ($Date) {
    try { $today = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null).ToString('yyyy-MM-dd') }
    catch { throw ('invalid -Date, expected yyyy-MM-dd: ' + $Date) }
} else {
    $today = (Get-Date).ToString('yyyy-MM-dd')
}
$pushedFrom = (Get-Date).AddDays(-1 * $pushedWithinDays).ToString('yyyy-MM-dd')
$newFrom    = (Get-Date).AddDays(-1 * $emergingDays).ToString('yyyy-MM-dd')

# --------------------------------------------------- deferred marking / one run a day
$outFile = Join-Path $dataDir ("candidates-$today.json")

# Callers pass the digest they actually published back here, so a collection
# whose digest failed does not burn candidates. Only links that came from the
# fresh buckets are marked; an unused pick stays available for tomorrow.
if ($CommitFrom) {
    if (-not (Test-Path -LiteralPath $CommitFrom)) { throw ('commit source not found: ' + $CommitFrom) }
    $published = [IO.File]::ReadAllText($CommitFrom, [Text.Encoding]::UTF8)
    $cand = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $fresh = @{}
    foreach ($r in @(@($cand.new_repos) + @($cand.growing_repos))) {
        if ($r -and $r.full_name) { $fresh[[string]$r.full_name] = $r.id }
    }
    $reportedFile = Join-Path $dataDir 'reported.json'
    $rows = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $reportedFile) {
        # PowerShell 5.1 wraps a top-level JSON array in one object; unwrap it.
        foreach ($item in ([IO.File]::ReadAllText($reportedFile, [Text.Encoding]::UTF8) | ConvertFrom-Json)) {
            foreach ($inner in @($item)) {
                if ($inner -and $inner.repo) { [void]$rows.Add($inner) }
            }
        }
    }
    $have = @{}
    $haveId = @{}
    foreach ($x in $rows) {
        $have[[string]$x.repo] = $true
        if ($x.id) { $haveId[[string]$x.id] = $true }
    }
    $added = 0
    foreach ($m in [regex]::Matches($published, 'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')) {
        $slug = $m.Groups[1].Value
        if (-not $fresh.ContainsKey($slug)) { continue }
        if ($have.ContainsKey($slug)) { continue }
        $newId = $fresh[$slug]
        if ($newId -and $haveId.ContainsKey([string]$newId)) { continue }
        [void]$rows.Add([pscustomobject]@{ repo = $slug; date = $today; id = $newId })
        $have[$slug] = $true
        if ($newId) { $haveId[[string]$newId] = $true }
        $added++
    }
    [IO.File]::WriteAllText($reportedFile, (ConvertTo-Json -InputObject @($rows) -Depth 4), $utf8Bom)
    Write-Output ('committed=' + $added + ' reported=' + $rows.Count)
    exit 0
}

# A second entry point (desktop shortcut, heartbeat) must reuse today's file
# instead of overwriting it and burning another 12 candidates from the pool.
if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
    Write-Output ('already-collected date=' + $today + ' json=' + $outFile)
    exit 0
}

$queries = @()
foreach ($q in @(Get-Prop $cfg 'queries' @())) {
    $text = [string](Get-Prop $q 'q' '')
    if (-not $text) { continue }
    $text = $text.Replace('{pushedFrom}', $pushedFrom)
    $text = $text.Replace('{newFrom}', $newFrom)
    $text = $text.Replace('{emergingFloor}', [string]$emergingFloor)
    $text = $text.Replace('{floor}', [string]$starFloor)
    $src = [string](Get-Prop $q 'source' 'query')
    $queries += [pscustomobject]@{ source = $src; q = $text }
}
if ($queries.Count -eq 0) { throw "no queries configured in $ConfigPath" }

# -------------------------------------------------------------------- requests
$tokenFile = Join-Path $OutputDir '.github-token'
if ((-not $Token) -and (Test-Path -LiteralPath $tokenFile)) {
    $Token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
}

$headers = @{
    'User-Agent' = 'codex-ai-digest'
    'Accept'     = 'application/vnd.github+json'
}
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

function Invoke-GitHubSearch {
    param([string]$Query, [int]$PerPage)
    $enc = [uri]::EscapeDataString($Query)
    $url = "https://api.github.com/search/repositories?q=$enc&sort=stars&order=desc&per_page=$PerPage"
    return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 45
}

# Unauthenticated search allows only 10 requests per minute per IP, so queries are
# spaced out and retried with backoff when rate limited.
function Invoke-GitHubSearchSafe {
    param([string]$Query, [int]$PerPage, [int]$MaxAttempts = 3)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-GitHubSearch -Query $Query -PerPage $PerPage
        } catch {
            $resp = $null
            $status = $null
            try {
                $resp = $_.Exception.Response
                if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }
            } catch { }
            $rateLimited = ($status -eq 403) -or ($status -eq 429)
            if ($rateLimited -and $attempt -lt $MaxAttempts) {
                $wait = 20 * $attempt
                try {
                    $hdr = $resp.Headers['X-RateLimit-Reset']
                    if ($hdr) {
                        $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$hdr).LocalDateTime
                        $secs = [int][Math]::Ceiling(($reset - (Get-Date)).TotalSeconds) + 3
                        if ($secs -gt 0 -and $secs -lt 120) { $wait = $secs }
                    }
                } catch { }
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

function ConvertTo-RepoRecord {
    param($Item, [string]$Source)
    $lic = $null
    if ($Item.license) { $lic = $Item.license.spdx_id }
    $ownerType = 'individual'
    if ($Item.owner -and $Item.owner.type -eq 'Organization') { $ownerType = 'org' }
    [pscustomobject]@{
        id          = [int64]$Item.id
        full_name   = $Item.full_name
        html_url    = $Item.html_url
        description = $Item.description
        stars       = [int]$Item.stargazers_count
        language    = $Item.language
        topics      = @($Item.topics)
        created_at  = $Item.created_at
        pushed_at   = $Item.pushed_at
        license     = $lic
        archived    = [bool]$Item.archived
        fork        = [bool]$Item.fork
        owner_type  = $ownerType
        tier        = $ownerType
        source      = $Source
    }
}

# Earlier runs could leave nested single-element arrays behind (a record wrapped
# in an array), which silently broke the dedup and heat lookups. Flatten here and
# keep only entries that really are records.
function Get-JsonList {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $out = New-Object System.Collections.ArrayList
    foreach ($item in $raw) {
        foreach ($inner in @($item)) {
            if ($inner -and $inner.repo) { [void]$out.Add($inner) }
        }
    }
    return $out
}

# -------------------------------------------------------------- collect repos
$repoMap = [ordered]@{}
$queryLog = @()
$firstQuery = $true
$filteredByTier = 0

foreach ($item in $queries) {
    if (-not $firstQuery) { Start-Sleep -Seconds 8 }
    $firstQuery = $false
    try {
        $resp = Invoke-GitHubSearchSafe -Query $item.q -PerPage $perPage
        $kept = 0
        foreach ($r in $resp.items) {
            if ($r.fork -or $r.archived) { continue }
            $rec = ConvertTo-RepoRecord -Item $r -Source $item.source

            # tiered floor: organization repos and individual repos use different bars
            $minStars = $minIndividual
            if ($rec.owner_type -eq 'org') { $minStars = $minOrg }
            if ($rec.stars -lt $minStars) { $filteredByTier++; continue }

            if ($repoMap.Contains($rec.full_name)) {
                $existing = $repoMap[$rec.full_name]
                $existing.source = (@($existing.source) + @($item.source) | Select-Object -Unique)
            } else {
                $repoMap[$rec.full_name] = $rec
            }
            $kept++
        }
        $queryLog += [pscustomobject]@{ source = $item.source; query = $item.q; returned = $kept; ok = $true }
    } catch {
        $queryLog += [pscustomobject]@{ source = $item.source; query = $item.q; returned = 0; ok = $false; error = $_.Exception.Message }
    }
}

$repos = @($repoMap.Values)

# ------------------------------------------------------- history and velocity
$histFile = Join-Path $dataDir 'history.json'
$history = @()
if (Test-Path -LiteralPath $histFile) {
    try { $history = @(Get-JsonList $histFile) } catch { $history = @() }
}

$histMap = @{}
foreach ($h in $history) {
    if (-not $h.date) { continue }
    # older snapshots only stored a date; the daily run happens around 08:00
    if (-not $h.ts) {
        $h | Add-Member -NotePropertyName ts -NotePropertyValue ($h.date + 'T08:00:00') -Force
    }
    if (-not $histMap.ContainsKey($h.repo)) { $histMap[$h.repo] = @() }
    $histMap[$h.repo] += $h
}

$now = Get-Date
# 1h tolerance, so a run a few seconds early still sees yesterday's snapshot
$cutShort = $now.AddHours(-1 * ($shortHours - 1))
$cutLong = $now.AddHours(-1 * ($longHours - 1))
$cut7 = $now.AddDays(-7)
$results = @()

foreach ($r in $repos) {
    $snaps = @()
    if ($histMap.ContainsKey($r.full_name)) {
        $snaps = @($histMap[$r.full_name] | Where-Object { $_.ts } | Sort-Object ts)
    }

    $deltaShort = $null; $deltaLong = $null; $delta7 = $null
    if ($snaps.Count -gt 0) {
        $olderShort = @($snaps | Where-Object { [datetime]$_.ts -le $cutShort })
        if ($olderShort.Count -gt 0) {
            $base = $olderShort[$olderShort.Count - 1]
            $deltaShort = $r.stars - [int]$base.stars
        }
        $olderLong = @($snaps | Where-Object { [datetime]$_.ts -le $cutLong })
        if ($olderLong.Count -gt 0) {
            $base = $olderLong[$olderLong.Count - 1]
            $deltaLong = $r.stars - [int]$base.stars
        }
        $older7 = @($snaps | Where-Object { [datetime]$_.ts -le $cut7 })
        if ($older7.Count -gt 0) {
            $base = $older7[$older7.Count - 1]
            $delta7 = $r.stars - [int]$base.stars
        }
    }

    # heat = the most recent block at full weight, the block before it at decay weight
    $heat = $null
    if ($deltaShort -ne $null -and $deltaLong -ne $null) {
        $heat = [Math]::Round((1.0 * $deltaShort) + $decay * ($deltaLong - $deltaShort), 1)
    } elseif ($deltaShort -ne $null) {
        $heat = [Math]::Round(1.0 * $deltaShort, 2)
    }

    $created = [datetime]$r.created_at
    $ageDays = [int][Math]::Max(1, ($now - $created).TotalDays)
    $r | Add-Member -NotePropertyName age_days -NotePropertyValue $ageDays -Force
    $r | Add-Member -NotePropertyName stars_per_day -NotePropertyValue ([Math]::Round($r.stars / $ageDays, 1)) -Force
    $r | Add-Member -NotePropertyName delta_short -NotePropertyValue $deltaShort -Force
    $r | Add-Member -NotePropertyName delta_long -NotePropertyValue $deltaLong -Force
    $r | Add-Member -NotePropertyName star_delta -NotePropertyValue $delta7 -Force
    $r | Add-Member -NotePropertyName heat -NotePropertyValue $heat -Force
    $r | Add-Member -NotePropertyName release_tag -NotePropertyValue $null -Force
    $r | Add-Member -NotePropertyName release_date -NotePropertyValue $null -Force
    $r | Add-Member -NotePropertyName resurface_reason -NotePropertyValue $null -Force
    $results += $r
}

# ------------------------------------------------------------ update history
foreach ($r in $results) {
    if (-not $histMap.ContainsKey($r.full_name)) { $histMap[$r.full_name] = @() }
    $sameDay = @($histMap[$r.full_name] | Where-Object { $_.date -eq $today })
    if ($sameDay.Count -eq 0) {
        $histMap[$r.full_name] += [pscustomobject]@{
            repo = $r.full_name; date = $today; ts = (Get-Date).ToString('s'); stars = $r.stars
        }
    }
}

$histKeep = (Get-Date).AddDays(-90).ToString('yyyy-MM-dd')
$newHistory = @()
foreach ($k in $histMap.Keys) {
    $newHistory += @($histMap[$k] | Where-Object { $_.date -ge $histKeep })
}
[IO.File]::WriteAllText($histFile, ($newHistory | ConvertTo-Json -Depth 4), $utf8Bom)

# ------------------------------------------------------------- reported list
$reportedFile = Join-Path $dataDir 'reported.json'
$reportedMap = @{}
$reportedById = @{}
$reportedRows = @()
$reportedLoaded = 0
if (Test-Path -LiteralPath $reportedFile) {
    try {
        foreach ($x in (Get-JsonList $reportedFile)) {
            # one unreadable record must not throw away the whole dedup list
            try {
                $d = [datetime]::ParseExact([string]$x.date, 'yyyy-MM-dd', $null)
                if ($reportedMap.ContainsKey($x.repo)) {
                    if ($d -gt $reportedMap[$x.repo]) { $reportedMap[$x.repo] = $d }
                } else {
                    $reportedMap[$x.repo] = $d
                }
                if ($x.id) {
                    $k = [string]$x.id
                    if (-not $reportedById.ContainsKey($k) -or $d -gt $reportedById[$k]) { $reportedById[$k] = $d }
                }
                $reportedRows += $x
                $reportedLoaded++
            } catch { }
        }
    } catch { }
}

# GitHub's numeric id survives renames and owner transfers; full_name does not.
function Get-ReportedDate {
    param($Repo)
    if ($Repo.id -and $reportedById.ContainsKey([string]$Repo.id)) { return $reportedById[[string]$Repo.id] }
    if ($reportedMap.ContainsKey([string]$Repo.full_name)) { return $reportedMap[[string]$Repo.full_name] }
    return $null
}

# ------------------------------------------------------------------- ranking
$withHeat = @($results | Where-Object { $_.heat -ne $null } | Sort-Object heat -Descending)
$withoutHeat = @($results | Where-Object { $_.heat -eq $null } | Sort-Object stars_per_day -Descending)
$ranked = @($withHeat + $withoutHeat)

$newRepos = @($ranked | Where-Object { $null -eq (Get-ReportedDate $_) } | Select-Object -First $maxNew)

# resurface: already pushed, but something happened worth another look
$resurfaceCandidates = @()
foreach ($r in $results) {
    $lastSeen = Get-ReportedDate $r
    if (-not $lastSeen) { continue }
    $daysSince = ($now - $lastSeen).TotalDays
    if ($daysSince -lt $resurfaceMinDays) { continue }
    $dLong = 0
    if ($r.delta_long -ne $null) { $dLong = [int]$r.delta_long }
    if ($dLong -ge $resurfaceMinDelta) {
        $r.resurface_reason = 'surge +' + $dLong + ' stars in ' + $longHours + 'h'
        $resurfaceCandidates += $r
    } elseif ($dLong -ge $releaseMinDelta) {
        $resurfaceCandidates += $r
    }
}

# release check: a version published after the last time we pushed it is real news
if (-not $SkipReleaseCheck -and $resurfaceCandidates.Count -gt 0) {
    $checked = 0
    foreach ($r in @($resurfaceCandidates | Sort-Object delta_long -Descending)) {
        if ($checked -ge $maxReleaseChecks) { break }
        $checked++
        try {
            $rel = Invoke-RestMethod -Uri ("https://api.github.com/repos/" + $r.full_name + "/releases/latest") `
                -Headers $headers -Method Get -TimeoutSec 30
            if ($rel -and $rel.published_at) {
                $pub = [datetime]$rel.published_at
                $last = [datetime](Get-ReportedDate $r)
                if ($pub -gt $last) {
                    $r.release_tag = $rel.tag_name
                    $r.release_date = $pub.ToString('yyyy-MM-dd')
                    $r.resurface_reason = 'release ' + $rel.tag_name + ' on ' + $pub.ToString('yyyy-MM-dd')
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
}

$growing = @(
    $resurfaceCandidates |
    Where-Object { $_.resurface_reason } |
    Sort-Object -Property @{ Expression = { if ($_.delta_long) { [int]$_.delta_long } else { 0 } } } -Descending |
    Select-Object -First $maxGrowing
)

$popular = @($results | Sort-Object stars -Descending | Select-Object -First $popularCount)

# mark what this run pushes, so tomorrow stays fresh; the resurface window is kept
$reportedList = @()
foreach ($x in $reportedRows) { $reportedList += $x }
foreach ($r in @($newRepos + $growing)) {
    $known = @($reportedList | Where-Object {
        ($r.id -and $_.id -and [string]$_.id -eq [string]$r.id) -or $_.repo -eq $r.full_name
    })
    if ($known.Count -gt 0) { continue }
    $reportedList += [pscustomobject]@{ repo = $r.full_name; date = $today; id = $r.id }
}
if ($NoMark) {
    Write-Output 'no-mark: reported.json left unchanged'
} else {
    [IO.File]::WriteAllText($reportedFile, ($reportedList | ConvertTo-Json -Depth 4), $utf8Bom)
}

# ------------------------------------------------------------------- payload

$heatAvailable = @($results | Where-Object { $_.heat -ne $null }).Count
$payload = [pscustomobject]@{
    date            = $today
    generated_at    = (Get-Date).ToString('s')
    authenticated   = [bool]$Token
    candidates_seen = $results.Count
    heat_available  = $heatAvailable
    filtered_by_tier = $filteredByTier
    settings        = [pscustomobject]@{
        heat            = 'stars gained in last ' + $shortHours + 'h plus the previous block at ' + $decay + ' weight'
        tier_min_stars  = [pscustomobject]@{ org = $minOrg; individual = $minIndividual }
        resurface_rule  = 'again after ' + $resurfaceMinDays + ' days when a release appeared or ' + $resurfaceMinDelta + '+ stars gained in ' + $longHours + 'h'
    }
    queries         = $queryLog
    new_repos       = $newRepos
    growing_repos   = $growing
    popular_repos   = $popular
}

[IO.File]::WriteAllText($outFile, ($payload | ConvertTo-Json -Depth 6), $utf8Bom)

$failed = @($queryLog | Where-Object { -not $_.ok })
Write-Output ("date=" + $today + " seen=" + $results.Count + " new=" + $newRepos.Count +
    " growing=" + $growing.Count + " heat_data=" + $heatAvailable +
    " tier_filtered=" + $filteredByTier + " reported_loaded=" + $reportedLoaded +
    " failed_queries=" + $failed.Count + " auth=" + [bool]$Token)
Write-Output ("json=" + $outFile)
foreach ($f in $failed) { Write-Output ("  query_failed: " + $f.source + " - " + $f.error) }
