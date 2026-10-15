# Simulated WLAN filters and admin rights only. No network settings are changed.
#Requires -Version 5.1
$ErrorActionPreference='Stop'
$script:Checks=0
function Assert($Condition,[string]$Message) {if(-not $Condition){throw "FAILED: $Message"};$script:Checks++}
function Expect-Failure([scriptblock]$Action,[string]$Pattern) {
    $failed=$false
    try {& $Action | Out-Null} catch {$failed=$true;Assert ($_.Exception.Message -like $Pattern) ("Expected $Pattern; got "+$_.Exception.Message)}
    Assert $failed "Expected failure: $Pattern"
}
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-StudentWifi.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Recovery parses in Windows PowerShell 5.1'
$core=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Restore-LocalStudentWifi'},$true)
Set-Item Function:\Restore-LocalStudentWifi -Value $core.Body.GetScriptBlock()
$script:OriginalComputer=$env:COMPUTERNAME
function Filter([int]$ListType,[int]$BssType,[string]$Hex='') {[pscustomobject]@{ListType=$ListType;BssType=$BssType;SSIDHex=$Hex}}
function Reset-Scenario {
    $env:COMPUTERNAME='307-Student-11'
    $script:Admin=$true;$script:Reads=0;$script:ReadFailure=0;$script:FailType='';$script:ThrowType='';$script:Stale=$false;$script:Concurrent=$false
    $script:Filters=@((Filter 2 1 '53-74-75-64-65-6E-74-73'),(Filter 3 1),(Filter 3 2))
    $script:Calls=New-Object 'System.Collections.Generic.List[string]'
}
function Test-StudentWifiAdministrator {$script:Admin}
function Get-StudentRecoveryWifiFilters {
    $script:Reads++
    if($script:Reads -eq $script:ReadFailure){throw 'WLAN service unavailable'}
    $script:Filters
}
function Remove-StudentWifiDenyAll {
    param([string]$NetworkType)
    $script:Calls.Add($NetworkType)
    if($NetworkType -eq $script:ThrowType){throw 'Simulated access failure'}
    if($NetworkType -eq $script:FailType -and -not $script:Concurrent){return [pscustomobject]@{ExitCode=1;Details='Simulated deletion failure'}}
    if(-not $script:Stale){
        $kind=if($NetworkType -eq 'infrastructure'){1}else{2}
        $script:Filters=@($script:Filters | Where-Object {-not($_.ListType -eq 3 -and $_.SSIDHex -eq '' -and $_.BssType -in $kind,3)})
    }
    [pscustomobject]@{ExitCode=$(if($script:Concurrent){1}else{0});Details='Simulated result'}
}
try {
    Reset-Scenario;$script:Admin=$false
    Expect-Failure {Restore-LocalStudentWifi} '*Administrator permission*'
    Assert ($script:Reads -eq 0 -and $script:Calls.Count -eq 0) 'No WLAN access without admin rights'
    foreach($name in @('307-TEACHER','307-Student-00','307-Student-28')){
        Reset-Scenario;$env:COMPUTERNAME=$name
        Expect-Failure {Restore-LocalStudentWifi} '*only for 307-Student*'
        Assert ($script:Reads -eq 0 -and $script:Calls.Count -eq 0) 'Wrong hosts are protected'
    }
    Reset-Scenario
    $result=Restore-LocalStudentWifi
    Assert ($result.Status -eq 'Restored') 'Both deny-all filters restored'
    Assert (($script:Calls -join ',') -eq 'infrastructure,adhoc') 'Both network types are processed'
    Assert ($script:Filters.Count -eq 1 -and $script:Filters[0].ListType -eq 2) 'Students allow entry preserved'
    Assert ($script:Reads -eq 2) 'Result verified against current filters'
    $script:Calls.Clear()
    $result=Restore-LocalStudentWifi
    Assert ($result.Status -eq 'AlreadyUnrestricted' -and $script:Calls.Count -eq 0) 'Repeat use is a no-op'

    foreach($kind in @(1,2)){
        Reset-Scenario;$script:Filters=@((Filter 3 $kind))
        $result=Restore-LocalStudentWifi
        Assert ($result.Status -eq 'Restored' -and $script:Calls.Count -eq 1) 'One missing filter does not cause failure'
    }
    Reset-Scenario;$script:Filters=@((Filter 3 3))
    $result=Restore-LocalStudentWifi
    Assert ($result.Status -eq 'Restored' -and $script:Calls.Count -eq 2) 'Any-BSS deny-all covers both network types'

    Reset-Scenario;$script:Filters+=@((Filter 3 1 '41-42'),(Filter 1 1))
    $result=Restore-LocalStudentWifi
    Assert ($result.IndividualBlocks -eq 1 -and $result.PolicyFilters -eq 1) 'Additional restrictions reported and retained'
    Assert ($script:Filters.Count -eq 3) 'Only classroom deny-all filters removed'

    Reset-Scenario;$script:ReadFailure=1
    Expect-Failure {Restore-LocalStudentWifi} '*WLAN service unavailable*'
    Assert ($script:Calls.Count -eq 0) 'Initial read failure cannot change filters'
    Reset-Scenario;$script:ReadFailure=2
    Expect-Failure {Restore-LocalStudentWifi} '*Unable to verify*'
    Reset-Scenario;$script:FailType='infrastructure'
    Expect-Failure {Restore-LocalStudentWifi} '*deny-all restrictions remain*'
    Assert ($script:Calls.Count -eq 2) 'Second filter attempted after first fails'
    Reset-Scenario;$script:ThrowType='infrastructure'
    Expect-Failure {Restore-LocalStudentWifi} '*deny-all restrictions remain*'
    Assert ($script:Calls.Count -eq 2) 'Second filter attempted after exception'
    Reset-Scenario;$script:Stale=$true
    Expect-Failure {Restore-LocalStudentWifi} '*deny-all restrictions remain*'
    Reset-Scenario;$script:Concurrent=$true;$script:FailType='infrastructure'
    $result=Restore-LocalStudentWifi
    Assert ($result.Status -eq 'Restored') 'Verified absence wins when another admin already removed a filter'
    Write-Output ("PASS: {0} checks; no real WLAN changes." -f $script:Checks)
} finally {$env:COMPUTERNAME=$script:OriginalComputer}
