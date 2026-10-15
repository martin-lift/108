# Run with Windows PowerShell 5.1. No real remote connections or report writes.
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
$menuPath = Join-Path $PSScriptRoot 'Teacher-Menu.ps1'
if (-not (Test-Path -LiteralPath $menuPath)) { $menuPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1' }
$baseDirectory = Split-Path $menuPath -Parent
$script:ConfigJson = Get-Content -LiteralPath (Join-Path $baseDirectory 'Uninteresting-Processes.json') -Raw
$script:ReplayRows = @()
if ($ReportPath) {
    $raw = Get-Content -LiteralPath $ReportPath -Raw
    foreach ($block in [regex]::Matches($raw, '(?ms)^Name: .*?(?=\r?\n\r?\nName:|\z)')) {
        $fields = @{}
        foreach ($line in $block.Value -split '\r?\n') {
            if ($line -match '^([^:]+): ?(.*)$') { $fields[$matches[1]] = $matches[2] }
        }
        $script:ReplayRows += [pscustomobject]@{ Name=$fields.Name; ProcessId=[uint32]$fields.PID; ParentProcessId=[uint32]$fields['Parent PID']; SessionId=[uint32]$fields['Session ID']; ExecutablePath=$fields.Path; CreationDate=[datetime]$fields['Started at (UTC)'] }
    }
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($menuPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-StudentNumber','Get-ClassroomErrorStatus','Test-WifiLoginError','ConvertFrom-ClassroomProcessFilter','Get-ClassroomProcessFilter','Show-ClassroomProcesses')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Set-Item -LiteralPath ('Function:\' + $name) -Value $definition.Body.GetScriptBlock()
}
$script:Checks = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:Checks++ }
$config = ConvertFrom-ClassroomProcessFilter $script:ConfigJson
Assert ($config.Names.Count -eq 66) 'Unexpected reviewed-name count'
Assert ($config.Names.ContainsKey('SVCHOST.EXE')) 'Exact names must be case-insensitive'
Assert (-not $config.Names.ContainsKey('msedge.exe') -and -not $config.Names.ContainsKey('msedgewebview2.exe')) 'Browser engines must remain visible'
foreach ($badJson in @('{','{"SchemaVersion":2,"Revision":"x","UninterestingProcesses":[]}',
    '{"SchemaVersion":1,"Revision":"x","UninterestingProcesses":[{"Name":"*host.exe"}]}',
    '{"SchemaVersion":1,"Revision":"x","UninterestingProcesses":[{"Name":"x.exe"},{"Name":"X.exe"}]}',
    '{"SchemaVersion":1,"Revision":"x","UninterestingProcesses":[{"Name":"../x.exe"}]}',
    '{"SchemaVersion":1,"Revision":"x","UninterestingProcesses":[{"Name":27}]}')) {
    $rejected = $false
    try { $null = ConvertFrom-ClassroomProcessFilter $badJson } catch { $rejected = $true }
    Assert $rejected 'Invalid filter was accepted'
}
$script:SyntheticRows = @(
    [pscustomobject]@{Name='svchost.exe';ProcessId=4;ParentProcessId=0;SessionId=0;ExecutablePath='C:\Windows\System32\svchost.exe';CreationDate=[datetime]'2026-10-15T05:00:00Z'},
    [pscustomobject]@{Name='msedge.exe';ProcessId=100;ParentProcessId=4;SessionId=1;ExecutablePath='C:\Browser\msedge.exe';CreationDate=[datetime]'2026-10-15T05:01:00Z'},
    [pscustomobject]@{Name='msedge.exe';ProcessId=101;ParentProcessId=100;SessionId=1;ExecutablePath='C:\Browser\msedge.exe';CreationDate=[datetime]'2026-10-15T05:02:00Z'},
    [pscustomobject]@{Name='UnknownApp.exe';ProcessId=102;ParentProcessId=103;SessionId=1;ExecutablePath='';CreationDate=[datetime]'2026-10-15T05:02:00Z'},
    [pscustomobject]@{Name='AnotherUnknown.exe';ProcessId=103;ParentProcessId=999;SessionId=1;ExecutablePath='';CreationDate=[datetime]'2026-10-15T05:03:00Z'}
)
function Reset-Test {
    $script:Rows = $script:SyntheticRows
    $script:Mode = ''
    $script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    $script:Answers.Enqueue('20')
    $script:Report = New-Object 'System.Collections.Generic.List[string]'
    $script:Messages = New-Object 'System.Collections.Generic.List[string]'
    $script:CacheJson = $script:ConfigJson
    $script:Closed = 0
    $script:Opened = 0
    $script:Downloads = 0
    $script:InventoryCalls = 0
}
function Read-Host { param($Prompt) $script:Answers.Dequeue() }
function Write-Host { param($Object, $ForegroundColor) $script:Messages.Add([string]$Object) }
function Out-Host { param([Parameter(ValueFromPipeline=$true)]$InputObject) process {} }
function Start-Service { param($Name, $ErrorAction) }
function Get-ClassroomCredential {
    param($UserName)
    Assert ($UserName -eq '307-Student-20\108SU') 'Unexpected target account'
    if ($script:Mode -eq 'CancelCredential') { return $null }
    [pscredential]::new($UserName, (ConvertTo-SecureString 'SIMULATED-NOT-A-REAL-PASSWORD' -AsPlainText -Force))
}
function New-PSSessionOption { param($OpenTimeout) @{} }
function New-PSSession {
    param($ComputerName, $Credential, $SessionOption, $ErrorAction)
    $script:Opened++
    Assert ($ComputerName -eq '307-Student-20.local') 'Unexpected target computer'
    if ($script:Mode -eq 'LoginError') { throw 'Access is denied.' }
    [pscustomobject]@{TestSession=$true}
}
function Remove-PSSession { param($Session, $ErrorAction) $script:Closed++ }
function Invoke-Command {
    param($Session, $ScriptBlock, [object[]]$ArgumentList, $ErrorAction)
    $savedName = $env:COMPUTERNAME
    try {
        $env:COMPUTERNAME = if ($script:Mode -eq 'WrongHost') { 'WRONG-HOST' } else { '307-Student-20' }
        & $ScriptBlock @ArgumentList
    } finally { $env:COMPUTERNAME = $savedName }
}
function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    $script:InventoryCalls++
    Assert ($Property -notcontains 'CommandLine') 'Unexpected command-line collection'
    if ($script:Mode -eq 'ReadError') { throw 'Inventory failed' }
    $script:Rows
}
function Get-Item { param($LiteralPath, $ErrorAction) [pscustomobject]@{VersionInfo=[pscustomobject]@{FileDescription='Synthetic metadata';CompanyName='Example Company'}} }
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
    $script:Downloads++
    Assert ($TimeoutSec -eq 10 -and $UseBasicParsing) 'Download must work in PS5.1 with a timeout'
    Assert ($Uri -eq 'https://raw.githubusercontent.com/martin-lift/108/main/Cabinet-307/Remote-Administration/Uninteresting-Processes.json') 'Unexpected download URL'
    if ($script:Mode -in 'Offline','NoFilter','BadCache') { throw 'Offline' }
    [pscustomobject]@{Content=$(if ($script:Mode -eq 'BadDownload') { '{' } else { $script:ConfigJson })}
}
function Test-Path { param($LiteralPath, $PathType) -not [string]::IsNullOrEmpty($script:CacheJson) }
function Get-Content { param($LiteralPath, [switch]$Raw, $ErrorAction) $script:CacheJson }
function New-Item { param($ItemType, $Path, [switch]$Force, $ErrorAction) }
function Set-Content {
    param($LiteralPath, $Encoding, [Parameter(ValueFromPipeline=$true)]$Value)
    process {
        if ($LiteralPath.EndsWith('.json')) {
            if ($script:Mode -eq 'CacheWriteError') { throw 'Cache write failed' }
            $script:CacheJson = [string]$Value
        } else {
            Assert ($script:Closed -eq 1) 'Remote session was not closed before report output'
            if ($script:Mode -eq 'ReportWriteError') { throw 'Report write failed' }
            $script:Report.Add([string]$Value)
        }
    }
}
Reset-Test
Show-ClassroomProcesses
Assert ($script:Report.Contains('Total process count: 5') -and $script:Report.Contains('Reported process count: 4')) 'Wrong filtered counts'
Assert ($script:Report.Contains('Excluded background process count: 1')) 'Excluded count missing'
Assert (($script:Report -join "`n") -notmatch 'svchost\.exe') 'Excluded name leaked into the report'
Assert ($script:Report.Contains('Parent name: [excluded background process]')) 'Excluded parent name was not redacted'
Assert ($script:Report.Contains('Parent name: msedge.exe')) 'Useful retained parent name was lost'
Assert ($script:Report.Contains('msedge.exe | PID 100') -and $script:Report.Contains('msedge.exe | PID 101')) 'Duplicate names lost individual PIDs'
Assert ($script:Report.Contains('UnknownApp.exe | PID 102')) 'Unknown process with missing metadata was hidden'
Assert ($script:Report.Contains('Filter source: GitHub')) 'Filter source missing'
Assert ($script:Opened -eq 1 -and $script:Closed -eq 1) 'Session cleanup failed'
foreach ($fallbackMode in @('Offline','BadDownload','CacheWriteError')) {
    Reset-Test
    $script:Mode = $fallbackMode
    Show-ClassroomProcesses
    Assert ($script:Report.Contains('Reported process count: 4')) "$fallbackMode lost the usable filter"
}
foreach ($fallbackMode in @('NoFilter','BadCache')) {
    Reset-Test
    $script:Mode = $fallbackMode
    $script:CacheJson = if ($fallbackMode -eq 'BadCache') { '{' } else { '' }
    Show-ClassroomProcesses
    Assert ($script:Report.Contains('Reported process count: 5') -and $script:Report.Contains('Filter revision: none')) 'Filter failure must preserve the complete inventory'
    Assert (@($script:Messages | Where-Object { $_ -like '*All processes will be included*' }).Count -eq 1) 'Missing fallback warning'
}
Reset-Test
$script:Rows = @($script:SyntheticRows[0])
Show-ClassroomProcesses
Assert ($script:Report.Contains('Reported process count: 0') -and $script:Report.Contains('Excluded background process count: 1')) 'An all-background snapshot must still produce a report'
Assert (($script:Report -join "`n") -notmatch 'svchost\.exe') 'Zero-result report leaked an excluded name'
foreach ($failureMode in @('WrongHost','LoginError','ReadError')) {
    Reset-Test
    $script:Mode = $failureMode
    Show-ClassroomProcesses
    Assert ($script:Report.Count -eq 0) "$failureMode wrote a report"
    Assert ($script:Closed -eq $(if ($failureMode -eq 'LoginError') { 0 } else { 1 })) 'Failed session cleanup'
    if ($failureMode -eq 'WrongHost') { Assert ($script:InventoryCalls -eq 0) 'Wrong-host inventory was read' }
}
Reset-Test
$script:Mode = 'CancelCredential'
Show-ClassroomProcesses
Assert ($script:Opened -eq 0 -and $script:Downloads -eq 0) 'Cancelled credentials caused work'
Reset-Test
$script:Mode = 'ReportWriteError'
Show-ClassroomProcesses
Assert (@($script:Messages | Where-Object { $_ -like 'REPORT_ERROR:*' }).Count -eq 1) 'Report-write error was not reported'
if ($script:ReplayRows.Count) {
    Reset-Test
    $script:Rows = $script:ReplayRows
    Show-ClassroomProcesses
    Assert ($script:Report.Contains('Total process count: 193') -and $script:Report.Contains('Excluded background process count: 159') -and $script:Report.Contains('Reported process count: 34')) 'Real report replay has unexpected counts'
    $outputNames = @($script:Report | Where-Object { $_ -match '^Name: ' } | ForEach-Object { $_.Substring(6) } | Select-Object -Unique)
    Assert (($outputNames -join ',') -eq 'msedge.exe,msedgewebview2.exe') 'Real report retained unexpected names'
    Write-Output 'Report replay: 193 total, 159 excluded, 34 retained (Edge and WebView2).'
}
Write-Output "PASS: Windows PowerShell $($PSVersionTable.PSVersion), $script:Checks checks. No student computer contacted; no reports or cache files written."
