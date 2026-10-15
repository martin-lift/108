# Standalone local recovery: the same deny-all removal as teacher menu options 4/6.
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ElevationRequested)
$ErrorActionPreference = 'Stop'

function Test-StudentWifiAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StudentRecoveryWifiFilters {
    # Same WLAN reader as Check-WifiRestrictions.ps1; independent of Windows UI language.
    if (-not ('Cabinet307.RecoveryWifiFilterReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Cabinet307 {
    public class RecoveryWifiFilter {
        public int ListType;
        public int BssType;
        public string SSIDHex;
    }
    public static class RecoveryWifiFilterReader {
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern uint WlanGetFilterList(IntPtr handle, int listType, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        public static RecoveryWifiFilter[] Read() {
            IntPtr handle;
            uint negotiated;
            uint result = WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle);
            if (result != 0) throw new Win32Exception((int)result, "Opening WLAN failed: " + new Win32Exception((int)result).Message);
            var entries = new List<RecoveryWifiFilter>();
            try {
                for (int kind = 0; kind < 4; kind++) {
                    IntPtr list = IntPtr.Zero;
                    try {
                        result = WlanGetFilterList(handle, kind, IntPtr.Zero, out list);
                        if (result != 0) throw new Win32Exception((int)result, "Reading WLAN filters failed: " + new Win32Exception((int)result).Message);
                        if (list == IntPtr.Zero) continue;
                        int count = Marshal.ReadInt32(list, 0);
                        if (count < 0 || count > 100000) throw new InvalidOperationException("Invalid WLAN filter count.");
                        // DOT11_NETWORK_LIST: 8-byte header, 40 bytes per DOT11_NETWORK.
                        for (int i = 0; i < count; i++) {
                            IntPtr network = IntPtr.Add(list, 8 + i * 40);
                            int length = Marshal.ReadInt32(network, 0);
                            if (length < 0 || length > 32) throw new InvalidOperationException("Invalid SSID length.");
                            byte[] bytes = new byte[length];
                            if (length > 0) Marshal.Copy(IntPtr.Add(network, 4), bytes, 0, length);
                            entries.Add(new RecoveryWifiFilter { ListType = kind, BssType = Marshal.ReadInt32(network, 36), SSIDHex = BitConverter.ToString(bytes) });
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
    [Cabinet307.RecoveryWifiFilterReader]::Read()
}

function Remove-StudentWifiDenyAll {
    param([ValidateSet('infrastructure','adhoc')][string]$NetworkType)
    $details = & "$env:SystemRoot\System32\netsh.exe" wlan delete filter permission=denyall "networktype=$NetworkType" 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ExitCode=$code;Details=($details | Out-String).Trim()}
}

function Restore-LocalStudentWifi {
    if (-not (Test-StudentWifiAdministrator)) { throw 'Administrator permission is required. Wi-Fi settings were not changed.' }
    if ($env:COMPUTERNAME -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "This script is only for 307-Student-01 through 307-Student-27. Current computer: $env:COMPUTERNAME."
    }
    $before = @(Get-StudentRecoveryWifiFilters)
    $denyAll = @($before | Where-Object { $_.ListType -eq 3 -and $_.SSIDHex -eq '' })
    $diagnostics = New-Object 'System.Collections.Generic.List[string]'
    foreach ($type in @('infrastructure','adhoc')) {
        $bssType = if ($type -eq 'infrastructure') {1} else {2}
        if (@($denyAll | Where-Object {$_.BssType -in $bssType,3}).Count -eq 0) { continue }
        # Attempt both types even if one fails; verify actual remaining filters afterwards.
        try {
            $result = Remove-StudentWifiDenyAll -NetworkType $type
            if ($result.ExitCode -ne 0) { $diagnostics.Add($type+': '+$result.Details) }
        } catch { $diagnostics.Add($type+': '+$_.Exception.Message) }
    }
    try { $after = @(Get-StudentRecoveryWifiFilters) }
    catch { throw ('Unable to verify Wi-Fi filters. Some restrictions may have been removed. '+$_.Exception.Message) }
    $remaining = @($after | Where-Object {$_.ListType -eq 3 -and $_.SSIDHex -eq ''})
    if ($remaining.Count -gt 0) {
        throw ('Some Wi-Fi deny-all restrictions remain. Ask an administrator to check this computer. '+($diagnostics -join ' '))
    }
    [pscustomobject]@{
        Status=$(if ($denyAll.Count -eq 0) {'AlreadyUnrestricted'} else {'Restored'})
        Computer=$env:COMPUTERNAME
        IndividualBlocks=@($after | Where-Object {$_.ListType -eq 3 -and $_.SSIDHex -ne ''}).Count
        PolicyFilters=@($after | Where-Object {$_.ListType -lt 2}).Count
    }
}

if (-not (Test-StudentWifiAdministrator)) {
    try {
        if ($ElevationRequested) { throw 'Administrator elevation was not granted.' }
        # Interactive window is needed to display the result and wait for the teacher.
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Normal -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-ElevationRequested') -Wait -PassThru -ErrorAction Stop
        exit $process.ExitCode
    } catch {
        Write-Host ('Administrator permission was not granted. Wi-Fi was not changed. '+$_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
$exitCode = 0
try {
    Write-Host 'CLASSROOM 307 - LOCAL WI-FI RECOVERY' -ForegroundColor Cyan
    $result = Restore-LocalStudentWifi
    if ($result.Status -eq 'AlreadyUnrestricted') {
        Write-Host 'The classroom Wi-Fi deny-all restrictions are already removed.' -ForegroundColor Green
    } else {
        Write-Host 'The classroom Wi-Fi deny-all restrictions have been removed.' -ForegroundColor Green
    }
    if ($result.IndividualBlocks -gt 0 -or $result.PolicyFilters -gt 0) {
        Write-Warning 'Additional individual or organization Wi-Fi filters are present. An administrator may need to review them.'
    }
    Write-Host 'Choose an available Wi-Fi network in Windows and enter its password if needed.'
    Write-Host 'DNS settings were not changed. For DNS recovery, use Restore-StudentDns.cmd.'
} catch {
    $exitCode = 1
    Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red
}
Read-Host 'Press Enter to close' | Out-Null
exit $exitCode
