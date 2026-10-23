# AWSLab

An AWS lab for practicing Active Directory attacks and investigating them afterward.

**Lab:** a domain controller and a member server (Windows Server Core) plus a Kali box, in `ap-southeast-2` (Sydney).

| File | What it is |
|---|---|
| `Start-AwsLab.ps1` | Step 1 launcher: starts the lab and opens access from your current IP |
| `Stop-AwsLab.ps1` / `stop-awslab.sh` | Step 4 reset: terminates the attacked DC + member, optional forensic snapshots (see [README-reset.md](README-reset.md)) |
| `sysmon_config.xml` | Sysmon configuration for the Windows hosts |
| `sysmon_main.ps1` | Downloads and installs Sysmon with the config above |

Automation is planned in three steps: **1. launch** (done), **2. per-topic vulnerable setup and audit policy**, **3. log collection** over WinRM.

---

## Launcher: `Start-AwsLab.ps1`

Run it on your laptop, not in AWS. It needs your current public IP and WinRM access from your machine.

### What it does

1. **Finds the lab instances** by their membership in the two lab security groups. No instance IDs are hard-coded, so instances you add to those groups later are picked up automatically.
2. **Starts them.** Stopped instances are started. Instances that are still `stopping` are left until they finish, then started. It waits until everything is `running`.
3. **Resolves your public IP** using `checkip.amazonaws.com`.
4. **Opens both security groups to that IP** (all traffic, `/32`):
   - `sg-02df021a36003f4f1` (Windows servers)
   - `sg-0549668744af8e82d` (Kali)

   Rules the launcher creates carry the description `AWSLab-launcher`. Each run revokes any tagged rule for an old IP and adds one for your current IP. It skips the add if that rule already exists. Rules without that description are never touched.
5. **Waits for WinRM** (TCP 5985) on the Windows hosts. Public IPs change on every start, so it reads them fresh.
6. **Prints a connection summary** with each instance's name, ID, OS, private and public IPs, and reachability, plus ready-to-copy connect commands.
7. **Writes `lab-state.json`** next to the script so later steps can read this launch's IPs. The file is git-ignored.

### Prerequisites (one time)

```powershell
# PowerShell 7+
Install-Module AWS.Tools.Installer -Scope CurrentUser
Install-AWSToolsModule AWS.Tools.EC2 -CleanUp

# AWS credentials: either an access key...
Set-AWSCredential -AccessKey <key> -SecretKey <secret> -StoreAs default
# ...or SSO / a named profile, then pass -ProfileName
```

Also after the first run, delete any security group rules you added by hand for older IPs. The launcher only cleans up its own tagged rules.

### Usage

```powershell
./Start-AwsLab.ps1                          # start every lab instance
./Start-AwsLab.ps1 -Name Kali               # start only Kali
./Start-AwsLab.ps1 -Name '*DC*', Kali       # several, with wildcards
./Start-AwsLab.ps1 -Name i-0123456789abcdef # by instance ID
./Start-AwsLab.ps1 -ProfileName lab         # use a named AWS profile
./Start-AwsLab.ps1 -Connect                 # also open a terminal tab per instance
./Start-AwsLab.ps1 -Connect -WinRmUser 'LAB\Administrator'   # pre-fill the WinRM user name
./Start-AwsLab.ps1 -Name dc, member01, kali # start just these three
./Start-AwsLab.ps1 -NoMountShare            # start the lab but don't map the log share
```

`-Name` matches each instance's `Name` tag or instance ID. Matching isn't case-sensitive and accepts wildcards. If nothing matches, the error lists the available names. Both security groups are still updated with your IP, so any instance already running stays reachable.

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Name` | *(all)* | Name tags or instance IDs to start; wildcards allowed |
| `-Region` | `ap-southeast-2` | AWS region |
| `-ProfileName` | *(default credentials)* | AWS credential profile |
| `-SecurityGroupIds` | the two lab SGs | Groups used to find instances and to open to your IP |
| `-TimeoutMinutes` | `15` | Overall limit for instances to start and WinRM to come up |
| `-StatePath` | `./lab-state.json` | Where the launch state is written |
| `-KaliKeyPath` | `C:\Users\egopez\Documents\Pentest study\ec2keys\kali-linux.pem` | SSH key used in the Kali connect command |
| `-Connect` | off | Open one terminal tab per reachable instance, already connecting |
| `-WinRmUser` | *(none)* | User name pre-filled in each Windows tab's credential prompt |
| `-ShareHostName` | `member01` | Name tag of the member server hosting the log share; wildcards allowed |
| `-ShareDrive` | `L:` | Drive letter the log share is mapped to on this laptop |
| `-ShareCredential` | *(prompts)* | Credential for the log share; prompts once if omitted |
| `-NoMountShare` | off | Skip mounting the log share |

### Connecting

The summary prints commands like these:

```powershell
Enter-PSSession -ComputerName <dc-public-ip> -Credential (Get-Credential -Message 'WinRM login for AD-DC01')
ssh -i 'C:\Users\egopez\Documents\Pentest study\ec2keys\kali-linux.pem' kali@<kali-public-ip>
```

**`-Connect`** runs those commands for you. It opens one tab per reachable instance in a single Windows Terminal window named `AWSLab`, each tab titled with the instance name. Windows tabs open a WinRM session and ask for the login; the Kali tab SSHes in with your key. Tabs stay open after you exit the session, so you can reconnect with the up arrow. Instances that aren't reachable are skipped with a warning. Without Windows Terminal it opens separate PowerShell windows instead; on macOS or Linux it does nothing but print the commands.

WinRM over HTTP to a bare IP needs the target in your laptop's TrustedHosts. This is a one-time setup from an elevated prompt:

```powershell
Start-Service WinRM
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force   # or list specific IPs
```

Because the lab's public IPs change on every start, `'*'` saves updating the list each time. Your security groups only admit your own IP.

### Log share mount

After launch, the script maps the member server's `LabLogs` share to a drive on your
laptop (default `L:`, member found by the `-ShareHostName` tag, default `member01`). It's on
by default; pass `-NoMountShare` to skip it.

Because the member server's public IP changes on every launch, the script first clears any
mapping on that one drive letter, then re-maps it — so a stale mapping from last session
can't get in the way. **Only that drive letter is touched; shares you've mapped to other
letters are left alone.** Give `-ShareCredential` to avoid the one-time login prompt.

> This mounts SMB (445) over the public internet. Your SG only admits your own IP, but many
> ISPs block outbound 445 — if the mount times out, that's usually why, and it's only the
> convenience mount that's affected. Log collection itself goes over WinRM (5985).

### `lab-state.json`

```json
{
  "LaunchedAt": "2026-10-18T17:00:00-04:00",
  "Region": "ap-southeast-2",
  "MyIp": "203.0.113.10",
  "Instances": [
    { "Name": "...", "InstanceId": "i-...", "Os": "Windows", "PrivateIp": "10.0.x.x",
      "PublicIp": "x.x.x.x", "Access": "WinRM 5985", "Reachable": true }
  ]
}
```

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `AWS.Tools.EC2 isn't installed` | Run the prerequisite install above |
| `No instances found in security groups` | Wrong region or profile, or the instances aren't in those SGs |
| `No lab instance matches -Name ...` | Typo in `-Name`; the error lists valid names |
| Timed out waiting for WinRM | The WinRM service or listener isn't up on the host, or Windows is still booting (raise `-TimeoutMinutes`) |
| `Reachable: False` for Kali | `sshd` isn't running, or the instance is still booting |
