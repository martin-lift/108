# All registry, scheduled task and process changes are simulated.
$ErrorActionPreference='Stop'
. "$PSScriptRoot\BrowserGuard.ps1"
function Assert($value,$message){if(-not $value){throw $message}}
$script:Policy=$null; $script:Status=$null; $script:Task=$null; $script:FailStart=$false
$script:Ticks=0; $script:Sleeps=0; $script:AfterSleep='disable'; $script:Starts=0
function Get-ItemProperty {param($LiteralPath,$Name,$ErrorAction) if($script:Policy){@{BrowserPolicy=$script:Policy}}}
function Test-Path { $true }
function New-Item { throw 'Existing registry key must not be recreated' }
function Set-ItemProperty {
    param($LiteralPath,$Name,$Value)
    if($Name -eq 'BrowserPolicy'){$script:Policy=$Value}
    elseif($Name -eq 'BrowserStatus'){$script:Status=$Value}
    else{throw 'Wi-Fi policy must not be modified'}
}
function Get-ScheduledTask {param($TaskPath) if($script:Task){$script:Task}}
function New-ScheduledTaskAction {param($Execute,$Argument) @{Execute=$Execute;Arguments=$Argument}}
function New-ScheduledTaskTrigger {param([switch]$AtStartup) Assert $AtStartup 'Startup trigger required'}
function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) @{}}
function Register-ScheduledTask {
    param($TaskName,$Description,$Action,$Trigger,$Settings,$User,$RunLevel)
    Assert ($User -eq 'SYSTEM' -and $RunLevel -eq 'Highest') 'Worker identity incorrect'
    Assert ($TaskName -eq 'Agent108-BrowserGuard' -and $Action.Arguments -eq 'browsers-watch') 'Wrong task modified'
    $script:Task=[pscustomobject]@{TaskName=$TaskName;Description=$Description;Actions=@($Action);State='Ready'}
}
function Start-ScheduledTask {param($TaskName) if($script:FailStart){throw 'simulated task failure'};$script:Task.State='Running';$script:Starts++}
function Stop-ScheduledTask {param($InputObject) Assert ($InputObject.TaskName -eq 'Agent108-BrowserGuard') 'Wi-Fi task touched';$script:Task.State='Ready'}
function Unregister-ScheduledTask {param($InputObject,[switch]$Confirm) $script:Task=$null}
function Get-ClassroomBrowserStopCommand { {param($expected,$teacher) $script:Ticks++;@{Stopped=2;Remaining=0;Diagnostics=''}} }
function Start-Sleep {
    param($Milliseconds)
    Assert ($Milliseconds -gt 0 -and $Milliseconds -le 6000) 'Wrong browser interval'
    $script:Sleeps++
    $p=$script:Policy | ConvertFrom-Json
    switch($script:AfterSleep){
        disable {$p.Enabled=$false}
        expire {$p.ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o')}
        replace {$p.Token='replacement-token'}
    }
    $script:Policy=$p | ConvertTo-Json -Compress
}
Assert (-not(Test-BrowserPolicyActive (Read-BrowserPolicy))) 'Default must be disabled'
Set-BrowserGuard $true 40 6
$p=Read-BrowserPolicy
Assert (Test-BrowserPolicyActive $p) 'Enabled policy missing'
Assert ($p.Seconds -eq 6 -and $script:Task.State -eq 'Running') 'Six-second worker missing'
Assert (-not(Test-BrowserPolicyActive $p ([datetime]::Parse($p.ExpiresUtc)))) 'Expiry boundary must be exclusive'
$wrong=$script:Policy | ConvertFrom-Json;$wrong.Computer='wrong-computer'
Assert (-not(Test-BrowserPolicyActive $wrong)) 'Policy for other computer accepted'
foreach($mode in @('disable','expire','replace')){
    Set-BrowserGuard $true 40 6
    $script:Ticks=0;$script:Sleeps=0;$script:AfterSleep=$mode
    Invoke-BrowserGuard
    Assert ($script:Ticks -eq 1 -and $script:Sleeps -eq 1) "Worker continued after $mode"
    Assert (($script:Status | ConvertFrom-Json).Remaining -eq 0) 'Last check missing'
}
Set-BrowserGuard $false
Assert (-not(Test-BrowserPolicyActive (Read-BrowserPolicy)) -and -not $script:Task) 'Manual disable failed'
$starts=$script:Starts
Restore-BrowserGuard
Assert ($script:Starts -eq $starts) 'Disabled policy restarted'
foreach($values in @(@(40,5),@(0,6),@(241,6))){
    $failed=$false;try{Set-BrowserGuard $true $values[0] $values[1]}catch{$failed=$true}
    Assert $failed 'Invalid duration/interval accepted'
}
$script:FailStart=$true
$failed=$false;try{Set-BrowserGuard $true 40 6}catch{$failed=$true}
Assert ($failed -and -not(Test-BrowserPolicyActive (Read-BrowserPolicy))) 'Failed start left enabled policy'
$script:FailStart=$false
$script:Task.Description='foreign task'
$before=$script:Policy
$failed=$false;try{Set-BrowserGuard $false}catch{$failed=$true}
Assert ($failed -and $before -ceq $script:Policy) 'Foreign task was overwritten'
'PASS: six-second worker, expiry, token replacement, manual disable, task ownership and Wi-Fi isolation.'
