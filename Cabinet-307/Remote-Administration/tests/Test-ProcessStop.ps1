# Simulated remoting and process objects only. No real process is terminated.
$ErrorActionPreference = 'Stop'
$menuPath = Join-Path $PSScriptRoot 'Teacher-Menu.ps1'
if (-not (Test-Path -LiteralPath $menuPath)) { $menuPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1' }
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($menuPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-StudentNumber','Get-ClassroomErrorStatus','Test-WifiLoginError','Get-ClassroomProcessStopCommand','Stop-ClassroomProcesses')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Set-Item -LiteralPath ('Function:\' + $name) -Value $definition.Body.GetScriptBlock()
}
$script:Checks = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:Checks++ }
function New-FakeProcess([int]$Number, [string]$Name, [int]$Session = 1) {
    $process = [pscustomobject]@{Id=$Number;ProcessName=$Name;SessionId=$Session;Handle=123;StartTime=[datetime]'2026-10-15T07:00:00Z';Path="C:\Apps\$Name.exe"}
    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        if ($script:Scenario -eq 'KillDenied') { throw 'Access denied' }
        $script:Killed.Add([int]$this.Id)
    }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Timeout) $script:Scenario -ne 'ExitTimeout' }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:Disposed++ }
    $process
}
function Reset-Test([string[]]$Answers = @('20','E','msedge','STOP')) {
    $script:Scenario = ''
    $script:Killed = New-Object 'System.Collections.Generic.List[int]'
    $script:Disposed = 0
    $script:Opened = 0
    $script:Closed = 0
    $script:CredentialCalls = 0
    $script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
    $script:Messages = New-Object 'System.Collections.Generic.List[string]'
    $script:Phases = New-Object 'System.Collections.Generic.List[string]'
    $script:Current = @{
        100 = (New-FakeProcess 100 'msedge'); 101 = (New-FakeProcess 101 'msedge')
        200 = (New-FakeProcess 200 'explorer'); 300 = (New-FakeProcess 300 'wsmprovhost')
        400 = (New-FakeProcess 400 'javaw')
    }
    $script:Items = @(
        [pscustomobject]@{Name='msedge.exe';ProcessId=100;SessionId=1;ExecutablePath='C:\Apps\msedge.exe'},
        [pscustomobject]@{Name='msedge.exe';ProcessId=101;SessionId=1;ExecutablePath='C:\Apps\msedge.exe'},
        [pscustomobject]@{Name='svchost.exe';ProcessId=4;SessionId=0;ExecutablePath=''},
        [pscustomobject]@{Name='explorer.exe';ProcessId=200;SessionId=1;ExecutablePath=''},
        [pscustomobject]@{Name='wsmprovhost.exe';ProcessId=300;SessionId=1;ExecutablePath=''},
        [pscustomobject]@{Name='javaw.exe';ProcessId=400;SessionId=1;ExecutablePath='C:\Apps\javaw.exe'}
    )
}
function Get-CimInstance { param($ClassName,$Property,$ErrorAction) $script:Items }
function Get-Process { param([int]$Id,$ErrorAction) $script:Current[$Id] }
function Read-Host { param($Prompt) if (-not $script:Answers.Count) { throw "Unexpected prompt: $Prompt" }; $script:Answers.Dequeue() }
function Write-Host { param($Object,$ForegroundColor) $script:Messages.Add([string]$Object) }
function Out-Host { param([Parameter(ValueFromPipeline=$true)]$InputObject) process {} }
function Start-Service { param($Name,$ErrorAction) }
function New-PSSessionOption { param($OpenTimeout) @{} }
function Get-ClassroomCredential {
    param($UserName)
    $script:CredentialCalls++
    Assert ($UserName -eq '307-Student-20\108SU') 'Incorrect target account'
    if ($script:Scenario -eq 'CancelCredential') { return $null }
    [pscredential]::new($UserName,(ConvertTo-SecureString 'SIMULATED-NOT-A-REAL-PASSWORD' -AsPlainText -Force))
}
function New-PSSession {
    param($ComputerName,$Credential,$SessionOption,$ErrorAction)
    $script:Opened++
    Assert ($ComputerName -eq '307-Student-20.local') 'Incorrect remote destination'
    if ($script:Scenario -eq 'LoginError') { throw 'Access is denied.' }
    [pscustomobject]@{TestSession=$true}
}
function Remove-PSSession { param($Session,$ErrorAction) $script:Closed++ }
function Invoke-Command {
    param($Session,$ScriptBlock,[object[]]$ArgumentList,$ErrorAction)
    $script:Phases.Add([string]$ArgumentList[2])
    if ($ArgumentList[2] -eq 'Stop') {
        Assert ($ArgumentList.Count -eq 6 -and $ArgumentList[5].Count -gt 0) 'Approved array was flattened'
        if ($script:Scenario -eq 'Disconnect') { throw 'Simulated lost connection' }
        if ($script:Scenario -eq 'NewProcess') {
            $script:Current[102] = New-FakeProcess 102 'msedge'
        }
    }
    $savedHost = $env:COMPUTERNAME
    try {
        $env:COMPUTERNAME = if ($script:Scenario -eq 'WrongHost') { 'UNEXPECTED' } else { '307-Student-20' }
        & $ScriptBlock @ArgumentList
    } finally { $env:COMPUTERNAME = $savedHost }
}
$command = Get-ClassroomProcessStopCommand
$savedHost = $env:COMPUTERNAME
try {
    $env:COMPUTERNAME = '307-Student-20'
    Reset-Test
    $preview = @(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' 'MSEDGE.EXE')
    Assert ($preview.Count -eq 2 -and @($preview | Where-Object Eligible).Count -eq 2) 'Case-insensitive exact-name matching failed'
    Assert (@(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' 'msedge').Count -eq 2) 'Exact names without .exe must work'
    Assert (@(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'S' 'edge').Count -eq 2) 'Substring matching failed'
    Assert (@(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' 'edge').Count -eq 0) 'Exact mode acted like substring mode'
    Assert (@(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'S' '.*').Count -eq 0) 'Substring mode evaluated a regex'
    Assert ($script:Killed.Count -eq 0) 'Preview terminated a process'
    foreach ($protectedName in @('svchost','explorer','wsmprovhost')) {
        $blocked = @(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' $protectedName)
        Assert ($blocked.Count -eq 1 -and -not $blocked[0].Eligible -and $blocked[0].Reason) 'Protected process was eligible'
    }
    $stopped = @(& $command '307-Student-20' 'TEST-TEACHER' 'Stop' '' '' $preview)
    Assert (($script:Killed -join ',') -eq '100,101' -and @($stopped | Where-Object Status -eq 'STOPPED').Count -eq 2) 'Approved process objects were not terminated'
    foreach ($identityCase in @('ReusedPID','Renamed','SessionChanged','Exited')) {
        Reset-Test
        $approved = @(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' 'javaw')
        switch ($identityCase) {
            'ReusedPID' { $script:Current[400].StartTime = $script:Current[400].StartTime.AddSeconds(1) }
            'Renamed' { $script:Current[400].ProcessName = 'different' }
            'SessionChanged' { $script:Current[400].SessionId = 2 }
            'Exited' { $script:Current.Remove(400) }
        }
        $result = @(& $command '307-Student-20' 'TEST-TEACHER' 'Stop' '' '' $approved)
        Assert ($script:Killed.Count -eq 0 -and $result[0].Status -eq $(if ($identityCase -eq 'Exited') { 'ALREADY_EXITED' } else { 'SKIPPED_CHANGED' })) 'Stale approval targeted another process'
    }
    foreach ($failureCase in @('KillDenied','ExitTimeout')) {
        Reset-Test
        $approved = @(& $command '307-Student-20' 'TEST-TEACHER' 'Preview' 'E' 'javaw')
        $script:Scenario = $failureCase
        $result = @(& $command '307-Student-20' 'TEST-TEACHER' 'Stop' '' '' $approved)
        Assert ($result[0].Status -eq $(if ($failureCase -eq 'KillDenied') { 'ERROR' } else { 'UNKNOWN' })) 'Failed termination was reported as success'
    }
    $rejected = $false
    try { $null = & $command '307-Student-20' '307-Student-20' 'Stop' '' '' $approved } catch { $rejected = $true }
    Assert $rejected 'Teacher host guard failed'
} finally { $env:COMPUTERNAME = $savedHost }
Reset-Test
Stop-ClassroomProcesses
Assert (($script:Phases -join ',') -eq 'Preview,Stop' -and $script:Killed.Count -eq 2 -and $script:Closed -eq 1) 'Confirmed menu action failed'
Reset-Test @('20','S','edge','STOP')
$script:Scenario = 'NewProcess'
Stop-ClassroomProcesses
Assert (($script:Killed -join ',') -eq '100,101') 'New matching process was included after approval'
foreach ($cancelAnswers in @(@(''),@('20',''),@('20','E',''),@('20','E','msedge',''),@('20','E','msedge','stop'))) {
    Reset-Test $cancelAnswers
    Stop-ClassroomProcesses
    Assert ($script:Killed.Count -eq 0 -and $script:Phases -notcontains 'Stop') 'Cancellation terminated processes'
    Assert ($script:Closed -eq $script:Opened) 'Cancelled action leaked a session'
}
Reset-Test @('20','E','explorer')
Stop-ClassroomProcesses
Assert ($script:Phases.Count -eq 1 -and $script:Killed.Count -eq 0 -and $script:Closed -eq 1) 'Protected-only search attempted a stop'
Reset-Test @('20','E','no-match')
Stop-ClassroomProcesses
Assert ($script:Phases.Count -eq 1 -and $script:Closed -eq 1) 'Empty search attempted a stop or leaked a session'
foreach ($failureCase in @('WrongHost','LoginError','Disconnect','CancelCredential')) {
    Reset-Test
    $script:Scenario = $failureCase
    Stop-ClassroomProcesses
    Assert ($script:Killed.Count -eq 0) 'Failed action terminated a process'
    Assert ($script:Closed -eq $(if ($failureCase -in 'LoginError','CancelCredential') { 0 } else { 1 })) 'Failure cleanup incorrect'
    if ($failureCase -eq 'Disconnect') { Assert (@($script:Messages | Where-Object { $_ -like 'UNKNOWN:*' }).Count -eq 1) 'Lost stop results must be UNKNOWN'
    }
}
$menuSwitch = $ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$choice' }, $true)
Assert (($menuSwitch.Clauses | Where-Object { $_.Item1.Value -eq '10' }).Item2.Extent.Text -match 'Stop-ClassroomProcesses') 'Option 10 is not connected'
Write-Output "PASS: Windows PowerShell $($PSVersionTable.PSVersion), $script:Checks checks. Only fake process objects were terminated."
