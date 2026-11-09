#requires -Version 5
<#
  External signals for the daily digest: is anyone outside GitHub actually
  covering this project? Backends are the already-installed Agent Reach ones:
    - Exa web search (mcporter call exa.web_search_exa), github.com hits excluded
    - Bilibili video search (bili search --type video)
  Best effort by design: a broken backend prints err and never blocks the digest.
  Output is one ASCII-labelled line per project, with any Chinese titles kept
  intact (console set to UTF-8).
#>
[CmdletBinding()]
param(
    [string]$Dir = '',
    [string]$Date = '',
    [int]$Top = 3
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
if (-not $Dir) { $Dir = $PSScriptRoot }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }

function Get-Tool {
    param([string]$Name, [string[]]$Candidates)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# returns @{ ok = <bool>; text = <string> }
function Invoke-Tool {
    param([string]$Exe, [string[]]$CmdArgs, [int]$TimeoutSec = 120)
    $ok = $false
    $text = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        # .NET Framework has no ArgumentList, so quote the arguments by hand
        $quoted = foreach ($a in $CmdArgs) {
            if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
        }
        $psi.Arguments = ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        # read both pipes asynchronously, otherwise a full pipe can deadlock
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($TimeoutSec * 1000)) {
            $ok = ($p.ExitCode -eq 0)
        } else {
            try { $p.Kill() } catch { }
        }
        $text = $outTask.Result
        $errText = $errTask.Result
        if (-not $text) { $text = '' }
        if (-not $ok -and $errText) { $text = $text + $errText }
    } catch {
        $ok = $false
    }
    return @{ ok = $ok; text = $text }
}

$candFile = Join-Path $Dir ('data\candidates-' + $Date + '.json')
if (-not (Test-Path -LiteralPath $candFile)) { Write-Output ('no_candidates_file=' + $candFile); exit 0 }

$data = Get-Content -LiteralPath $candFile -Raw -Encoding UTF8 | ConvertFrom-Json
$picks = @($data.new_repos | Select-Object -First $Top)
if ($picks.Count -eq 0) { Write-Output 'no_repos'; exit 0 }

$nodeDir = Split-Path (Get-Command node -ErrorAction SilentlyContinue).Source
$mcporter = Get-Tool 'mcporter' @((Join-Path $nodeDir 'mcporter.cmd'))
$bili = Get-Tool 'bili' @((Join-Path $env:USERPROFILE '.local\bin\bili.exe'))
Write-Output ('tools | mcporter=' + ($(if ($mcporter) { 'ok' } else { 'missing' })) + ' | bili=' + ($(if ($bili) { 'ok' } else { 'missing' })))

foreach ($p in $picks) {
    $repo = $p.full_name
    $name = $repo.Split('/')[-1]

    # ---- third party coverage (github.com itself does not count) ----
    $webCount = 'err'; $webTop = ''
    if ($mcporter) {
        # natural-language phrasing works far better than a keyword pile
        $q = 'query="blog posts, tutorials and reviews about the project ' + $repo + '"'
        $res = Invoke-Tool $mcporter @('call', 'exa.web_search_exa', $q, 'numResults=8') 150
        if ($res.ok -and $res.text) {
            $blocks = [regex]::Matches($res.text, '(?s)Title:\s*(.+?)\s*URL:\s*(\S+)')
            $thirdParty = @()
            foreach ($b in $blocks) {
                $u = $b.Groups[2].Value
                if ($u -notmatch 'github\.com') { $thirdParty += $b.Groups[1].Value.Trim() }
            }
            $webCount = [string]$thirdParty.Count
            if ($thirdParty.Count -gt 0) { $webTop = $thirdParty[0] }
        }
    }

    # ---- chinese video coverage ----
    $biliCount = 'err'; $biliTop = ''
    if ($bili) {
        $res2 = Invoke-Tool $bili @('search', ('"' + $name + '"'), '--type', 'video', '-n', '5', '--yaml') 120
        if ($res2.ok) {
            $ids = @([regex]::Matches($res2.text, '(?m)^- id:\s*(BV\w+)') | ForEach-Object { $_.Groups[1].Value })
            $biliCount = [string]$ids.Count
            $t = [regex]::Match($res2.text, '(?m)^\s*title:\s*(.+)$')
            if ($t.Success) { $biliTop = $t.Groups[1].Value.Trim() }
        }
    }

    # ---- direction trend: is the wider area being discussed lately? ----
    # Exa exposes no date filter, so "last 30 days" is a ranking hint, not a guarantee.
    $trend30 = 'err'; $trend30Top = ''
    if ($mcporter) {
        $direction = [string]$p.description
        if (-not $direction) { $direction = (@($p.topics | Select-Object -First 2) -join ' ') }
        if (-not $direction) { $direction = $name }
        $direction = ($direction -split '\.')[0].Trim()
        if ($direction.Length -gt 90) { $direction = $direction.Substring(0, 90) }
        $q3 = 'query="what people are discussing about ' + $direction + ' in the last 30 days"'
        $res3 = Invoke-Tool $mcporter @('call', 'exa.web_search_exa', $q3, 'numResults=5', 'objective="pages published in the last 30 days"') 150
        if ($res3.ok -and $res3.text) {
            $blocks3 = [regex]::Matches($res3.text, '(?s)Title:\s*(.+?)\s*URL:\s*(\S+)')
            $recent = @()
            foreach ($b in $blocks3) {
                $u = $b.Groups[2].Value
                if ($u -notmatch 'github\.com') { $recent += $b.Groups[1].Value.Trim() }
            }
            $trend30 = [string]$recent.Count
            if ($recent.Count -gt 0) { $trend30Top = $recent[0] }
        }
    }

    $line = 'repo=' + $repo + ' | third_party_pages=' + $webCount + ' | bili_videos=' + $biliCount
    if ($biliTop) { $line += ' | bili_top=' + $biliTop }
    if ($webTop) { $line += ' | web_top=' + $webTop }
    $line += ' | trend30_pages=' + $trend30
    if ($trend30Top) { $line += ' | trend30_top=' + $trend30Top }
    Write-Output $line
}
