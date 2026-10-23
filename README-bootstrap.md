# Member server bootstrap: `bootstrap-member.ps1`

First-boot provisioning for a lab **member server** (Windows Server Core). Run as EC2
user-data when launching a fresh instance; it joins the domain, installs Sysmon, and
creates the log share, then reboots. You run it once per rebuild — it is *not* a
laptop-side launcher.

> The domain controller hosts the domain; the **member server hosts the log share**, on
> purpose — the DC is the box you attack, so its logs are evidence and should not share a
> box with your collection tooling.

## What it does, on first boot

1. Points DNS at the domain controller (`172.31.5.192`).
2. Waits for `lab.local` to resolve, then checks LDAP/389 reachability to the DC.
3. **Joins the domain** (the critical path).
4. **Renames** the computer to `MEMBER01`, retrying the transient *"directory service is
   busy"* error that happens when a join and rename land too close together.
5. Installs **Sysmon** from this repo (`sysmon_main.ps1` + `sysmon_config.xml`).
6. Creates the **`LabLogs`** SMB share at `C:\LabLogs`.
7. Reboots once to apply the join and rename.

Everything after the join is **non-fatal**: if rename, Sysmon, or the share fails, it is
logged and skipped so the box still ends up joined.

## Before you launch

- **Set `$JoinPass`** at the top of the script (it ships as `CHANGE_ME`).
- Launch the **Server 2022 Core** AMI in the **same subnet** as the DC, with the Windows
  security group `sg-02df021a36003f4f1` and your usual key pair.
- The Windows SG needs a **self-referencing inbound rule** (source = the SG itself) so the
  member can reach the DC on the private network. Without it, the script fails fast on the
  `:389` check with a clear message.
- Paste the script into **Advanced details → User data**.

> **Credentials warning:** the join password is embedded in user-data, which is readable
> from instance metadata. Acceptable for a throwaway lab only.

## Checking whether it worked — read the log

The script writes every step, with timestamps, to **`C:\bootstrap.log`**. After the box
comes back up, connect (WinRM/RDP) and run:

```powershell
# 1. Did it join? (the thing that matters)
(Get-WmiObject Win32_ComputerSystem) | Select-Object Name, Domain, PartOfDomain
#    want: Domain = lab.local, PartOfDomain = True

# 2. Read the bootstrap log end to end
Get-Content C:\bootstrap.log
```

### Reading `bootstrap.log`

A clean run looks like this (the final reboot line may be the last thing you see):

```
... Setting DNS to 172.31.5.192
... Waiting for lab.local to resolve
... Joining lab.local
... Joined OK
... Renamed to MEMBER01
... Installing Sysmon
... Sysmon done
... Creating log share
... Rebooting to apply join
```

| Last line you see | What it means | What to do |
|---|---|---|
| `Rebooting to apply join` (and `PartOfDomain = True`) | Full success | Nothing — you're done |
| `Joined OK` but no `Renamed to MEMBER01` | Join worked, rename lost the race 5× (name stays `EC2AMAZ-...`) | Rename is cosmetic; rename by hand (below) if you want it |
| `FAILED: Can't reach DC on LDAP/389 ...` | Member can't reach the DC | Add the SG self-referencing rule, relaunch |
| `Sysmon step failed (continuing): ...` | Join fine, Sysmon didn't install | Re-run `sysmon_main.ps1` by hand |
| **No `C:\bootstrap.log` at all** | User-data body never ran | Check `C:\ProgramData\Amazon\EC2Launch\log\agent.log` for a `<powershell>` tag / syntax error |

### Manual finishers (only if a non-fatal step was skipped)

```powershell
# rename, if it lost the race
$cred = Get-Credential        # LAB\Administrator
Rename-Computer -NewName MEMBER01 -DomainCredential $cred -Restart -Force

# Sysmon, if it was skipped
C:\AWSLab\sysmon_main.ps1

# log share, if it was skipped
New-Item C:\LabLogs -ItemType Directory -Force
New-SmbShare -Name LabLogs -Path C:\LabLogs -FullAccess 'LAB\Domain Admins'
```

## Verifying the extras

```powershell
Get-Service Sysmon*      # Running
Get-SmbShare  LabLogs    # share present
```
