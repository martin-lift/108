# Setup-Student.ps1 — run LOCALLY as administrator on ONE student PC.
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [ValidateRange(1,27)][int]$Number,
  [switch]$AllowFullRemoteToken
)
$ErrorActionPreference = 'Stop'
Write-Host 'Each student computer must have a unique number. Do not reuse a number assigned to another computer.'
if (-not $PSBoundParameters.ContainsKey('Number')) {
  do {
    $inputNumber = Read-Host 'Enter student computer number'
    $parsedNumber = 0
    $validNumber = [int]::TryParse($inputNumber, [ref]$parsedNumber) -and
      $parsedNumber -ge 1 -and $parsedNumber -le 27
    if (-not $validNumber) { Write-Warning 'Invalid student computer number. Please try again.' }
  } until ($validNumber)
  $Number = $parsedNumber
}
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
$appliedActions = New-Object 'System.Collections.Generic.List[string]'
$skippedActions = New-Object 'System.Collections.Generic.List[string]'
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
    AppliedActions = @($appliedActions.ToArray()); SkippedActions = @($skippedActions.ToArray())
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
function Get-RemoteTokenPolicy {
  # Read the key with terminating errors; an absent value means the default (0).
  $properties = Get-ItemProperty -Path $reg -ErrorAction Stop
  $value = if ($null -ne $properties) { $properties.PSObject.Properties['LocalAccountTokenFilterPolicy'] } else { $null }
  [pscustomobject]@{ Exists = ($null -ne $value); Value = if ($value) { $value.Value } else { 0 } }
}
function Write-ActionResult([string]$Action, [bool]$Applied) {
  if ($WhatIfPreference) { return }
  if ($Applied) {
    $appliedActions.Add($Action)
    Write-SetupEvent 'Applied'
    Write-Host "Applied: $Action."
  } else {
    $skippedActions.Add($Action)
    Write-SetupEvent 'Skipped'
    Write-Warning "Skipped: $Action."
  }
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
    $policy = Get-RemoteTokenPolicy
    $snapshot = [pscustomobject]@{
      OriginalComputerName = $env:COMPUTERNAME
      OriginalAdminName = $user.Name
      OriginalWinRMStartType = (Get-Service WinRM).StartType.ToString()
      OriginalWinRMStatus = (Get-Service WinRM).Status.ToString()
      LocalAccountTokenFilterPolicyExisted = $policy.Exists
      LocalAccountTokenFilterPolicyValue = if ($policy.Exists) { $policy.Value } else { $null }
      CapturedAt = (Get-Date).ToString('o')
    }
    if ($PSCmdlet.ShouldProcess($backupFile,'Create initial snapshot')) {
      New-Item -Path $dir -ItemType Directory -Force | Out-Null
      $snapshot | ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8
      # Read back the snapshot before permitting configuration changes.
      $null = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
      Write-ActionResult 'Snapshot' $true
    } elseif (-not $WhatIfPreference) {
      Write-ActionResult 'Snapshot' $false
      $outcome = 'Incomplete'
      Write-SetupEvent 'RunIncomplete'
      Write-SetupStatus
      Write-Warning 'Setup stopped: the initial snapshot is required before configuration changes.'
      return
    }
  } else {
    $savedSnapshot = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    $requiredFields = @('OriginalComputerName', 'OriginalAdminName', 'OriginalWinRMStartType',
      'OriginalWinRMStatus', 'LocalAccountTokenFilterPolicyExisted', 'LocalAccountTokenFilterPolicyValue', 'CapturedAt')
    foreach ($field in $requiredFields) {
      if ($null -eq $savedSnapshot -or $field -notin $savedSnapshot.PSObject.Properties.Name) {
        throw 'The existing initial snapshot is invalid. Configuration was not started.'
      }
    }
    Write-Host 'Initial snapshot already exists and will be preserved.'
  }
  Set-SetupStage 'RenameAccount'
  if ($spaced) {
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Rename local user 108 SU to 108SU')) {
      Rename-LocalUser -Name '108 SU' -NewName '108SU'
      Write-ActionResult 'RenameAccount' $true
    } else { Write-ActionResult 'RenameAccount' $false }
  } else { Write-Host 'Account name is already 108SU.' }
  Set-SetupStage 'EnableRemoting'
  if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Enable PowerShell remoting on Public profile')) {
    Enable-PSRemoting -SkipNetworkProfileCheck -Force
    Write-ActionResult 'EnableRemoting' $true
  } else { Write-ActionResult 'EnableRemoting' $false }
  Set-SetupStage 'RemoteTokenPolicy'
  if ($AllowFullRemoteToken) {
    Write-Warning 'Setting LocalAccountTokenFilterPolicy=1 reduces remote UAC restrictions for ALL local administrators.'
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Set LocalAccountTokenFilterPolicy=1')) {
      Set-ItemProperty -Path $reg -Name LocalAccountTokenFilterPolicy -Value 1
      Write-ActionResult 'RemoteTokenPolicy' $true
    } else { Write-ActionResult 'RemoteTokenPolicy' $false }
  }
  $currentPolicy = Get-RemoteTokenPolicy
  if ($currentPolicy.Value -eq 1) {
    Write-Warning 'Current LocalAccountTokenFilterPolicy=1: remote UAC filtering is disabled for ALL local administrators.'
  } else {
    Write-Warning ("Current LocalAccountTokenFilterPolicy={0}: remote administrative operations using 108SU may be restricted." -f $currentPolicy.Value)
  }
  if ($WhatIfPreference) {
    Write-Host 'This is the current policy; the preview has not changed it.'
  }
  Set-SetupStage 'RenameComputer'
  if ($env:COMPUTERNAME -ne $target) {
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,"Rename computer to $target")) {
      Rename-Computer -NewName $target -Force
      $restartRequired = $true
      Write-ActionResult 'RenameComputer' $true
    } else { Write-ActionResult 'RenameComputer' $false }
  } else { Write-Host "Computer name is already $target." }
  $outcome = if ($skippedActions.Count -gt 0) { 'Incomplete' } else { 'Completed' }
  $stage = 'Finished'
  if ($WhatIfPreference) {
    Write-Host "Preview finished. Target: $target. No changes or diagnostic files were written."
  } else {
    Write-SetupEvent ('Run' + $outcome)
    Write-SetupStatus
    Write-Host "Setup outcome: $outcome. Target: $target."
    if ($restartRequired) { Write-Warning 'Restart the computer to apply the new computer name.' }
    else { Write-Host 'No computer-name restart was requested by this run.' }
    if ($skippedActions.Count -gt 0) {
      Write-Warning ('Setup is incomplete. Skipped actions: ' + ($skippedActions -join ', ') + '.')
    }
  }
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
