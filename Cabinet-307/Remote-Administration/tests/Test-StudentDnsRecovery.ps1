# Only simulated adapters/registry/admin rights; files are written under a temporary test directory.
$ErrorActionPreference='Stop'
$script:Checks=0
function Assert($Condition,[string]$Message) {if(-not $Condition){throw "FAILED: $Message"};$script:Checks++}
function Expect-Failure([scriptblock]$Action,[string]$Pattern) {
    $failed=$false
    try {& $Action | Out-Null} catch {$failed=$true;Assert ($_.Exception.Message -like $Pattern) ("Expected $Pattern; got "+$_.Exception.Message)}
    Assert $failed "Expected failure: $Pattern"
}
$tokens=$null;$errors=$null
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-StudentDns.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Recovery script parses in Windows PowerShell'
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restore-LocalStudentDns'},$true)
Set-Item Function:\Restore-LocalStudentDns -Value $function.Body.GetScriptBlock()
$commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object {$_.GetCommandName()})
Assert (@($commands | Where-Object {$_ -in 'Invoke-Command','New-PSSession','Resolve-DnsName','Invoke-WebRequest','Invoke-RestMethod','Set-NetIPAddress'}).Count -eq 0) 'Recovery has no remoting, online lookup, download or IP address change'
Assert ($ast.Extent.Text -match '-Verb RunAs') 'Interactive entry point requests Windows elevation'
$script:Root=Join-Path $env:TEMP ('dns-recovery-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:Root
$oldComputer=$env:COMPUTERNAME
function Reset-Scenario([string]$Name) {
    $env:COMPUTERNAME='307-Student-24'
    $script:Directory=Join-Path $script:Root ($Name+'\DnsControl')
    $script:Admin=$true; $script:Static='192.168.31.37'; $script:Effective=@($script:Static); $script:Dhcp=@('192.168.28.1')
    $script:Adapters=@([pscustomobject]@{Name='WiFi';ifIndex=4;InterfaceGuid=[guid]'01234567-1234-1234-1234-123456789abc';NdisPhysicalMedium=9;Status='Up'})
    $script:Calls=New-Object 'System.Collections.Generic.List[object]'
    $script:Answers=New-Object 'System.Collections.Generic.Queue[string]'
    $script:WriteFailure='';$script:SnapshotFailure=$false;$script:FlushFailure=$false;$script:ArchiveFailure=$false;$script:AclFailure=$false
}
function Test-StudentDnsAdministrator {$script:Admin}
function Get-StudentDnsDirectory {$script:Directory}
function Get-NetAdapter {param([switch]$Physical,$ErrorAction) Assert $Physical 'Only physical adapters are requested';$script:Adapters}
function Get-ItemProperty {param($LiteralPath,$ErrorAction) [pscustomobject]@{NameServer=$script:Static}}
function Get-DnsClientServerAddress {
    param($InterfaceIndex,$AddressFamily,$ErrorAction)
    Assert ($AddressFamily -eq 'IPv4') 'Only IPv4 configuration is requested'
    [pscustomobject]@{InterfaceIndex=$InterfaceIndex;AddressFamily=$AddressFamily;ServerAddresses=@($script:Effective)}
}
function Set-DnsClientServerAddress {
    param($InputObject,[string[]]$ServerAddresses,[switch]$ResetServerAddresses,[switch]$Validate,$ErrorAction)
    Assert ($InputObject.AddressFamily -eq 'IPv4') 'Every mutation is scoped to IPv4'
    Assert (-not $Validate) 'Recovery never requires a DNS server to be reachable'
    $script:Calls.Add([pscustomobject]@{Index=$InputObject.InterfaceIndex;Automatic=[bool]$ResetServerAddresses;Servers=@($ServerAddresses)})
    if($ResetServerAddresses){$script:Static='';$script:Effective=@($script:Dhcp)}else{$script:Static=$ServerAddresses -join ',';$script:Effective=@($ServerAddresses)}
    if($script:WriteFailure -eq 'Once'){$script:WriteFailure='';throw 'Simulated partial write'}
    if($script:WriteFailure -eq 'Always'){throw 'Simulated access denied'}
}
function Set-Acl {
    param($LiteralPath,$AclObject,$ErrorAction)
    if($script:AclFailure){throw 'Cannot protect recovery directory'}
    Assert $AclObject.AreAccessRulesProtected 'Recovery folder does not inherit student write permissions'
    $rules=@($AclObject.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Assert (($rules.IdentityReference.Value | Sort-Object) -join ',' -eq 'S-1-5-18,S-1-5-32-544') 'Recovery data restricted to SYSTEM and administrators'
}
function Set-Content {
    param($LiteralPath,$Encoding,[Parameter(ValueFromPipeline=$true)]$Value)
    process {if($script:SnapshotFailure){throw 'Recovery snapshot write failed'}; Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop}
}
function Move-Item {param($LiteralPath,$Destination,$ErrorAction) if($script:ArchiveFailure){throw 'Archive failed'};Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop}
function Clear-DnsClientCache {param($ErrorAction) if($script:FlushFailure){throw 'Cache flush failed'}}
function Read-Host {param($Prompt) if($script:Answers.Count -eq 0){throw 'Unexpected prompt'};$script:Answers.Dequeue()}
function Write-Host {param($Object,$ForegroundColor)}
function Backup-Path {Join-Path $script:Directory 'before-teacher-dns.json'}
function Save-Backup([string]$Mode='Automatic',[string[]]$Servers=@()) {
    $null=New-Item -ItemType Directory -Path $script:Directory -Force
    [ordered]@{Schema=1;Computer='307-Student-24';AdapterGuid='01234567-1234-1234-1234-123456789abc';AdapterName='WiFi';Mode=$Mode;Servers=$Servers;SavedAtUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Backup-Path) -Encoding UTF8
}
try {
    Reset-Scenario 'admin-denied';$script:Admin=$false
    Expect-Failure {Restore-LocalStudentDns} '*Administrator permission*'
    Assert (-not(Test-Path $script:Directory) -and $script:Calls.Count -eq 0) 'No file or DNS mutation without admin rights'
    Reset-Scenario 'teacher';$env:COMPUTERNAME='307-TEACHER'
    Expect-Failure {Restore-LocalStudentDns} '*only for 307-Student*'
    Assert (-not(Test-Path $script:Directory) -and $script:Calls.Count -eq 0) 'Teacher computer is protected'

    Reset-Scenario 'automatic';Save-Backup
    $script:Adapters[0].Name='Renamed';$script:Adapters[0].ifIndex=18
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'Restored' -and $script:Static -eq '' -and $r.DnsServers -eq '192.168.28.1') 'Saved automatic mode restored'
    Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].Index -eq 18) 'Adapter selected by saved GUID after rename and reindex'
    Assert (-not(Test-Path (Backup-Path))) 'Successful restoration retires the teacher snapshot'
    Assert (@(Get-ChildItem -LiteralPath $script:Directory -Filter 'restored-local-*.json').Count -eq 1) 'Teacher snapshot archived'
    Assert ((Get-Content -LiteralPath $r.RecoverySnapshot -Raw | ConvertFrom-Json).Servers[0] -eq '192.168.31.37') 'State before the attempt is saved'

    Reset-Scenario 'offline';Save-Backup;$script:Adapters[0].Status='Disconnected';$script:Dhcp=@()
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'WaitingForNetwork' -and $script:Static -eq '' -and $script:Calls.Count -eq 1) 'Offline automatic DNS is retained without rollback to the unavailable teacher'
    Assert (-not(Test-Path (Backup-Path))) 'Offline restoration still retires the active snapshot'
    Reset-Scenario 'no-dhcp-yet';Save-Backup;$script:Dhcp=@()
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'WaitingForNetwork' -and $script:Static -eq '') 'Connected adapter without DHCP DNS keeps automatic mode'
    Reset-Scenario 'static';Save-Backup 'Static' @('192.168.28.2','192.168.28.3');$script:Adapters[0].Status='Disconnected'
    $r=Restore-LocalStudentDns
    Assert ($script:Static -eq '192.168.28.2,192.168.28.3' -and $r.Status -eq 'WaitingForNetwork') 'Saved static server order restored offline'

    Reset-Scenario 'missing-cancel';$script:Answers.Enqueue('')
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'Cancelled' -and $script:Calls.Count -eq 0) 'No backup does not silently switch DNS'
    Reset-Scenario 'missing-auto';$script:Answers.Enqueue('A');$script:Adapters[0].Status='Disabled';$script:Dhcp=@()
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'WaitingForNetwork' -and $script:Static -eq '') 'Explicit automatic fallback works with disabled Wi-Fi'
    Reset-Scenario 'ambiguous';$script:Adapters+= [pscustomobject]@{Name='Other';ifIndex=9;InterfaceGuid=[guid]::NewGuid();NdisPhysicalMedium=9;Status='Up'}
    Expect-Failure {Restore-LocalStudentDns} '*one physical Wi-Fi*'
    Assert ($script:Calls.Count -eq 0) 'Ambiguous adapters are never guessed'
    Reset-Scenario 'ethernet';Save-Backup;$script:Adapters[0].NdisPhysicalMedium=14
    Expect-Failure {Restore-LocalStudentDns} '*one physical Wi-Fi*'
    Assert ($script:Calls.Count -eq 0) 'Ethernet is never modified'
    Reset-Scenario 'adapter-replaced';Save-Backup;$script:Adapters[0].InterfaceGuid=[guid]::NewGuid()
    Expect-Failure {Restore-LocalStudentDns} '*one physical Wi-Fi*'
    Assert ($script:Calls.Count -eq 0) 'Backup for another adapter is not applied'

    foreach($scenario in @('foreign','corrupt','invalid-address')) {
        Reset-Scenario $scenario;Save-Backup
        $saved=Get-Content -LiteralPath (Backup-Path) -Raw | ConvertFrom-Json
        if($scenario -eq 'foreign'){$saved.Computer='307-Student-01'}
        if($scenario -eq 'invalid-address'){$saved.Mode='Static';$saved.Servers=@('127.0.0.1')}
        $saved | ConvertTo-Json | Set-Content -LiteralPath (Backup-Path) -Encoding UTF8
        if($scenario -eq 'corrupt'){'{' | Set-Content -LiteralPath (Backup-Path) -Encoding UTF8}
        Expect-Failure {Restore-LocalStudentDns} '*'
        Assert ($script:Calls.Count -eq 0 -and (Test-Path (Backup-Path))) 'Invalid snapshots are preserved and never applied'
    }
    Reset-Scenario 'snapshot-fails';Save-Backup;$script:SnapshotFailure=$true
    Expect-Failure {Restore-LocalStudentDns} '*snapshot write failed*'
    Assert ($script:Calls.Count -eq 0) 'Recovery snapshot is required before a DNS write'
    Reset-Scenario 'acl-fails';Save-Backup;$script:AclFailure=$true
    Expect-Failure {Restore-LocalStudentDns} '*protect recovery directory*'
    Assert ($script:Calls.Count -eq 0) 'Insecure recovery data prevents mutation'
    Reset-Scenario 'write-fails';Save-Backup;$script:WriteFailure='Once'
    Expect-Failure {Restore-LocalStudentDns} 'DNS_CHANGE_ROLLED_BACK:*'
    Assert ($script:Static -eq '192.168.31.37' -and $script:Calls.Count -eq 2 -and (Test-Path (Backup-Path))) 'Partial failure rolls back and retains the original backup'
    Reset-Scenario 'rollback-fails';Save-Backup;$script:WriteFailure='Always'
    Expect-Failure {Restore-LocalStudentDns} 'DNS_RECOVERY_REQUIRED:*'
    Assert (Test-Path (Backup-Path)) 'Failed rollback retains the teacher backup'
    Reset-Scenario 'locked';Save-Backup
    $held=[IO.File]::Open((Join-Path $script:Directory 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {Expect-Failure {Restore-LocalStudentDns} '*Another DNS operation*'} finally {$held.Dispose()}
    Assert ($script:Calls.Count -eq 0) 'Local restore cannot race the teacher DNS menu'
    Reset-Scenario 'warnings';Save-Backup;$script:ArchiveFailure=$true;$script:FlushFailure=$true
    $r=Restore-LocalStudentDns
    Assert ($r.Status -eq 'Restored' -and $r.Notes -like '*archived*' -and $r.Notes -like '*cache*') 'Post-change archive and cache problems are reported accurately'
    Assert (Test-Path (Backup-Path)) 'Failed archive does not delete the backup'
    "PASS: $script:Checks checks; no real DNS, adapters, services or admin rights changed."
} finally {$env:COMPUTERNAME=$oldComputer}
