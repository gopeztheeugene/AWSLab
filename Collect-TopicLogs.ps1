#Requires -Version 7.0
<#
.SYNOPSIS
    Step 3 of the AWS DFIR lab: log collection. After an attack, while the boxes
    are still up, pull the relevant Security / Sysmon / PowerShell logs over WinRM
    into the log share. Collection only - it never stops or terminates anything.

.DESCRIPTION
    Reads a per-topic manifest (collection/<topic>.psd1) that says which logs to
    pull from which hosts and which event IDs are the signal. For each host it:
      - exports each named log in full to .evtx (forensic copy, via wevtutil on
        the host), then copies it back over the WinRM session (no SMB);
      - pulls a filtered CSV + JSON summary of the focus event IDs for quick look;
      - hashes everything and writes a manifest.json + README.txt.

    Host IPs come from lab-state.json (written by step 1). Transport is WinRM over
    HTTP 5985 (PSRP), matching the lab's "WinRM, not SMB" decision, so this runs
    under pwsh 7 on either the Windows laptop or the Linux mini PC.

.EXAMPLE
    ./Collect-TopicLogs.ps1 -Topic kerberoast
    Pull the kerberoast logs from the hosts named in the manifest into the share.
.EXAMPLE
    ./Collect-TopicLogs.ps1 -Topic kerberoast -SinceMinutes 120 -OutputRoot ~/lab-logs
    Only events from the last 2 hours; write under ~/lab-logs (Linux mini PC).
.EXAMPLE
    ./Collect-TopicLogs.ps1 -Topic kerberoast -WhatIf
    Show what would be collected from where; connect to nothing.

.PARAMETER Topic
    Manifest to use: collection/<Topic>.psd1.
.PARAMETER Hosts
    Override the manifest's host list (Name tags). Default: all hosts in the manifest.
.PARAMETER SinceMinutes
    Only collect events newer than this many minutes. 0 (default) = whole log.
.PARAMETER OutputRoot
    Where to write. Default L: on Windows, ~/lab-logs on Linux (the mounted share).
.PARAMETER Credential
    WinRM credential for the Windows hosts (e.g. lab\Administrator). Prompts once if omitted.
.PARAMETER StatePath
    lab-state.json from step 1. Default next to this script.
.PARAMETER ManifestDir
    Folder holding <topic>.psd1. Default ./collection.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $Topic,
    [string[]]      $Hosts,
    [int]           $SinceMinutes = 0,
    [string]        $OutputRoot,
    [pscredential]  $Credential,
    [string]        $StatePath   = (Join-Path $PSScriptRoot 'lab-state.json'),
    [string]        $ManifestDir = (Join-Path $PSScriptRoot 'collection')
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

# --- Manifest ----------------------------------------------------------------
$manifestPath = Join-Path $ManifestDir "$Topic.psd1"
if (-not (Test-Path $manifestPath)) { throw "No collection manifest at $manifestPath. Topics available: $((Get-ChildItem $ManifestDir -Filter *.psd1 -ErrorAction SilentlyContinue).BaseName -join ', ')" }
$manifest = Import-PowerShellDataFile -Path $manifestPath

$hostNames = if ($Hosts) { $Hosts } else { @($manifest.Hosts.Keys) }
if (-not $hostNames) { throw "Manifest $manifestPath lists no hosts." }

# --- State (host IPs from step 1) --------------------------------------------
if (-not (Test-Path $StatePath)) { throw "No lab-state.json at $StatePath. Run step 1 (Start-AwsLab) first so the lab is up and its IPs are recorded." }
$state = Get-Content $StatePath -Raw | ConvertFrom-Json
$ipByName = @{}
foreach ($i in $state.Instances) { $ipByName[$i.Name] = $i.PublicIp }

# --- Output location ---------------------------------------------------------
if (-not $OutputRoot) { $OutputRoot = if ($IsWindows) { 'L:' } else { Join-Path $HOME 'lab-logs' } }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$destDir = Join-Path (Join-Path $OutputRoot $Topic) $stamp

$startTime = if ($SinceMinutes -gt 0) { (Get-Date).AddMinutes(-$SinceMinutes) } else { $null }

Write-Step "Collecting '$Topic' from: $($hostNames -join ', ')"
Write-Host "    output : $destDir"
Write-Host "    window : $(if ($startTime) { "since $($startTime.ToString('s')) ($SinceMinutes min)" } else { 'whole log' })"

if (-not $PSCmdlet.ShouldProcess($destDir, "collect $Topic logs from $($hostNames -join ', ')")) {
    foreach ($h in $hostNames) {
        $logs = @($manifest.Hosts[$h].Logs)
        Write-Host "    [whatif] $h ($($ipByName[$h] ?? 'no IP in state')): $($logs -join ', ')"
    }
    return
}

if (-not $Credential) { $Credential = Get-Credential -Message 'WinRM login for the lab Windows hosts (e.g. lab\Administrator)' }
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

$collected = [System.Collections.Generic.List[object]]::new()

foreach ($h in $hostNames) {
    $ip = $ipByName[$h]
    if (-not $ip) { Write-Warning "$h isn't in lab-state.json (not launched this run?); skipping."; continue }

    $logs = @($manifest.Hosts[$h].Logs)
    Write-Step "$h ($ip)"
    $hostDir = Join-Path $destDir $h
    New-Item -ItemType Directory -Path $hostDir -Force | Out-Null

    try {
        $session = New-PSSession -ComputerName $ip -Port 5985 -Credential $Credential -Authentication Negotiate -ErrorAction Stop
    } catch {
        Write-Warning "Couldn't open WinRM to $h ($ip): $_. Skipping this host."
        continue
    }

    try {
        foreach ($log in $logs) {
            $safe = ($log -replace '[\\/]', '-')

            # 1. Full .evtx forensic copy: wevtutil exports on the host, we copy it back over WinRM.
            $remotePath = "C:\collect\$Topic-$h-$safe.evtx"
            $q = if ($startTime) {
                # wevtutil wants ms since the event; use a relative time query.
                $ms = [int64]((Get-Date) - $startTime).TotalMilliseconds
                "*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]"
            } else { $null }

            $exported = Invoke-Command -Session $session -ScriptBlock {
                param($Log, $Out, $Query)
                New-Item -ItemType Directory -Path (Split-Path $Out) -Force | Out-Null
                if (Test-Path $Out) { Remove-Item $Out -Force }
                if ($Query) { & wevtutil epl $Log $Out "/q:$Query" "/ow:true" 2>&1 }
                else        { & wevtutil epl $Log $Out "/ow:true" 2>&1 }
                if (Test-Path $Out) { (Get-Item $Out).Length } else { -1 }
            } -ArgumentList $log, $remotePath, $q

            if ($exported -lt 0) {
                Write-Warning "    $log : export produced no file (log empty, missing, or access denied). Skipping."
                continue
            }

            $localEvtx = Join-Path $hostDir "$safe.evtx"
            Copy-Item -FromSession $session -Path $remotePath -Destination $localEvtx -Force
            Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item $p -Force -ErrorAction SilentlyContinue } -ArgumentList $remotePath
            Write-Host "    $log -> $(Split-Path $localEvtx -Leaf) ($([math]::Round((Get-Item $localEvtx).Length/1KB)) KB)"

            # 2. Filtered quick-look of the focus event IDs for this log.
            $focusIds = @($manifest.Focus[$log] | ForEach-Object { $_.Id })
            if ($focusIds) {
                $events = Invoke-Command -Session $session -ScriptBlock {
                    param($Log, $Ids, $Start)
                    $filter = @{ LogName = $Log; Id = $Ids }
                    if ($Start) { $filter.StartTime = $Start }
                    try {
                        Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
                            Select-Object TimeCreated, Id, LevelDisplayName, MachineName,
                                          @{n='Message'; e={ ($_.Message -split "`r?`n")[0] }}
                    } catch {
                        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { @() } else { throw }
                    }
                } -ArgumentList $log, $focusIds, $startTime

                $events = @($events)
                if ($events.Count) {
                    $base = Join-Path $hostDir "$safe-focus"
                    $events | Export-Csv -Path "$base.csv" -NoTypeInformation
                    $events | ConvertTo-Json -Depth 4 | Set-Content "$base.json"
                    $byId = ($events | Group-Object Id | Sort-Object Name | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
                    Write-Host "      focus: $($events.Count) events ($byId)"
                } else {
                    Write-Warning "      focus: 0 of event IDs $($focusIds -join ',') in $log. If this is the Security log, check step 2's audit policy (RequiredAudit in the manifest)."
                }
            }

            $collected.Add([pscustomobject]@{ Host = $h; Log = $log; File = "$h/$safe.evtx" })
        }
    } finally {
        Remove-PSSession $session
    }
}

# --- Manifest + hashes -------------------------------------------------------
Write-Step 'Writing collection manifest'
$files = Get-ChildItem $destDir -Recurse -File | Where-Object Name -ne 'manifest.json'
$hashes = foreach ($f in $files) {
    [pscustomobject]@{
        File   = [IO.Path]::GetRelativePath($destDir, $f.FullName)
        Bytes  = $f.Length
        SHA256 = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
}
[pscustomobject]@{
    Topic        = $Topic
    CollectedAt  = (Get-Date).ToString('o')
    CollectedBy  = $env:USERNAME ?? $env:USER
    Region       = $state.Region
    WindowMin    = $SinceMinutes
    Hosts        = $hostNames
    Files        = $hashes
    ManifestUsed = $manifestPath
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $destDir 'manifest.json')

$readme = @"
$Topic log collection
Collected : $(Get-Date -Format 'u')
Window    : $(if ($startTime) { "last $SinceMinutes min" } else { 'whole log' })
Hosts     : $($hostNames -join ', ')

Layout:
  <host>/<log>.evtx         full forensic export (open in Event Viewer / EvtxECmd)
  <host>/<log>-focus.csv    filtered to the topic's focus event IDs
  <host>/<log>-focus.json   same, as JSON
  manifest.json             SHA-256 of every file above

$Topic signal: Security 4769 on the DC with Ticket Encryption Type 0x17 (RC4),
a burst of distinct Service Names from one Client Address. No 4769 at all ->
check the step 2 audit policy.
"@
$readme | Set-Content (Join-Path $destDir 'README.txt')

Write-Step 'Done'
Write-Host "    $($collected.Count) logs from $($hostNames.Count) host(s) -> $destDir"
Write-Host '    collection only; nothing was stopped or terminated.'
