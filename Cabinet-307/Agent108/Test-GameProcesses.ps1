$ErrorActionPreference='Stop'
. "$PSScriptRoot\GameProcesses.ps1"
function Assert($value,$message){if(-not $value){throw $message}}
$script:Processes=@()
function New-FakeProcess($name,[bool]$fail=$false){
    $p=[pscustomobject]@{ProcessName=$name;Id=12345;Handle=1;HasExited=$false;Kills=0;Fail=$fail;Disposed=$false}
    $p | Add-Member ScriptMethod Kill {if($this.Fail){throw 'simulated access denied'};$this.Kills++;$this.HasExited=$true}
    $p | Add-Member ScriptMethod WaitForExit {param($timeout) $this.HasExited}
    $p | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $p
}
function Get-Process {param($ErrorAction) $script:Processes | Where-Object {-not $_.HasExited}}
function Start-Sleep {param($Milliseconds)}
$command=Get-ClassroomGameStopCommand
$script:Processes=@(New-FakeProcess RobloxPlayerBeta;New-FakeProcess RobloxPlayer)
$r=& $command $env:COMPUTERNAME 'OTHER'
Assert ($r.Stopped -eq 2 -and $r.Remaining -eq 0 -and $r.Status -eq 'GAMES_STOPPED') 'Roblox players not stopped'
Assert (@($script:Processes | Where-Object {$_.Kills -ne 1 -or -not $_.Disposed}).Count -eq 0) 'Process lifecycle incorrect'
$script:Processes=@('RobloxStudioBeta','chrome','explorer','Windows10Universal','Teacher108' | ForEach-Object {New-FakeProcess $_})
$r=& $command $env:COMPUTERNAME 'OTHER'
Assert ($r.Stopped -eq 0 -and @($script:Processes | Where-Object Kills -ne 0).Count -eq 0) 'Unlisted process killed'
$script:Processes=@(New-FakeProcess RobloxPlayerBeta $true)
$r=& $command $env:COMPUTERNAME 'OTHER'
Assert ($r.Status -eq 'GAMES_REMAINING' -and $r.Remaining -eq 1 -and $r.Diagnostics -match 'access denied') 'Failure reported as success'
foreach($names in @(@('WRONG','OTHER'),@($env:COMPUTERNAME,$env:COMPUTERNAME),@('','OTHER'))){
    $failed=$false;try{& $command @names | Out-Null}catch{$failed=$true}
    Assert $failed 'Unsafe identity allowed'
}
$script:Processes=@(New-FakeProcess 'prefix-MYGAME-helper';New-FakeProcess 'chrome';New-FakeProcess 'Agent108';New-FakeProcess 'svchost')
$r=& $command $env:COMPUTERNAME 'OTHER' -Patterns @('mygame','Agent','svchost','','ch')
Assert ($r.Stopped -eq 1) 'Literal substring matching or protected processes failed'
$script:Processes=@(New-FakeProcess RobloxPlayerBeta)
$r=& $command $env:COMPUTERNAME 'OTHER' -Patterns @()
Assert ($r.Stopped -eq 0) 'Empty list must not match all processes'
$normalized=@(ConvertTo-GamePatterns @('',' ','ab',' RobloxPlayer ','robloxplayer','RobloxPlayerBeta'))
Assert ($normalized.Count -eq 2 -and $normalized[0] -eq 'RobloxPlayer') 'Normalization failed'
$script:Processes=@(New-FakeProcess 'RobloxPlayerBeta-helper';New-FakeProcess 'MY[GAME]';New-FakeProcess 'MYXGAME')
$r=& $command $env:COMPUTERNAME 'OTHER' -Patterns @('robloxplayer','[game]')
Assert ($r.Stopped -eq 2) 'Fragments must match case-insensitively and literally'
$script:SavedPatterns=$null
function Test-Path { $true }
function Set-ItemProperty { param($LiteralPath,$Name,$Value) $script:SavedPatterns=$Value }
function Encode($text) { -join ([Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object {$_.ToString('x2')}) }
Set-GamePatterns (Encode '["", "xy", " MyGame ", "mygame"]')
Assert ($script:SavedPatterns -eq '["MyGame"]') 'Saved fragments not normalized'
Set-GamePatterns (Encode '[]')
Assert ($script:SavedPatterns -eq '[]') 'Empty list not preserved'
foreach($bad in @('zz',(Encode '{}'),(Encode '[123]'))) {
    $failed=$false;try {Set-GamePatterns $bad}catch{$failed=$true};Assert $failed 'Malformed list accepted'
}
'PASS: configurable literal fragments, defaults, normalization, empty list, protected processes, identity and failure reporting; simulated.'


function Get-ItemProperty { @{GamePatterns='[]'} }
if (@(Read-GamePatterns).Count -ne 0) { throw 'Empty saved list not preserved' }
function Get-ItemProperty { @{GamePatterns='[" xyz ","xy",""]'} }
$values=@(Read-GamePatterns)
if($values.Count -ne 1 -or $values[0] -ne 'xyz'){throw 'Saved list normalization failed'}
function Get-ItemProperty { $null }
if (@(Read-GamePatterns).Count -ne 2) { throw 'Missing list defaults failed' }
'PASS: persisted empty list, normalization and defaults'
