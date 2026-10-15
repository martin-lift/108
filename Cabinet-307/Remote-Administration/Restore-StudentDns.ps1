# Standalone, local emergency recovery. No teacher connection or Internet required.
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ElevationRequested)
$ErrorActionPreference = 'Stop'

function Test-StudentDnsAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StudentDnsDirectory {
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Cabinet307\DnsControl'
}

function Restore-LocalStudentDns {
    if (-not (Test-StudentDnsAdministrator)) { throw 'Administrator permission is required. No DNS settings changed.' }
    $computer = $env:COMPUTERNAME
    if ($computer -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "This script is only for 307-Student-01 through 307-Student-27. Current computer: $computer."
    }
    function ConvertTo-RecoveryIPv4([string]$Address) {
        $parsed=$null
        if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
            -not [Net.IPAddress]::TryParse($Address,[ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $parsed.GetAddressBytes()[0] -in 0,127 -or $parsed.GetAddressBytes()[0] -ge 224 -or
            $Address -like '169.254.*') { throw "Invalid saved DNS IPv4 address: $Address" }
        $parsed.ToString()
    }
    function Assert-RecoveryPath([string]$Path) {
        if ((Test-Path -LiteralPath $Path) -and
            ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "DNS recovery files must not be links: $Path"
        }
    }
    function Read-RecoveryState($Adapter) {
        $key='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'+([guid]$Adapter.InterfaceGuid).ToString('B')
        $raw=[string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).NameServer
        $dns=@(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
        if ($dns.Count -ne 1) { throw 'Cannot identify this adapter IPv4 DNS configuration.' }
        $servers=@(); $mode='Automatic'
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $mode='Static'
            $servers=@($raw -split '[,;\s]+' | Where-Object {$_} | ForEach-Object {ConvertTo-RecoveryIPv4 $_})
        }
        [pscustomobject]@{Mode=$mode;Servers=$servers;EffectiveServers=@($dns[0].ServerAddresses)}
    }
    function Write-RecoveryState($Adapter,$State) {
        $dns=@(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
        if ($dns.Count -ne 1) { throw 'Cannot identify this adapter IPv4 DNS configuration.' }
        # InputObject limits the write to IPv4. Never validate a server over the network.
        if ($State.Mode -eq 'Automatic') {
            Set-DnsClientServerAddress -InputObject $dns[0] -ResetServerAddresses -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InputObject $dns[0] -ServerAddresses ([string[]]$State.Servers) -Validate:$false -ErrorAction Stop
        }
        $after=Read-RecoveryState $Adapter
        if ($after.Mode -ne $State.Mode -or ($State.Mode -eq 'Static' -and
            (@($after.Servers) -join ',') -ne (@($State.Servers) -join ','))) {
            throw 'Windows did not retain the requested DNS settings.'
        }
        if ($State.Mode -eq 'Static' -and $Adapter.Status -eq 'Up' -and $after.EffectiveServers.Count -gt 0 -and
            (@($after.EffectiveServers) -join ',') -ne (@($State.Servers) -join ',')) {
            throw 'Effective DNS differs from the requested settings. Check Windows network policy.'
        }
        $after
    }
    $directory=Get-StudentDnsDirectory
    Assert-RecoveryPath (Split-Path $directory -Parent)
    Assert-RecoveryPath $directory
    $null=New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
    $lockPath=Join-Path $directory 'operation.lock'
    $backupPath=Join-Path $directory 'before-teacher-dns.json'
    Assert-RecoveryPath $lockPath
    Assert-RecoveryPath $backupPath
    $lock=$null
    try {
        # Shared with teacher menu options 15/16: concurrent operations cannot overlap.
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Another DNS operation is running, or the recovery folder is inaccessible. Try again after it finishes.' }
        $saved=$null
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            if ((Get-Item -LiteralPath $backupPath).Length -gt 65536) { throw 'The saved DNS backup is too large; no DNS settings changed.' }
            try { $saved=Get-Content -LiteralPath $backupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { throw 'The saved DNS backup is damaged; no DNS settings changed. Ask an administrator to inspect it.' }
            $savedGuid=[guid]::Empty
            if ($saved.Schema -ne 1 -or $saved.Computer -ine $computer -or
                -not [guid]::TryParse([string]$saved.AdapterGuid,[ref]$savedGuid) -or $savedGuid -eq [guid]::Empty -or
                $saved.Mode -notin 'Automatic','Static') { throw 'The saved DNS backup is invalid or belongs to another computer.' }
            if ($saved.Mode -eq 'Static') {
                if (@($saved.Servers).Count -eq 0) { throw 'The saved static DNS list is empty.' }
                $saved.Servers=@($saved.Servers | ForEach-Object {ConvertTo-RecoveryIPv4 ([string]$_)})
            }
        }
        $wifi=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {[int]$_.NdisPhysicalMedium -in 1,9})
        $selected=if ($null -ne $saved) {
            @($wifi | Where-Object {([guid]$_.InterfaceGuid) -eq $savedGuid})
        } else { @($wifi) }
        if (@($selected).Count -ne 1) { throw 'Cannot identify one physical Wi-Fi adapter to restore. No DNS settings changed.' }
        $adapter=@($selected)[0]
        if ($null -eq $saved) {
            Write-Host 'No saved DNS settings were found. Automatic DNS uses the servers supplied by the network.'
            if ((Read-Host 'Type A for automatic DNS, or press Enter to cancel').Trim().ToUpperInvariant() -ne 'A') {
                return [pscustomobject]@{Status='Cancelled';Computer=$computer}
            }
            $desired=[pscustomobject]@{Mode='Automatic';Servers=@()}
        } else { $desired=$saved }
        $before=Read-RecoveryState $adapter
        $recoveryPath=Join-Path $directory ('emergency-before-'+[guid]::NewGuid().ToString('N')+'.json')
        [ordered]@{
            Schema=1;Computer=$computer;AdapterGuid=([guid]$adapter.InterfaceGuid).ToString('D');AdapterName=[string]$adapter.Name
            SavedAtUtc=[datetime]::UtcNow.ToString('o');Mode=$before.Mode;Servers=@($before.Servers)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recoveryPath -Encoding UTF8 -ErrorAction Stop
        try { $after=Write-RecoveryState $adapter $desired }
        catch {
            $reason=$_.Exception.Message
            try { $null=Write-RecoveryState $adapter $before }
            catch { throw "DNS_RECOVERY_REQUIRED: $reason Rollback also failed: $($_.Exception.Message). Recovery snapshot: $recoveryPath" }
            throw "DNS_CHANGE_ROLLED_BACK: $reason The settings from before this attempt were restored."
        }
        $notes=New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $saved) {
            $archive=Join-Path $directory ('restored-local-'+[guid]::NewGuid().ToString('N')+'.json')
            try { Move-Item -LiteralPath $backupPath -Destination $archive -ErrorAction Stop }
            catch { $notes.Add('Settings restored, but the original backup could not be archived: '+$_.Exception.Message) }
        }
        try { Clear-DnsClientCache -ErrorAction Stop }
        catch { $notes.Add('Settings restored, but the DNS cache could not be cleared.') }
        # A disconnected PC may have no DHCP DNS yet. Keep automatic DNS for the next connection.
        $status=if ($adapter.Status -ne 'Up' -or $after.EffectiveServers.Count -eq 0) {'WaitingForNetwork'} else {'Restored'}
        [pscustomobject]@{
            Status=$status;Computer=$computer;Adapter=[string]$adapter.Name;Mode=$after.Mode
            DnsServers=(@($after.EffectiveServers) -join ', ');Notes=($notes -join ' ');RecoverySnapshot=$recoveryPath
        }
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

# Entry point. Elevation is mandatory even when the script is launched directly.
if ($env:COMPUTERNAME -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
    Write-Host 'Run this recovery on the affected student computer, not on the teacher computer.' -ForegroundColor Red
    exit 1
}
if (-not (Test-StudentDnsAdministrator)) {
    try {
        if ($ElevationRequested) { throw 'Administrator elevation was not granted.' }
        $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-ElevationRequested') -Wait -PassThru -ErrorAction Stop
        exit $process.ExitCode
    } catch {
        Write-Host ('Administrator permission was not granted. DNS was not changed. '+$_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
$exitCode=0
try {
    Write-Host 'CLASSROOM 307 - LOCAL DNS RECOVERY' -ForegroundColor Cyan
    $result=Restore-LocalStudentDns
    if ($result.Status -eq 'Cancelled') { Write-Host 'Cancelled. DNS settings were not changed.' }
    else {
        Write-Host ('DNS settings restored on '+$result.Adapter+'. Mode: '+$result.Mode) -ForegroundColor Green
        if ($result.DnsServers) { Write-Host ('DNS servers: '+$result.DnsServers) }
        if ($result.Status -eq 'WaitingForNetwork') {
            if ($result.Mode -eq 'Automatic') {
                Write-Host 'Settings are saved. Connect Wi-Fi; automatic DNS will be obtained when the network supplies it.' -ForegroundColor Yellow
            } else {
                Write-Host 'Saved DNS addresses are restored. Connect Wi-Fi to use them.' -ForegroundColor Yellow
            }
        }
        if ($result.Notes) { Write-Warning $result.Notes }
        Write-Host 'This restores Wi-Fi IPv4 DNS settings. Internet connectivity has not been tested.'
    }
} catch {
    $exitCode=1
    Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red
}
Read-Host 'Press Enter to close' | Out-Null
exit $exitCode
