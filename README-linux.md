# Linux launcher: `start-awslab.sh`

The bash counterpart of `Start-AwsLab.ps1`, for driving the lab from a Linux box
(e.g. the mini PC). Same job: start the instances, open both security groups to
**this machine's** public IP, wait for WinRM, mount the member server's log
share, and print a connection summary. It finds instances by security-group
membership and only touches rules it tagged `AWSLab-launcher`.

## Prerequisites

```bash
# AWS CLI v2 + helpers
sudo apt install -y jq curl cifs-utils      # cifs-utils only needed for --mount
# install awscli v2 per AWS docs, then configure creds:
aws configure                                # or SSO; region ap-southeast-2
```

## Usage

```bash
./start-awslab.sh                              # start every lab instance + mount share
./start-awslab.sh -n dc,member01,kali          # start just these three (not the VPN)
./start-awslab.sh --no-mount                   # start, but don't mount the share
./start-awslab.sh -n kali --no-mount           # just Kali, no mount
./start-awslab.sh --profile lab --region us-east-1
```

Options: `-n/--name`, `--region`, `--profile`, `--share-host` (default `member01`),
`--mount-point` (default `~/lab-logs`), `--cred-file` (default `~/.awslab/share.cred`),
`--no-mount`, `--timeout` (minutes, default 15), `-h/--help`.

## Mounting the log share

The mount uses CIFS and needs two one-time things:

1. **A credentials file** (chmod 600 so only you can read it):
   ```bash
   mkdir -p ~/.awslab
   cat > ~/.awslab/share.cred <<'EOF'
   username=Administrator
   password=YOUR_PASSWORD
   domain=LAB
   EOF
   chmod 600 ~/.awslab/share.cred
   ```
2. **Permission to mount.** `mount -t cifs` needs root, so the script calls `sudo`.
   For a hands-free / Claude-launched run (no password prompt), allow just the
   mount and umount without a password — `sudo visudo` and add:
   ```
   youruser ALL=(root) NOPASSWD: /usr/bin/mount.cifs, /usr/bin/umount
   ```
   Or simply run with `--no-mount` and mount by hand when you sit down.

The mount is **non-fatal**: if it fails (e.g. your ISP blocks outbound SMB/445),
the launch still completes and log collection still works over WinRM (5985).
Because the member server's public IP changes each launch, the script unmounts a
stale mount at the same point before re-mounting.

## Having Claude launch it (mini PC)

With the Claude desktop app installed on the mini PC and this chat linked to it,
Claude runs the launcher for you through the machine's shell:

```bash
/path/to/AWSLab/start-awslab.sh -n dc,member01,kali
```

This is the Linux half of the `lab` skill — "start the lab" on the mini PC runs
this; the Windows work laptop runs `Start-AwsLab.ps1` from its own local shortcut.
The mini PC must be awake, online, and running the Claude desktop app.

## Notes

- Connect hints are printed per host: `ssh kali@<ip>` for Kali, and
  `evil-winrm`/`xfreerdp` for the Windows boxes.
- Writes `lab-state.json` next to the script (git-ignored), same shape as the
  PowerShell launcher's.
- Each machine that runs a launcher opens the SG to *its own* IP, so running this
  on the mini PC and the laptop launcher at the same time will fight over the
  single allowed IP. Drive the lab from one machine at a time.
