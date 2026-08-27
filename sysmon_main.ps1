function Write-Log {
param([string]$Message)
$TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path "$dest\script.log" -Value "[$TimeStamp] $Message"
}

$dest = "C:\Sysmon"
$zip = "$dest\Sysmon.zip"
$config_link = "https://raw.githubusercontent.com/gopeztheeugene/AWSLab/refs/heads/main/sysmon_config.xml"
$sysmon_config = "$dest\sysmon_config.xml" 

Set-Location $dest
New-Item -ItemType Directory -Force -Path $dest
if ($?){Write-Log "Folder Created"}

while ($true) {
    try {
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $zip
    }
    catch {
     Write-Log "Attempt to download sysmon failed: $($_.Exception.Message)" | Out-File "$dest\sysmon_script.log" -Append
     Start-Sleep -Seconds 10
    }
    if (test-path $zip) {
        Write-Log "Sysmon zip file downloaded succeeded"
        break
    }
    
}

Expand-Archive -Path $zip -DestinationPath $dest -Force
if($?){
    Write-Log "Successfuly unziped file"
    Remove-Item $zip -Force
}

while ($true) {
    try {
    Invoke-WebRequest -Uri $config_link -OutFile $sysmon_config
    }
    catch {
     Write-Log "Attempt to download sysmon config file failed: $($_.Exception.Message)"
     Start-Sleep -Seconds 10
    }
    if (test-path $sysmon_config) {
        Write-Log "Successfuly downloaded sysmon config file"
        break
    }
}

try{
    Start-Process ` -FilePath "$dest\Sysmon64.exe" `
    -ArgumentList "-accepteula", "-i", "$dest\sysmon_config.xml"
    if($?){Write-Log "Config Loaded"}
}
catch{
    Write-Log "Attempt to load sysmon failed: $($_.Exception.Message)"
}

