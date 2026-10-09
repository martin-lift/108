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
# Diagnostics use fixed event names only: never serialize commands, credentials or raw errors.
$runId = [guid]::NewGuid().ToString('N')
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$logFile = Join-Path $dir 'Setup-Student.log'
$statusFile = Join-Path $dir 'Setup-Student-status.json'
$stage = 'Initialize'
$outcome = 'Running'
$restartRequired = $false
$loggingReady = $false
$lock = $null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-SetupEvent([string]$Event) {
  if ($WhatIfPreference) { return }
  $line = '{0} run={1} stage={2} event={3}' -f (Get-Date).ToUniversalTime().ToString('o'), $runId, $stage, $Event
  [IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, $utf8)
}
function Write-SetupStatus {
  if ($WhatIfPreference) { return }
  $status = [ordered]@{
    RunId = $runId; StartedAt = $startedAt
    UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Target = $target; Outcome = $outcome; Stage = $stage
    RestartRequired = $restartRequired
  }
  $tempFile = Join-Path $dir ('.Setup-Student-status-' + $runId + '.tmp')
  $previousFile = $tempFile + '.bak'
  try {
    [IO.File]::WriteAllText($tempFile, ($status | ConvertTo-Json), $utf8)
    if ([IO.File]::Exists($statusFile)) {
      [IO.File]::Replace($tempFile, $statusFile, $previousFile)
    } else { [IO.File]::Move($tempFile, $statusFile) }
  } finally {
    if ([IO.File]::Exists($tempFile)) { [IO.File]::Delete($tempFile) }
    if ([IO.File]::Exists($previousFile)) { [IO.File]::Delete($previousFile) }
  }
}
function Set-SetupStage([string]$Name) {
  Set-Variable -Name stage -Value $Name -Scope 1 -WhatIf:$false -Confirm:$false
  Write-SetupEvent 'Started'
  Write-SetupStatus
}
try {
  if (-not $WhatIfPreference) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    # Exclusive handle prevents concurrent runs from mixing status or configuration.
    $lock = [IO.File]::Open((Join-Path $dir 'Setup-Student.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    Write-SetupEvent 'RunStarted'
    $loggingReady = $true
    Write-SetupStatus
  }
  Set-SetupStage 'ValidateAccount'
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
  Set-SetupStage 'Snapshot'
  if (-not (Test-Path $backupFile)) {
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
      New-Item -Path $dir -ItemType Directory -Force | Out-Null
      $snapshot | ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8
      Write-SetupEvent 'Applied'
    }
  }
  Set-SetupStage 'RenameAccount'
  if ($spaced -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Rename local user 108 SU to 108SU')) {
    Rename-LocalUser -Name '108 SU' -NewName '108SU'
    Write-SetupEvent 'Applied'
  }
  Set-SetupStage 'EnableRemoting'
  if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Enable PowerShell remoting on Public profile')) {
    Enable-PSRemoting -SkipNetworkProfileCheck -Force
    Write-SetupEvent 'Applied'
  }
  Set-SetupStage 'RemoteTokenPolicy'
  if ($AllowFullRemoteToken) {
    Write-Warning 'Setting LocalAccountTokenFilterPolicy=1 reduces remote UAC restrictions for ALL local administrators.'
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Set LocalAccountTokenFilterPolicy=1')) {
      Set-ItemProperty -Path $reg -Name LocalAccountTokenFilterPolicy -Value 1
      Write-SetupEvent 'Applied'
    }
  } else {
    Write-Warning 'Remote administrative operations with the local 108SU account may fail while LocalAccountTokenFilterPolicy=0.'
  }
  Set-SetupStage 'RenameComputer'
  if ($env:COMPUTERNAME -ne $target -and
      $PSCmdlet.ShouldProcess($env:COMPUTERNAME,"Rename computer to $target")) {
    Rename-Computer -NewName $target -Force
    $restartRequired = $true
    Write-SetupEvent 'Applied'
    Write-Warning 'Restart required for the new computer name.'
  }
  Write-Host "Target: $target. Verify firewall scope, identity and remote access before wider deployment."

  $outcome = 'Completed'
  $stage = 'Finished'
  Write-SetupEvent 'RunCompleted'
  Write-SetupStatus
} catch {
  # Preserve the original terminating error even if diagnostic storage also fails.
  $outcome = 'Failed'
  if ($loggingReady) {
    try { Write-SetupEvent 'RunFailed' } catch { Write-Warning 'Unable to append setup failure to the log.' }
    try { Write-SetupStatus } catch { Write-Warning 'Unable to save setup failure status.' }
  } elseif (-not $WhatIfPreference) {
    Write-Warning 'Setup diagnostics could not be initialized; configuration was not started.'
  }
  throw
} finally {
  if ($null -ne $lock) { $lock.Dispose() }
}
