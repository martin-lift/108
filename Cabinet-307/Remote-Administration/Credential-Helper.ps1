#Requires -Version 5.1
# Local credential preflight. Does not open a desktop or contact student computers.
function Invoke-TeacherCredentialValidation {
    param([Parameter(Mandatory=$true)][Security.SecureString]$Password)
    if (-not ('Cabinet307.TeacherPasswordValidator' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;
namespace Cabinet307 {
    public static class TeacherPasswordValidator {
        [DllImport("advapi32.dll", EntryPoint="LogonUserW", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int provider, out IntPtr token);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        public static int Validate(SecureString password) {
            IntPtr clearPassword = IntPtr.Zero;
            IntPtr token = IntPtr.Zero;
            try {
                clearPassword = Marshal.SecureStringToGlobalAllocUnicode(password);
                // NETWORK validates immediately, without caching credentials or creating a desktop.
                bool success = LogonUser("108SU", ".", clearPassword, 3, 0, out token);
                int error = success ? 0 : Marshal.GetLastWin32Error();
                return error;
            } finally {
                if (token != IntPtr.Zero) CloseHandle(token);
                if (clearPassword != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(clearPassword);
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    [Cabinet307.TeacherPasswordValidator]::Validate($Password)
}

function Get-ClassroomCredential {
    [CmdletBinding()]
    param([string]$UserName = '108SU')
    $ErrorActionPreference = 'Stop'
    $assumption = "The local 108SU account is expected to use the same password on the teacher computer and all student computers."
    try {
        $localAccount = Get-LocalUser -Name '108SU' -ErrorAction Stop
    } catch {
        throw "LOCAL_ACCOUNT_CHECK_FAILED: $assumption Cannot verify local account 108SU on teacher computer '$env:COMPUTERNAME'. No student login attempts were made. $($_.Exception.Message)"
    }
    if (-not $localAccount.Enabled) {
        throw "LOCAL_ACCOUNT_CHECK_FAILED: $assumption Account 108SU on teacher computer '$env:COMPUTERNAME' is disabled. The password could not be validated. No student login attempts were made."
    }
    Write-Host 'Check keyboard layout: use English (ENG) for the password.'
    $entered = Get-Credential -UserName "$env:COMPUTERNAME\108SU" -Message 'Shared classroom password; first checked against local 108SU on this teacher computer'
    if ($null -eq $entered) { return $null }
    Write-Host ("Checking the password for local 108SU on teacher computer '{0}'..." -f $env:COMPUTERNAME)
    $code = Invoke-TeacherCredentialValidation -Password $entered.Password
    if ($code -eq 0) {
        return [pscredential]::new($UserName, $entered.Password)
    }
    if ($code -eq 1326 -or $code -eq 86) {
        $message = "PASSWORD_CHECK_FAILED: $assumption We checked the entered password against local 108SU on teacher computer '$env:COMPUTERNAME', and it was not accepted. Check the password, keyboard layout (ENG), and Caps Lock. No student login attempts were made."
    } else {
        $reason = switch ($code) {
            1909 { 'The local account is locked.' }
            1331 { 'The local account is disabled.' }
            1330 { 'The local password has expired.' }
            1793 { 'The local account has expired.' }
            1907 { 'The local password must be changed.' }
            1385 { 'Windows policy does not allow this type of local credential validation.' }
            default { [ComponentModel.Win32Exception]::new([int]$code).Message }
        }
        $message = "LOCAL_PASSWORD_CHECK_ERROR: $assumption The check on teacher computer '$env:COMPUTERNAME' could not complete. $reason (Windows error $code). This does not establish that the password is incorrect. No student login attempts were made."
    }
    $entered = $null
    $exception = [InvalidOperationException]::new($message)
    $record = [System.Management.Automation.ErrorRecord]::new($exception, 'ClassroomLocalPasswordCheckFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $env:COMPUTERNAME)
    $PSCmdlet.ThrowTerminatingError($record)
}
