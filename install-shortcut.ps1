#requires -Version 5
<#
  Create a desktop shortcut that runs open-today.ps1 only when clicked.
  This source is pure ASCII; the Chinese shortcut name is read from
  site-config.json as UTF-8.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ShortcutPath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'site-config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw ('config file not found: ' + $ConfigPath) }

$config = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$name = [string]$config.shortcutName
if (-not $name) { $name = 'AI Daily Digest' }
if (-not $ShortcutPath) { $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ($name + '.lnk') }

$launcher = Join-Path $PSScriptRoot 'open-today.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
$icon = Join-Path $env:SystemRoot 'System32\imageres.dll,13'

if ($DryRun) {
    Write-Output ('shortcut=' + $ShortcutPath)
    Write-Output ('target=' + $powershell)
    Write-Output ('arguments=' + $arguments)
    return
}

$parent = Split-Path -Parent $ShortcutPath
if (-not (Test-Path -LiteralPath $parent)) { throw ('shortcut directory not found: ' + $parent) }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = $icon
$shortcut.Description = $name
$shortcut.WindowStyle = 7
$shortcut.Save()

Write-Output ('shortcut=' + $ShortcutPath)
