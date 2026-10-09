# Setup-Student.ps1 — run LOCALLY as administrator on ONE student PC.
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [Parameter(Mandatory=$true)][ValidateRange(1,27)][int]$Number,
  [switch]$AllowFullRemoteToken
)
$ErrorActionPreference = 'Stop'
$target = '307-Student-{0:D2}' -f $Number
$dir = Join-Path $env:ProgramData 'Cabinet307'
$backupFile = Join-Path $dir 'Student-before-setup.json'
$reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$normal = Get-LocalUser -Name '108SU' -ErrorAction SilentlyContinue
$spaced = Get-LocalUser -Name '108 SU' -ErrorAction SilentlyContinue
if ($normal -and $spaced) { throw 'Both 108SU and 108 SU exist: resolve manually.' }
if (-not $normal -and -not $spaced) { throw 'Neither 108SU nor 108 SU exists.' }
$user = if ($normal) { $normal } else { $spaced }
$adminGroup = Get-LocalGroup -SID 'S-1-5-32-544'
$adminSids = @(Get-LocalGroupMember -Group $adminGroup.Name | ForEach-Object { $_.SID.Value })
if (-not $user.Enabled -or $user.SID.Value -notin $adminSids) {
  throw 'The account is disabled or is not a local administrator.'
}
if (-not (Test-Path $backupFile)) {
  New-Item -Path $dir -ItemType Directory -Force | Out-Null
  $property = Get-ItemProperty -Path $reg -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
  $snapshot = [pscustomobject]@{
    OriginalComputerName = $env:COMPUTERNAME
    OriginalAdminName = $user.Name
    OriginalWinRMStartType = (Get-Service WinRM).StartType.ToString()
    OriginalWinRMStatus = (Get-Service WinRM).Status.ToString()
    LocalAccountTokenFilterPolicyExisted = ($null -ne $property)
    LocalAccountTokenFilterPolicyValue = if ($property) { $property.LocalAccountTokenFilterPolicy } else { $null }
    CapturedAt = (Get-Date).ToString('o')
  }
  if ($PSCmdlet.ShouldProcess($backupFile,'Create initial snapshot')) {
    $snapshot | ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8
  }
}
if ($spaced -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Rename local user 108 SU to 108SU')) {
  Rename-LocalUser -Name '108 SU' -NewName '108SU'
}
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Enable PowerShell remoting on Public profile')) {
  Enable-PSRemoting -SkipNetworkProfileCheck -Force
}
if ($AllowFullRemoteToken) {
  Write-Warning 'Setting LocalAccountTokenFilterPolicy=1 reduces remote UAC restrictions for ALL local administrators.'
  if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Set LocalAccountTokenFilterPolicy=1')) {
    Set-ItemProperty -Path $reg -Name LocalAccountTokenFilterPolicy -Value 1
  }
} else {
  Write-Warning 'Remote administrative operations with the local 108SU account may fail while LocalAccountTokenFilterPolicy=0.'
}
if ($env:COMPUTERNAME -ne $target -and
    $PSCmdlet.ShouldProcess($env:COMPUTERNAME,"Rename computer to $target")) {
  Rename-Computer -NewName $target -Force
  Write-Warning 'Restart required for the new computer name.'
}
Write-Host "Target: $target. Verify firewall scope, identity and remote access before wider deployment."
