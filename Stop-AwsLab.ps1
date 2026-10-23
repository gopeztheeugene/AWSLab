#Requires -Version 7.0
<#
.SYNOPSIS
    Step 4 of the AWS DFIR lab: reset. Terminate the attacked DC + member pair
    and clean up, optionally snapshotting their disks first.

.DESCRIPTION
    - Finds the lab instances by security-group membership, like the launcher
      (terminated instances are ignored).
    - Refuses to run unless every box it would terminate has an available golden
      AMI with launch settings (Launch* tags), so step 1 -RebuildIfMissing can
      bring it back.
    - -PreserveDisk: EBS-snapshots every attached volume first, tagged with topic
      + date, and waits for the snapshots to complete (forensic acquisition).
    - Terminates the pair and waits until they're gone, so their fixed private
      IPs are released for the rebuild.
    - Stops the other lab boxes (Kali, VPN server). They have no golden AMI, so
      they're never terminated.
    - Revokes the security-group rules the launcher created (description
      'AWSLab-launcher'), unmounts the log share and removes lab-state.json.
    No relaunch here: bringing the lab back is step 1's job.

.EXAMPLE
    ./Stop-AwsLab.ps1 -WhatIf
    Show what would be snapshotted, terminated and stopped; change nothing.
.EXAMPLE
    ./Stop-AwsLab.ps1
    Terminate dc + member01 (asks to confirm), stop the rest, clean up.
.EXAMPLE
    ./Stop-AwsLab.ps1 -PreserveDisk -Topic kerberoast
    Snapshot the attacked disks first, tagged Topic=kerberoast, then terminate.

.PARAMETER PreserveDisk
    EBS-snapshot every attached volume of the boxes being terminated before terminating them.
.PARAMETER Topic
    Attack topic written to the snapshot tags. Required with -PreserveDisk.
.PARAMETER ResetName
    Name tags of the golden-backed boxes to terminate. Default dc, member01 (the matched pair).
.PARAMETER Force
    Skip the confirmation prompt.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]   $PreserveDisk,
    [string]   $Topic,
    [string[]] $ResetName        = @('dc', 'member01'),
    [string]   $Region           = 'ap-southeast-2',
    [string]   $ProfileName,
    [string[]] $SecurityGroupIds = @('sg-02df021a36003f4f1', 'sg-0549668744af8e82d'),
    [int]      $TimeoutMinutes   = 30,
    [string]   $StatePath        = (Join-Path $PSScriptRoot 'lab-state.json'),
    [string]   $ShareDrive       = 'L:',
    [string]   $Project          = 'AWSLab',
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'
$RuleTag = 'AWSLab-launcher'

if ($PreserveDisk -and -not $Topic) { throw '-PreserveDisk needs -Topic, for the snapshot tags (e.g. -Topic kerberoast).' }

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
function Get-LabInstances {
    # Same discovery as the launcher; terminated / shutting-down instances are ignored.
    $filters = @(
        @{ Name = 'instance.group-id';   Values = $SecurityGroupIds }
        @{ Name = 'instance-state-name'; Values = @('pending', 'running', 'stopping', 'stopped') }
    )
    @((Get-EC2Instance -Filter $filters @aws).Instances)
}

function Get-InstanceName($Instance) {
    $name = ($Instance.Tags | Where-Object Key -eq 'Name').Value
    if ($name) { $name } else { $Instance.InstanceId }
}

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
function Assert-NotTimedOut([string]$What) {
    if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes min waiting for $What." }
}

# --- 1. Find the lab instances ------------------------------------------------
Write-Step "Finding lab instances in $Region"
$instances = Get-LabInstances
if (-not $instances) { throw "No live instances in security groups $($SecurityGroupIds -join ', '). Nothing to reset." }

$toTerminate = @($instances | Where-Object { $ResetName -contains (Get-InstanceName $_) })
$toStop      = @($instances | Where-Object { $ResetName -notcontains (Get-InstanceName $_) -and "$($_.State.Name)" -in 'pending', 'running' })

foreach ($i in $instances) {
    $action = if ($toTerminate -contains $i) { 'terminate' } elseif ($toStop -contains $i) { 'stop' } else { 'leave (already stopped)' }
    Write-Host ("    {0,-24} {1}  {2,-9} -> {3}" -f (Get-InstanceName $i), $i.InstanceId, $i.State.Name, $action)
}

# Duplicate Name tags would mean terminating something unexpected; stop and let a human look.
$dupes = @($toTerminate | Group-Object { Get-InstanceName $_ } | Where-Object Count -gt 1)
if ($dupes) { throw "More than one live instance named $($dupes.Name -join ', '). Sort that out by hand first." }

$missing = @($ResetName | Where-Object { $_ -notin ($toTerminate | ForEach-Object { Get-InstanceName $_ }) })
if ($missing) { Write-Warning "Not present (already reset?): $($missing -join ', ')" }

# --- 2. Golden AMI check -------------------------------------------------------
# Terminating is only safe if step 1 can rebuild. Mirror what -RebuildIfMissing
# needs: an available golden AMI per box, with its Launch* tags.
if ($toTerminate) {
    Write-Step 'Checking golden AMIs'
    $amis = @(Get-EC2Image -Owner self -Filter @(
        @{ Name = 'tag:Baseline'; Values = 'golden' }
        @{ Name = 'state';        Values = 'available' }
    ) @aws)

    foreach ($i in $toTerminate) {
        $boxName = Get-InstanceName $i
        $ami = $amis |
            Where-Object { ($_.Tags | Where-Object Key -eq 'LaunchName').Value -eq $boxName } |
            Sort-Object CreationDate -Descending | Select-Object -First 1
        if (-not $ami) {
            throw "No available golden AMI with LaunchName=$boxName. Step 1 couldn't rebuild it, so nothing was terminated. Capture one with New-GoldenBaseline.ps1 (or add the Launch* tags to the existing AMI)."
        }
        $tag = @{}
        $ami.Tags | ForEach-Object { $tag[$_.Key] = $_.Value }
        foreach ($need in 'LaunchInstanceType', 'LaunchSubnetId', 'LaunchKeyName', 'LaunchSecurityGroupIds') {
            if (-not $tag[$need]) { throw "Golden AMI $($ami.ImageId) for '$boxName' is missing tag '$need', so step 1 couldn't rebuild it. Nothing was terminated." }
        }
        Write-Host "    $boxName  -> $($ami.ImageId)  ($($tag['BaselineId']))"
    }
}

# --- Confirm ------------------------------------------------------------------
$plan = @()
if ($toTerminate) { $plan += "terminate $(($toTerminate | ForEach-Object { Get-InstanceName $_ }) -join ', ')" + $(if ($PreserveDisk) { ' (snapshot disks first)' } else { ' (disks deleted)' }) }
if ($toStop)      { $plan += "stop $(($toStop | ForEach-Object { Get-InstanceName $_ }) -join ', ')" }
$plan += 'revoke AWSLab-launcher SG rules, unmount the log share, remove lab-state.json'

if ($Force) { $ConfirmPreference = 'None' }
if (-not $PSCmdlet.ShouldProcess("AWS lab in $Region", ($plan -join '; '))) { return }
$ConfirmPreference = 'None'   # confirmed once above; don't let each AWS cmdlet ask again

# --- 3. Snapshot the attacked disks (-PreserveDisk) ---------------------------
$snapshots = @()
if ($PreserveDisk -and $toTerminate) {
    Write-Step "Snapshotting attached volumes (Topic=$Topic)"
    $date = Get-Date -Format 'yyyy-MM-dd'
    foreach ($i in $toTerminate) {
        $boxName = Get-InstanceName $i
        foreach ($bdm in $i.BlockDeviceMappings | Where-Object { $_.Ebs }) {
            $tags = @(
                @{ Key = 'Name';           Value = "$Project-$Topic-$boxName-$date" }
                @{ Key = 'Project';        Value = $Project }
                @{ Key = 'Purpose';        Value = 'forensic' }
                @{ Key = 'Topic';          Value = $Topic }
                @{ Key = 'Date';           Value = $date }
                @{ Key = 'SourceName';     Value = $boxName }
                @{ Key = 'SourceInstance'; Value = $i.InstanceId }
                @{ Key = 'SourceDevice';   Value = $bdm.DeviceName }
            )
            $spec = [Amazon.EC2.Model.TagSpecification]::new()
            $spec.ResourceType = 'snapshot'
            $spec.Tags = [System.Collections.Generic.List[Amazon.EC2.Model.Tag]]::new()
            $tags | ForEach-Object { $spec.Tags.Add([Amazon.EC2.Model.Tag]::new($_.Key, $_.Value)) }

            $snap = New-EC2Snapshot -VolumeId $bdm.Ebs.VolumeId -TagSpecification $spec `
                -Description "$Project forensic: $Topic $boxName $($bdm.DeviceName) $date" @aws
            Write-Host "    $boxName $($bdm.DeviceName) $($bdm.Ebs.VolumeId) -> $($snap.SnapshotId)"
            $snapshots += $snap.SnapshotId
        }
    }

    # Wait for completion before terminating: the volumes are deleted with the instances.
    while ($snapshots) {
        $state = @(Get-EC2Snapshot -SnapshotId $snapshots @aws)
        $failed = @($state | Where-Object { "$($_.State)" -eq 'error' })
        if ($failed) { throw "Snapshot failed: $($failed.SnapshotId -join ', '). Nothing was terminated." }
        $pending = @($state | Where-Object { "$($_.State)" -ne 'completed' })
        if (-not $pending) { break }
        Assert-NotTimedOut "snapshots ($(($pending | ForEach-Object { "$($_.SnapshotId) $($_.Progress)" }) -join ', '))"
        Start-Sleep -Seconds 15
    }
    if ($snapshots) { Write-Host '    all snapshots completed' }
}

# --- 4. Terminate the pair, stop the rest -------------------------------------
if ($toTerminate) {
    Write-Step 'Terminating'
    Remove-EC2Instance -InstanceId $toTerminate.InstanceId -Force @aws | Out-Null
    $toTerminate | ForEach-Object { Write-Host "    terminating $(Get-InstanceName $_)" }
}
if ($toStop) {
    Write-Step 'Stopping the other lab boxes'
    Stop-EC2Instance -InstanceId $toStop.InstanceId @aws | Out-Null
    $toStop | ForEach-Object { Write-Host "    stopping $(Get-InstanceName $_)" }
}

# Wait until terminated (releases the private IPs the rebuild reuses) and stopped.
$waitIds = @($toTerminate.InstanceId) + @($toStop.InstanceId) | Where-Object { $_ }
if ($waitIds) {
    Write-Step 'Waiting for terminated / stopped'
    while ($true) {
        $now  = @((Get-EC2Instance -InstanceId $waitIds @aws).Instances)
        $busy = @($now | Where-Object { "$($_.State.Name)" -notin 'terminated', 'stopped' })
        if (-not $busy) { break }
        Assert-NotTimedOut "$(($busy | ForEach-Object { "$(Get-InstanceName $_) ($($_.State.Name))" }) -join ', ')"
        Start-Sleep -Seconds 10
    }
    Write-Host '    done'
}

# --- 5. Clean up --------------------------------------------------------------
Write-Step 'Cleaning up'

# Volumes that outlived their instance (DeleteOnTermination off). Reported, not deleted.
if ($toTerminate) {
    $volIds = @($toTerminate.BlockDeviceMappings | Where-Object { $_.Ebs } | ForEach-Object { $_.Ebs.VolumeId })
    $left = if ($volIds) {
        @(Get-EC2Volume -Filter @(
            @{ Name = 'volume-id'; Values = $volIds }
            @{ Name = 'status';    Values = 'available' }
        ) @aws)
    }
    if ($left) {
        Write-Warning "Volumes left behind (DeleteOnTermination off; still billed): $($left.VolumeId -join ', '). Delete with Remove-EC2Volume if not needed."
    }
}

foreach ($sg in $SecurityGroupIds) {
    $tagged = @(Get-EC2SecurityGroupRule -Filter @{ Name = 'group-id'; Values = $sg } @aws |
                Where-Object { -not $_.IsEgress -and $_.Description -eq $RuleTag })
    if ($tagged) {
        Revoke-EC2SecurityGroupIngress -GroupId $sg -SecurityGroupRuleId $tagged.SecurityGroupRuleId @aws | Out-Null
        Write-Host "    $sg  revoked: $($tagged.CidrIpv4 -join ', ')"
    } else {
        Write-Host "    $sg  no launcher rules"
    }
}

if ($IsWindows -and (Get-Command Get-SmbMapping -ErrorAction SilentlyContinue)) {
    $mapping = Get-SmbMapping -LocalPath $ShareDrive -ErrorAction SilentlyContinue
    if ($mapping) {
        $mapping | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        Write-Host "    unmounted $ShareDrive"
    }
}

if (Test-Path $StatePath) {
    Remove-Item $StatePath
    Write-Host "    removed $StatePath"
}

# --- 6. Summary ---------------------------------------------------------------
Write-Step 'Lab reset'
if ($toTerminate) { Write-Host "    terminated: $(($toTerminate | ForEach-Object { Get-InstanceName $_ }) -join ', ')" }
if ($toStop)      { Write-Host "    stopped:    $(($toStop | ForEach-Object { Get-InstanceName $_ }) -join ', ')" }
if ($snapshots)   { Write-Host "    snapshots:  $($snapshots -join ', ')  (Topic=$Topic)" }
Write-Host '    bring it back with: ./Start-AwsLab.ps1 -RebuildIfMissing'
