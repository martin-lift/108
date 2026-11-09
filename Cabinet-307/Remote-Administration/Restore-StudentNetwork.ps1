#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'

function Get-AgentTask {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    # Include hidden tasks. An inaccessible scheduler must not look like an absent agent.
    foreach ($task in $scheduler.GetFolder('\').GetTasks(1)) {
        if ($task.Name -eq 'Classroom108-WifiReconnect') { return $task }
    }
}

function Suspend-LocalAgent {
    $task = Get-AgentTask
    if ($null -eq $task) { return 'Agent108 is not installed.' }
    if ($task.Definition.RegistrationInfo.Description -cne 'Classroom108 Wi-Fi recovery v1') {
        throw 'A scheduled task with this name exists, but its description does not match Agent108.'
    }
    $task.Enabled = $false
    if ($task.GetInstances(0).Count -gt 0) {
        try { $task.Stop(0) } catch { if ($task.GetInstances(0).Count -gt 0) { throw } }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($task.GetInstances(0).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    $verified = Get-AgentTask
    if ($null -eq $verified -or $verified.Enabled -or $verified.GetInstances(0).Count -gt 0) {
        throw 'Could not confirm that Agent108 is stopped and its task is disabled.'
    }
    'Agent108 is stopped. Its scheduled task will stay disabled after a restart.'
}

function Initialize-WifiFilterApi {
    if ('Cabinet307.UsbWifiFilters' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Cabinet307 {
    public static class UsbWifiFilters {
        // WLAN_FILTER_LIST_TYPE: group-policy deny = 1, local deny = 3.
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern uint WlanGetFilterList(IntPtr handle, int kind, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanSetFilterList(IntPtr handle, int kind, IntPtr list, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        static void Check(uint code, string operation) {
            if (code != 0) throw new Win32Exception((int)code, operation + " (Windows " + code + "): " + new Win32Exception((int)code).Message);
        }
        static int Count(IntPtr handle, int kind) {
            IntPtr list;
            Check(WlanGetFilterList(handle, kind, IntPtr.Zero, out list), kind == 3 ? "Read local Wi-Fi blocks" : "Read Wi-Fi policy");
            if (list == IntPtr.Zero) return 0;
            try { return Marshal.ReadInt32(list); }
            finally { WlanFreeMemory(list); }
        }
        public static int CheckBlocks(bool clearLocal) {
            IntPtr handle;
            uint version;
            Check(WlanOpenHandle(2, IntPtr.Zero, out version, out handle), "Open Wi-Fi service");
            try {
                if (clearLocal && Count(handle, 3) != 0) {
                    uint code = WlanSetFilterList(handle, 3, IntPtr.Zero, IntPtr.Zero);
                    // Windows also accepts an explicit DOT11_NETWORK_LIST with zero items.
                    if (code == 123 || code == 87) {
                        IntPtr empty = Marshal.AllocHGlobal(48);
                        try {
                            Marshal.Copy(new byte[48], 0, empty, 48);
                            code = WlanSetFilterList(handle, 3, empty, IntPtr.Zero);
                        } finally { Marshal.FreeHGlobal(empty); }
                    }
                    Check(code, "Clear local Wi-Fi blocks");
                }
                if (Count(handle, 3) != 0) throw new InvalidOperationException("Local Wi-Fi blocks remain.");
                return Count(handle, 1);
            } finally { WlanCloseHandle(handle, IntPtr.Zero); }
        }
    }
}
'@
}

function Get-NativeWifiBlockState([switch]$ClearLocal) {
    Initialize-WifiFilterApi
    [Cabinet307.UsbWifiFilters]::CheckBlocks([bool]$ClearLocal)
}

function Invoke-NetshWifiFilter([string[]]$Arguments) {
    $netsh = Join-Path ([Environment]::SystemDirectory) 'netsh.exe'
    $output = & $netsh wlan @Arguments 2>&1
    [pscustomobject]@{Code=$LASTEXITCODE; Text=($output | Out-String).Trim()}
}

function Clear-LocalWifiBlockList {
    try { return (Get-NativeWifiBlockState -ClearLocal) }
    catch { $nativeError = $_.Exception.GetBaseException().Message }
    # These are the same two local deny-all filters installed by Classroom108.
    $errors = @()
    foreach ($type in @('infrastructure','adhoc')) {
        try {
            $reply = Invoke-NetshWifiFilter @('delete','filter','permission=denyall',"networktype=$type")
            if ($reply.Code -ne 0) { $errors += "$type ($($reply.Code)): $($reply.Text)" }
        } catch { $errors += "${type}: $($_.Exception.Message)" }
    }
    # Missing filters can give nonzero deletion codes. Only a fresh read determines success.
    try { return (Get-NativeWifiBlockState) }
    catch { $readError = $_.Exception.GetBaseException().Message }
    $report = Invoke-NetshWifiFilter @('show','filters')
    $rows = @(($report.Text -split '\r?\n').Trim() | Where-Object { $_ -and $_ -notmatch '^-+$' })
    # Accept this text fallback only when Windows positively identifies BOTH lists as empty.
    # Other display languages are handled by the native API; unknown output is never success.
    if ($report.Code -eq 0 -and ($rows -join "`n") -match '(?im)^Block list on the system \(group policy\)\n<None>\nBlock list on the system \(user\)\n<None>\z') {
        return 0
    }
    throw ("Could not verify Wi-Fi access. First attempt: {0}. Check after retry: {1}. netsh exit code {2}: {3} {4}" -f
        $nativeError,$readError,$report.Code,$report.Text,($errors -join ' / '))
}

function Restore-WifiAccess {
    $policyBlocks = Clear-LocalWifiBlockList
    if ($policyBlocks -gt 0) {
        throw 'Local Wi-Fi blocks are clear. A school policy still blocks some networks.'
    }
    'Local Wi-Fi blocks are clear. You can select another network in Windows.'
}

function Restore-WifiDns {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
        [int]$_.NdisPhysicalMedium -in 1,9 -or [int]$_.ifType -eq 71
    })
    if (-not $adapters.Count) { throw 'No physical Wi-Fi adapter was found.' }
    $failed = @()
    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            $guid = ([guid]$adapter.InterfaceGuid).ToString('B')
            $families = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop)
            if (-not $families.Count) { throw 'No DNS settings were found for this adapter.' }
            foreach ($family in $families) {
                $service = switch ([int]$family.AddressFamily) { 2 {'Tcpip'} 23 {'Tcpip6'} default {throw 'Unrecognized IP address family.'} }
                $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$guid"
                if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
                    if ([int]$family.AddressFamily -eq 2) { throw 'Could not verify the IPv4 DNS setting.' }
                    continue
                }
                $manual = (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).NameServer
                if (-not [string]::IsNullOrWhiteSpace(($manual -join ' '))) { throw 'Windows still has a manually configured DNS server.' }
            }
            $servers = @(foreach ($family in $families) { $family.ServerAddresses | Where-Object { $_ } })
            $detail = if ($servers.Count) { $servers -join ', ' } else { 'the network has not supplied a DNS server address yet' }
            Write-Host ("{0}: automatic DNS ({1})." -f $adapter.Name,$detail)
        } catch {
            $failed += ('{0}: {1}' -f $adapter.Name,$_.Exception.Message)
        }
    }
    if ($failed.Count) { throw ($failed -join ' / ') }
    Clear-DnsClientCache -ErrorAction Stop
    'Wi-Fi is set to obtain DNS server addresses automatically.'
}

function Invoke-StudentRecovery {
    if ($env:COMPUTERNAME -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "This script is for 307-Student-01 through 307-Student-27. Current computer: $env:COMPUTERNAME."
    }
    $failed = 0
    $steps = [ordered]@{Agent108={Suspend-LocalAgent}; 'Wi-Fi'={Restore-WifiAccess}; DNS={Restore-WifiDns}}
    foreach ($step in $steps.GetEnumerator()) {
        try {
            $message = & $step.Value
            Write-Host ("[OK] {0}: {1}" -f $step.Key,$message) -ForegroundColor Green
        } catch {
            $failed++
            Write-Host ("[ERROR] {0}: {1}" -f $step.Key,$_.Exception.Message) -ForegroundColor Red
        }
    }
    return $failed
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    if ($env:COMPUTERNAME -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "Current computer: $env:COMPUTERNAME. Run this tool on a student computer in classroom 307."
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($Elevated) { throw 'Administrator privileges are required.' }
        $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Elevated') -Wait -PassThru
        exit $proc.ExitCode
    }
    Write-Host "Restoring network settings on $env:COMPUTERNAME" -ForegroundColor Cyan
    $failed = Invoke-StudentRecovery
    if ($failed -eq 0) {
        Write-Host 'DONE. Select an available Wi-Fi network and enter its password if prompted.' -ForegroundColor Green
    } else {
        Write-Host 'RECOVERY INCOMPLETE. Check the [ERROR] lines. You can run this tool again after resolving the errors.' -ForegroundColor Yellow
    }
    Read-Host 'Press Enter to close' | Out-Null
    if ($failed) { exit 1 }
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
