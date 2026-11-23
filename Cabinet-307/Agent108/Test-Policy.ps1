$ErrorActionPreference='Stop'
. "$PSScriptRoot\Main.ps1"
$script:events=@()
$script:worker='param($Profile,[switch]$CheckOnly); 1'
function Invoke-Network($action){$script:events+=$action}
function Get-ScheduledTask { @() }
function Test-Path { $true }
function New-Item { throw 'Existing registry key must not be recreated' }
function Set-ItemProperty($path,$name,$value){$script:policy=$value | ConvertFrom-Json}
function New-ScheduledTaskAction {}
function New-ScheduledTaskTrigger {}
function New-ScheduledTaskSettingsSet {}
function Register-ScheduledTask { $script:events+='register' }
function Start-ScheduledTask { $script:events+='start' }
Configure Students 0
if($policy.Seconds -ne 0 -or ($events -join ',') -ne 'NetWifiRestrict'){throw 'Zero must retain the restriction without a periodic task'}
$events=@()
Configure Students 60
if($policy.Seconds -ne 60 -or ($events -join ',') -ne 'NetWifiRestrict,register,start'){throw '60-second worker missing'}
$events=@()
Configure All 60
if(($events -join ',') -ne 'NetWifiRemove'){throw 'All networks must disable periodic checks'}
'PASS: zero, 60 seconds and all-networks policies'
