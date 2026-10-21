# All service methods are simulated. The only writes are to a temporary test folder.
$ErrorActionPreference = 'Stop'
$menuPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1'
$tokens=$null;$parseErrors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($menuPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$definition=$tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ClassroomAudioCommand'},$true)
Set-Item -LiteralPath 'Function:\Get-ClassroomAudioCommand' -Value $definition.Body.GetScriptBlock()
$script:Checks=0
function Assert($Condition,[string]$Message) { if(-not $Condition){throw "FAILED: $Message"};$script:Checks++ }
function New-FakeService([string]$Name,[string]$Status='Running') {
    $s=[pscustomobject]@{Name=$Name;Status=$Status;DependentServices=@();Stops=0;Starts=0;FailStop=$false;FailStart=$false;FailWait=$false;Disposed=$false}
    $s | Add-Member ScriptMethod Refresh {}
    $s | Add-Member ScriptMethod Stop {if($this.FailStop){throw 'Stop failed'};$this.Stops++;$this.Status='Stopped'}
    $s | Add-Member ScriptMethod Start {if($this.FailStart){throw 'Start failed'};$this.Starts++;$this.Status='Running'}
    $s | Add-Member ScriptMethod WaitForStatus {param($State,$Timeout) if($this.FailWait){throw 'Timeout'};if($this.Status -in 'StartPending','StopPending'){$this.Status=[string]$State};if($this.Status -ne [string]$State){throw 'State not reached'}}
    $s | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $s
}
function Get-Service {param($Name,$ErrorAction) if($Name -eq 'Audiosrv'){return $script:Audio};if($Name -eq 'RtkAudioUniversalService'){return $script:Realtek};throw "Unexpected service: $Name"}
$originalComputer=$env:COMPUTERNAME;$originalProgramData=$env:ProgramData
$testRoot=Join-Path $env:TEMP ('test-state-'+[guid]::NewGuid().ToString('N'))
function Reset-Services {
    $env:ProgramData=Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $script:Audio=New-FakeService Audiosrv
    $script:Realtek=New-FakeService RtkAudioUniversalService
    $script:Audio.DependentServices=@($script:Realtek)
    $script:StatePath=Join-Path $env:ProgramData 'Cabinet307\AudioControl\stopped-dependents.json'
}
function Invoke-Audio([string]$Action) { & (Get-ClassroomAudioCommand) '307-Student-10' '307-TEACHER' $Action }
function Assert-Failure([scriptblock]$Code,[string]$Message) {$failed=$false;try{& $Code}catch{$failed=$true};Assert $failed $Message}
try {
    $env:COMPUTERNAME='307-Student-10'
    Reset-Services
    Assert ((Invoke-Audio Stop).Status -eq 'AUDIO_STOPPED') 'Realtek plus audio stop succeeds'
    Assert ($script:Audio.Status -eq 'Stopped' -and $script:Realtek.Status -eq 'Stopped') 'Both services stopped'
    Assert (Test-Path $script:StatePath) 'Recovery saved'
    $null=Invoke-Audio Stop
    Assert ($script:Audio.Stops -eq 1 -and $script:Realtek.Stops -eq 1) 'Repeated stop preserves original recovery'
    Assert ((Invoke-Audio Restore).Status -eq 'AUDIO_RUNNING') 'Restore succeeds'
    Assert ($script:Audio.Status -eq 'Running' -and $script:Realtek.Status -eq 'Running') 'Both services restored'
    Assert (-not (Test-Path $script:StatePath)) 'Recovery removed after confirmation'
    $null=Invoke-Audio Restore
    Assert ($script:Audio.Starts -eq 1 -and $script:Realtek.Starts -eq 1) 'Repeated restore is idempotent'
    Reset-Services;$script:Realtek.Status='Stopped'
    $null=Invoke-Audio Stop;$null=Invoke-Audio Restore
    Assert ($script:Realtek.Starts -eq 0) 'Previously stopped Realtek remains stopped'
    Reset-Services;$script:Audio.DependentServices+=New-FakeService Unknown
    Assert-Failure {Invoke-Audio Stop} 'Unknown dependency fails'
    Assert ($script:Audio.Stops -eq 0 -and $script:Realtek.Stops -eq 0) 'Unknown dependency changes nothing'
    Reset-Services;$script:Realtek.DependentServices=@((New-FakeService Other))
    Assert-Failure {Invoke-Audio Stop} 'Nested dependency fails'
    Assert ($script:Audio.Stops -eq 0 -and $script:Realtek.Stops -eq 0) 'Nested dependency changes nothing'
    foreach($stage in 'RealtekStop','AudioStop','RealtekWait') {
        Reset-Services
        switch($stage){RealtekStop{$script:Realtek.FailStop=$true};AudioStop{$script:Audio.FailStop=$true};RealtekWait{$script:Realtek.FailWait=$true}}
        Assert-Failure {Invoke-Audio Stop} "Failure reported: $stage"
        Assert (Test-Path $script:StatePath) 'Failed stop retains recovery'
        $script:Audio.FailStop=$false;$script:Realtek.FailStop=$false;$script:Realtek.FailWait=$false
        $null=Invoke-Audio Restore
        Assert ($script:Realtek.Status -eq 'Running' -and $script:Audio.Status -eq 'Running') 'Partial stop can be restored'
    }
    Reset-Services;$null=Invoke-Audio Stop;$script:Realtek.FailStart=$true
    Assert-Failure {Invoke-Audio Restore} 'Failed companion restore is not success'
    Assert (Test-Path $script:StatePath) 'Failed restore retains recovery'
    $script:Realtek.FailStart=$false;$null=Invoke-Audio Restore
    Assert ($script:Realtek.Status -eq 'Running') 'Restore retry succeeds'
    Reset-Services;$null=Invoke-Audio Stop
    $script:Audio.Status='Running';$script:Realtek.Status='Running'
    $null=Invoke-Audio Restore
    Assert (-not (Test-Path $script:StatePath)) 'Restore after reboot clears stale recovery'
    Reset-Services
    $null=New-Item -ItemType Directory (Split-Path $script:StatePath -Parent) -Force
    '{"Version":1,"Computer":"307-Student-10","Services":["Unrelated"]}' | Set-Content $script:StatePath
    Assert-Failure {Invoke-Audio Restore} 'Recovery cannot start unrelated services'
    Assert ($script:Audio.Starts -eq 0 -and $script:Realtek.Starts -eq 0) 'Invalid recovery changes nothing'
    Reset-Services;$env:COMPUTERNAME='307-TEACHER'
    Assert-Failure {Invoke-Audio Stop} 'Teacher excluded'
    Assert ($script:Audio.Stops -eq 0 -and $script:Realtek.Stops -eq 0) 'Identity checked before service changes'
    Write-Output ("PASS: {0} Realtek audio checks; no real services or remote computers changed." -f $script:Checks)
} finally {$env:COMPUTERNAME=$originalComputer;$env:ProgramData=$originalProgramData}
