#requires -Version 5
<#
  Build a browsable static site from *-ai-digest.md files.

  Output: <Dir>\site\style.css
          <Dir>\site\bg.jpg              background artwork, copied from <Dir>\bg.jpg
          <Dir>\site\index.html          list of every issue
          <Dir>\site\<date>.html         one page per issue
          <Dir>\site\<date>.pdf          newest issue, only with -Pdf
          <Dir>\site\latest.json         newest issue metadata for the desktop shortcut

  This script source is deliberately pure ASCII. PowerShell 5.1 reads BOM-less
  script files using the ANSI code page, which corrupts non-ASCII source text.
  Every Chinese label lives in the UTF-8 template files, which are read here with
  an explicit UTF-8 decoder. The stylesheet is one of those files
  (style-template.css), not an inline here-string, so it can carry non-ASCII
  comments and be edited without touching this script.
#>
[CmdletBinding()]
param(
    [string]$Dir = '',
    [switch]$Pdf,
    [string]$EdgePath = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = $PSScriptRoot }

$siteDir = Join-Path $Dir 'site'
if (-not (Test-Path -LiteralPath $siteDir)) {
    New-Item -ItemType Directory -Path $siteDir -Force | Out-Null
}
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$DASH = [string][char]0x2014   # em dash separator between name and stats
$DOT  = [string][char]0x00B7   # middle dot separator between stat badges
$STAR = [string][char]0x2605   # star glyph
# "external signal:" label, built from escapes so this source stays pure ASCII
$SIGNAL_LABEL = [regex]::Unescape('\u5916\u90E8\u4FE1\u53F7\uff1a')

function Read-Utf8 {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8Bom)
}

function Extract-Block {
    param([string]$Text, [string]$Name)
    $startTag = '<!--' + $Name + '-->'
    $endTag = '<!--/' + $Name + '-->'
    $i = $Text.IndexOf($startTag)
    $j = $Text.IndexOf($endTag)
    if ($i -lt 0 -or $j -lt 0) { throw "template block not found: $Name" }
    $block = $Text.Substring($i + $startTag.Length, $j - $i - $startTag.Length)
    $script:templateRest = $Text.Remove($i, ($j + $endTag.Length) - $i)
    return $block
}

function Convert-InlineText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = [Net.WebUtility]::HtmlEncode($Text)
    $t = [regex]::Replace($t, '&lt;(https?://[^\s&]+?)&gt;', {
            param($m) '<a href="' + $m.Groups[1].Value + '">' + $m.Groups[1].Value + '</a>'
        })
    $t = [regex]::Replace($t, '\[([^\]]+)\]\((https?://[^\s)]+)\)', {
            param($m) '<a href="' + $m.Groups[2].Value + '">' + $m.Groups[1].Value + '</a>'
        })
    $t = [regex]::Replace($t, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $t = [regex]::Replace($t, '`([^`]+)`', '<code>$1</code>')
    return $t
}

# Assets ship next to the templates; fall back to this script's own folder when
# -Dir points at a different output directory.
$assetDir = $Dir
if (-not (Test-Path -LiteralPath (Join-Path $assetDir 'style-template.css')) -and $PSScriptRoot) {
    $assetDir = $PSScriptRoot
}
$styleFile = Join-Path $assetDir 'style-template.css'
if (-not (Test-Path -LiteralPath $styleFile)) {
    throw ('style-template.css not found: ' + $styleFile)
}
$css = Read-Utf8 $styleFile

$cardBlock = Extract-Block -Text (Read-Utf8 (Join-Path $Dir 'card-template.html')) -Name 'CARD'
$sectionBlockSrc = Read-Utf8 (Join-Path $Dir 'card-template.html')
$sectionBlock = Extract-Block -Text $sectionBlockSrc -Name 'SECTION'
$issueTemplate = Read-Utf8 (Join-Path $Dir 'site-template.html')
$indexTemplateSrc = Read-Utf8 (Join-Path $Dir 'index-template.html')
$itemBlock = Extract-Block -Text $indexTemplateSrc -Name 'ITEM'
$indexTemplate = $templateRest

Write-Utf8 (Join-Path $siteDir 'style.css') $css

$bgFile = Join-Path $assetDir 'bg.jpg'
if (Test-Path -LiteralPath $bgFile) {
    Copy-Item -LiteralPath $bgFile -Destination (Join-Path $siteDir 'bg.jpg') -Force
}

$mdFiles = @(
    Get-ChildItem -LiteralPath $Dir -Filter '*-ai-digest.md' -File |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}' } |
    Sort-Object Name -Descending
)

if ($mdFiles.Count -eq 0) {
    Write-Output 'no digest files found'
    return
}

$pages = @()

foreach ($f in $mdFiles) {
    $date = $f.Name.Substring(0, 10)
    $lines = ((Read-Utf8 $f.FullName) -replace "`r", '') -split "`n"

    # A digest may only cite repos that existed in that day's candidate pool.
    # Catches a digest written from stale or invented data before it is published.
    $snapFile = Join-Path (Join-Path $Dir 'data') ('candidates-' + $date + '.json')
    if (Test-Path -LiteralPath $snapFile) {
        $snap = [IO.File]::ReadAllText($snapFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $known = @{}
        foreach ($b in @(@($snap.new_repos) + @($snap.growing_repos) + @($snap.popular_repos))) {
            if ($b) { $known[[string]$b.full_name] = $true }
        }
        $histFile = Join-Path (Join-Path $Dir 'data') 'history.json'
        if (Test-Path -LiteralPath $histFile) {
            # PowerShell 5.1 wraps a top-level JSON array in one object; unwrap it.
            foreach ($item in ([IO.File]::ReadAllText($histFile, [Text.Encoding]::UTF8) | ConvertFrom-Json)) {
                foreach ($h in @($item)) {
                    if ([string]$h.date -eq $date) { $known[[string]$h.repo] = $true }
                }
            }
        }
        $unknown = @()
        foreach ($m in [regex]::Matches(($lines -join "`n"), 'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')) {
            $slug = $m.Groups[1].Value
            if (-not $known.ContainsKey($slug) -and $unknown -notcontains $slug) { $unknown += $slug }
        }
        if ($unknown.Count -gt 0) {
            throw ('digest ' + $date + ' cites repos not in that day''s candidate pool: ' + ($unknown -join ', '))
        }
    }

    $pageTitle = $date
    $sections = New-Object System.Collections.ArrayList
    $curSection = $null
    $curCard = $null
    $introParts = @()

    foreach ($line in $lines) {
        $l = $line.Trim()
        if ($l -eq '') { continue }

        if ($l -match '^#\s+(.+)$') { $pageTitle = $Matches[1]; continue }

        if ($l -match '^##\s+(.+)$') {
            $curSection = @{ title = $Matches[1]; cards = @() }
            [void]$sections.Add($curSection)
            $curCard = $null
            continue
        }

        if ($l -match '^###\s+(.+)$') {
            $curCard = @{ raw = $Matches[1]; desc = ''; why = ''; signal = ''; link = '' }
            if ($null -eq $curSection) {
                $curSection = @{ title = ''; cards = @() }
                [void]$sections.Add($curSection)
            }
            $curSection.cards += $curCard
            continue
        }

        if ($l -eq '---') { continue }

        if ($null -eq $curCard) { $introParts += $l; continue }

        if ($l -match '^<(https?://[^>]+)>$') { $curCard.link = $Matches[1]; continue }

        # external signal gets its own styled block, not a run-on sentence
        if ($l.StartsWith($SIGNAL_LABEL)) { $curCard.signal = $l; continue }

        if ($l -match '^\*\*[^*]+\*\*') { $curCard.why = $l; continue }

        if ($curCard.desc -eq '') { $curCard.desc = $l } else { $curCard.desc = $curCard.desc + ' ' + $l }
    }

    $cardsTotal = 0
    foreach ($s in $sections) { $cardsTotal += $s.cards.Count }
    $pages += [pscustomobject]@{ date = $date; title = $pageTitle; count = $cardsTotal; file = ($date + '.html') }

    $sectionsHtml = ''
    foreach ($s in $sections) {
        $cardsHtml = ''
        foreach ($c in $s.cards) {
            $name = $c.raw
            $stats = ''
            $dashAt = $c.raw.IndexOf($DASH)
            if ($dashAt -gt 0) {
                $name = $c.raw.Substring(0, $dashAt).Trim()
                $stats = $c.raw.Substring($dashAt + 1).Trim()
            }

            $badgeHtml = ''
            if ($stats -ne '') {
                foreach ($part in ($stats -split [regex]::Escape($DOT))) {
                    $p = $part.Trim()
                    if ($p -eq '') { continue }
                    if ($p.Contains($STAR)) {
                        $num = $p.Replace($STAR, '').Trim()
                        $badgeHtml += '<span class="badge stars">' + [Net.WebUtility]::HtmlEncode($num) + ' ' + $STAR + '</span>'
                    } else {
                        $badgeHtml += '<span class="badge">' + [Net.WebUtility]::HtmlEncode($p) + '</span>'
                    }
                }
            }

            $link = $c.link
            if (-not $link -and $name -match '^[\w.-]+/[\w.-]+$') { $link = 'https://github.com/' + $name }
            if (-not $link) { $link = '#' }

            $cardHtml = $cardBlock
            $cardHtml = $cardHtml.Replace('{{NAME}}', [Net.WebUtility]::HtmlEncode($name))
            $cardHtml = $cardHtml.Replace('{{BADGES}}', $badgeHtml)
            $cardHtml = $cardHtml.Replace('{{DESC}}', (Convert-InlineText $c.desc))
            $cardHtml = $cardHtml.Replace('{{WHY}}', (Convert-InlineText $c.why))
            $cardHtml = $cardHtml.Replace('{{SIGNAL}}', (Convert-InlineText $c.signal))
            $cardHtml = $cardHtml.Replace('{{LINK}}', $link)
            $cardsHtml += $cardHtml
        }

        $secHtml = $sectionBlock
        $secHtml = $secHtml.Replace('{{SECTION_TITLE}}', [Net.WebUtility]::HtmlEncode($s.title))
        $secHtml = $secHtml.Replace('{{SECTION_CARDS}}', $cardsHtml)
        $sectionsHtml += $secHtml
    }

    # drop empty optional paragraphs left by cards without a description or note
    $sectionsHtml = $sectionsHtml -replace '<p class="desc"></p>', ''
    $sectionsHtml = $sectionsHtml -replace '<p class="why"></p>', ''
    $sectionsHtml = $sectionsHtml -replace '<p class="signal"></p>', ''

    $html = $issueTemplate
    $html = $html.Replace('{{PAGE_TITLE}}', [Net.WebUtility]::HtmlEncode($pageTitle))
    $html = $html.Replace('{{HEADING}}', [Net.WebUtility]::HtmlEncode($pageTitle))
    $html = $html.Replace('{{LEAD}}', (Convert-InlineText ($introParts -join ' ')))
    $html = $html.Replace('{{CONTENT}}', $sectionsHtml)
    $html = $html.Replace('{{HOME}}', 'index.html')

    $idx = 0
    for ($k = 0; $k -lt $pages.Count; $k++) { if ($pages[$k].date -eq $date) { $idx = $k; break } }
    $newerPage = $null; $olderPage = $null
    if ($idx -gt 0) { $newerPage = $pages[$idx - 1] }
    if ($idx -lt ($pages.Count - 1)) { $olderPage = $pages[$idx + 1] }

    if ($newerPage) {
        $html = $html.Replace('{{PREV_HREF}}', $newerPage.file)
        $html = $html.Replace('{{PREV_DATE}}', $newerPage.date)
        $html = $html.Replace('{{PREV_CLASS}}', '')
    } else {
        $html = $html.Replace('{{PREV_HREF}}', '#')
        $html = $html.Replace('{{PREV_DATE}}', '')
        $html = $html.Replace('{{PREV_CLASS}}', 'is-hidden')
    }

    if ($olderPage) {
        $html = $html.Replace('{{NEXT_HREF}}', $olderPage.file)
        $html = $html.Replace('{{NEXT_DATE}}', $olderPage.date)
        $html = $html.Replace('{{NEXT_CLASS}}', '')
    } else {
        $html = $html.Replace('{{NEXT_HREF}}', '#')
        $html = $html.Replace('{{NEXT_DATE}}', '')
        $html = $html.Replace('{{NEXT_CLASS}}', 'is-hidden')
    }

    Write-Utf8 (Join-Path $siteDir ($date + '.html')) $html
}

$itemsHtml = ''
foreach ($p in $pages) {
    $itemHtml = $itemBlock
    $itemHtml = $itemHtml.Replace('{{HREF}}', $p.file)
    $itemHtml = $itemHtml.Replace('{{DATE}}', $p.date)
    $itemHtml = $itemHtml.Replace('{{TITLE}}', [Net.WebUtility]::HtmlEncode($p.title))
    $itemHtml = $itemHtml.Replace('{{COUNT_N}}', [string]$p.count)
    $itemsHtml += $itemHtml
}
$indexHtml = $indexTemplate.Replace('{{ITEMS}}', $itemsHtml)
Write-Utf8 (Join-Path $siteDir 'index.html') $indexHtml

$newest = $pages[0].date
Write-Output ("site=" + $siteDir)
Write-Output ("pages=" + $pages.Count + " newest=" + $newest + " cards=" + $pages[0].count)

if ($Pdf) {
    if (-not $EdgePath) {
        foreach ($cand in @(
                'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
                'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
            )) {
            if (Test-Path -LiteralPath $cand) { $EdgePath = $cand; break }
        }
    }
    if (-not $EdgePath -or -not (Test-Path -LiteralPath $EdgePath)) {
        Write-Output 'pdf=skipped (Microsoft Edge not found)'
    } else {
        $htmlPath = Join-Path $siteDir ($newest + '.html')
        $pdfPath = Join-Path $siteDir ($newest + '.pdf')
        $html = Read-Utf8 $htmlPath
        $html = $html.Replace('<link rel="stylesheet" href="style.css">', ('<style>' + $css + '</style>'))
        $runId = [guid]::NewGuid().ToString('N')
        $tmpHtml = Join-Path ([IO.Path]::GetTempPath()) ('digest-' + $newest + '-' + $runId + '.html')
        Write-Utf8 $tmpHtml $html
        $profileDir = Join-Path ([IO.Path]::GetTempPath()) ('edge-print-profile-' + $runId)
        $fileUrl = 'file:///' + ($tmpHtml -replace '\\', '/')
        $printed = $false
        foreach ($mode in @('--headless=new', '--headless')) {
            # print to an ASCII temp path: Edge splits arguments that contain spaces,
            # so a target path like "E:\dir with space\file.pdf" breaks the print job
            $tmpPdf = Join-Path ([IO.Path]::GetTempPath()) ('digest-' + $newest + '-' + $runId + '.pdf')
            if (Test-Path -LiteralPath $tmpPdf) { Remove-Item -LiteralPath $tmpPdf -Force }
            $edgeArgs = @(
                $mode, '--disable-gpu', '--no-first-run', '--disable-sync',
                '--no-default-browser-check', '--disable-extensions',
                ('--user-data-dir=' + $profileDir),
                '--no-pdf-header-footer', ('--print-to-pdf=' + $tmpPdf), $fileUrl
            )
            $proc = Start-Process -FilePath $EdgePath -ArgumentList $edgeArgs -PassThru
            $deadline = (Get-Date).AddSeconds(45)
            $stable = $false
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 700
                if (Test-Path -LiteralPath $tmpPdf) {
                    $size1 = (Get-Item -LiteralPath $tmpPdf).Length
                    Start-Sleep -Milliseconds 1200
                    if (Test-Path -LiteralPath $tmpPdf) {
                        $size2 = (Get-Item -LiteralPath $tmpPdf).Length
                        if ($size1 -gt 1024 -and $size1 -eq $size2) { $stable = $true; break }
                    }
                }
            }
            # Edge often keeps running after writing the PDF; clean up only the
            # process tree we started.
            try { if (-not $proc.HasExited) { taskkill /PID $proc.Id /T /F | Out-Null } } catch { }
            if ($stable) {
                Move-Item -LiteralPath $tmpPdf -Destination $pdfPath -Force
                $printed = $true
                break
            }
        }
        if ($printed) {
            Write-Output ("pdf=" + $pdfPath)
        } else {
            Write-Output 'pdf=failed'
        }
    }
}

$latestPdf = Join-Path $siteDir ($newest + '.pdf')
$latest = [pscustomobject]@{
    date = $newest
    html = ($newest + '.html')
    pdf = $(if (Test-Path -LiteralPath $latestPdf) { $newest + '.pdf' } else { $null })
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $siteDir 'latest.json'), ($latest | ConvertTo-Json -Depth 2), $utf8NoBom)
