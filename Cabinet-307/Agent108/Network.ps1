function Get-ClassroomInternetCommand {
    {
        param($Expected, $Teacher, $Action, $SSID, $TeacherAddress)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $Expected -or $env:COMPUTERNAME -ieq $Teacher) { throw 'Computer identity mismatch.' }
        if ($Action -notin @('NetWifiCheck','NetWifiRestrict','NetWifiRemove','NetDnsSet','NetDnsAutomatic','NetDnsRestore','NetDnsSnapshot','NetDnsClear')) { throw 'Unsupported internet action.' }
        function Result($Status, $Reason, $Details) {
            @{computer=$env:COMPUTERNAME;action=$Action;status=$Status;reason=$Reason;diagnostics=$Details}
        }
        function Get-WifiRestrictionStatus {
    param([object[]]$Filters, [string]$ExpectedSSID)
    $expectedHex = [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($ExpectedSSID))
    $policy = @($Filters | Where-Object { $_.ListType -lt 2 })
    $allows = @($Filters | Where-Object { $_.ListType -eq 2 })
    $denies = @($Filters | Where-Object { $_.ListType -eq 3 })
    if ($policy.Count -gt 0) {
        return [pscustomobject]@{ Status='PARTIAL'; Reason='Group Policy filters are present; their effective policy requires separate verification.' }
    }
    if ($denies.Count -eq 0) {
        return [pscustomobject]@{ Status='UNRESTRICTED'; Reason='No deny filters are present. Allow entries alone do not block other networks.' }
    }
    $denyInfrastructure = @($denies | Where-Object { $_.SSIDHex -eq '' -and $_.BssType -in 1,3 }).Count -gt 0
    $denyAdhoc = @($denies | Where-Object { $_.SSIDHex -eq '' -and $_.BssType -in 2,3 }).Count -gt 0
    $schoolAllowed = @($allows | Where-Object { $_.SSIDHex -ceq $expectedHex -and $_.BssType -in 1,3 }).Count -gt 0
    $extraAllows = @($allows | Where-Object { $_.SSIDHex -cne $expectedHex -or $_.BssType -ne 1 })
    $schoolBlocked = @($denies | Where-Object { $_.SSIDHex -ceq $expectedHex -and $_.BssType -in 1,3 }).Count -gt 0
    if ($denyInfrastructure -and $denyAdhoc -and $schoolAllowed -and $extraAllows.Count -eq 0 -and -not $schoolBlocked) {
        return [pscustomobject]@{ Status='RESTRICTED'; Reason="Only '$ExpectedSSID' is allowed by the local Wi-Fi filters; infrastructure and ad hoc deny-all filters are present." }
    }
    $reasons = @()
    if (-not $denyInfrastructure) { $reasons += 'Infrastructure deny-all filter is missing.' }
    if (-not $denyAdhoc) { $reasons += 'Ad hoc deny-all filter is missing.' }
    if (-not $schoolAllowed) { $reasons += "School SSID '$ExpectedSSID' is not allowed." }
    if ($schoolBlocked) { $reasons += 'The school SSID also has a block filter.' }
    if ($extraAllows.Count) { $reasons += ('Additional allowed entries: ' + (($extraAllows | ForEach-Object { if ($_.SSIDHex -eq '') { '<all SSIDs>' } else { $_.SSID } }) -join ', ') + '.') }
    [pscustomobject]@{ Status='PARTIAL'; Reason=($reasons -join ' ') }
}

$readFilters = {
    param([string]$ExpectedName)
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ine $ExpectedName) { throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)." }
    # Read filter lists through the Windows WLAN API, independent of netsh UI language.
    if (-not ('Classroom108Internet.WifiFilterReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Classroom108Internet {
    public class WifiFilterEntry {
        public int ListType;
        public int BssType;
        public string SSID;
        public string SSIDHex;
    }
    public static class WifiFilterReader {
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern uint WlanGetFilterList(IntPtr handle, int listType, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        public static WifiFilterEntry[] Read() {
            IntPtr handle;
            uint negotiated;
            uint result = WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle);
            if (result != 0) throw new Win32Exception((int)result, "Opening WLAN for filter reading failed: " + new Win32Exception((int)result).Message);
            var entries = new List<WifiFilterEntry>();
            try {
                for (int kind = 0; kind < 4; kind++) {
                    IntPtr list = IntPtr.Zero;
                    try {
                        result = WlanGetFilterList(handle, kind, IntPtr.Zero, out list);
                        if (result != 0) throw new Win32Exception((int)result, "Reading WLAN filter list " + kind + " failed: " + new Win32Exception((int)result).Message);
                        if (list == IntPtr.Zero) continue;
                        int count = Marshal.ReadInt32(list, 0);
                        if (count < 0 || count > 100000) throw new InvalidOperationException("Invalid WLAN filter count.");
                        // DOT11_NETWORK_LIST has an 8-byte header; each DOT11_NETWORK is 40 bytes.
                        for (int i = 0; i < count; i++) {
                            IntPtr network = IntPtr.Add(list, 8 + i * 40);
                            int length = Marshal.ReadInt32(network, 0);
                            if (length < 0 || length > 32) throw new InvalidOperationException("Invalid SSID length.");
                            byte[] bytes = new byte[length];
                            if (length > 0) Marshal.Copy(IntPtr.Add(network, 4), bytes, 0, length);
                            entries.Add(new WifiFilterEntry { ListType = kind, BssType = Marshal.ReadInt32(network, 36), SSID = Encoding.UTF8.GetString(bytes), SSIDHex = BitConverter.ToString(bytes) });
                        }
                    } finally { if (list != IntPtr.Zero) WlanFreeMemory(list); }
                }
            } finally { WlanCloseHandle(handle, IntPtr.Zero); }
            return entries.ToArray();
        }
    }
}
'@
    }
    [Classroom108Internet.WifiFilterReader]::Read()
}
        function Invoke-WlanFilter([string[]]$Arguments) {
            $details = & netsh.exe @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('Wi-Fi filter command failed; changes may be partial. ' + ($details | Out-String)) }
        }
        if ($Action -like 'NetWifi*') {
            if ([string]::IsNullOrWhiteSpace($SSID) -or [Text.Encoding]::UTF8.GetByteCount($SSID) -gt 32 -or $SSID -match '["\r\n\x00]') { throw 'Invalid school SSID (maximum 32 UTF-8 bytes).' }
            $filters = @(& $readFilters $Expected)
            $hex = [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($SSID))
            if ($Action -eq 'NetWifiRestrict') {
                if (@($filters | Where-Object { $_.ListType -lt 2 }).Count) { throw 'Group Policy Wi-Fi filters exist; no local filters were changed.' }
                if (@($filters | Where-Object { $_.ListType -eq 3 -and $_.SSIDHex -ceq $hex -and $_.BssType -in 1,3 }).Count) { throw 'School SSID has a block filter; no filters were changed.' }
                if (-not @($filters | Where-Object { $_.ListType -eq 2 -and $_.SSIDHex -ceq $hex -and $_.BssType -in 1,3 }).Count) {
                    Invoke-WlanFilter @('wlan','add','filter','permission=allow',"ssid=$SSID",'networktype=infrastructure')
                }
                foreach ($type in @(1,2)) {
                    if (-not @($filters | Where-Object { $_.ListType -eq 3 -and $_.SSIDHex -eq '' -and $_.BssType -in @($type,3) }).Count) {
                        $network = if ($type -eq 1) {'infrastructure'} else {'adhoc'}
                        Invoke-WlanFilter @('wlan','add','filter','permission=denyall',"networktype=$network")
                    }
                }
            } elseif ($Action -eq 'NetWifiRemove') {
                foreach ($type in @(1,2)) {
                    if (@($filters | Where-Object { $_.ListType -eq 3 -and $_.SSIDHex -eq '' -and $_.BssType -in @($type,3) }).Count) {
                        $network = if ($type -eq 1) {'infrastructure'} else {'adhoc'}
                        Invoke-WlanFilter @('wlan','delete','filter','permission=denyall',"networktype=$network")
                    }
                }
            }
            $filters = @(& $readFilters $Expected)
            $state = Get-WifiRestrictionStatus -Filters $filters -ExpectedSSID $SSID
            $details = "School SSID: $SSID`nFilters: $($state.Status)`n$($state.Reason)`n" + ($filters | Format-Table ListType,BssType,SSID -AutoSize | Out-String)
            if ($Action -eq 'NetWifiCheck') {
                $details += (Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,IPv4Connectivity | Format-Table | Out-String)
                $details += (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object InterfaceAlias,IPAddress | Format-Table | Out-String)
                $wlan = & netsh.exe wlan show interfaces 2>&1
                $details += ($wlan | Out-String)
                if ($LASTEXITCODE -ne 0) { $details += "`nWi-Fi interface details unavailable (Windows location permission may be required); filter reading succeeded." }
                $status = if ($state.Status -eq 'RESTRICTED') {'NETWORK_OK'} else {'NETWORK_ERROR'}
                return Result $status ('WIFI_' + $state.Status) $details
            }
            if ($Action -eq 'NetWifiRemove') {
                $remaining = @($filters | Where-Object { $_.ListType -lt 2 -or $_.ListType -eq 3 })
                $status = if ($remaining.Count) {'NETWORK_ERROR'} else {'NETWORK_OK'}
                return Result $status 'WIFI_FILTERS_REMOVED' ($details + "`nOnly local deny-all filters are removed. Other filters and saved profiles are preserved.")
            }
            $status = if ($state.Status -eq 'RESTRICTED') {'NETWORK_OK'} else {'NETWORK_ERROR'}
            return Result $status ('WIFI_' + $state.Status) ($details + "`nExisting additional allow entries are preserved. USB and Ethernet are not restricted.")
        }
        if ($Action -eq 'NetDnsClear') {
            Clear-DnsClientCache -ErrorAction Stop
            return Result 'NETWORK_OK' 'DNS_CACHE_CLEARED' 'Windows DNS cache cleared. Browser data, connections and DNS server settings are unchanged.'
        }
        function ConvertTo-DnsIPv4([string]$Address) {
            $parsed = $null
            if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($Address,[ref]$parsed) -or
                $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.GetAddressBytes()[0] -in 0,127 -or
                $parsed.GetAddressBytes()[0] -ge 224 -or $Address -like '169.254.*') { throw 'Invalid teacher DNS IPv4 address.' }
            $parsed.ToString()
        }
        function Read-DnsState($Adapter) {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + ([guid]$Adapter.InterfaceGuid).ToString('B')
            $static = [string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).NameServer
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
            if ($dns.Count -ne 1) { throw 'Cannot identify Wi-Fi IPv4 DNS configuration.' }
            $servers = @($static -split '[,;\s]+' | Where-Object { $_ })
            if ($servers.Count -and ($servers -join ',') -ne (@($dns[0].ServerAddresses) -join ',')) { throw 'Configured and effective DNS differ; check network policy.' }
            [pscustomobject]@{Mode=$(if ($servers.Count) {'Static'} else {'Automatic'});Servers=$servers;Effective=@($dns[0].ServerAddresses);InputObject=$dns[0]}
        }
        function Write-DnsState($Adapter, $State, [switch]$ValidateServer) {
            $current = Read-DnsState $Adapter
            if ($State.Mode -eq 'Automatic') {
                Set-DnsClientServerAddress -InputObject $current.InputObject -ResetServerAddresses -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InputObject $current.InputObject -ServerAddresses ([string[]]$State.Servers) -Validate:$ValidateServer -ErrorAction Stop
            }
            $after = Read-DnsState $Adapter
            if ($after.Mode -ne $State.Mode -or ($State.Mode -eq 'Static' -and ($after.Servers -join ',') -ne ($State.Servers -join ','))) { throw 'Windows did not retain the requested IPv4 DNS settings.' }
            $after
        }
        function Get-DnsStorageRoot {
            Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Classroom108\DnsControl'
        }
        function Assert-DnsPlainPath([string]$Path) {
            if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "DNS settings path must not be a link: $Path"
            }
        }
        function Initialize-DnsStorage {
            $root = Get-DnsStorageRoot
            Assert-DnsPlainPath (Split-Path -Parent $root)
            Assert-DnsPlainPath $root
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
            # Only administrators and SYSTEM may change recovery settings.
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
                $identity = New-Object Security.Principal.SecurityIdentifier($sid)
                $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
            $root
        }
        function Read-SavedDns([string]$Path) {
            Assert-DnsPlainPath $Path
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Length -gt 65536) { throw 'Invalid DNS settings file size/type.' }
            $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $guid = [guid]::Empty
            if ($saved.Schema -ne 1 -or $saved.Computer -ine $Expected -or
                -not [guid]::TryParse([string]$saved.AdapterGuid,[ref]$guid) -or $guid -eq [guid]::Empty -or
                $saved.Mode -notin @('Automatic','Static') -or $saved.Active -isnot [bool]) { throw 'Saved DNS settings are invalid or belong to another computer.' }
            $servers = @($saved.Servers)
            if ($saved.Mode -eq 'Static') {
                if ($servers.Count -eq 0) { throw 'Saved static DNS list is empty.' }
                $saved.Servers = @($servers | ForEach-Object { ConvertTo-DnsIPv4 ([string]$_) })
            } elseif ($servers.Count -ne 0) { throw 'Automatic DNS record must not contain static addresses.' }
            $saved
        }
        function Save-DnsRecord([string]$Path, $Record) {
            Assert-DnsPlainPath $Path
            $temporary = Join-Path (Split-Path -Parent $Path) ([guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $json = $Record | ConvertTo-Json -Depth 5
                [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
                if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
            } finally {
                # Remove only this call's temporary file, never an existing recovery record.
                if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
            }
        }
        if ($Action -eq 'NetDnsSet') { $TeacherAddress = ConvertTo-DnsIPv4 $TeacherAddress }
        $lock = $null
        try {
            try {
                $root = Initialize-DnsStorage
                $savedPath = Join-Path $root 'PreviousDns.json'
                $lockPath = Join-Path $root 'operation.lock'
                Assert-DnsPlainPath $lockPath
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch { return Result 'NETWORK_ERROR' 'DNS_STORE_ERROR' ('Cannot lock/protect DNS recovery storage; no DNS changes made. ' + $_.Exception.Message) }
            $saved = $null
            $recordWarning = ''
            try { $saved = Read-SavedDns $savedPath }
            catch {
                if ($Action -ne 'NetDnsAutomatic') { return Result 'NETWORK_ERROR' 'DNS_SAVED_INVALID' ('Saved DNS record was not overwritten; no DNS changes made. ' + $_.Exception.Message) }
                $recordWarning = 'Saved DNS record is unreadable and was preserved. Automatic DNS does not require it.'
            }
            if ($Action -eq 'NetDnsRestore' -and $null -eq $saved) {
                return Result 'NETWORK_ERROR' 'DNS_SAVED_MISSING' 'No previous DNS settings are saved for this computer. Use automatic DNS from the network if appropriate.'
            }
            $allWifi = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { [int]$_.NdisPhysicalMedium -in 1,9 })
            $adapters = if ($Action -eq 'NetDnsRestore') {
                @($allWifi | Where-Object { ([guid]$_.InterfaceGuid) -eq ([guid]$saved.AdapterGuid) })
            } elseif ($Action -eq 'NetDnsSnapshot' -and $allWifi.Count -eq 1) { $allWifi } else { @($allWifi | Where-Object { $_.Status -eq 'Up' }) }
            if (@($adapters).Count -ne 1) { return Result 'NETWORK_ERROR' 'DNS_ADAPTER_ERROR' 'Cannot identify exactly one expected physical Wi-Fi adapter; no DNS changes made.' }
            $adapter = @($adapters)[0]
            $adapterGuid = ([guid]$adapter.InterfaceGuid).ToString('D')
            $before = Read-DnsState $adapter
            if ($Action -eq 'NetDnsSnapshot') {
                if ($null -eq $saved) {
                    $record=[pscustomobject]@{Schema=1;Computer=$Expected;AdapterGuid=$adapterGuid;AdapterName=$adapter.Name;SavedAtUtc=[datetime]::UtcNow.ToString('o');Mode=$before.Mode;Servers=@($before.Servers);Active=$false}
                    Save-DnsRecord $savedPath $record
                }
                return Result 'NETWORK_OK' 'DNS_SNAPSHOT' 'Previous settings preserved.'
            }
            $desired = if ($Action -eq 'NetDnsSet') { @{Mode='Static';Servers=@($TeacherAddress)} }
                elseif ($Action -eq 'NetDnsRestore') { $saved } else { @{Mode='Automatic';Servers=@()} }
            if ($Action -eq 'NetDnsSet') {
                if ($saved -and $saved.Active -and ([guid]$saved.AdapterGuid) -ne ([guid]$adapterGuid)) {
                    return Result 'NETWORK_ERROR' 'DNS_ADAPTER_ERROR' 'An active DNS recovery record belongs to another Wi-Fi adapter; it was preserved. Restore that adapter first.'
                }
                if ($null -eq $saved -or -not $saved.Active) {
                    if ($before.Mode -eq 'Static' -and ($before.Servers -join ',') -eq $TeacherAddress) {
                        return Result 'NETWORK_ERROR' 'DNS_ORIGINAL_UNKNOWN' 'Teacher DNS is already configured, but its previous settings are unknown. No original record was invented. Select automatic DNS first if that is the desired normal configuration.'
                    }
                    $saved = [pscustomobject][ordered]@{
                        Schema=1;Computer=$Expected;AdapterGuid=$adapterGuid;AdapterName=[string]$adapter.Name
                        SavedAtUtc=[datetime]::UtcNow.ToString('o');Mode=$before.Mode;Servers=@($before.Servers);Active=$true
                    }
                    try { Save-DnsRecord $savedPath $saved }
                    catch { return Result 'NETWORK_ERROR' 'DNS_SAVE_FAILED' ('Previous DNS settings could not be saved; no DNS changes made. ' + $_.Exception.Message) }
                }
            }
            try { $after = Write-DnsState $adapter $desired -ValidateServer:($Action -eq 'NetDnsSet') }
            catch {
                $failure = $_.Exception.Message
                try { $null = Write-DnsState $adapter $before }
                catch { return Result 'NETWORK_ERROR' 'DNS_RECOVERY_REQUIRED' "Change failed: $failure`nRollback also failed: $($_.Exception.Message). Previous DNS record preserved at $savedPath. Check this computer locally." }
                return Result 'NETWORK_ERROR' 'DNS_ROLLED_BACK' "Change failed: $failure`nCurrent settings restored from memory. Previous DNS record preserved."
            }
            $notes = "Adapter: $($adapter.Name)`nMode: $($after.Mode)`nIPv4 DNS: $($after.Effective -join ', ')`nIPv6 and browser Secure DNS are unchanged."
            $warning = -not [string]::IsNullOrWhiteSpace($recordWarning)
            if ($recordWarning) { $notes += "`n$recordWarning" }
            # Keep a single recovery record. A completed cycle is replaced only on the next Set.
            # Restore remains available after Automatic until a new cycle starts.
            if ($Action -ne 'NetDnsSet' -and $saved -and ([guid]$saved.AdapterGuid) -eq ([guid]$adapterGuid)) {
                $saved.Active = $false
                try { Save-DnsRecord $savedPath $saved }
                catch { $warning=$true; $notes += "`nDNS was applied, but the recovery record could not be marked complete: $($_.Exception.Message)" }
            }
            if ($saved) { $notes += "`nPrevious DNS: $($saved.Mode); $(@($saved.Servers) -join ', '); saved $($saved.SavedAtUtc); record: $savedPath" }
            if ($after.Mode -eq 'Automatic' -and $after.Effective.Count -eq 0) { $warning=$true; $notes += "`nAutomatic DNS is configured, but the network has not supplied IPv4 DNS servers. Check DHCP/connectivity." }
            try { Clear-DnsClientCache -ErrorAction Stop }
            catch { $warning=$true; $notes += "`nDNS was applied, but cache clearing failed: $($_.Exception.Message)" }
            $status = if ($warning) {'NETWORK_WARNING'} else {'NETWORK_OK'}
            $reason = if ($Action -eq 'NetDnsSet') {'DNS_TEACHER_SET'} elseif ($Action -eq 'NetDnsRestore') {'DNS_PREVIOUS_RESTORED'} else {'DNS_AUTOMATIC'}
            Result $status $reason $notes
        } finally { if ($null -ne $lock) { $lock.Dispose() } }
    }
}

function Assert-ClassroomTeacherDns([string]$Address) {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop | Select-Object -ExpandProperty IPAddress)
    if ($Address -notin $addresses -or $Address -match '^(127\.|169\.254\.|0\.)') { throw 'Select an IPv4 address assigned to this teacher computer.' }
    $listeners = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -in @($Address,'0.0.0.0') })
    if (-not $listeners.Count) { throw 'No DNS service listens on the selected teacher IPv4 address (UDP 53). Start AdGuard Home first. No student DNS was changed.' }
}

function Invoke-ClassroomAdGuard([string]$Action) {
    if ($Action -eq 'TeacherAdGuardFilters') {
        Start-Process -FilePath 'http://127.0.0.1:3000/#filters' -ErrorAction Stop | Out-Null
        return @{status='NETWORK_OK';reason='ADGUARD_FILTERS_OPENED';diagnostics='Opened http://127.0.0.1:3000/#filters on the teacher computer. Page loading is not verified.'}
    }
    if ($Action -ne 'TeacherAdGuardStart') { throw 'Unsupported AdGuard action.' }
    $service = Get-Service -Name AdGuardHome -ErrorAction Stop
    if ($service.Status -eq 'StartPending') { $service.WaitForStatus('Running',[timespan]::FromSeconds(15)) }
    elseif ($service.Status -eq 'Stopped') { Start-Service -Name AdGuardHome -ErrorAction Stop; $service.WaitForStatus('Running',[timespan]::FromSeconds(15)) }
    elseif ($service.Status -ne 'Running') { throw "Unexpected AdGuard Home state: $($service.Status)" }
    for ($attempt=0; $attempt -lt 10; $attempt++) {
        $owner = Get-CimInstance Win32_Service -Filter "Name='AdGuardHome'" -ErrorAction Stop
        $udp = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $owner.ProcessId })
        $tcp = @(Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $owner.ProcessId })
        if ($owner.ProcessId -gt 0 -and $udp.Count -and $tcp.Count) { return @{status='NETWORK_OK';reason='ADGUARD_READY';diagnostics=('AdGuard Home is running; UDP and TCP 53 are listening. Addresses: ' + (($udp.LocalAddress | Select-Object -Unique) -join ', '))} }
        Start-Sleep -Milliseconds 500
    }
    throw 'AdGuard Home service started, but its UDP/TCP DNS listeners are not ready.'
}
