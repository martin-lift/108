# Windows PowerShell 5.1: fake credential UI, local validation and remoting only.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Credential-Helper.ps1')
$script:Prompts=0;$script:Validations=0;$script:Result=0;$script:Cancel=$false;$script:Checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:Checks++}
function Get-LocalUser {param($Name,$ErrorAction) [pscustomobject]@{Enabled=$true}}
function Get-Credential {param($UserName,$Message) $script:Prompts++;if($script:Cancel){return};[pscredential]::new($UserName,(ConvertTo-SecureString 'fake-only' -AsPlainText -Force))}
function Invoke-TeacherCredentialValidation {param($Password) $script:Validations++;$script:Result}
function Assert-Rejected { $failed=$false;try{Get-ClassroomCredential | Out-Null}catch{$failed=$true};Assert $failed 'Invalid password rejected' }
try {
    Clear-ClassroomCredentialCache
    $null=Get-ClassroomCredential;$null=Get-ClassroomCredential
    Assert ($script:Prompts -eq 2 -and $script:Validations -eq 2) 'Standalone calls still prompt'
    Initialize-ClassroomCredentialCache
    $first=Get-ClassroomCredential
    $second=Get-ClassroomCredential -UserName '307-Student-12\108SU'
    Assert ($script:Prompts -eq 3 -and $script:Validations -eq 3) 'One prompt and validation for menu session'
    Assert ($second.UserName -eq '307-Student-12\108SU') 'Cached password uses requested target username'
    Assert ($global:Cabinet307MenuCredentialCache.Password -is [Security.SecureString]) 'Only SecureString is cached'
    Assert ($global:Cabinet307MenuCredentialCache.Password.IsReadOnly()) 'Cached SecureString is read only'
    Assert (-not [object]::ReferenceEquals($first.Password,$global:Cabinet307MenuCredentialCache.Password)) 'Cache owns its copy'
    # Manager dot-sources the helper into a child script scope. It must use the same cache.
    $script:Connections=0
    function New-PSSession {param($ComputerName,$Credential,$ErrorAction) $script:Connections++;Assert ($Credential.UserName -eq '307-Student-12\108SU') 'Manager rebuilds target credentials';[pscustomobject]@{Name=$ComputerName}}
    function Invoke-Command {param($Session,$ScriptBlock,$ArgumentList,$ErrorAction) 'simulated'}
    function Remove-PSSession {param($Session,$ErrorAction)}
    $report=@(& (Join-Path $root 'Manage-Classroom.ps1') -Numbers 12 -ScriptBlock {'simulated'} -Confirm:$false)
    Assert ($report.Count -eq 1 -and $report[0].Status -eq 'OK') 'Helper script operation succeeds with cached credential'
    Assert ($script:Prompts -eq 3) 'Helper reload does not prompt again'
    Clear-ClassroomCredentialCache
    Assert ($null -eq (Get-Variable Cabinet307MenuCredentialCache -Scope Global -ErrorAction SilentlyContinue)) 'Clear removes global state'
    # Reload resets fake validator definition because the helper defines the real one.
    function Invoke-TeacherCredentialValidation {param($Password) $script:Validations++;$script:Result}
    Initialize-ClassroomCredentialCache
    $null=Get-ClassroomCredential
    Assert ($script:Prompts -eq 4) 'New menu session prompts again'
    Initialize-ClassroomCredentialCache
    $script:Cancel=$true
    Assert ($null -eq (Get-ClassroomCredential)) 'Cancel returns without a credential'
    Assert ($null -eq $global:Cabinet307MenuCredentialCache.Password) 'Cancel does not populate cache'
    $script:Cancel=$false;$script:Result=1326
    Assert-Rejected
    Assert ($null -eq $global:Cabinet307MenuCredentialCache.Password) 'Rejected password not cached'
    $script:Result=0;$null=Get-ClassroomCredential
    Assert ($script:Prompts -eq 7) 'Retry after failed password prompts'
    $tokens=$null;$parseErrors=$null
    $menu=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Teacher-Menu.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Menu parses'
    $guard=$menu.Find({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Finally.Extent.Text.Contains('Clear-ClassroomCredentialCache')},$true)
    Assert ($null -ne $guard -and $guard.Body.Extent.Text.Contains("Read-Host 'Choose an action'")) 'Menu loop clears cache in finally'
    Write-Output ("PASS: {0} credential cache checks; no real credentials or remote connections." -f $script:Checks)
} finally {Clear-ClassroomCredentialCache}
