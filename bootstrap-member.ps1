<#
.SYNOPSIS
    First-boot provisioning for an AWS DFIR lab member server (Windows Server Core).

.DESCRIPTION
    Paste the body of this file into EC2 user-data (inside the <powershell> tags) when
    launching a fresh member server. On first boot it:
      1. Points DNS at the domain controller.
      2. Waits for the domain to resolve and checks LDAP/389 reachability.
      3. Joins the domain (critical path).
      4. Renames the computer, retrying the transient "directory service is busy" race.
      5. Installs Sysmon from the AWSLab repo (non-fatal).
      6. Creates the log share (non-fatal).
      7. Reboots once to apply the join + rename.

    Everything after the join is non-fatal: a failure in rename, Sysmon or the share is
    logged and skipped so the box always ends up joined. Every step is written to
    C:\bootstrap.log - see README-bootstrap.md for how to read it.

    NOTE: domain credentials are embedded below. This is fine for a throwaway lab, where
    user-data is readable from instance metadata anyway. Never do this in production.

    This is NOT a standalone script to run on your laptop - it is server-side user-data.
#>

<powershell>
$ErrorActionPreference = 'Stop'
$log = 'C:\bootstrap.log'
function Log($m){ "$(Get-Date -Format o)  $m" | Tee-Object -FilePath $log -Append }

# --- config -----------------------------------------------------------------
$DomainDC   = '172.31.5.192'
$DomainFQDN = 'lab.local'
$NewName    = 'MEMBER01'
$JoinUser   = 'Administrator@lab.local'          # UPN form - no NetBIOS guess
$JoinPass   = 'CHANGE_ME'                          # <-- set before launch
$RepoUrl    = 'https://github.com/gopeztheeugene/AWSLab'
$RepoDir    = 'C:\AWSLab'
$ShareDir   = 'C:\LabLogs'
# ----------------------------------------------------------------------------

try {
    Log "Setting DNS to $DomainDC"
    Get-NetAdapter | Where-Object Status -eq 'Up' |
        Set-DnsClientServerAddress -ServerAddresses $DomainDC

    Log "Waiting for $DomainFQDN to resolve"
    for ($i = 0; $i -lt 30; $i++) {
        try { Resolve-DnsName $DomainFQDN -ErrorAction Stop | Out-Null; break }
        catch { Start-Sleep 10 }
    }
    if (-not (Test-NetConnection $DomainDC -Port 389 -InformationLevel Quiet)) {
        throw "Can't reach DC on LDAP/389 - check the SG self-referencing rule."
    }

    # --- JOIN (critical path) ----------------------------------------------
    Log "Joining $DomainFQDN"
    $cred = [pscredential]::new($JoinUser,(ConvertTo-SecureString $JoinPass -AsPlainText -Force))
    Add-Computer -DomainName $DomainFQDN -Credential $cred -Force
    Log "Joined OK"

    # --- RENAME (non-fatal; retries the 'directory service is busy' race) ---
    for ($r = 0; $r -lt 5; $r++) {
        try {
            Rename-Computer -NewName $NewName -DomainCredential $cred -Force -ErrorAction Stop
            Log "Renamed to $NewName"; break
        } catch {
            Log "Rename attempt $($r + 1) failed, retrying: $_"; Start-Sleep 15
        }
    }

    # --- SYSMON (non-fatal) -------------------------------------------------
    try {
        Log "Installing Sysmon"
        New-Item $RepoDir     -ItemType Directory -Force | Out-Null
        New-Item 'C:\Sysmon'  -ItemType Directory -Force | Out-Null   # guard the repo-script path
        $zip = "$env:TEMP\awslab.zip"
        Invoke-WebRequest "$RepoUrl/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath 'C:\' -Force
        if (Test-Path 'C:\AWSLab-main') { Copy-Item 'C:\AWSLab-main\*' $RepoDir -Recurse -Force }
        & "$RepoDir\sysmon_main.ps1"
        Log "Sysmon done"
    } catch { Log "Sysmon step failed (continuing): $_" }

    # --- LOG SHARE (non-fatal) ---------------------------------------------
    try {
        Log "Creating log share"
        New-Item $ShareDir -ItemType Directory -Force | Out-Null
        New-SmbShare -Name 'LabLogs' -Path $ShareDir -FullAccess 'Administrators' -ErrorAction SilentlyContinue
    } catch { Log "Share step failed (continuing): $_" }

    # --- apply join + rename with one reboot -------------------------------
    Log "Rebooting to apply join"
    Restart-Computer -Force
}
catch {
    Log "FAILED: $_"
    throw
}
</powershell>
<persist>true</persist>
