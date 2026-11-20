#Requires -Version 5.1
# All registry and language writes are mocked. No real keyboard settings change.
$ErrorActionPreference = 'Stop'
$global:KeyboardTest_checks = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $global:KeyboardTest_checks++ }
$scriptDirectory = $PSScriptRoot
if (-not (Test-Path (Join-Path $scriptDirectory 'Set-StudentKeyboards.ps1'))) { $scriptDirectory = Split-Path $PSScriptRoot -Parent }
$profilePath = Join-Path $scriptDirectory 'Set-StudentKeyboardProfile.ps1'
$mainPath = Join-Path $scriptDirectory 'Set-StudentKeyboards.ps1'
foreach ($path in @($profilePath,$mainPath)) {
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Parse $path"
}
$assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$remoteSetup' },$true)
$remote = $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
$global:KeyboardTest_writes = 0
function New-Item { param($Path,[switch]$Force,$ItemType) $global:KeyboardTest_writes++ }
function New-ItemProperty { param($Path,$Name,$Value,$PropertyType,[switch]$Force) $global:KeyboardTest_state[$Name]=$Value; $global:KeyboardTest_writes++ }
function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) if ($global:KeyboardTest_state.ContainsKey($Name)) { [pscustomobject]@{ Value=$global:KeyboardTest_state[$Name] } } }
function New-WinUserLanguageList {
    param($Language)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $tips = New-Object 'System.Collections.Generic.List[string]'
    $list.Add([pscustomobject]@{LanguageTag=$Language;InputMethodTips=$tips})
    return ,$list
}
function Get-WinUserLanguageList { return ,$global:KeyboardTest_languages }
function Set-WinUserLanguageList { param($LanguageList,[switch]$Force) $global:KeyboardTest_sets++; if (-not $global:KeyboardTest_failSet) { $global:KeyboardTest_languages=$LanguageList } }
function Set-WinDefaultInputMethodOverride { param($InputTip) $global:KeyboardTest_default=$InputTip }
function Get-WinDefaultInputMethodOverride { [pscustomobject]@{InputMethodTip=$global:KeyboardTest_default} }
$computer = $env:COMPUTERNAME
try {
    $env:COMPUTERNAME = '307-TEACHER'
    $failed=$false
    try { & $remote '307-Student-01' 'unused' } catch { $failed=$true }
    Assert $failed 'Wrong remote identity is rejected'
    Assert ($global:KeyboardTest_writes -eq 0) 'Identity mismatch performs no writes'
    $failed=$false
    try { & $profilePath -ExpectedComputer '307-TEACHER' } catch { $failed=$true }
    Assert $failed 'Teacher profile is rejected even when expected name matches'
    Assert ($global:KeyboardTest_writes -eq 0) 'Teacher settings untouched'
    $env:COMPUTERNAME = '307-Student-01'
    $global:KeyboardTest_state=@{}; $global:KeyboardTest_sets=0; $global:KeyboardTest_failSet=$false
    $global:KeyboardTest_languages=New-WinUserLanguageList 'bg-BG'
    $global:KeyboardTest_languages[0].InputMethodTips.Add('0402:00020402')
    & $profilePath -ExpectedComputer '307-Student-01' -RunId 'test1'
    $tips = @($global:KeyboardTest_languages | ForEach-Object { $_.InputMethodTips })
    Assert ($tips.Count -eq 3) 'Exactly three keyboards'
    Assert (@(Compare-Object @('0409:00000409','0402:00040402','0402:00000402') $tips).Count -eq 0) 'Correct US, traditional phonetic and BDS identifiers'
    Assert ($global:KeyboardTest_languages[0].LanguageTag -eq 'bg-BG') 'Existing Bulgarian preference retained'
    Assert ($global:KeyboardTest_state.Status -eq 'OK' -and $global:KeyboardTest_state.RunId -eq 'test1') 'Verified status includes this run identifier'
    $original=$global:KeyboardTest_state.OriginalLanguages
    & $profilePath -ExpectedComputer '307-Student-01' -RunId 'test2'
    Assert ($global:KeyboardTest_sets -eq 1) 'Already configured profile does not reset language list'
    Assert ($global:KeyboardTest_state.OriginalLanguages -eq $original) 'Original settings retained on rerun'
    $global:KeyboardTest_languages=New-WinUserLanguageList 'en-US'
    $global:KeyboardTest_languages[0].InputMethodTips.Add('0409:00010409')
    $global:KeyboardTest_failSet=$true
    $failed=$false
    try { & $profilePath -ExpectedComputer '307-Student-01' -RunId 'failed' } catch { $failed=$true }
    Assert $failed 'Read-back mismatch fails'
    Assert ($global:KeyboardTest_state.Status -ne 'OK') 'Read-back mismatch cannot report success'
    # Run the real coordinator with a simulated WinRM transport.
    $global:KeyboardTest_prompts=0; $global:KeyboardTest_targets=@(); $global:KeyboardTest_closed=0
    function Get-ClassroomCredential {
        $global:KeyboardTest_prompts++
        [pscredential]::new('108SU',(ConvertTo-SecureString 'test-only-dummy' -AsPlainText -Force))
    }
    function New-PSSessionOption { param($OpenTimeout,$OperationTimeout) 'mock-options' }
    function Start-Service { param($Name) Assert ($Name -eq 'WinRM') 'Only the WinRM service is started locally' }
    function New-PSSession {
        param($ComputerName,$Credential,$SessionOption)
        if ($ComputerName -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])\.local$') { throw 'Non-student target' }
        Assert ($Credential.UserName -eq ($ComputerName.Replace('.local','')+'\108SU')) 'Per-machine local credential'
        $global:KeyboardTest_targets += $ComputerName
        [pscustomobject]@{ComputerName=$ComputerName}
    }
    function Invoke-Command { param($Session,$ScriptBlock,$ArgumentList) [pscustomobject]@{Status='OK';AppliedProfiles=1;NextSignInProfiles=1;Details=''} }
    function Remove-PSSession { param($Session,$ErrorAction) $global:KeyboardTest_closed++ }
    function Export-Csv { param($LiteralPath,[switch]$NoTypeInformation,$Encoding,[Parameter(ValueFromPipeline=$true)]$InputObject) process {} }
    $coordinator = Get-Content -LiteralPath $mainPath -Raw
    $coordinator = $coordinator.Replace('#Requires -RunAsAdministrator','')
    $coordinator = $coordinator.Replace(". (Join-Path `$PSScriptRoot 'Credential-Helper.ps1')",'')
    $coordinator = $coordinator.Replace('$PSScriptRoot', ("'" + $scriptDirectory.Replace("'","''") + "'"))
    & ([scriptblock]::Create($coordinator)) *> $null
    Assert ($global:KeyboardTest_prompts -eq 1) 'Password requested exactly once for all targets'
    Assert ($global:KeyboardTest_targets.Count -eq 27) 'All 27 students included'
    Assert ($global:KeyboardTest_closed -eq 27) 'Every WinRM session closed'
    'PASS: {0} checks' -f $global:KeyboardTest_checks
} finally { $env:COMPUTERNAME=$computer }
