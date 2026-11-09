# Exercise the real installer only inside a temporary directory, with an inert payload.
#Requires -Version 5.1
param([string]$ScriptPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-RestoreStudentNetwork.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join ' / ')}
. $ScriptPath
function Check($Condition,$Message){if(-not $Condition){throw $Message}}
# Verify the production policy before substituting the test operator for the administrator.
foreach($acl in @((New-RecoveryAcl -Directory),(New-RecoveryAcl))) {
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Check ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Wrong owner or inherited rights'
    foreach($rule in $rules){Check ($rule.IdentityReference.Value -in 'S-1-5-18','S-1-5-32-544' -and $rule.FileSystemRights -eq 'FullControl') 'Unexpected private access rule'}
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $adminSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
}
$rootPath=[IO.Path]::GetTempPath()
$tmp=Join-Path $rootPath ('Cabinet307-InstallTest-'+[guid]::NewGuid().ToString('N'))
$programFiles=Join-Path $tmp 'Program Files'
$programs=Join-Path $tmp 'Start Menu'
$source=Join-Path $tmp 'Test only.ps1'
$exe=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
try {
    [void][IO.Directory]::CreateDirectory($programFiles)
    [void][IO.Directory]::CreateDirectory($programs)
    [IO.File]::WriteAllText($source,"throw 'A payload must never run during installation'")
    Install-StudentRecovery $source $programFiles $programs $exe
    $installed=Join-Path $programFiles 'RestoreStudentNetwork\RestoreStudentNetwork.ps1'
    Check ((Get-FileHash $source).Hash -eq (Get-FileHash $installed).Hash) 'Installed content differs'
    $links=@(Get-ChildItem -LiteralPath $programs -Filter '*.lnk')
    Check ($links.Count -eq 1) 'Expected one permanent shortcut'
    Check ($links[0].Name -ceq 'RestoreStudentNetwork.lnk') 'Wrong Start menu name'
    $link=(New-Object -ComObject WScript.Shell).CreateShortcut($links[0].FullName)
    Check (($link.Arguments -like "*$installed*") -and (([IO.File]::ReadAllBytes($links[0].FullName)[0x15] -band 0x20) -ne 0)) 'Shortcut is not for the installed elevated target'
    [IO.File]::WriteAllText($source,"throw 'Updated test payload'")
    Install-StudentRecovery $source $programFiles $programs $exe
    Check ((Get-FileHash $source).Hash -eq (Get-FileHash $installed).Hash) 'Update failed'
    # A saved script with unexpected write permissions must never be trusted on update.
    $bad=New-RecoveryAcl
    $bad.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Modify','Allow'))
    [IO.File]::SetAccessControl($installed,$bad)
    $refused=$false
    try { Install-StudentRecovery $source $programFiles $programs $exe } catch { $refused=$true }
    Check $refused 'Accepted modified access controls'
    Write-Output 'PASS: private ACL, install, elevated shortcut, update and unsafe permissions refusal in a temporary fixture.'
} finally {
    $full=[IO.Path]::GetFullPath($tmp)
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine $rootPath.TrimEnd('\') -or [IO.Path]::GetFileName($full) -notmatch '^Cabinet307-InstallTest-[0-9a-f]{32}$'){throw 'Unsafe test path'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
