# Mocked DNS, registry and WinRM only. Never changes a real adapter or contacts a student.
$ErrorActionPreference = 'Stop'
$script:Checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Checks++
}
function Expect-Failure([scriptblock]$Operation, [string]$Pattern) {
    $failed = $false
    try { & $Operation | Out-Null } catch {
        $failed = $true
        Assert ($_.Exception.Message -like $Pattern) ("Expected '$Pattern', received: " + $_.Exception.Message)
    }
    Assert $failed "Expected failure: $Pattern"
}
$menuPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($menuPath,[ref]$tokens,[ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) 'Menu parses'
foreach ($functionName in @('Get-ClassroomDnsCommand','Invoke-ClassroomDnsAction','Get-ClassroomErrorStatus','Test-WifiLoginError')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true)
    Assert ($null -ne $definition) "Function exists: $functionName"
    Set-Item -LiteralPath ('Function:\'+$functionName) -Value $definition.Body.GetScriptBlock()
}
$switches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.SwitchStatementAst]},$true))
$menuSwitch=$switches[-1]
$labels=@($menuSwitch.Clauses | ForEach-Object { $_.Item1.Value })
Assert (($labels -join ',') -eq ((1..20) -join ',')) 'Menu actions 1 through 20 are unique and ordered'
Assert ($menuSwitch.Clauses[12].Item2.Extent.Text -match 'SetTeacher') '13 sets teacher DNS'
Assert ($menuSwitch.Clauses[13].Item2.Extent.Text -match 'Action Restore') '14 restores DNS'

$script:TestRoot=Join-Path $env:TEMP ('cabinet307-dns-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:TestRoot
$originalProgramData=$env:ProgramData
$originalComputerName=$env:COMPUTERNAME
function Reset-Scenario([string]$Name, [string]$Static='') {
    $env:ProgramData=Join-Path $script:TestRoot $Name
    $null=New-Item -ItemType Directory -Path $env:ProgramData -Force
    $env:COMPUTERNAME='307-Student-24'
    $script:Static=$Static
    $script:Dhcp=@('192.168.28.1')
    $script:Effective=if($Static){@($Static -split ',')}else{@($script:Dhcp)}
    $script:IPv6=@('2001:db8::53')
    $script:Adapters=@([pscustomobject]@{Name='WiFi';ifIndex=4;InterfaceGuid=[guid]'01234567-1234-1234-1234-123456789abc';NdisPhysicalMedium=9;Status='Up'})
    $script:SetCalls=New-Object 'System.Collections.Generic.List[object]'
    $script:Failure=''
    $script:FlushFailure=$false
    $script:FlushCalls=0
    $script:BackupWriteFailure=$false
}
function Get-NetAdapter { param([switch]$Physical,$ErrorAction) $script:Adapters }
function Get-ItemProperty { param($LiteralPath,$ErrorAction) [pscustomobject]@{NameServer=$script:Static} }
function Get-DnsClientServerAddress {
    param($InterfaceIndex,$AddressFamily,$ErrorAction)
    [pscustomobject]@{InterfaceIndex=$InterfaceIndex;AddressFamily=$AddressFamily;ServerAddresses=$(if($AddressFamily -eq 'IPv4'){@($script:Effective)}else{@($script:IPv6)})}
}
function Set-DnsClientServerAddress {
    param($InputObject,[string[]]$ServerAddresses,[switch]$ResetServerAddresses,[switch]$Validate,$ErrorAction)
    Assert ($InputObject.AddressFamily -eq 'IPv4') 'Every write is limited to IPv4'
    $script:SetCalls.Add([pscustomobject]@{Index=$InputObject.InterfaceIndex;Servers=@($ServerAddresses);Automatic=[bool]$ResetServerAddresses;Validate=[bool]$Validate})
    if($Validate -and $script:Failure -eq 'Unreachable') { throw 'DNS server is not responding' }
    if($script:Failure -eq 'RollbackFails' -and -not $Validate) { throw 'Rollback access denied' }
    if($ResetServerAddresses) { $script:Static=''; $script:Effective=@($script:Dhcp) }
    else { $script:Static=$ServerAddresses -join ','; $script:Effective=@($ServerAddresses) }
    if($script:Failure -in 'Partial','RollbackFails' -and $Validate) {
        if($script:Failure -eq 'Partial') {$script:Failure=''}
        throw 'Simulated partially applied write'
    }
    if($script:Failure -eq 'RestoreFails' -and $ResetServerAddresses) {
        $script:Failure=''; throw 'Simulated restore error'
    }
}
function Set-Acl { param($LiteralPath,$AclObject,$ErrorAction) }
function Clear-DnsClientCache { param($ErrorAction) $script:FlushCalls++; if($script:FlushFailure){throw 'Flush failed'} }
function Set-Content {
    param($LiteralPath,$Encoding,[Parameter(ValueFromPipeline=$true)]$Value)
    process {
        if($script:BackupWriteFailure){throw 'Simulated backup disk error'}
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop
    }
}
function Invoke-Remote([string]$Action='SetTeacher',[string]$Address='192.168.31.37') {
    & (Get-ClassroomDnsCommand) $Action $Address '307-Student-24'
}
function Backup-Path { Join-Path $env:ProgramData 'Cabinet307\DnsControl\before-teacher-dns.json' }
try {
    Reset-Scenario 'dhcp'
    $result=Invoke-Remote
    Assert ($result.Status -eq 'OK' -and $script:Static -eq '192.168.31.37') 'Teacher DNS applied'
    Assert $script:SetCalls[0].Validate 'Teacher DNS responsiveness is validated on the student'
    Assert ($script:FlushCalls -eq 1 -and $result.Notes -like '*Windows DNS cache cleared*') 'Successful teacher DNS change clears and confirms the cache'
    Assert ($result.Notes -like '*IPv6*') 'Other configured DNS is reported'
    $backupBefore=[IO.File]::ReadAllText((Backup-Path))
    $result=Invoke-Remote 'ClearCache' ''
    Assert ($result.Status -eq 'OK' -and $script:FlushCalls -eq 2) 'Standalone cache clearing returns confirmation'
    Assert ($script:SetCalls.Count -eq 1 -and $script:Static -eq '192.168.31.37' -and [IO.File]::ReadAllText((Backup-Path)) -ceq $backupBefore) 'Cache-only action preserves DNS settings and the restore backup'
    $null=Invoke-Remote 'SetTeacher' '192.168.31.38'
    Assert ([IO.File]::ReadAllText((Backup-Path)) -ceq $backupBefore) 'Repeated application never overwrites original backup'
    $script:Adapters[0].Name='Renamed WiFi'; $script:Adapters[0].ifIndex=18; $script:Adapters[0].Status='Disconnected'
    $result=Invoke-Remote 'RestoreSaved'
    Assert ($result.Mode -eq 'Automatic' -and $script:Static -eq '' -and $result.DnsServers -eq '192.168.28.1') 'Original automatic mode restored'
    Assert ($script:SetCalls[-1].Index -eq 18) 'Restore uses GUID after adapter rename and reindex'
    Assert (-not (Test-Path -LiteralPath (Backup-Path))) ('Successful restore retires active backup: '+$result.Notes)
    Assert (@(Get-ChildItem (Split-Path (Backup-Path)) -Filter 'restored-*.json').Count -eq 1) 'Original snapshot is archived'
    Assert ($script:IPv6[0] -eq '2001:db8::53') 'IPv6 remains unchanged'

    Reset-Scenario 'static' '192.168.28.2,192.168.28.3'
    $null=Invoke-Remote
    $null=Invoke-Remote 'RestoreSaved'
    Assert ($script:Static -eq '192.168.28.2,192.168.28.3') 'Static DNS servers and priority restored'
    Assert (-not $script:SetCalls[-1].Validate) 'Restoration does not require old DNS to respond'

    Reset-Scenario 'manual-legacy' '192.168.31.37'
    $result=Invoke-Remote 'Automatic'
    Assert ($result.Mode -eq 'Automatic' -and $result.DnsServers -eq '192.168.28.1') 'DHCP reset works without a historical snapshot'
    Reset-Scenario 'missing'
    Expect-Failure { Invoke-Remote 'RestoreSaved' } '*No saved DNS settings*'
    Assert ($script:SetCalls.Count -eq 0) 'Missing backup never changes DNS'

    Reset-Scenario 'unreachable'
    $script:Failure='Unreachable'
    Expect-Failure { Invoke-Remote } 'DNS_CHANGE_ROLLED_BACK:*'
    Assert ($script:Static -eq '') 'Unreachable teacher DNS preserves DHCP'
    Assert (Test-Path -LiteralPath (Backup-Path)) 'Recovery snapshot remains available'

    Reset-Scenario 'cache-only';$script:Adapters=@();$script:FlushFailure=$true
    Expect-Failure {Invoke-Remote 'ClearCache' ''} '*Flush failed*'
    Assert ($script:SetCalls.Count -eq 0 -and -not(Test-Path (Backup-Path))) 'Cache failure neither modifies DNS nor creates a restore backup'
    $script:FlushFailure=$false
    $null=Invoke-Remote 'ClearCache' ''
    Assert ($script:FlushCalls -eq 2) 'Cache clearing does not depend on an active Wi-Fi adapter'
    $env:COMPUTERNAME='307-TEACHER'
    Expect-Failure {Invoke-Remote 'ClearCache' ''} '*Unexpected remote computer*'
    Assert ($script:FlushCalls -eq 2) 'Wrong target cannot clear the teacher cache'

    Reset-Scenario 'partial' '192.168.28.2'
    $script:Failure='Partial'
    Expect-Failure { Invoke-Remote } 'DNS_CHANGE_ROLLED_BACK:*'
    Assert ($script:Static -eq '192.168.28.2') 'Partial write is rolled back'
    Reset-Scenario 'double-failure'
    $script:Failure='RollbackFails'
    Expect-Failure { Invoke-Remote } 'DNS_RECOVERY_REQUIRED:*'
    Assert (Test-Path -LiteralPath (Backup-Path)) 'Failed rollback retains backup'

    Reset-Scenario 'no-dhcp' '192.168.31.37'
    $script:Dhcp=@()
    Expect-Failure { Invoke-Remote 'Automatic' } 'DNS_CHANGE_ROLLED_BACK:*no IPv4 DNS*'
    Assert ($script:Static -eq '192.168.31.37') 'Empty DHCP DNS result does not strand the client'

    Reset-Scenario 'restore-failure'
    $null=Invoke-Remote
    $script:Failure='RestoreFails'
    Expect-Failure { Invoke-Remote 'RestoreSaved' } 'DNS_CHANGE_ROLLED_BACK:*'
    Assert ($script:Static -eq '192.168.31.37' -and (Test-Path -LiteralPath (Backup-Path))) 'Failed restore keeps active DNS and snapshot'

    Reset-Scenario 'flush-failure'
    $script:FlushFailure=$true
    $result=Invoke-Remote
    Assert ($result.Status -eq 'OK' -and $result.Notes -like '*clearing*failed*') 'Cache flush failure is reported without claiming DNS failed'

    Reset-Scenario 'bad-backup'
    $null=Invoke-Remote
    $saved=Get-Content -LiteralPath (Backup-Path) -Raw | ConvertFrom-Json
    $saved.Computer='307-Student-01'
    $saved | ConvertTo-Json | Set-Content -LiteralPath (Backup-Path) -Encoding UTF8
    $count=$script:SetCalls.Count
    Expect-Failure { Invoke-Remote 'RestoreSaved' } '*invalid or belongs to another computer*'
    Assert ($script:SetCalls.Count -eq $count) 'Wrong-computer backup rejected before mutation'

    Reset-Scenario 'wrong-machine'
    $env:COMPUTERNAME='307-Teacher'
    Expect-Failure { Invoke-Remote } '*Unexpected remote computer*'
    Assert ($script:SetCalls.Count -eq 0) 'Identity checked before mutation'
    Reset-Scenario 'bad-address'
    foreach($address in @('127.0.0.1','::1','8.8.8.8;whoami','0.0.0.0','224.0.0.1','169.254.1.2','999.1.1.1')) {
        Expect-Failure { Invoke-Remote 'SetTeacher' $address } '*Invalid DNS IPv4*'
    }
    Assert ($script:SetCalls.Count -eq 0) 'Invalid server addresses never reach DNS writer'

    Reset-Scenario 'ambiguous'
    $script:Adapters+= [pscustomobject]@{Name='OtherWiFi';ifIndex=12;InterfaceGuid=[guid]::NewGuid();NdisPhysicalMedium=9;Status='Up'}
    Expect-Failure { Invoke-Remote } '*Expected one Wi-Fi*'
    Assert ($script:SetCalls.Count -eq 0) 'Multiple Wi-Fi adapters rejected'
    Reset-Scenario 'ethernet-only'
    $script:Adapters[0].NdisPhysicalMedium=14
    Expect-Failure { Invoke-Remote } '*Expected one Wi-Fi*'
    Assert ($script:SetCalls.Count -eq 0) 'Ethernet and virtual adapters are not modified'

    Reset-Scenario 'disk-error'
    $script:BackupWriteFailure=$true
    Expect-Failure { Invoke-Remote } '*backup disk error*'
    Assert ($script:SetCalls.Count -eq 0) 'Backup must be saved before any DNS write'

    Reset-Scenario 'locked'
    $null=Invoke-Remote
    $count=$script:SetCalls.Count
    $held=[IO.File]::Open((Join-Path (Split-Path (Backup-Path)) 'operation.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Expect-Failure { Invoke-Remote } '*used by another process*' } finally {$held.Dispose()}
    Assert ($script:SetCalls.Count -eq $count) 'Concurrent changes are rejected'

    # Teacher-side flow: no real WinRM, service or socket operations.
    function Reset-Menu([string[]]$Answers) {
        $script:Answers=New-Object 'System.Collections.Generic.Queue[string]'
        foreach($answer in $Answers){$script:Answers.Enqueue($answer)}
        $script:Selected=@(1,2); $script:Opened=@(); $script:Closed=@(); $script:Invoked=@(); $script:Credentials=0
        $script:SelectionCalls=0
        $script:Listening=$true; $script:MenuFailure=''; $script:Messages=@(); $script:Table=@()
    }
    function Get-StudentNumbers {$script:SelectionCalls++;$script:Selected}
    function Read-Host {param($Prompt) if($script:Answers.Count -eq 0){throw "Unexpected prompt: $Prompt"}; $script:Answers.Dequeue()}
    function Write-Host {param($Object,$ForegroundColor) $script:Messages+=[string]$Object}
    function Out-Host {param([Parameter(ValueFromPipeline=$true)]$InputObject) process{}}
    function Format-Table {param($Property,[switch]$AutoSize,[switch]$Wrap,[Parameter(ValueFromPipeline=$true)]$InputObject) process{if($InputObject.PSObject.Properties['Computer']){$script:Table+=$InputObject}}}
    function Get-NetIPAddress {param($AddressFamily,$AddressState,$ErrorAction) [pscustomobject]@{InterfaceAlias='WiFi';InterfaceIndex=4;IPAddress='192.168.31.37'}}
    function Get-NetUDPEndpoint {param($LocalPort,$ErrorAction) if($script:Listening){[pscustomobject]@{LocalAddress='0.0.0.0';LocalPort=53}}}
    function Start-Service {param($Name,$ErrorAction)}
    function Get-ClassroomCredential {
        $script:Credentials++
        if($script:MenuFailure -eq 'CancelCredentials'){return $null}
        [pscredential]::new('108SU',(ConvertTo-SecureString 'MOCK-ONLY' -AsPlainText -Force))
    }
    function New-PSSessionOption {param($OpenTimeout,$OperationTimeout) @{}}
    function New-PSSession {
        param($ComputerName,$Credential,$SessionOption,$ErrorAction)
        Assert ($Credential.UserName -eq (($ComputerName -replace '\.local$','')+'\108SU')) 'Target-specific credential'
        $script:Opened+=$ComputerName
        if($script:MenuFailure -eq 'LoginFailure' -and $ComputerName -like '*01.local'){throw 'Access is denied'}
        [pscustomobject]@{Name=$ComputerName}
    }
    function Remove-PSSession {param($Session,$ErrorAction) $script:Closed+=$Session.Name}
    function Invoke-Command {
        param($Session,$ScriptBlock,$ArgumentList,$ErrorAction)
        $script:Invoked+=,$ArgumentList
        if($script:MenuFailure -eq 'OperationFailure' -and $Session.Name -like '*01.local'){throw 'Simulated operation failure'}
        if($script:MenuFailure -eq 'Disconnect' -and $Session.Name -like '*01.local'){throw [Management.Automation.Remoting.PSRemotingTransportException]::new('connection lost')}
        if($script:MenuFailure -eq 'NoConfirmation' -and $Session.Name -like '*01.local'){return}
        [pscustomobject]@{Computer=$ArgumentList[2];Action=$ArgumentList[0];Status='OK';Adapter='WiFi';Mode='Static';DnsServers='192.168.31.37';Notes=''}
    }
    Reset-Scenario 'menu'
    Reset-Menu @('S','')
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Credentials -eq 1 -and $script:Invoked.Count -eq 2 -and $script:Closed.Count -eq 2) 'One credential prompt, two sessions cleaned up'
    Assert ($script:Invoked[0][0] -eq 'SetTeacher' -and $script:Invoked[0][1] -eq '192.168.31.37') 'Teacher address is detected and sent'
    Reset-Menu @('S',''); $script:Listening=$false
    Expect-Failure {Invoke-ClassroomDnsAction SetTeacher} '*Start AdGuard Home first*'
    Assert ($script:Opened.Count -eq 0 -and $script:Credentials -eq 0) 'Stopped DNS is detected before any student connection'
    Reset-Menu @('S','8.8.8.8')
    Expect-Failure {Invoke-ClassroomDnsAction SetTeacher} '*currently assigned to the teacher*'
    Reset-Menu @('S','B'); $script:Listening=$false
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Invoked[0][0] -eq 'RestoreSaved') 'Restore works with teacher DNS stopped'
    Reset-Menu @('S','A')
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Invoked[0][0] -eq 'Automatic') 'Automatic DNS is an explicit choice'
    foreach($scope in @('A','S')) {
        Reset-Menu @($scope);$script:Listening=$false
        Invoke-ClassroomDnsAction ClearCache
        $expectedCount=if($scope -eq 'A'){27}else{2}
        Assert ($script:Invoked.Count -eq $expectedCount -and $script:Closed.Count -eq $expectedCount -and $script:Credentials -eq 1) 'Cache clearing shares all/selected targeting and session cleanup'
        Assert ($script:Invoked[0][0] -eq 'ClearCache' -and $script:Invoked[0][1] -eq '') 'Cache clearing requires no teacher DNS address or running DNS server'
    }
    Reset-Menu @('')
    Invoke-ClassroomDnsAction ClearCache
    Assert ($script:Credentials -eq 0 -and $script:Opened.Count -eq 0) 'Cache scope cancellation does not connect'
    Reset-Menu @('S','C')
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Opened.Count -eq 0) 'Cancel address choice makes no connection'
    Reset-Menu @('S'); $script:Selected=@()
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Opened.Count -eq 0) 'Cancel computer selection makes no connection'
    Reset-Menu @('S',''); $script:MenuFailure='CancelCredentials'
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Opened.Count -eq 0) 'Cancel credentials makes no connection'
    Reset-Menu @(' a ','')
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Invoked.Count -eq 27 -and $script:Opened.Count -eq 27 -and $script:Closed.Count -eq 27) 'All targets exactly 27 students and closes all sessions'
    Assert ($script:Credentials -eq 1 -and $script:SelectionCalls -eq 0) 'All uses one credential prompt without asking for numbers'
    Assert (($script:Opened -join ',') -eq ((1..27 | ForEach-Object {'307-Student-{0:D2}.local' -f $_}) -join ',')) 'All covers student numbers 01 through 27 exactly once'
    Reset-Menu @('')
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Opened.Count -eq 0 -and $script:Credentials -eq 0 -and $script:SelectionCalls -eq 0) 'Cancel scope makes no selection or connection'
    Reset-Menu @('S');$script:Selected=@()
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Opened.Count -eq 0 -and $script:Credentials -eq 0) 'Cancel selected numbers makes no connection'
    Reset-Menu @('wrong',' s ','')
    Invoke-ClassroomDnsAction SetTeacher
    Assert ($script:Invoked.Count -eq 2 -and $script:SelectionCalls -eq 1 -and $script:Messages -contains 'Enter A for all computers, S to select computers, or press Enter to cancel.') 'Invalid scope is retried and selected mode is normalized'
    foreach($restoreMode in @('B','A')) {
        Reset-Menu @(' a ',$restoreMode);$script:Listening=$false
        Invoke-ClassroomDnsAction Restore
        $expectedAction=if($restoreMode -eq 'B'){'RestoreSaved'}else{'Automatic'}
        Assert ($script:Invoked.Count -eq 27 -and $script:Closed.Count -eq 27) "Restore all processes and closes exactly 27 sessions for $expectedAction"
        Assert ($script:Credentials -eq 1 -and $script:SelectionCalls -eq 0) 'Restore all asks once for credentials and does not ask for student numbers'
        Assert (($script:Opened -join ',') -eq ((1..27 | ForEach-Object {'307-Student-{0:D2}.local' -f $_}) -join ',')) 'Restore all covers 01 through 27 exactly once'
        Assert (@($script:Invoked | Where-Object {$_[0] -ne $expectedAction -or $_[1] -ne ''}).Count -eq 0) "Restore all sends $expectedAction without a teacher DNS address"
    }
    Reset-Menu @('')
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Opened.Count -eq 0 -and $script:Credentials -eq 0 -and $script:SelectionCalls -eq 0) 'Cancel restore scope makes no connection'
    Reset-Menu @('A','')
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Opened.Count -eq 0 -and $script:Credentials -eq 0) 'Cancel restore mode after choosing all makes no connection'
    Reset-Menu @('wrong',' s ','B')
    Invoke-ClassroomDnsAction Restore
    Assert ($script:Invoked.Count -eq 2 -and $script:SelectionCalls -eq 1 -and $script:Invoked[0][0] -eq 'RestoreSaved') 'Restore retries invalid scope and uses selected targets'
    foreach($failure in @('LoginFailure','OperationFailure','Disconnect','NoConfirmation')) {
        Reset-Menu @('S','A'); $script:MenuFailure=$failure
        Invoke-ClassroomDnsAction Restore
        Assert ($script:Opened.Count -eq 2 -and $script:Table.Count -eq 2 -and $script:Table[1].Status -eq 'OK') "Continue after $failure"
        $expectedClosed=if($failure -eq 'LoginFailure'){1}else{2}
        Assert ($script:Closed.Count -eq $expectedClosed) "Session cleanup after $failure"
        if($failure -in 'Disconnect','NoConfirmation'){Assert ($script:Table[0].Status -eq 'UNKNOWN') 'Missing confirmation does not report false success'}
    }
} finally {
    $env:ProgramData=$originalProgramData
    $env:COMPUTERNAME=$originalComputerName
}
[Console]::WriteLine("PASS: $script:Checks checks; no real DNS or WinRM changes.")

