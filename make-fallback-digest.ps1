#requires -Version 5
<#
  Generate a digest with no model involvement, then build the site.

  Used when the daily 08:00 agent run has not produced today's issue yet: the
  launcher shows this as a progress window and opens the result in the browser.
  User-facing text lives in fallback-template.md (UTF-8); this source stays pure
  ASCII because PowerShell 5.1 reads BOM-less files as ANSI/GBK.
#>
[CmdletBinding()]
param(
    [string]$Dir = '',
    [string]$Date = '',
    [string]$OutDir = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

if (-not $Dir) { $Dir = $PSScriptRoot }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $OutDir) { $OutDir = $Dir }

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Read-Utf8 { param([string]$Path) return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }

function Extract-Block {
    param([string]$Text, [string]$Name)
    $startTag = '<!--' + $Name + '-->'
    $endTag = '<!--/' + $Name + '-->'
    $i = $Text.IndexOf($startTag)
    $j = $Text.IndexOf($endTag)
    if ($i -lt 0 -or $j -lt 0) { throw "template block not found: $Name" }
    return $Text.Substring($i + $startTag.Length, $j - $i - $startTag.Length).Trim()
}

function Clean-Text {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text -replace '[\r\n]+', ' '
    $t = $t -replace '[`*_]', ''
    $t = $t -replace '<', ' '
    $t = $t -replace '>', ' '
    $t = $t.Trim()
    if ($t.StartsWith('#')) { $t = $t.TrimStart('#').Trim() }
    return $t
}

$template = Read-Utf8 (Join-Path $Dir 'fallback-template.md')
$msgGenerating = Extract-Block -Text $template -Name 'MSG_GENERATING'
$msgCollectFailed = Extract-Block -Text $template -Name 'MSG_COLLECT_FAILED'

$dataDir = Join-Path $Dir 'data'
$candFile = Join-Path $dataDir ('candidates-' + $Date + '.json')
$lockFile = Join-Path $dataDir '.generating'

if (Test-Path -LiteralPath $lockFile) {
    $age = (Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt 15) {
        Write-Output 'another generation is already running'
        exit 0
    }
}

Write-Output $msgGenerating
[IO.File]::WriteAllText($lockFile, (Get-Date).ToString('s'), $utf8Bom)

try {
    $needsCollect = $true
    if (Test-Path -LiteralPath $candFile) {
        $age = (Get-Date) - (Get-Item -LiteralPath $candFile).LastWriteTime
        if ($age.TotalMinutes -lt 30) { $needsCollect = $false }
    }

    if ($needsCollect) {
        $collector = Join-Path $Dir 'collect-github-ai.ps1'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $collector -NoMark
        } catch {
            Write-Output $msgCollectFailed
            Write-Output $_.Exception.Message
            exit 2
        }
    }

    if (-not (Test-Path -LiteralPath $candFile)) {
        Write-Output $msgCollectFailed
        exit 2
    }

    $data = Read-Utf8 $candFile | ConvertFrom-Json

    $star = [string][char]0x2605
    $dash = [string][char]0x2014
    $dot = [string][char]0x00B7

    $itemBlock = Extract-Block -Text $template -Name 'ITEM'
    $signalBlock = Extract-Block -Text $template -Name 'SIGNAL'
    $reasonBlock = Extract-Block -Text $template -Name 'REASON'
    $sectionBlock = Extract-Block -Text $template -Name 'SECTION'
    $titleNew = Extract-Block -Text $template -Name 'TITLE_NEW'
    $titleGrowing = Extract-Block -Text $template -Name 'TITLE_GROWING'
    $noNews = Extract-Block -Text $template -Name 'NO_NEWS'

    $shortHours = 24
    if ($data.settings -and $data.settings.heat -match '(\d+)') { $shortHours = [int]$Matches[1] }

    function Render-Items {
        param($Items)
        $out = ''
        foreach ($r in $Items) {
            $tech = [string]$r.language
            if ($r.license) { $tech = $tech + ' ' + $dot + ' ' + [string]$r.license }
            if (-not $tech) { $tech = '-' }

            $signal = ''
            if ($r.delta_short -ne $null) {
                $signal = $signalBlock
                $signal = $signal.Replace('{{SHORT_HOURS}}', [string]$script:shortHours)
                $signal = $signal.Replace('{{DELTA_SHORT}}', ('{0:N0}' -f [int]$r.delta_short))
                $signal = $signal.Replace('{{STARS}}', ('{0:N0}' -f [int]$r.stars))
                $signal = $signal.Replace('{{CREATED}}', ([datetime]$r.created_at).ToString('yyyy-MM-dd'))
            }

            $reason = ''
            if ($r.resurface_reason) {
                $reason = $reasonBlock.Replace('{{REASON_TEXT}}', (Clean-Text ([string]$r.resurface_reason)))
            }

            $desc = Clean-Text ([string]$r.description)
            if (-not $desc) { $desc = '-' }

            $block = $itemBlock
            $block = $block.Replace('{{NAME}}', (Clean-Text ([string]$r.full_name)))
            $block = $block.Replace('{{STARS}}', ('{0:N0}' -f [int]$r.stars))
            $block = $block.Replace('{{AGE_DAYS}}', [string]$r.age_days)
            $block = $block.Replace('{{TECH}}', $tech)
            $block = $block.Replace('{{DESC}}', $desc)
            $block = $block.Replace('{{SIGNAL}}', $signal)
            $block = $block.Replace('{{REASON}}', $reason)
            $block = $block.Replace('{{LINK}}', [string]$r.html_url)
            $out += $block + "`r`n`r`n"
        }
        return $out
    }

    $sections = ''
    $newItems = @($data.new_repos)
    $growingItems = @($data.growing_repos)

    if ($newItems.Count -gt 0) {
        $sec = $sectionBlock
        $sec = $sec.Replace('{{SECTION_TITLE}}', $titleNew)
        $sec = $sec.Replace('{{SECTION_ITEMS}}', (Render-Items -Items $newItems))
        $sections += $sec + "`r`n`r`n"
    }
    if ($growingItems.Count -gt 0) {
        $sec = $sectionBlock
        $sec = $sec.Replace('{{SECTION_TITLE}}', $titleGrowing)
        $sec = $sec.Replace('{{SECTION_ITEMS}}', (Render-Items -Items $growingItems))
        $sections += $sec + "`r`n`r`n"
    }
    if ($newItems.Count -eq 0 -and $growingItems.Count -eq 0) {
        $sections += $noNews + "`r`n"
    }

    $head = $template.Substring(0, $template.IndexOf('<!--SECTION-->'))
    $head = $head.Replace('{{DATE}}', $Date)
    $head = $head.Replace('{{COUNT}}', [string]$newItems.Count)
    $head = $head.Replace('{{GROWING}}', [string]$growingItems.Count)
    $head = $head.Replace('{{BODY}}', $sections.Trim())

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $outFile = Join-Path $OutDir ($Date + '-ai-digest.md')
    [IO.File]::WriteAllText($outFile, $head, $utf8Bom)
    Write-Output ('digest=' + $outFile)

    # Mark only what the digest actually published, now that it exists.
    $picks = Join-Path (Join-Path $Dir 'data') ($Date + '.json')
    if (Test-Path -LiteralPath $picks) {
        $collector = Join-Path $Dir 'collect-github-ai.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $collector -CommitFrom $outFile
    }

    if (-not $SkipBuild) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'build-site.ps1') -Dir $OutDir -Pdf
    }
} finally {
    if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force }
}
