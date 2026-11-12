#requires -Version 5
<#
  Desktop fallback for the cloud digest. It does no startup work. When clicked,
  it opens today's issue or dispatches the GitHub workflow and waits for it.
  The GitHub token is read from Windows Credential Manager and never printed.
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repo = 'sxf80250-arch/ai-digest'
$baseUrl = 'https://sxf80250-arch.github.io/ai-digest'
$textPath = Join-Path $PSScriptRoot 'desktop-text.json'
if (-not (Test-Path -LiteralPath $textPath)) { throw ('text file not found: ' + $textPath) }
$text = [IO.File]::ReadAllText($textPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

function Show-Message {
    param([string]$Body, [string]$Title)
    if ($DryRun) { return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        $Body, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Get-Latest {
    $url = $baseUrl + '/latest.json?v=' + (Get-Date).ToString('yyyyMMddHHmmss')
    $json = & curl.exe -L --fail --silent --show-error --retry 2 --retry-delay 1 `
        --connect-timeout 10 --max-time 20 $url 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return (($json -join "`n").TrimStart([char]0xFEFF) | ConvertFrom-Json) }
    catch { return $null }
}

function Get-GitHubToken {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AiDigestCredential {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);
    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) { return null; }
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            var bytes = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, bytes, 0, bytes.Length);
            return System.Text.Encoding.UTF8.GetString(bytes).TrimEnd('\0');
        } finally {
            CredFree(ptr);
        }
    }
}
'@
    return [AiDigestCredential]::Read('gh:github.com:sxf80250-arch')
}

function Send-Dispatch {
    $token = Get-GitHubToken
    if (-not $token) { return $false }
    $endpoint = 'https://api.github.com/repos/' + $repo + '/actions/workflows/ai-digest.yml/dispatches'
    $config = "header = `"Authorization: Bearer $token`"`n" +
        "header = `"Accept: application/vnd.github+json`"`n" +
        "header = `"X-GitHub-Api-Version: 2022-11-28`"`n" +
        "user-agent = `"ai-digest-desktop`"`n"
    $bodyFile = Join-Path $env:TEMP ('ai-digest-dispatch-' + [guid]::NewGuid().ToString('N') + '.json')
    $responseFile = $bodyFile + '.response'
    [IO.File]::WriteAllText($bodyFile, '{"ref":"main"}', (New-Object Text.UTF8Encoding($false)))
    try {
        $status = $config | & curl.exe --config - --silent --show-error `
            --request POST --header 'Content-Type: application/json' `
            --data-binary ('@' + $bodyFile) --output $responseFile --write-out '%{http_code}' $endpoint 2>&1
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
    $token = $null
    Remove-Item -LiteralPath $responseFile -Force -ErrorAction SilentlyContinue
    return ((($status | ForEach-Object { [string]$_ }) -join ' ').Trim() -eq '204')
}

function Open-Latest {
    param($Latest)
    $html = ([string]$Latest.html).TrimStart('/')
    if ($html -notmatch '^\d{4}-\d{2}-\d{2}\.html$') { return $false }
    if (-not $DryRun) { Start-Process -FilePath ($baseUrl + '/' + $html) }
    return $true
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$latest = Get-Latest
if ($DryRun) {
    $token = Get-GitHubToken
    $state = if ($latest -and [string]$latest.date -eq $today) { 'today' } else { 'would_dispatch' }
    Write-Output ('status=' + $state + ' latest=' + $(if ($latest) { [string]$latest.date } else { 'unknown' }) +
        ' today=' + $today + ' token=' + $(if ($token) { 'ok' } else { 'missing' }))
    $token = $null
    exit 0
}

if ($latest -and [string]$latest.date -eq $today) {
    if (-not (Open-Latest $latest)) { throw 'invalid latest metadata' }
    exit 0
}

$lock = Join-Path $env:TEMP 'ai-digest-trigger.lock'
$recent = (Test-Path -LiteralPath $lock) -and (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -lt 2)
if (-not $recent) {
    if (-not (Send-Dispatch)) {
        [void](Show-Message ([string]$text.authFailed) ([string]$text.authTitle))
        exit 1
    }
    [IO.File]::WriteAllText($lock, (Get-Date).ToString('s'), [Text.Encoding]::UTF8)
}

[void](Show-Message ([string]$text.generating) ([string]$text.generatingTitle))
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $latest = Get-Latest
    if ($latest -and [string]$latest.date -eq $today -and (Open-Latest $latest)) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        exit 0
    }
}

[void](Show-Message (([string]$text.failed).Replace('{url}', 'https://github.com/' + $repo + '/actions/workflows/ai-digest.yml')) ([string]$text.failedTitle))
exit 1
