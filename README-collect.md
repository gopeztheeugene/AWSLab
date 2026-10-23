# Step 3, log collection: `Collect-TopicLogs.ps1`

After an attack, while the boxes are still up, pull the relevant logs over WinRM
into the log share. **Collection only** — it never stops or terminates anything
(that's step 4). Runs under PowerShell 7 on the Windows laptop or the Linux mini
PC; transport is WinRM over HTTP 5985 (PSRP), no SMB.

## What it collects

Driven by a per-topic manifest, `collection/<topic>.psd1`, which names — per host —
which logs to pull and which event IDs are the signal. For each host it:

- exports each named log in full to `.evtx` (`wevtutil` on the host, copied back
  over the WinRM session) — the forensic copy;
- pulls a filtered `*-focus.csv` / `.json` of the topic's focus event IDs — quick look;
- hashes everything into `manifest.json` and writes a `README.txt`.

Output goes to `<OutputRoot>/<topic>/<timestamp>/<host>/…` (OutputRoot defaults to
`L:` on Windows, `~/lab-logs` on Linux — the mounted share from step 1).

## Usage

```powershell
./Collect-TopicLogs.ps1 -Topic kerberoast -WhatIf          # show plan, connect to nothing
./Collect-TopicLogs.ps1 -Topic kerberoast                  # pull all hosts in the manifest
./Collect-TopicLogs.ps1 -Topic kerberoast -Hosts dc -SinceMinutes 120
./Collect-TopicLogs.ps1 -Topic kerberoast -OutputRoot ~/lab-logs   # Linux mini PC
```

| Parameter | Default | Purpose |
|---|---|---|
| `-Topic` | (required) | Manifest `collection/<topic>.psd1` |
| `-Hosts` | all in manifest | Limit to these Name tags |
| `-SinceMinutes` | 0 (whole log) | Only events newer than this |
| `-OutputRoot` | `L:` / `~/lab-logs` | Where to write |
| `-Credential` | prompts | WinRM login (e.g. `lab\Administrator`) |
| `-StatePath` | `./lab-state.json` | Host IPs from step 1 |

## Kerberoasting

The DC (KDC) logs the service-ticket activity, so the DC `Security` log is the
primary evidence. The signal is **4769** with **Ticket Encryption Type 0x17**
(RC4) and a burst of distinct Service Names (SPNs) from one Client Address.

If the Security export has **no 4769**, the step 2 audit policy wasn't on — the
manifest's `RequiredAudit` lists what must be enabled (Kerberos Service Ticket
Operations, Success).
