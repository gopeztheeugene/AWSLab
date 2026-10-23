<#
    New-GoldenBaseline.ps1
    --------------------------------------------------------------------------
    Capture CLEAN golden AMIs of the DC + member server as a matched pair,
    for the AWSLab reset/rollback model (step 1 rebuilds from these).

    Run this from the machine that has your AWS credentials + the AWS Tools
    for PowerShell (AWS.Tools.EC2) installed. It does NOT sysprep/generalize:
    it keeps the domain join, SID and computer-account trust intact, which is
    what you want for a domain-joined DC+member pair.

    PREREQ: the lab must be CLEAN right now — member joined, Sysmon installed,
    patched, and NOTHING attacked yet. Whatever state these two boxes are in
    is the state every future rebuild starts from.
    --------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    [string]$Region  = 'ap-southeast-2',   # the lab lives in Sydney
    [string]$Project = 'AWSLab',

    # Discovery is by the instances' Name tag (standardized to dc / member01).
    # Override the names here, or pass instance IDs directly to skip discovery.
    [string]$DcName          = 'dc',
    [string]$MemberName      = 'member01',
    [string]$DcInstanceId,
    [string]$MemberInstanceId,

    # Off by default = allow the reboot for a filesystem-consistent image.
    # Only set this if you have a reason to keep the boxes running.
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
Set-DefaultAWSRegion -Region $Region

# Shared id that links the two AMIs as one baseline set.
$baselineId = 'golden-{0:yyyyMMdd-HHmm}' -f (Get-Date)
Write-Host "Baseline id for this run: $baselineId" -ForegroundColor Cyan

function Resolve-LabInstance {
    param([string]$NameTag)
    $found = (Get-EC2Instance -Filter @(
        @{ Name = 'tag:Name';             Values = $NameTag },
        @{ Name = 'instance-state-name';  Values = @('running','stopped') }
    )).Instances
    if (@($found).Count -ne 1) {
        throw "Expected exactly 1 instance with Name tag '$NameTag', found $(@($found).Count). Pass the instance ID explicitly, or check the Name tag."
    }
    $found.InstanceId
}

if (-not $DcInstanceId)     { $DcInstanceId     = Resolve-LabInstance -NameTag $DcName }
if (-not $MemberInstanceId) { $MemberInstanceId = Resolve-LabInstance -NameTag $MemberName }

Write-Host "DC    : $DcInstanceId"
Write-Host "Member: $MemberInstanceId"

$targets = @(
    [pscustomobject]@{ Role = 'DC';     InstanceId = $DcInstanceId },
    [pscustomobject]@{ Role = 'Member'; InstanceId = $MemberInstanceId }
)

$results = foreach ($t in $targets) {
    # Read the source instance's launch settings so the AMI is self-describing:
    # the launcher's rebuild path reads these tags and needs nothing else.
    $src      = (Get-EC2Instance -InstanceId $t.InstanceId).Instances[0]
    $srcName  = ($src.Tags | Where-Object Key -eq 'Name').Value
    $srcSgIds = @($src.SecurityGroups | ForEach-Object { $_.GroupId }) -join ','
    $srcIam   = $src.IamInstanceProfile.Arn

    $name = "$Project-$($t.Role)-$baselineId"
    Write-Host "`nCreating AMI for $($t.Role) ($($t.InstanceId), Name=$srcName) -> $name" -ForegroundColor Green

    # Reboot-for-consistency unless -NoReboot was passed.
    $imageId = New-EC2Image -InstanceId $t.InstanceId `
        -Name $name `
        -Description "Clean golden baseline $baselineId for $($t.Role)" `
        -NoReboot ([bool]$NoReboot)

    $tags = @(
        @{ Key = 'Name';                   Value = $name }
        @{ Key = 'Project';                Value = $Project }
        @{ Key = 'Role';                   Value = $t.Role }
        @{ Key = 'Baseline';               Value = 'golden' }
        @{ Key = 'BaselineId';             Value = $baselineId }
        # --- launch settings: enough for the launcher to recreate this box ---
        @{ Key = 'LaunchName';             Value = $srcName }
        @{ Key = 'LaunchInstanceType';     Value = "$($src.InstanceType)" }
        @{ Key = 'LaunchSubnetId';         Value = $src.SubnetId }
        @{ Key = 'LaunchPrivateIp';        Value = $src.PrivateIpAddress }
        @{ Key = 'LaunchKeyName';          Value = $src.KeyName }
        @{ Key = 'LaunchSecurityGroupIds'; Value = $srcSgIds }
    )
    if ($srcIam) { $tags += @{ Key = 'LaunchIamProfileArn'; Value = $srcIam } }

    # Tag the AMI.
    New-EC2Tag -Resource $imageId -Tag $tags

    # Tag the backing snapshot(s) too, so forensic/cost tooling can see them.
    # Snapshot IDs appear in the image's block device mapping once registration
    # progresses; poll (up to ~2 min) until they're populated.
    $snapIds = @()
    for ($i = 0; $i -lt 20 -and $snapIds.Count -eq 0; $i++) {
        Start-Sleep -Seconds 6
        $img = Get-EC2Image -ImageId $imageId
        $snapIds = @($img.BlockDeviceMapping.Ebs.SnapshotId | Where-Object { $_ })
    }
    if ($snapIds.Count) {
        New-EC2Tag -Resource $snapIds -Tag $tags
    } else {
        Write-Warning "Snapshot IDs for $name weren't populated in time; snapshots left untagged (cosmetic — tag later if wanted)."
    }

    [pscustomobject]@{
        Role      = $t.Role
        Name      = $srcName
        AmiId     = $imageId
        PrivateIp = $src.PrivateIpAddress
        Snapshot  = ($snapIds -join ',')
    }
}

Write-Host "`nGolden baseline captured ($baselineId):" -ForegroundColor Cyan
$results | Format-Table -AutoSize

Write-Host @"

NOTE:
  * The AMIs start in 'pending' and take a few minutes to reach 'available'.
    Check with: Get-EC2Image -Owner self -Filter @{Name='tag:BaselineId';Values='$baselineId'}
  * Both AMIs share BaselineId '$baselineId' -- restore the PAIR together on a
    reset, never one against a drifted partner.
  * Each AMI carries its launch settings as Launch* tags (LaunchName,
    LaunchInstanceType, LaunchSubnetId, LaunchPrivateIp, LaunchKeyName,
    LaunchSecurityGroupIds). Start-AwsLab.ps1 -RebuildIfMissing reads those.
"@ -ForegroundColor DarkGray
