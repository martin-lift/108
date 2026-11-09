#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
$adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')

function New-RecoveryAcl {
    param([switch]$Directory, [switch]$PublicShortcut)
    if ($Directory) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    } else {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($adminSid)
    foreach ($sid in @($adminSid,$systemSid)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$inherit,'None','Allow'))
    }
    if ($PublicShortcut) {
        $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-11')
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users,'ReadAndExecute','Allow'))
    }
    return $acl
}

function Assert-RecoveryObject($Path,$ExpectedAcl,[switch]$Directory) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -ne [bool]$Directory) {
        throw "Unexpected file type or redirected path: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sidType = [Security.Principal.SecurityIdentifier]
    # Windows can reorder equivalent entries or set bookkeeping bits when persisting an ACL.
    $rules = {
        param($descriptor)
        $descriptor.GetAccessRules($true,$true,$sidType) | ForEach-Object {
            '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value,$_.AccessControlType,[int]$_.FileSystemRights,
                $_.InheritanceFlags,$_.PropagationFlags,$_.IsInherited
        } | Sort-Object
    }
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner($sidType).Value -ne $ExpectedAcl.GetOwner($sidType).Value -or
        ((& $rules $acl) -join ';') -cne ((& $rules $ExpectedAcl) -join ';')) {
        throw "Unexpected permissions or owner: $Path"
    }
}

function New-AdminShortcut($LinkPath,$Payload,$PowerShellExe) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($LinkPath)
    $link.TargetPath = $PowerShellExe
    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Payload + '" -Elevated'
    $link.WorkingDirectory = [IO.Path]::GetDirectoryName($Payload)
    $link.Description = 'Restore network settings for classroom 307 (administrator privileges required)'
    $link.Save()
    # ShellLinkHeader.LinkFlags (offset 0x14): enable RunAsUser without changing other flags.
    $bytes = [IO.File]::ReadAllBytes($LinkPath)
    if ($bytes.Length -lt 76 -or [BitConverter]::ToUInt32($bytes,0) -ne 76) { throw 'Invalid Windows shortcut.' }
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($LinkPath,$bytes)
}

function Publish-InstallFile($Staged,$Destination,$Acl) {
    [IO.File]::SetAccessControl($Staged,$Acl)
    Assert-RecoveryObject $Staged $Acl
    if (Test-Path -LiteralPath $Destination -ErrorAction Stop) {
        Assert-RecoveryObject $Destination $Acl
        # File.Replace keeps this already verified destination ACL and updates atomically.
        [IO.File]::Replace($Staged,$Destination,[System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($Staged,$Destination)
    }
    Assert-RecoveryObject $Destination $Acl
}

function Install-StudentRecovery($Source,$ProgramFiles,$Programs,$PowerShellExe) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'RestoreStudentNetwork.ps1 is missing from the installer folder.' }
    $directory = Join-Path $ProgramFiles 'RestoreStudentNetwork'
    $payload = Join-Path $directory 'RestoreStudentNetwork.ps1'
    $shortcut = Join-Path $Programs 'RestoreStudentNetwork.lnk'
    $dirAcl = New-RecoveryAcl -Directory
    $fileAcl = New-RecoveryAcl
    $linkAcl = New-RecoveryAcl -PublicShortcut
    if (-not (Test-Path -LiteralPath $directory -ErrorAction Stop)) {
        [void][IO.Directory]::CreateDirectory($directory,$dirAcl)
    }
    Assert-RecoveryObject $directory $dirAcl -Directory
    # Refuse unrelated pre-existing files before updating either artifact.
    if (Test-Path -LiteralPath $payload) { Assert-RecoveryObject $payload $fileAcl }
    if (Test-Path -LiteralPath $shortcut) { Assert-RecoveryObject $shortcut $linkAcl }
    $unique = [Guid]::NewGuid().ToString('N')
    $stageFile = Join-Path $directory ($unique + '.tmp')
    $stageLink = Join-Path $Programs ($unique + '.lnk')
    try {
        [IO.File]::Copy($Source,$stageFile,$false)
        $expectedHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $stageFile).Hash -ne $expectedHash) { throw 'The copied file does not match the source.' }
        New-AdminShortcut $stageLink $payload $PowerShellExe
        # Verify the shortcut before publishing either file.
        $linkHash = (Get-FileHash -LiteralPath $stageLink).Hash
        $readBack = (New-Object -ComObject WScript.Shell).CreateShortcut($stageLink)
        if ($readBack.TargetPath -ine $PowerShellExe) { throw "Unexpected shortcut target: $($readBack.TargetPath)" }
        if ($readBack.Arguments -cne ('-NoProfile -ExecutionPolicy Bypass -File "' + $payload + '" -Elevated')) { throw "Unexpected shortcut arguments: $($readBack.Arguments)" }
        if (([IO.File]::ReadAllBytes($stageLink)[0x15] -band 0x20) -eq 0) { throw 'The shortcut does not request administrator privileges.' }
        Publish-InstallFile $stageFile $payload $fileAcl
        Publish-InstallFile $stageLink $shortcut $linkAcl
        if ((Get-FileHash -LiteralPath $shortcut).Hash -ne $linkHash) { throw 'The installed shortcut does not match the verified copy.' }
        if ((Get-FileHash -LiteralPath $payload).Hash -ne $expectedHash) { throw 'The installed file does not match the source.' }
    } finally {
        foreach ($temp in @($stageFile,$stageLink)) {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
    return $payload
}

function Complete-StudentRecoveryInstall($InstalledScript,$PowerShellExe) {
    Write-Host "RestoreStudentNetwork is installed. You can also open it from the Start menu." -ForegroundColor Green
    while ($true) {
        $answer = ([string](Read-Host 'Run RestoreStudentNetwork now? [1] Yes / [2] No (Enter = No)')).Trim()
        if ($answer -in @('','2','не','н','no','n')) { return 0 }
        if ($answer -in @('1','да','д','yes','y')) { break }
        Write-Host 'Enter 1 for Yes or 2 for No.'
    }
    # A child process inherits this console and its elevated token. Run the verified installed file.
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $InstalledScript),'-Elevated')
    $child = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    return $child.ExitCode
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    if ($env:COMPUTERNAME -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
        throw "This installer is for 307-Student-01 through 307-Student-27. Current computer: $env:COMPUTERNAME."
    }
    $exe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($Elevated) { throw 'Administrator privileges are required.' }
        $child = Start-Process -FilePath $exe -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Elevated') -Wait -PassThru
        exit $child.ExitCode
    }
    $source = Join-Path $PSScriptRoot 'RestoreStudentNetwork.ps1'
    if (-not (Test-Path -LiteralPath $source)) { $source = Join-Path $PSScriptRoot 'Restore-StudentNetwork.ps1' }
    $installed = Install-StudentRecovery $source ([Environment]::GetFolderPath('ProgramFiles')) ([Environment]::GetFolderPath('CommonPrograms')) $exe
    exit (Complete-StudentRecoveryInstall $installed $exe)
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
