@{
    # -------------------------------------------------------------------------
    # Step 3 collection manifest: kerberoasting.
    #
    # What to pull after a kerberoast and why each log is the signal. Read by
    # Collect-TopicLogs.ps1. Collection only; nothing here changes the hosts.
    #
    # The KDC (the DC) logs the service-ticket activity, so the DC's Security
    # log is the primary evidence. Sysmon is corroboration; the roast tool
    # itself usually runs off-host (Kali), so on-host process-create may be thin.
    # -------------------------------------------------------------------------

    Topic       = 'kerberoast'
    Description = 'Kerberoasting: TGS-REQ for SPN-bearing accounts, RC4 tickets cracked offline.'

    # Per-host logs to export in full (.evtx) and filter for the focus IDs below.
    Hosts = @{
        dc = @{
            Logs = @(
                'Security'
                'Microsoft-Windows-Sysmon/Operational'
                'Microsoft-Windows-PowerShell/Operational'
            )
        }
        member01 = @{
            Logs = @(
                'Microsoft-Windows-Sysmon/Operational'
                'Security'
            )
        }
    }

    # Focus events pulled into the filtered CSV/JSON summary, by log. The full
    # .evtx is still exported regardless; these just drive the quick-look summary.
    Focus = @{
        'Security' = @(
            @{ Id = 4769; Why = 'Kerberos service ticket requested (TGS-REQ). THE signal. Watch Ticket Encryption Type 0x17 (RC4) — roasting tools request it for crackable tickets — and a burst of distinct Service Names (SPNs) from one Client Address.' }
            @{ Id = 4768; Why = 'Kerberos TGT requested (AS-REQ). Auth context for the roast; ties the client to the TGS burst.' }
            @{ Id = 4770; Why = 'Kerberos service ticket renewed. Secondary context.' }
            @{ Id = 4771; Why = 'Kerberos pre-auth failed. Context / adjacent AS-REP activity.' }
        )
        'Microsoft-Windows-Sysmon/Operational' = @(
            @{ Id = 1;  Why = 'Process creation. Catches on-host enumeration (setspn, PowerView GetUserSPNs) or a roast tool if run on the DC/member.' }
            @{ Id = 3;  Why = 'Network connection. Kerberos (TCP/UDP 88) connections around the request burst.' }
            @{ Id = 10; Why = 'ProcessAccess. LSASS access if credentials were touched — adjacent, not core.' }
            @{ Id = 11; Why = 'FileCreate. Tool or output drops (e.g. harvested hashes written to disk).' }
        )
        'Microsoft-Windows-PowerShell/Operational' = @(
            @{ Id = 4104; Why = 'Script block logging. Invoke-Kerberoast / GetUserSPNs if the enumeration or roast used PowerShell.' }
        )
    }

    # Audit policy that MUST be on for 4769 to appear (set in step 2). If the
    # Security export has no 4769, check this first.
    RequiredAudit = @(
        'Kerberos Service Ticket Operations (Success) -> 4769/4770'
        'Kerberos Authentication Service (Success)    -> 4768/4771'
    )
}
