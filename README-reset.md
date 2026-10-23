# Step 4, reset: `Stop-AwsLab.ps1` / `stop-awslab.sh`

Terminates the attacked DC + member pair and cleans up, so the next step 1 run
rebuilds them clean from the golden AMIs. `Stop-AwsLab.ps1` (PowerShell 7 +
AWS.Tools.EC2) and `stop-awslab.sh` (bash + AWS CLI v2 + jq) do the same thing.

No relaunch here. Bringing the lab back is step 1's job (`Start-AwsLab.ps1 -RebuildIfMissing`).

## What it does

1. **Finds the lab instances** by security-group membership, like the launcher. Terminated instances are ignored.
2. **Checks the golden AMIs.** Every box it would terminate needs an available golden AMI (`Baseline=golden`) whose
   `LaunchName` matches, carrying the `Launch*` tags the rebuild reads. If any is missing, it stops before changing anything.
3. **Asks to confirm** the plan (`-Force` / `-y` skips; `-WhatIf` / `--dry-run` shows it and exits).
4. **Optional: snapshots** (`-PreserveDisk`). Snapshots every attached EBS volume of the pair and waits for them to complete.
5. **Terminates `dc` + `member01`** together (a matched pair, never one alone) and waits for `terminated`, so their fixed
   private IPs are free for the rebuild.
6. **Stops the other lab boxes** (Kali, VPN server). They have no golden AMI, so they're never terminated.
7. **Cleans up:**
   - revokes the `AWSLab-launcher` security-group rules (hand-made rules untouched)
   - unmounts the log share (`L:` / `~/lab-logs`)
   - removes `lab-state.json`
   - warns about any volume left behind with DeleteOnTermination off (reported, not deleted)

Pull the logs you need with step 3 **before** running this. Without `-PreserveDisk`, the disks are deleted.

## Usage

```powershell
./Stop-AwsLab.ps1 -WhatIf                           # show the plan, change nothing
./Stop-AwsLab.ps1                                   # terminate the pair, stop the rest (asks first)
./Stop-AwsLab.ps1 -PreserveDisk -Topic kerberoast   # snapshot the attacked disks first
./Stop-AwsLab.ps1 -Force -ProfileName lab
```

```bash
./stop-awslab.sh --dry-run
./stop-awslab.sh                                    # asks you to type 'reset'
./stop-awslab.sh --preserve-disk --topic kerberoast
./stop-awslab.sh -y --profile lab
```

| PowerShell | bash | Default | Purpose |
|---|---|---|---|
| `-PreserveDisk` | `--preserve-disk` | off | Snapshot the pair's volumes before terminating |
| `-Topic` | `--topic` | (required with the above) | Attack topic for the snapshot tags |
| `-ResetName` | `--reset-name` | `dc`, `member01` | Golden-backed boxes to terminate |
| `-Region` | `--region` | `ap-southeast-2` | AWS region |
| `-ProfileName` | `--profile` | (default creds) | AWS credential profile |
| `-TimeoutMinutes` | `--timeout` | 30 | Overall wait for snapshots and termination |
| `-ShareDrive` | `--mount-point` | `L:` / `~/lab-logs` | Log share mount to remove |
| `-Force` | `-y`, `--yes` | off | Skip the confirmation |
| `-WhatIf` | `--dry-run` | off | Show the plan only |

## Forensic snapshots

Each snapshot is tagged:

| Tag | Value |
|---|---|
| `Name` | `AWSLab-<topic>-<box>-<yyyy-mm-dd>` |
| `Project` | `AWSLab` |
| `Purpose` | `forensic` |
| `Topic` | the `-Topic` value |
| `Date` | the run date |
| `SourceName` / `SourceInstance` / `SourceDevice` | where it came from |

Find them later:

```powershell
Get-EC2Snapshot -OwnerId self -Filter @{ Name = 'tag:Purpose'; Values = 'forensic' } -Region ap-southeast-2
```

To examine one, create a volume from it and attach it to an analysis box as a secondary disk.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No available golden AMI with LaunchName=...` | The AMI predates the `Launch*` tags (added with `-RebuildIfMissing`). Re-capture with `New-GoldenBaseline.ps1`, or add the tags by hand. |
| `More than one live instance named ...` | Two boxes share a Name tag; terminate the wrong one by hand first. |
| `Not present (already reset?)` | That box is already gone; the rest still runs. |
| Rebuild says the private IP is still in use | Rare after this script, since it waits for `terminated`. Wait a minute and re-run step 1. |
