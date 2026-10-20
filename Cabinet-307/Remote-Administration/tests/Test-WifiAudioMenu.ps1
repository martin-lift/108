# Windows PowerShell 5.1. Fake services, WLAN commands and remoting only.
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$menuPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($menuPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($name in @('Get-StudentNumbers','Get-ClassroomTargetNumbers','Set-ClassroomWifi','Remove-ClassroomWifiRestrictions','Test-WifiLoginError','Get-ClassroomErrorStatus','Get-ClassroomAudioCommand','Invoke-ClassroomAudioAction')) {
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Set-Item -LiteralPath ('Function:\'+$name) -Value $definition.Body.GetScriptBlock()
}
$script:Checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:Checks++}
function Read-Host {param($Prompt) if($script:Answers.Count -eq 0){throw 'Unexpected prompt'}; $script:Answers.Dequeue()}
function Reset-Answers([string[]]$Values){$script:Answers=New-Object 'System.Collections.Generic.Queue[string]';foreach($value in $Values){$script:Answers.Enqueue($value)}}
Reset-Answers @('x',' a ')
Assert ((@(Get-ClassroomTargetNumbers -Prompt 'Test') -join ',') -eq ((1..27) -join ',')) 'All selector'
Reset-Answers @('s','0','1, 3 3 27')
Assert ((@(Get-ClassroomTargetNumbers -Prompt 'Test') -join ',') -eq '1,3,27') 'Selected selector validates and deduplicates'
foreach($answers in @(@(''),@('S',''))){Reset-Answers $answers;Assert (@(Get-ClassroomTargetNumbers -Prompt 'Test').Count -eq 0) 'Cancel selector'}
$menuSwitch=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst]},$true))[-1]
Assert ((@($menuSwitch.Clauses | ForEach-Object {$_.Item1.Value}) -join ',') -eq ((1..20) -join ',')) 'All menu actions unique and ordered'
$mapping=@{3='Set-ClassroomWifi';4='Remove-ClassroomWifiRestrictions';7='Show-ClassroomProcesses';8='Stop-ClassroomProcesses';13='SetTeacher';14='Action Restore';17='ClearCache';18='Open-ClassroomWebsite';19='AudioAction -Action Stop';20='AudioAction -Action Restore'}
foreach($key in $mapping.Keys){Assert ($menuSwitch.Clauses[$key-1].Item2.Extent.Text.Contains($mapping[$key])) "Menu mapping $key"}
function Start-Service {param($Name,$ErrorAction) Assert ($Name -eq 'WinRM') 'Only WinRM starts locally'}
function New-PSSessionOption {param($OpenTimeout,$OperationTimeout) @{}}
function Get-ClassroomCredential {$script:Prompts++;if($script:CredentialCancel){return};[pscredential]::new('test',(ConvertTo-SecureString 'fake-test-only' -AsPlainText -Force))}
function New-PSSession {
    param($ComputerName,$Credential,$SessionOption,$ErrorAction)
    $script:Attempts+=$ComputerName
    if($ComputerName -eq $script:FailComputer){throw 'name cannot be resolved'}
    $script:Opened++; [pscustomobject]@{Name=$ComputerName.Replace('.local','')}
}
function Remove-PSSession {param($Session,$ErrorAction) $script:Closed++}
function Format-Table {param($Property,[switch]$AutoSize,[switch]$Wrap,[Parameter(ValueFromPipeline=$true)]$InputObject) process{$script:Rows+=$InputObject}}
function Out-Host {param([Parameter(ValueFromPipeline=$true)]$InputObject) process{}}
function netsh { $script:WlanCalls+=($args -join ' ');$global:LASTEXITCODE=0;'OK' }
function Invoke-Command {
    param($Session,$ScriptBlock,[object[]]$ArgumentList,$ErrorAction)
    $savedName=$env:COMPUTERNAME
    try {
        $env:COMPUTERNAME=$Session.Name
        if($script:LostConnection){throw [Management.Automation.Remoting.PSRemotingTransportException]::new('Connection lost')}
        if($script:MissingConfirmation){return}
        & $ScriptBlock @ArgumentList
    } finally {$env:COMPUTERNAME=$savedName}
}
function Reset-Operation {
    $script:Attempts=@();$script:Opened=0;$script:Closed=0;$script:Prompts=0;$script:Rows=@();$script:WlanCalls=@();$script:FailComputer='';$script:CredentialCancel=$false;$script:LostConnection=$false;$script:MissingConfirmation=$false
}
Reset-Operation;Reset-Answers @('S','1,3','')
Set-ClassroomWifi
Assert (($script:Attempts -join ',') -eq '307-Student-01.local,307-Student-03.local' -and $script:WlanCalls.Count -eq 6 -and $script:Prompts -eq 1 -and $script:Opened -eq $script:Closed) 'Selected Wi-Fi targets and shared password'
Assert ($script:WlanCalls[0] -match 'permission=allow ssid=Students' -and $script:WlanCalls[1] -match 'permission=denyall') 'Wi-Fi defaults and filter order'
Reset-Operation;Reset-Answers @('A','School network');$script:FailComputer='307-Student-02.local'
Set-ClassroomWifi
Assert ($script:Attempts.Count -eq 27 -and $script:WlanCalls.Count -eq 78 -and $script:Closed -eq 26 -and $script:Prompts -eq 1) 'All Wi-Fi continues past an unreachable target'
Reset-Operation;Reset-Answers @('S','2 4')
Remove-ClassroomWifiRestrictions
Assert ($script:WlanCalls.Count -eq 4 -and ($script:Attempts -join ',') -eq '307-Student-02.local,307-Student-04.local' -and $script:Closed -eq 2) ('Selected Wi-Fi removal: '+($script:Rows | ConvertTo-Json -Compress))
Reset-Operation;Reset-Answers @('A')
Remove-ClassroomWifiRestrictions
Assert ($script:WlanCalls.Count -eq 54 -and $script:Closed -eq 27) 'All Wi-Fi removal'
foreach($operation in 'Set-ClassroomWifi','Remove-ClassroomWifiRestrictions'){
    Reset-Operation;Reset-Answers @('');& $operation
    Assert ($script:Prompts -eq 0 -and $script:Attempts.Count -eq 0) 'Wi-Fi cancel does not connect'
}
Reset-Operation;Reset-Answers @('S','1','bad"ssid')
$failed=$false;try{Set-ClassroomWifi}catch{$failed=$true}
Assert ($failed -and $script:Attempts.Count -eq 0 -and $script:Prompts -eq 0) 'Invalid SSID never connects'
function New-FakeAudio([string]$State='Running') {
    $service=[pscustomobject]@{Status=$State;DependentServices=@();Stops=0;Starts=0;Disposed=$false;WaitFails=$false;StopFails=$false;StartFails=$false}
    $service|Add-Member ScriptMethod Refresh {}
    $service|Add-Member ScriptMethod WaitForStatus {param($Target,$Timeout) if($this.WaitFails){throw 'Timed out'};$this.Status=[string]$Target}
    $service|Add-Member ScriptMethod Stop {if($this.StopFails){throw 'Stop denied'};$this.Stops++;$this.Status='Stopped'}
    $service|Add-Member ScriptMethod Start {if($this.StartFails){throw 'Start denied'};$this.Starts++;$this.Status='Running'}
    $service|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $service
}
function Get-Service {param($Name,$ErrorAction) Assert ($Name -eq 'Audiosrv') 'Only Windows Audio targeted';$script:Audio}
$command=Get-ClassroomAudioCommand
$savedName=$env:COMPUTERNAME
try {
    $env:COMPUTERNAME='307-Student-01'
    foreach($action in 'Stop','Restore') {
        $script:Audio=New-FakeAudio $(if($action -eq 'Stop'){'Running'}else{'Stopped'})
        $result=& $command '307-Student-01' 'Teacher' $action
        Assert ($result.Status -eq $(if($action -eq 'Stop'){'AUDIO_STOPPED'}else{'AUDIO_RUNNING'}) -and $script:Audio.Disposed) 'Audio confirmed and service disposed'
        $null=& $command '307-Student-01' 'Teacher' $action
        Assert (($script:Audio.Stops+$script:Audio.Starts) -eq 1) 'Repeated audio operation is idempotent'
    }
    foreach($state in 'StartPending','StopPending'){
        $script:Audio=New-FakeAudio $state
        $result=& $command '307-Student-01' 'Teacher' Stop
        Assert ($result.Status -eq 'AUDIO_STOPPED') 'Pending service settles before change'
    }
    foreach($scenario in 'Mismatch','Teacher','Dependency','Timeout','StopDenied','StartDenied') {
        $script:Audio=New-FakeAudio
        $expected='307-Student-01';$teacher='Teacher';$action='Stop'
        switch($scenario){
            Mismatch {$expected='307-Student-02'}
            Teacher {$teacher='307-Student-01'}
            Dependency {$script:Audio.DependentServices=@([pscustomobject]@{Name='OtherService';Status='Running'})}
            Timeout {$script:Audio.WaitFails=$true}
            StopDenied {$script:Audio.StopFails=$true}
            StartDenied {$action='Restore';$script:Audio.Status='Stopped';$script:Audio.StartFails=$true}
        }
        $failed=$false;try{& $command $expected $teacher $action}catch{$failed=$true}
        Assert $failed "Audio failure reported: $scenario"
        if($scenario -in 'Mismatch','Teacher','Dependency'){Assert (($script:Audio.Stops+$script:Audio.Starts) -eq 0) 'Wrong host or dependent services never changed'}
    }
} finally {$env:COMPUTERNAME=$savedName}
Reset-Operation;Reset-Answers @('A');$script:Audio=New-FakeAudio;$script:FailComputer='307-Student-02.local'
Invoke-ClassroomAudioAction -Action Stop
Assert ($script:Rows.Count -eq 27 -and $script:Rows[1].Status -eq 'NAME_ERROR' -and $script:Rows[26].Status -eq 'AUDIO_STOPPED' -and $script:Closed -eq 26 -and $script:Prompts -eq 1) 'All audio continues past failure and reports each target'
Reset-Operation;Reset-Answers @('S','1,3');$script:Audio=New-FakeAudio 'Stopped'
Invoke-ClassroomAudioAction -Action Restore
Assert ($script:Rows.Count -eq 2 -and $script:Rows[0].Status -eq 'AUDIO_RUNNING' -and $script:Closed -eq 2) 'Selected audio restore'
foreach($scenario in 'LostConnection','MissingConfirmation') {
    Reset-Operation;Reset-Answers @('S','1');Set-Variable -Scope Script -Name $scenario -Value $true
    Invoke-ClassroomAudioAction -Action Stop
    Assert ($script:Rows[0].Status -eq 'UNKNOWN' -and $script:Closed -eq 1) 'Missing audio confirmation is never success'
}
Reset-Operation;Reset-Answers @('')
Invoke-ClassroomAudioAction -Action Stop
Assert ($script:Attempts.Count -eq 0 -and $script:Prompts -eq 0) 'Audio cancellation does not connect'
Reset-Operation;Reset-Answers @('A');$script:CredentialCancel=$true
Invoke-ClassroomAudioAction -Action Stop
Assert ($script:Attempts.Count -eq 0) 'Credential cancellation does not connect'
Microsoft.PowerShell.Utility\Write-Output ("PASS: {0} Wi-Fi/audio checks; no real remote or service changes." -f $script:Checks)
