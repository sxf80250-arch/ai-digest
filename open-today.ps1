#requires -Version 5
<#
  Desktop shortcut worker. It checks the public latest.json once, then opens
  today's issue or offers the newest available issue. It performs no startup
  work and no background polling. User-facing text lives in site-config.json.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'site-config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw ('config file not found: ' + $ConfigPath) }

$config = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$baseUrl = ([string]$config.siteBaseUrl).Trim().TrimEnd('/')
$messages = $config.messages

function Show-Message {
    param([string]$Text, [string]$Title, [switch]$Question)
    if ($DryRun) {
        Write-Host ('message=' + $Text.Replace("`r", ' ').Replace("`n", ' '))
        return $false
    }
    Add-Type -AssemblyName System.Windows.Forms
    if ($Question) {
        $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $buttons, $icon) -eq [System.Windows.Forms.DialogResult]::Yes
    }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    return $false
}

function Open-Url {
    param([string]$Url)
    if ($DryRun) {
        Write-Output ('open=' + $Url)
        return
    }
    Start-Process -FilePath $Url
}

if (-not $baseUrl -or $baseUrl -match 'OWNER|REPOSITORY') {
    [void](Show-Message ([string]$messages.configurationBody) ([string]$messages.configurationTitle))
    if ($DryRun) { Write-Output 'status=not_configured' }
    exit 1
}

$stamp = (Get-Date).ToString('yyyyMMddHHmmss')
$metaUrl = $baseUrl + '/latest.json?v=' + $stamp
$json = & curl.exe -L --fail --silent --show-error --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 20 $metaUrl 2>&1
if ($LASTEXITCODE -ne 0) {
    [void](Show-Message ([string]$messages.offlineBody) ([string]$messages.offlineTitle))
    if ($DryRun) { Write-Output ('status=offline error=' + ($json -join ' ')) }
    exit 1
}
try {
    $latest = ($json -join "`n").TrimStart([char]0xFEFF) | ConvertFrom-Json
} catch {
    [void](Show-Message ([string]$messages.latestMissingBody) ([string]$messages.notReadyTitle))
    if ($DryRun) { Write-Output ('status=invalid_json error=' + $_.Exception.Message) }
    exit 1
}

$latestDate = [string]$latest.date
$latestHtml = ([string]$latest.html).TrimStart('/')
try { $latestDate = [datetime]::ParseExact($latestDate, 'yyyy-MM-dd', $null).ToString('yyyy-MM-dd') }
catch { $latestDate = '' }
if (-not $latestDate -or $latestHtml -notmatch '^\d{4}-\d{2}-\d{2}\.html$') {
    [void](Show-Message ([string]$messages.latestMissingBody) ([string]$messages.notReadyTitle))
    if ($DryRun) { Write-Output 'status=invalid_metadata' }
    exit 1
}

$today = (Get-Date).ToString('yyyy-MM-dd')
if ($latestDate -eq $today) {
    if ($DryRun) { Write-Output ('status=today date=' + $today) }
    Open-Url ($baseUrl + '/' + $latestHtml)
    exit 0
}

$text = ([string]$messages.notReadyBody).Replace('{date}', $latestDate)
$openLatest = Show-Message $text ([string]$messages.notReadyTitle) -Question
if ($DryRun) { Write-Output ('status=not_ready today=' + $today + ' latest=' + $latestDate) }
if ($openLatest) { Open-Url ($baseUrl + '/' + $latestHtml) }
exit 0
