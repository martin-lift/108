#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='All')]
param(
    [Parameter(ParameterSetName='Selected',Mandatory=$true)]
    [ValidateRange(1,27)][int[]]$Numbers,
    [Parameter(ParameterSetName='All')][switch]$All,
    [ValidateNotNullOrEmpty()][string]$SchoolSSID = 'Students'
)
$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'All') { $Numbers = @(1..27) }
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
function Test-WifiLoginError {
    param([System.Management.Automation.ErrorRecord]$Record)
    # Used only for errors while opening the session, never for a remote read error.
    $exception = $Record.Exception
    while ($null -ne $exception) {
        foreach ($property in @('ErrorCode','HResult')) {
            if ($exception.PSObject.Properties[$property]) {
                $code = [int64]$exception.$property -band 4294967295L
                if ($code -in 5,1326,1909,1331,1330,1385,2147942405L,2147943726L,2147944309L,2147943731L,2147943730L,2147943785L,2148074252L) { return $true }
            }
        }
        $exception = $exception.InnerException
    }
    if ($Record.FullyQualifiedErrorId -match 'AccessDenied|LogonFailure|AuthenticationFailed|InvalidCredential') { return $true }
    $Record.Exception.Message -match 'Access is denied|user name or password is incorrect|logon failure|authentication failed|account.*(locked|disabled)|\u041e\u0442\u043a\u0430\u0437\u0430\u043d \u0434\u043e\u0441\u0442\u044a\u043f|\u0414\u043e\u0441\u0442\u044a\u043f\u044a\u0442 \u0435 \u043e\u0442\u043a\u0430\u0437\u0430\u043d|\u043d\u0435\u043f\u0440\u0430\u0432\u0438\u043b\u043d\u0430.*\u043f\u0430\u0440\u043e\u043b\u0430'
}
$readFilters = {
    param([string]$ExpectedName)
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ine $ExpectedName) { throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)." }
    # Read filter lists through the Windows WLAN API, independent of netsh UI language.
    if (-not ('Cabinet307.WifiFilterReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Cabinet307 {
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
    [Cabinet307.WifiFilterReader]::Read()
}
Start-Service WinRM -ErrorAction Stop
Write-Host 'Check keyboard layout: use English (ENG) for the password.'
$credentialInput = Get-Credential -UserName '108SU' -Message 'LOCAL admin password for classroom Wi-Fi checks'
if ($null -eq $credentialInput) { return }
$report = @()
$sessionOption = New-PSSessionOption -OpenTimeout 15000
$current = 0
foreach ($number in $Numbers) {
    $current++
    $name = '307-Student-{0:D2}' -f $number
    $destination = "$name.local"
    Write-Host ("[{0}/{1}] Checking Wi-Fi filters on {2}... " -f $current, $Numbers.Count, $destination) -NoNewline
    $session = $null
    $phase = 'Login'
    try {
        $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
        $session = New-PSSession -ComputerName $destination -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        $phase = 'Read'
        $filters = @(Invoke-Command -Session $session -ScriptBlock $readFilters -ArgumentList $name -ErrorAction Stop)
        $result = Get-WifiRestrictionStatus -Filters $filters -ExpectedSSID $SchoolSSID
        $row = [pscustomobject]@{ Computer=$name; Status=$result.Status; Reason=$result.Reason }
    } catch {
        $status = 'ERROR'
        if ($phase -eq 'Login' -and (Test-WifiLoginError -Record $_)) { $status = 'LOGIN_ERROR' }
        $row = [pscustomobject]@{ Computer=$name; Status=$status; Reason=($_.Exception.Message -replace '\s+', ' ').Trim() }
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    $color = 'Yellow'
    if ($row.Status -eq 'RESTRICTED') { $color = 'Green' }
    if ($row.Status -in 'LOGIN_ERROR','ERROR') { $color = 'Red' }
    Write-Host $row.Status -ForegroundColor $color
    $report += $row
}
$problems = @($report | Where-Object { $_.Status -ne 'RESTRICTED' })
if ($problems.Count) {
    Write-Host ''
    $problems | Format-Table Computer, Status, Reason -AutoSize -Wrap | Out-Host
}
# Structured results remain available for export when the script is called directly.
$report
