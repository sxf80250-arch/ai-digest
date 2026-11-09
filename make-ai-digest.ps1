#requires -Version 5
<#
  Write the daily digest with the DeepSeek Chat Completions API.

  The API key is read only from DEEPSEEK_API_KEY. Candidate data stays local
  to this project and is sent to the configured API endpoint for generation.
  This source is pure ASCII because Windows PowerShell 5.1 reads BOM-less
  scripts as ANSI/GBK; Chinese prompt text lives in digest-prompt.md.
#>
[CmdletBinding()]
param(
    [string]$Date = '',
    [string]$CandidatesPath = '',
    [string]$SignalsPath = '',
    [string]$OutPath = '',
    [string]$PromptPath = '',
    [string]$Model = 'deepseek-flash',
    [string]$BaseUrl = 'https://api.deepseek.com',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
try { $Date = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null).ToString('yyyy-MM-dd') }
catch { throw ('invalid -Date, expected yyyy-MM-dd: ' + $Date) }

if (-not $CandidatesPath) { $CandidatesPath = Join-Path $PSScriptRoot ('data\candidates-' + $Date + '.json') }
if (-not $PromptPath) { $PromptPath = Join-Path $PSScriptRoot 'digest-prompt.md' }
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot ($Date + '-ai-digest.md') }

if (-not (Test-Path -LiteralPath $CandidatesPath)) { throw ('candidate file not found: ' + $CandidatesPath) }
if (-not (Test-Path -LiteralPath $PromptPath)) { throw ('prompt file not found: ' + $PromptPath) }

function Read-Utf8 {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Select-Repo {
    param($Repo)
    return [pscustomobject]@{
        full_name        = [string]$Repo.full_name
        html_url         = [string]$Repo.html_url
        description      = [string]$Repo.description
        topics           = @($Repo.topics | Select-Object -First 8)
        language         = [string]$Repo.language
        license          = [string]$Repo.license
        stars            = $Repo.stars
        heat             = $Repo.heat
        delta_short      = $Repo.delta_short
        age_days         = $Repo.age_days
        created_at       = [string]$Repo.created_at
        resurface_reason = [string]$Repo.resurface_reason
    }
}

$data = Read-Utf8 $CandidatesPath | ConvertFrom-Json
$newRepos = @($data.new_repos | ForEach-Object { Select-Repo $_ })
$growingRepos = @($data.growing_repos | ForEach-Object { Select-Repo $_ })
$popularRepos = @($data.popular_repos | ForEach-Object { Select-Repo $_ })

if ($newRepos.Count -eq 0 -and $growingRepos.Count -eq 0) {
    throw 'no new or growing repositories are available for the digest'
}

$signals = 'external_signals=unavailable'
if ($SignalsPath -and (Test-Path -LiteralPath $SignalsPath)) {
    $signals = Read-Utf8 $SignalsPath
}
if ($signals.Length -gt 24000) { $signals = $signals.Substring(0, 24000) }

$brief = [pscustomobject]@{
    date            = $Date
    candidates_seen = $data.candidates_seen
    heat_available  = $data.heat_available
    new_repos       = $newRepos
    growing_repos   = $growingRepos
    popular_repos   = @($popularRepos | Select-Object -First 5)
}
$briefJson = $brief | ConvertTo-Json -Depth 7

$prompt = Read-Utf8 $PromptPath
$prompt = $prompt.Replace('{{DATE}}', $Date)
$prompt = $prompt.Replace('{{CANDIDATES_JSON}}', $briefJson)
$prompt = $prompt.Replace('{{EXTERNAL_SIGNALS}}', $signals)

if ($DryRun) {
    Write-Output ('dry_run=1 model=' + $Model + ' date=' + $Date)
    Write-Output ('new=' + $newRepos.Count + ' growing=' + $growingRepos.Count + ' popular=' + $popularRepos.Count)
    Write-Output ('prompt_chars=' + $prompt.Length + ' out=' + $OutPath)
    return
}

$apiKey = [string]$env:DEEPSEEK_API_KEY
if (-not $apiKey.Trim()) { throw 'DEEPSEEK_API_KEY is not set' }
if (-not $BaseUrl) { throw '-BaseUrl is required' }
$endpoint = $BaseUrl.TrimEnd('/') + '/chat/completions'

$request = @{
    model = $Model
    messages = @(
        @{
            role = 'system'
            content = 'Follow the supplied editorial specification exactly. Return Markdown only.'
        },
        @{
            role = 'user'
            content = $prompt
        }
    )
    thinking = @{ type = 'disabled' }
    temperature = 0.4
    max_tokens = 6000
}
$body = $request | ConvertTo-Json -Depth 8
$bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
$headers = @{
    Authorization = 'Bearer ' + $apiKey.Trim()
    'Content-Type' = 'application/json; charset=utf-8'
}

try {
    $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 240
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    throw ('DeepSeek request failed' + $(if ($status) { ' (HTTP ' + $status + ')' } else { '' }) + ': ' + $_.Exception.Message)
}

$choice = @($response.choices)[0]
if (-not $choice) { throw 'DeepSeek returned no choices' }
if ([string]$choice.finish_reason -ne 'stop') {
    throw ('DeepSeek stopped early: ' + [string]$choice.finish_reason)
}

$markdown = [string]$choice.message.content
$markdown = $markdown.Trim()
if ($markdown -match '(?s)^```(?:markdown)?\s*(.*?)\s*```$') { $markdown = $Matches[1].Trim() }
$titleIndex = $markdown.IndexOf('# AI ')
if ($titleIndex -gt 0) { $markdown = $markdown.Substring($titleIndex).Trim() }

$expectedTitle = [regex]::Unescape('\u0023 AI \u9879\u76ee\u65e5\u62a5 \u00b7 ') + $Date
if (-not $markdown.StartsWith($expectedTitle)) {
    throw ('digest title mismatch; expected: ' + $expectedTitle)
}
if ($markdown -notmatch 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+') {
    throw 'digest contains no GitHub repository link'
}
$allowed = @{}
foreach ($repo in @(@($data.new_repos) + @($data.growing_repos) + @($data.popular_repos))) {
    if ($repo -and $repo.full_name) { $allowed[[string]$repo.full_name] = $true }
}
foreach ($match in [regex]::Matches($markdown, 'https?://[^\s<>()\[\]]+')) {
    $url = $match.Value.TrimEnd('.', ',', ';')
    if ($url -match '^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$') {
        $slug = $Matches[1]
    } else {
        throw ('digest contains a non-repository URL: ' + $url)
    }
    if (-not $allowed.ContainsKey($slug)) {
        throw ('digest contains a repository outside the candidate pool: ' + $slug)
    }
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[IO.File]::WriteAllText($OutPath, $markdown, $utf8Bom)

Write-Output ('digest=' + $OutPath)
Write-Output ('model=' + [string]$response.model + ' prompt_tokens=' + [string]$response.usage.prompt_tokens +
    ' completion_tokens=' + [string]$response.usage.completion_tokens)
