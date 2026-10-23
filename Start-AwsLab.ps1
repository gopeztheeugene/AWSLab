#Requires -Version 7.0
<#
.SYNOPSIS
    Step 1 of the AWS DFIR lab: start the lab, open both security groups to your
    current public IP, wait for WinRM on the Windows hosts, and print a summary.

.DESCRIPTION
    - Finds the lab instances by security-group membership (no hard-coded instance IDs),
      so the DC, member server and Kali box are picked up automatically.
    - Starts anything stopped (waits out "stopping" first), then waits until all are running.
    - Resolves your public IP and allows ALL traffic from it to both security groups.
      Rules this script creates are tagged with the description 'AWSLab-launcher';
      stale tagged rules (old IPs) are revoked. Hand-made rules are never touched.
    - Waits for TCP 5985 (WinRM over HTTP) on the Windows hosts.
    - Prints a connection summary and writes lab-state.json for steps 2 and 3.

.EXAMPLE
    ./Start-AwsLab.ps1
.EXAMPLE
    ./Start-AwsLab.ps1 -ProfileName lab -TimeoutMinutes 20
.EXAMPLE
    ./Start-AwsLab.ps1 -Name DC, Kali
    Starts only the instances whose Name tag (or instance ID) matches. Wildcards work: -Name '*DC*'.

.EXAMPLE
    ./Start-AwsLab.ps1 -Connect -WinRmUser 'LAB\Administrator'
    After launch, opens one Windows Terminal tab per reachable instance, already connecting.

.PARAMETER Name
    Optional. Name tags or instance IDs to start; wildcards allowed. Omit to start every lab instance.
.PARAMETER Connect
    Optional. Open a terminal tab per reachable instance (Windows only): WinRM session for
    Windows hosts, SSH for Kali. Uses Windows Terminal if installed, otherwise separate windows.
.PARAMETER WinRmUser
    Optional. Pre-fills the user name in each Windows tab's credential prompt.
.PARAMETER ShareHostName
    Name tag of the member server that hosts the log share. Default 'srv01'. Wildcards allowed.
.PARAMETER ShareDrive
    Drive letter to map the log share to on this laptop. Default 'L:'.
.PARAMETER ShareCredential
    Optional. Credential for the log share; prompts once if omitted.
.PARAMETER NoMountShare
    Skip mounting the log share.
#>
[CmdletBinding()]
param(
    [string[]] $Name,
    [string]   $Region           = 'ap-southeast-2',
    [string]   $ProfileName,
    [string[]] $SecurityGroupIds = @('sg-02df021a36003f4f1', 'sg-0549668744af8e82d'),
    [int]      $TimeoutMinutes   = 15,
    [string]   $StatePath        = (Join-Path $PSScriptRoot 'lab-state.json'),
    [string]   $KaliKeyPath      = 'C:\Users\egopez\Documents\Pentest study\ec2keys\kali-linux.pem',
    [switch]   $Connect,
    [string]   $WinRmUser,
    [string]        $ShareHostName   = 'srv01',
    [string]        $ShareDrive      = 'L:',
    [pscredential]  $ShareCredential,
    [switch]        $NoMountShare
)

$ErrorActionPreference = 'Stop'
$RuleTag = 'AWSLab-launcher'

# --- Prerequisites -----------------------------------------------------------
try {
    Import-Module AWS.Tools.EC2 -ErrorAction Stop
} catch {
    throw "AWS.Tools.EC2 isn't installed. Run: Install-Module AWS.Tools.Installer; Install-AWSToolsModule AWS.Tools.EC2 -CleanUp"
}

# Common parameters for every AWS call
$aws = @{ Region = $Region }
if ($ProfileName) { $aws.ProfileName = $ProfileName }

# --- Helpers -----------------------------------------------------------------
function Get-LabInstances([switch]$All) {
    $filters = @(
        @{ Name = 'instance.group-id';   Values = $SecurityGroupIds }
        @{ Name = 'instance-state-name'; Values = @('pending', 'running', 'stopping', 'stopped') }
    )
    $found = @((Get-EC2Instance -Filter $filters @aws).Instances)
    if ($All -or -not $Name) { return $found }

    # Keep only instances whose Name tag or ID matches one of the -Name patterns
    @($found | Where-Object {
        $inst = $_
        $Name | Where-Object { (Get-InstanceName $inst) -like $_ -or $inst.InstanceId -like $_ }
    })
}

function Get-InstanceName($Instance) {
    $name = ($Instance.Tags | Where-Object Key -eq 'Name').Value
    if ($name) { $name } else { $Instance.InstanceId }
}

function Test-IsWindows($Instance) { "$($Instance.Platform)" -eq 'Windows' }

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    # Works on Windows and macOS (Test-NetConnection is Windows-only)
    $client = [System.Net.Sockets.TcpClient]::new()
    try   { $client.ConnectAsync($HostName, $Port).Wait($TimeoutMs) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

function Get-ConnectCommand($Entry) {
    # One place builds the connect command, used for both the printed hints and -Connect tabs
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }   # PowerShell single-quote escaping
    if ($Entry.Os -eq 'Windows') {
        $user = if ($WinRmUser) { " -UserName $(& $q $WinRmUser)" } else { '' }
        "Enter-PSSession -ComputerName $($Entry.PublicIp) -Credential (Get-Credential$user -Message $(& $q "WinRM login for $($Entry.Name)"))"
    } else {
        "ssh -i $(& $q $KaliKeyPath) kali@$($Entry.PublicIp)"
    }
}

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
function Assert-NotTimedOut([string]$What) {
    if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes min waiting for $What." }
}

# --- 1. Find and start the instances ----------------------------------------
Write-Step "Finding lab instances in $Region"
$instances = Get-LabInstances
if (-not $instances) {
    if ($Name) {
        $names = (Get-LabInstances -All | ForEach-Object { Get-InstanceName $_ }) -join ', '
        throw "No lab instance matches -Name $($Name -join ', '). Available: $names"
    }
    throw "No instances found in security groups $($SecurityGroupIds -join ', '). Check the region, profile and SG IDs."
}
$instances | ForEach-Object { Write-Host ("    {0,-24} {1}  {2}" -f (Get-InstanceName $_), $_.InstanceId, $_.State.Name) }

Write-Step 'Starting instances and waiting for running'
$started = @{}
while ($true) {
    $instances = Get-LabInstances

    # Start anything that's fully stopped (instances in 'stopping' get started on a later pass)
    $toStart = @($instances | Where-Object { "$($_.State.Name)" -eq 'stopped' -and -not $started[$_.InstanceId] })
    if ($toStart) {
        Start-EC2Instance -InstanceId $toStart.InstanceId @aws | Out-Null
        $toStart | ForEach-Object { $started[$_.InstanceId] = $true; Write-Host "    started $(Get-InstanceName $_)" }
    }

    $notRunning = @($instances | Where-Object { "$($_.State.Name)" -ne 'running' })
    if (-not $notRunning) { break }

    Assert-NotTimedOut "instances to reach 'running' ($((($notRunning | ForEach-Object { Get-InstanceName $_ }) -join ', ')))"
    Start-Sleep -Seconds 5
}
Write-Host '    all running'

# --- 2. Resolve your public IP ----------------------------------------------
Write-Step 'Resolving your public IP'
$myIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 10).Trim()
if ($myIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Unexpected public IP response: '$myIp'" }
$cidr = "$myIp/32"
Write-Host "    $cidr"

# --- 3. Update both security groups ------------------------------------------
Write-Step 'Updating security groups'
foreach ($sg in $SecurityGroupIds) {
    $tagged = @(Get-EC2SecurityGroupRule -Filter @{ Name = 'group-id'; Values = $sg } @aws |
                Where-Object { -not $_.IsEgress -and $_.Description -eq $RuleTag })

    $stale   = @($tagged | Where-Object CidrIpv4 -ne $cidr)
    $current = @($tagged | Where-Object CidrIpv4 -eq $cidr)

    if ($stale) {
        Revoke-EC2SecurityGroupIngress -GroupId $sg -SecurityGroupRuleId $stale.SecurityGroupRuleId @aws | Out-Null
        Write-Host "    $sg  revoked old: $($stale.CidrIpv4 -join ', ')"
    }

    if ($current) {
        Write-Host "    $sg  already allows $cidr"
    } else {
        $range = [Amazon.EC2.Model.IpRange]::new()
        $range.CidrIp      = $cidr
        $range.Description = $RuleTag

        $perm = [Amazon.EC2.Model.IpPermission]::new()
        $perm.IpProtocol = '-1'   # all traffic
        $perm.Ipv4Ranges = [System.Collections.Generic.List[Amazon.EC2.Model.IpRange]]::new()
        $perm.Ipv4Ranges.Add($range)

        Grant-EC2SecurityGroupIngress -GroupId $sg -IpPermission $perm @aws | Out-Null
        Write-Host "    $sg  allowed all traffic from $cidr"
    }
}

# --- 4. Wait for WinRM on the Windows hosts ---------------------------------
Write-Step 'Waiting for WinRM (5985) on Windows hosts'
$instances = Get-LabInstances   # refresh: public IPs change on every start
$windows   = @($instances | Where-Object { Test-IsWindows $_ })

foreach ($w in $windows) {
    if (-not $w.PublicIpAddress) { Write-Warning "$(Get-InstanceName $w) has no public IP; skipping WinRM check."; continue }
    while (-not (Test-TcpPort $w.PublicIpAddress 5985)) {
        Assert-NotTimedOut "WinRM on $(Get-InstanceName $w)"
        Start-Sleep -Seconds 10
    }
    Write-Host "    $(Get-InstanceName $w)  WinRM up"
}

# --- 5. Summary and state file ----------------------------------------------
$summary = foreach ($i in $instances | Sort-Object { -not (Test-IsWindows $_) }, { Get-InstanceName $_ }) {
    $isWin = Test-IsWindows $i
    $port  = if ($isWin) { 5985 } else { 22 }
    [pscustomobject]@{
        Name       = Get-InstanceName $i
        InstanceId = $i.InstanceId
        Os         = if ($isWin) { 'Windows' } else { 'Linux' }
        PrivateIp  = $i.PrivateIpAddress
        PublicIp   = $i.PublicIpAddress
        Access     = if ($isWin) { 'WinRM 5985' } else { 'SSH 22' }
        Reachable  = [bool]($i.PublicIpAddress -and (Test-TcpPort $i.PublicIpAddress $port))
    }
}

Write-Step 'Lab is up'
$summary | Format-Table -AutoSize | Out-Host

[pscustomobject]@{
    LaunchedAt = (Get-Date).ToString('o')
    Region     = $Region
    MyIp       = $myIp
    Instances  = $summary
} | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding utf8
Write-Host "State written to $StatePath"

foreach ($s in $summary) {
    Write-Host "  $($s.Name):  $(Get-ConnectCommand $s)"
}

# --- 6. Mount the member server's log share on this laptop ------------------
if (-not $NoMountShare) {
    $shareHost = @($summary | Where-Object { $_.Name -like $ShareHostName })[0]
    if (-not $shareHost) {
        Write-Warning "Share host '$ShareHostName' not among the started instances; skipping mount."
    } elseif (-not $shareHost.Reachable) {
        Write-Warning "$($shareHost.Name) isn't reachable; skipping share mount."
    } else {
        $remote = "\\$($shareHost.PublicIp)\LabLogs"
        Write-Step "Mounting $remote on $ShareDrive"
        # Public IP changes every launch, so clear only THIS drive's stale mapping.
        # Shares mapped to other drive letters are left untouched.
        Get-SmbMapping -LocalPath $ShareDrive -ErrorAction SilentlyContinue |
            Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        if (-not $ShareCredential) {
            $ShareCredential = Get-Credential -Message "Log share login for $($shareHost.Name) (e.g. LAB\Administrator)"
        }
        try {
            New-SmbMapping -LocalPath $ShareDrive -RemotePath $remote `
                -UserName $ShareCredential.UserName `
                -Password $ShareCredential.GetNetworkCredential().Password `
                -Persistent $false | Out-Null
            Write-Host "    mounted $remote -> $ShareDrive"
        } catch {
            Write-Warning "Couldn't mount $remote : $_"
            Write-Warning "If that timed out, your ISP may block outbound SMB (445); logs can still be pulled over WinRM (5985)."
        }
    }
}

# --- 7. Optional: one terminal tab per instance -----------------------------
if ($Connect) {
    Write-Step 'Opening a terminal per instance'
    if (-not $IsWindows) {
        Write-Warning '-Connect opens Windows Terminal tabs and only works on Windows; use the commands above.'
    } else {
        $useWt = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
        if (-not $useWt) { Write-Warning 'Windows Terminal not found; opening separate windows instead.' }

        foreach ($s in $summary) {
            if (-not $s.Reachable) { Write-Warning "$($s.Name) isn't reachable yet; no terminal opened."; continue }

            # -EncodedCommand sidesteps quoting problems with spaces in the key path or names
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-ConnectCommand $s)))
            if ($useWt) {
                # '-w AWSLab' puts every tab in the same named window
                Start-Process wt.exe -ArgumentList "-w AWSLab new-tab --title `"$($s.Name)`" pwsh -NoExit -EncodedCommand $encoded"
                Start-Sleep -Milliseconds 800   # let the window exist before the next tab targets it
            } else {
                Start-Process pwsh -ArgumentList "-NoExit -EncodedCommand $encoded"
            }
            Write-Host "    opened $($s.Name)"
        }
    }
}
