# Simulations only. No Windows tasks, adapters, DNS or WLAN settings are accessed.
#Requires -Version 5.1
param([string]$ScriptPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-StudentNetwork.ps1'))
$ErrorActionPreference='Stop'
$astTokens=$null; $astErrors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$astTokens,[ref]$astErrors)
if($astErrors.Count){throw ($astErrors.Message -join ' / ')}
. $ScriptPath
Initialize-WifiFilterApi   # compile the native declarations, without opening WLAN
$script:checks=0
function Check($condition,$message){if(-not $condition){throw $message}; $script:checks++}
function ExpectFailure($action,$match){
    try { & $action | Out-Null } catch { Check ($_.Exception.Message -like $match) $_.Exception.Message; return }
    throw "Expected failure: $match"
}
# Simulate Windows rejecting a native operation when elevated under another account.
& {
    $calls=[Collections.Generic.List[string]]::new()
    $script:nativeReadFails=$false
    $script:showCode=0
    $script:showText="Block list on the system (group policy)`n----------`n    <None>`nBlock list on the system (user)`n----------`n    <None>"
    function Get-NativeWifiBlockState([switch]$ClearLocal) {
        if($ClearLocal -or $script:nativeReadFails){throw 'The filename, directory name, or volume label syntax is incorrect.'}
        return 0
    }
    function Invoke-NetshWifiFilter([string[]]$Arguments) {
        $calls.Add($Arguments -join ' ')
        if($Arguments[0] -eq 'show'){return [pscustomobject]@{Code=$script:showCode; Text=$script:showText}}
        return [pscustomobject]@{Code=1; Text='Filter already absent or deletion failed.'}
    }
    Check ((Clear-LocalWifiBlockList) -eq 0) 'Verified native read after fallback should succeed'
    Check (($calls -join ';') -eq 'delete filter permission=denyall networktype=infrastructure;delete filter permission=denyall networktype=adhoc') 'Only the two classroom filters should be targeted'
    $script:nativeReadFails=$true
    Check ((Clear-LocalWifiBlockList) -eq 0) 'Independent positive verification should succeed'
    $script:showCode=1
    ExpectFailure {Clear-LocalWifiBlockList} '*Wi-Fi*'
    $script:showCode=0
    $script:showText=$script:showText.Replace('<None>','SSID: "", Type: Infrastructure')
    ExpectFailure {Clear-LocalWifiBlockList} '*Wi-Fi*'
    $script:showText='unexpected output'
    ExpectFailure {Clear-LocalWifiBlockList} '*Wi-Fi*'
}
# Replace system entry points before exercising the actual orchestration.
function Get-AgentTask { $script:agent }
function New-TestAgent($marker){
    $agent=[pscustomobject]@{Enabled=$true;Running=1;Definition=@{RegistrationInfo=@{Description=$marker}}}
    $agent|Add-Member ScriptMethod GetInstances { param($flags) return @{Count=$this.Running} }
    $agent|Add-Member ScriptMethod Stop { param($flags) if($this.Enabled){throw 'Stopped before disabled'}; $this.Running=0 }
    $agent
}
$script:agent=New-TestAgent 'Classroom108 Wi-Fi recovery v1'
$null=Suspend-LocalAgent
Check (!$agent.Enabled -and $agent.Running -eq 0) 'Running agent not suspended'
$null=Suspend-LocalAgent
$script:agent=$null
Check ((Suspend-LocalAgent) -like '*Agent108*') 'Missing agent should be an explicit success'
$script:agent=New-TestAgent 'someone else'
ExpectFailure {Suspend-LocalAgent} '*Agent108*'
Check ($agent.Enabled -and $agent.Running -eq 1) 'Foreign task was changed'
function New-TestNic($name,$index,$medium,$type){
    [pscustomobject]@{Name=$name;ifIndex=$index;NdisPhysicalMedium=$medium;ifType=$type;InterfaceGuid=[guid]::NewGuid();Status='Disconnected'}
}
$script:wifi=New-TestNic 'wireless' 7 9 71
$script:ethernet=New-TestNic 'ethernet' 5 14 6
function Get-NetAdapter {param([switch]$Physical) if(!$Physical){throw 'Expected physical only'}; $script:ethernet; $script:wifi}
function Set-DnsClientServerAddress {param($InterfaceIndex,[switch]$ResetServerAddresses)
    if($InterfaceIndex -ne 7 -or !$ResetServerAddresses){throw 'Wrong interface or action'}; $script:resets++}
function Get-DnsClientServerAddress {param($InterfaceIndex)
    if($InterfaceIndex -ne 7){throw 'Wrong interface'}; foreach($af in 2,23){[pscustomobject]@{AddressFamily=$af;ServerAddresses=@()}}}
function Test-Path {param($LiteralPath) if($LiteralPath -notmatch '^HKLM:'){throw 'Unexpected path'}; $true}
function Get-ItemProperty {param($LiteralPath) [pscustomobject]@{NameServer=$script:static}}
function Clear-DnsClientCache {$script:flush++}
$script:static='';$script:resets=0;$script:flush=0
$null=Restore-WifiDns
Check ($resets -eq 1 -and $flush -eq 1) 'Disconnected Wi-Fi was not reset'
$script:static='192.168.31.37'
ExpectFailure {Restore-WifiDns} '*DNS*'
Check ($flush -eq 1) 'Should report manual address left behind'
$script:static='';$script:filterCalls=0;$script:policyCount=0
function Clear-LocalWifiBlockList {$script:filterCalls++; $script:policyCount}
Check ((Restore-WifiAccess) -like '*Wi-Fi*') 'No remaining blocks should succeed'
$script:policyCount=1
ExpectFailure {Restore-WifiAccess} '*политика*'
$script:filterCalls=0
$savedName=$env:COMPUTERNAME
try {
    $env:COMPUTERNAME='307-TEACHER'
    ExpectFailure {Invoke-StudentRecovery} '*307-Student-01*'
    Check ($filterCalls -eq 0 -and $resets -eq 2) 'Teacher guard changed settings'
    $env:COMPUTERNAME='307-Student-04'
    $script:agent=New-TestAgent 'Classroom108 Wi-Fi recovery v1'
    $result=Invoke-StudentRecovery
    Check ($result -eq 1 -and !$agent.Enabled -and $resets -eq 3 -and $filterCalls -eq 1) 'Partial result must leave DNS and agent independently verified'
} finally { $env:COMPUTERNAME=$savedName }
Write-Output "PASS: $checks simulated assertions, Windows PowerShell $($PSVersionTable.PSVersion)."
