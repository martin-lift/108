# Setup-Teacher.ps1 — run in elevated Windows PowerShell 5.1
# Configures ONLY outbound WinRM client access to 27 named student computers.
# No passwords are stored. Does not enable inbound remoting.
# Run once; re-running is safe.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$service = Get-Service -Name WinRM
if ($service.Status -ne 'Running') { Start-Service WinRM }
$path = 'WSMan:\localhost\Client\TrustedHosts'
$old = [string](Get-Item $path).Value
$backupDir = Join-Path $env:ProgramData 'Cabinet307'
New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
$backupPath = Join-Path $backupDir 'TrustedHosts-before-setup.txt'
if (-not (Test-Path $backupPath)) {
    Set-Content -LiteralPath $backupPath -Value $old -Encoding UTF8
}
$names = @(1..27 | ForEach-Object { '307-Student-{0:D2}.local' -f $_ })
$current = @($old -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$merged = @(($current + $names) | Select-Object -Unique)
$newValue = $merged -join ','
if ($newValue -ne $old) { Set-Item -Path $path -Value $newValue -Force }
Write-Host "WinRM client ready. TrustedHosts entry count: $($merged.Count)"
Write-Host "Original list saved (first run): $backupPath"
Write-Warning 'TrustedHosts is NOT host authentication. Use only on a controlled network.'
