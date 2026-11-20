#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1,27)][int[]]$StudentNumbers = (1..27),
    [string]$ReportPath = (Join-Path $PSScriptRoot ('Keyboard-Results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Credential-Helper.ps1')
$profileScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-StudentKeyboardProfile.ps1') -Raw
Start-Service -Name WinRM
$credentialInput = Get-ClassroomCredential
if ($null -eq $credentialInput) { return }
$sessionOption = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 120000
$results = @()
$remoteSetup = {
    param([string]$ExpectedName, [string]$UserScript)
    $ErrorActionPreference = 'Stop'
    # Check identity before any remote write, including Program Files and scheduled tasks.
    if ($env:COMPUTERNAME -ine $ExpectedName -or $ExpectedName -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)."
    }
    foreach ($layout in @('00000409','00040402','00000402')) {
        if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$layout")) { throw "Missing keyboard layout: $layout" }
    }
    $root = Join-Path $env:ProgramFiles 'Cabinet307-Keyboards'
    New-Item -Path $root -ItemType Directory -Force | Out-Null
    # The user-executed payload must never be writable by ordinary users.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
        $identity = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    $payload = Join-Path $root 'Set-StudentKeyboardProfile.ps1'
    Set-Content -LiteralPath $payload -Value $UserScript -Encoding UTF8
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $baseArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ExpectedComputer "{1}"' -f $payload, $ExpectedName
    $action = New-ScheduledTaskAction -Execute $exe -Argument $baseArguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances Parallel
    Register-ScheduledTask -TaskName 'Cabinet307-Keyboards-AtLogon' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    # Also set and verify the WinRM account profile.
    & ([scriptblock]::Create($UserScript)) -ExpectedComputer $ExpectedName -RunId $runId
    $ownSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.SID -match '^S-1-(5-21|12-1)-' })
    $active = @()
    $pending = @()
    $errors = @()
    foreach ($profile in $profiles) {
        if ($profile.SID -eq $ownSid) { continue }
        if (-not $profile.Loaded) { $pending += $profile.SID; continue }
        $taskName = 'Cabinet307-Keyboards-Now-' + $profile.SID
        try {
            $userPrincipal = New-ScheduledTaskPrincipal -UserId $profile.SID -LogonType Interactive -RunLevel Limited
            $userAction = New-ScheduledTaskAction -Execute $exe -Argument ($baseArguments + ' -RunId ' + $runId)
            Register-ScheduledTask -TaskName $taskName -Action $userAction -Principal $userPrincipal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            $active += [pscustomobject]@{ Sid=$profile.SID; Task=$taskName }
        } catch { $errors += "$($profile.SID): $($_.Exception.Message)" }
    }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $waiting = @($active | Where-Object {
            $state = Get-ItemProperty -LiteralPath ("Registry::HKEY_USERS\{0}\Software\Cabinet307\KeyboardSetup" -f $_.Sid) -ErrorAction SilentlyContinue
            $null -eq $state -or $state.RunId -ne $runId
        })
        if ($waiting.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    $applied = @($ownSid)
    foreach ($user in $active) {
        $state = Get-ItemProperty -LiteralPath ("Registry::HKEY_USERS\{0}\Software\Cabinet307\KeyboardSetup" -f $user.Sid) -ErrorAction SilentlyContinue
        if ($null -ne $state -and $state.RunId -eq $runId -and $state.Status -eq 'OK') {
            $applied += $user.Sid
        } else {
            $errors += "$($user.Sid): not verified; applies again at next sign-in"
        }
        # Remove only our temporary tasks; retain the all-user logon task.
        if ((Get-ScheduledTask -TaskName $user.Task).State -ne 'Running') {
            Unregister-ScheduledTask -TaskName $user.Task -Confirm:$false
        }
    }
    [pscustomobject]@{
        Status = $(if ($errors.Count) { 'PARTIAL' } else { 'OK' })
        AppliedProfiles = $applied.Count
        NextSignInProfiles = $pending.Count
        Details = ($errors -join '; ')
    }
}
try {
    $numbers = @($StudentNumbers | Select-Object -Unique)
    foreach ($number in $numbers) {
        $name = '307-Student-{0:D2}' -f $number
        $session = $null
        Write-Host "Configuring $name ..."
        try {
            $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
            $session = New-PSSession -ComputerName "$name.local" -Credential $credential -SessionOption $sessionOption
            $result = Invoke-Command -Session $session -ScriptBlock $remoteSetup -ArgumentList $name, $profileScript
            $row = [pscustomobject]@{ Computer=$name; Status=$result.Status; AppliedProfiles=$result.AppliedProfiles; NextSignInProfiles=$result.NextSignInProfiles; Details=$result.Details }
        } catch {
            $row = [pscustomobject]@{ Computer=$name; Status='ERROR'; AppliedProfiles=0; NextSignInProfiles=0; Details=$_.Exception.Message }
        } finally {
            if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
        $results += $row
        $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
        Write-Host ("{0}: {1}; applied={2}; next sign-in={3}" -f $row.Computer,$row.Status,$row.AppliedProfiles,$row.NextSignInProfiles)
    }
} finally {
    $credentialInput.Password.Dispose()
    $credentialInput = $null
    $credential = $null
}
$results | Format-Table -AutoSize -Wrap | Out-Host
Write-Host "Report: $ReportPath"
Write-Host 'Inactive profiles receive the three keyboards at next sign-in. Existing apps may require sign-out/sign-in.'
if (@($results | Where-Object Status -ne 'OK').Count) { exit 1 }
