#requires -Version 5
<#
  Launcher used by the desktop shortcut.

  If today's issue already exists it opens it in the default browser. Otherwise
  it runs the generator in a visible window so progress is visible, waits for it,
  then opens the result. If generation fails it opens the newest earlier issue.
  Pure ASCII source on purpose; user-facing text lives in fallback-template.md.
#>
[CmdletBinding()]
param(
    [string]$Dir = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = $PSScriptRoot }

$today = (Get-Date).ToString('yyyy-MM-dd')
$siteDir = Join-Path $Dir 'site'
$todayHtml = Join-Path $siteDir ($today + '.html')

function Open-Page {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { Start-Process -FilePath $Path | Out-Null }
}

if ((Test-Path -LiteralPath $todayHtml) -and (-not $Force)) {
    Open-Page $todayHtml
    exit 0
}

$worker = Join-Path $Dir 'make-fallback-digest.ps1'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '"'
$psi.UseShellExecute = $true
$psi.WindowStyle = 'Normal'
$psi.CreateNoWindow = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit()

if (Test-Path -LiteralPath $todayHtml) {
    Open-Page $todayHtml
    exit 0
}

$latest = @(
    Get-ChildItem -LiteralPath $siteDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'index.html' } |
    Sort-Object Name -Descending
) | Select-Object -First 1
if ($latest) {
    Open-Page $latest.FullName
} else {
    Open-Page (Join-Path $siteDir 'index.html')
}
