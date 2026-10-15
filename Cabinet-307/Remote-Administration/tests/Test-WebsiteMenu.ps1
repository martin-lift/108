# Simulated Task Scheduler, sessions and WinRM. No real task or browser is started.
#Requires -Version 5.1
$ErrorActionPreference='Stop'
$script:Checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:Checks++}
$tokens=$null;$errors=$null
$menu=Join-Path (Split-Path $PSScriptRoot -Parent) 'Teacher-Menu.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($menu,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Menu syntax'
foreach($name in @('Get-ClassroomWebsiteCommand','Open-ClassroomWebsite','Get-ClassroomErrorStatus','Test-WifiLoginError')){
 $function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Set-Item -LiteralPath ('Function:\'+$name) -Value $function.Body.GetScriptBlock()
}
# Preload an in-memory fake so the native console reader is never called by these tests.
Add-Type -TypeDefinition @'
namespace Cabinet307 {
 public class WebsiteConsoleUser { public int SessionId=2; public string UserName="Student"; public string DomainName="307-Student-11"; public bool Active=true; }
 public static class WebsiteConsole {
  public static WebsiteConsoleUser Current; public static WebsiteConsoleUser Next; public static int Reads;
  public static WebsiteConsoleUser Read(){ Reads++; return Reads>1 && Next!=null ? Next : Current; }
 }
}
'@
$oldComputer=$env:COMPUTERNAME
function Reset-Remote([string]$Scenario=''){
 $script:Scenario=$Scenario;$env:COMPUTERNAME='307-Student-11'
 [Cabinet307.WebsiteConsole]::Current=New-Object Cabinet307.WebsiteConsoleUser
 [Cabinet307.WebsiteConsole]::Next=$null;[Cabinet307.WebsiteConsole]::Reads=0
 $script:Registrations=0;$script:Launches=0;$script:Deletes=0;$script:Stops=0
 $script:Action=[pscustomobject]@{Path='';Arguments=''}
 $actions=[pscustomobject]@{}
 $actions|Add-Member ScriptMethod Create {param($Kind) Assert ($Kind -eq 0) 'Exec action only';$script:Action}
 $script:Definition=[pscustomobject]@{RegistrationInfo=[pscustomobject]@{Description=''};Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=1};Settings=[pscustomobject]@{Enabled=$false;AllowDemandStart=$false;StartWhenAvailable=$true;DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true;Hidden=$false;ExecutionTimeLimit=''};Actions=$actions}
 $script:Task=[pscustomobject]@{LastRunTime=[datetime]::Now;LastTaskResult=0;State=3}
 if($Scenario -eq 'TaskFailure'){$script:Task.LastTaskResult=1}
 if($Scenario -eq 'Queued'){$script:Task.State=2}
 if($Scenario -eq 'Running'){$script:Task.State=4}
 $script:Task|Add-Member ScriptMethod RunEx {
  param($Params,$Flags,$Session,$User)
  $script:Launches++
  Assert ($Flags -eq 4 -and $Session -eq 2 -and $null -eq $User) 'Explicit console session; never run as remoting user'
  if($script:Scenario -eq 'RunFailure'){throw 'Run failure'}
 }
 $script:Task|Add-Member ScriptMethod Stop {param($Flags) $script:Stops++}
 $script:Folder=[pscustomobject]@{}
 $script:Folder|Add-Member ScriptMethod RegisterTaskDefinition {
  param($Name,$Definition,$Flags,$User,$Password,$LogonType,$Sddl)
  $script:Registrations++;$script:TaskName=$Name
  Assert ($Name -match '^Cabinet307-OpenWebsite-[a-f0-9]{32}$') 'Unique scoped task name'
  Assert ($Flags -eq 2 -and $null -eq $Password -and $LogonType -eq 3) 'Create only; interactive token; no password'
  Assert ($User -eq 'S-1-5-21-111-222-333-1001' -and $Definition.Principal.UserId -eq $User -and $Definition.Principal.RunLevel -eq 0) 'Least privilege for console SID'
  Assert ($Sddl -eq 'D:P(A;;GA;;;SY)(A;;GA;;;BA)') 'Only SYSTEM/admins can change task definition'
  Assert ($Definition.Settings.Enabled -and $Definition.Settings.AllowDemandStart -and -not $Definition.Settings.StartWhenAvailable) 'Enabled on-demand with no delayed startup'
  Assert ($script:Action.Arguments -like '*-WindowStyle Hidden -EncodedCommand *') 'Launcher console hidden'
  $payload=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($script:Action.Arguments -split ' ')[-1]))
  Assert ($payload -match "Start-Process -FilePath 'https://martin-lift.github.io/108/'" -and $payload -match 'SessionId -ne 2' -and $payload -match 'S-1-5-21-111-222-333-1001') 'Fixed URL and child identity/session checks'
  if($script:Scenario -eq 'RegistrationFailure'){throw 'Registration failure'}
  $script:Task
 }
 $script:Folder|Add-Member ScriptMethod GetTask {param($Name) Assert ($Name -eq $script:TaskName) 'Only own task inspected';$script:Task}
 $script:Folder|Add-Member ScriptMethod DeleteTask {
  param($Name,$Flags)
  Assert ($Name -eq $script:TaskName -and $Flags -eq 0) 'Only own task removed'
  if($script:Scenario -eq 'CleanupFailure'){throw 'Cleanup failure'}
  $script:Deletes++
 }
 $script:Scheduler=[pscustomobject]@{}
 $script:Scheduler|Add-Member ScriptMethod Connect {}
 $script:Scheduler|Add-Member ScriptMethod GetFolder {param($Path) $script:Folder}
 $script:Scheduler|Add-Member ScriptMethod NewTask {param($Flags) $script:Definition}
}
function New-Object {
 param($TypeName,[object[]]$ArgumentList,$ComObject)
 if($ComObject){Assert ($ComObject -eq 'Schedule.Service') 'Only Task Scheduler COM requested';return $script:Scheduler}
 if($TypeName -eq 'Security.Principal.NTAccount'){
  $account=[pscustomobject]@{}
  $account|Add-Member ScriptMethod Translate {param($Type) [pscustomobject]@{Value='S-1-5-21-111-222-333-1001'}}
  return $account
 }
 Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}
function Start-Sleep {param($Milliseconds)}
try {
 $command=Get-ClassroomWebsiteCommand
 Reset-Remote
 $result=&$command '307-Student-11'
 Assert ($result.Status -eq 'LAUNCH_REQUESTED' -and $script:Launches -eq 1 -and $script:Deletes -eq 1) 'One launch and task cleanup'
 Assert ($result.Notes -like '*loading is not verified*') 'Does not claim verified page load'
 Reset-Remote;[Cabinet307.WebsiteConsole]::Current.UserName=''
 $result=&$command '307-Student-11'
 Assert ($result.Status -eq 'NO_USER' -and $script:Registrations -eq 0) 'No task or password fallback without logged-on user'
 Reset-Remote;[Cabinet307.WebsiteConsole]::Current.Active=$false
 Assert ((&$command '307-Student-11').Status -eq 'NO_USER') 'Disconnected console is skipped'
 Reset-Remote
 [Cabinet307.WebsiteConsole]::Next=New-Object Cabinet307.WebsiteConsoleUser
 [Cabinet307.WebsiteConsole]::Next.UserName='OtherStudent'
 $result=&$command '307-Student-11'
 Assert ($result.Status -eq 'SESSION_CHANGED' -and $script:Launches -eq 0 -and $script:Deletes -eq 1) 'User switching cannot launch into another session'
 foreach($scenario in @('RegistrationFailure','RunFailure','TaskFailure','Queued','Running','CleanupFailure')){
  Reset-Remote $scenario
  $result=&$command '307-Student-11'
  $expected=if($scenario -in 'RunFailure','Queued','Running'){'UNKNOWN'}elseif($scenario -eq 'CleanupFailure'){'LAUNCH_REQUESTED'}else{'ERROR'}
  Assert ($result.Status -eq $expected) ('Honest result for '+$scenario)
  if($scenario -eq 'Queued'){Assert ($script:Stops -eq 1) 'Queued launch cannot run at a later login'}
  if($scenario -eq 'Running'){Assert ($script:Stops -eq 0) 'Does not terminate a running browser launcher'}
  if($scenario -eq 'CleanupFailure'){Assert ($result.Notes -like '*cleanup could not be confirmed*') 'Cleanup failure is visible'}
 }
 Reset-Remote;$env:COMPUTERNAME='307-TEACHER';$failed=$false
 try {&$command '307-Student-11'|Out-Null}catch{$failed=$true}
 Assert ($failed -and $script:Registrations -eq 0) 'Wrong host cannot create a task'

 function Reset-Menu([string[]]$Answers){
  $script:Answers=[Collections.Generic.Queue[string]]::new()
  foreach($answer in $Answers){$script:Answers.Enqueue($answer)}
  $script:Opened=@();$script:Closed=@();$script:Called=@();$script:Rows=@();$script:Credentials=0;$script:Failure='';$script:Selected=@(11,12)
 }
 function Read-Host {param($Prompt) if(-not $script:Answers.Count){throw 'Unexpected prompt'};$script:Answers.Dequeue()}
 function Write-Host {param($Object,$ForegroundColor)}
 function Get-StudentNumbers {$script:Selected}
 function Start-Service {param($Name,$ErrorAction)}
 function Get-ClassroomCredential { $script:Credentials++;if($script:Failure -eq 'Cancel'){return};[pscredential]::new('108SU',(ConvertTo-SecureString 'MOCK-ONLY' -AsPlainText -Force)) }
 function New-PSSessionOption {param($OpenTimeout,$OperationTimeout) @{}}
 function New-PSSession {
  param($ComputerName,$Credential,$SessionOption,$ErrorAction)
  $script:Opened+=$ComputerName
  Assert ($Credential.UserName -eq (($ComputerName -replace '\.local$','')+'\108SU')) 'Per-target WinRM credential'
  if($script:Failure -eq 'Login' -and $ComputerName -like '*11.local'){throw 'Access is denied'}
  [pscustomobject]@{Name=$ComputerName}
 }
 function Remove-PSSession {param($Session,$ErrorAction) $script:Closed+=$Session.Name}
 function Invoke-Command {
  param($Session,$ScriptBlock,$ArgumentList,$ErrorAction)
  $script:Called+=$ArgumentList
  if($script:Failure -eq 'Missing'){return}
  if($script:Failure -eq 'Disconnect'){throw [Management.Automation.Remoting.PSRemotingTransportException]::new('Connection lost')}
  [pscustomobject]@{Computer=$ArgumentList[0];Status='LAUNCH_REQUESTED';Url='https://martin-lift.github.io/108/';Notes='Simulated'}
 }
 function Format-Table {param($Property,[switch]$AutoSize,[switch]$Wrap,[Parameter(ValueFromPipeline=$true)]$InputObject) process{$script:Rows+=$InputObject}}
 function Out-Host {param([Parameter(ValueFromPipeline=$true)]$InputObject) process{}}
 foreach($scope in @('A','S')){
  Reset-Menu @($scope);Open-ClassroomWebsite
  $count=if($scope -eq 'A'){27}else{2}
  Assert ($script:Opened.Count -eq $count -and $script:Closed.Count -eq $count -and $script:Credentials -eq 1) 'All/selected with one password and all sessions closed'
 }
 Reset-Menu @('');Open-ClassroomWebsite
 Assert ($script:Credentials -eq 0 -and $script:Opened.Count -eq 0) 'Cancel before credentials'
 Reset-Menu @('S');$script:Selected=@();Open-ClassroomWebsite
 Assert ($script:Credentials -eq 0) 'Cancel selected numbers'
 Reset-Menu @('invalid',' s ');Open-ClassroomWebsite
 Assert ($script:Called.Count -eq 2) 'Invalid scope retried and case normalized'
 foreach($failure in @('Cancel','Login','Missing','Disconnect')){
  Reset-Menu @('S');$script:Failure=$failure;Open-ClassroomWebsite
  if($failure -eq 'Cancel'){Assert ($script:Opened.Count -eq 0) 'Cancelled password makes no connection'}
  elseif($failure -eq 'Login'){Assert ($script:Rows[0].Status -eq 'LOGIN_ERROR' -and $script:Rows[1].Status -eq 'LAUNCH_REQUESTED' -and $script:Closed.Count -eq 1) 'Login error does not stop remaining computers'}
  else{Assert ($script:Rows[0].Status -eq 'UNKNOWN' -and $script:Closed.Count -eq 2) 'Lost or missing confirmation is not reported as success'}
 }
 Microsoft.PowerShell.Utility\Write-Output ("PASS: {0} website checks; no real task, browser or WinRM action." -f $script:Checks)
} finally {$env:COMPUTERNAME=$oldComputer}
