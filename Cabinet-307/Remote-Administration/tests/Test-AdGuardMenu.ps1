$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Menu parse failed'}
$definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-ClassroomAdGuard'},$true)
Set-Item Function:\Start-ClassroomAdGuard -Value $definition.Body.GetScriptBlock()
function Get-Service { param($Name,$ErrorAction) $script:Service }
function Start-Service { param($Name,$ErrorAction) $script:Starts++; if($script:StartError){throw 'Start denied'}; $script:Service.Status='Running' }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{State='Running';ProcessId=55} }
function Get-NetUDPEndpoint { param($LocalPort,$ErrorAction) if($script:Sockets){[pscustomobject]@{OwningProcess=$script:Owner;LocalAddress='192.168.31.37'}} }
function Get-NetTCPConnection { param($LocalPort,$State,$ErrorAction) Get-NetUDPEndpoint }
function Start-Sleep { param($Seconds) }
function Reset([string]$State='Running') {
    $script:Starts=0; $script:StartError=$false; $script:Sockets=$true; $script:Owner=55
    $script:Service=[pscustomobject]@{Status=$State}
    $script:Service | Add-Member ScriptMethod Refresh {}
    $script:Service | Add-Member ScriptMethod WaitForStatus {param($State,$Timeout) $this.Status=$State}
}
function ExpectFailure([string]$Pattern) {
    try {Start-ClassroomAdGuard} catch {if($_.Exception.Message -like $Pattern){return}; throw}
    throw "Expected failure: $Pattern"
}
Reset; Start-ClassroomAdGuard; Start-ClassroomAdGuard
if($script:Starts -ne 0){throw 'Running service was started twice'}
Reset Stopped; Start-ClassroomAdGuard
if($script:Starts -ne 1){throw 'Stopped service was not started exactly once'}
Reset StartPending; Start-ClassroomAdGuard
if($script:Starts -ne 0){throw 'Pending start was started again'}
Reset StopPending; Start-ClassroomAdGuard
if($script:Starts -ne 1){throw 'Pending stop was not followed by start'}
Reset; $script:Service=$null; ExpectFailure '*not installed*'
Reset Stopped; $script:StartError=$true; ExpectFailure '*Start denied*'
Reset Paused; ExpectFailure '*unexpected state*'
Reset; $script:Sockets=$false; ExpectFailure '*listeners are not ready*'
Reset; $script:Owner=99; ExpectFailure '*listeners are not ready*'
'PASS: AdGuard service menu handles 9 scenarios; no real service changes.'
