# Test-Student.ps1 — run on teacher PC. Read-only remote verification.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateRange(1,27)][int]$Number)
$ErrorActionPreference = 'Stop'
$name = '307-Student-{0:D2}' -f $Number
$destination = "$name.local"
$test = Test-NetConnection -ComputerName $destination -Port 5985 -WarningAction SilentlyContinue
if (-not $test.TcpTestSucceeded) { throw "Port 5985 is not reachable: $destination" }
$credential = Get-Credential -UserName "$name\108SU" -Message "Administrator of $name"
$result = Invoke-Command -ComputerName $destination -Credential $credential -ErrorAction Stop -ScriptBlock {
  $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  [pscustomobject]@{
    Computer = $env:COMPUTERNAME
    Identity = (whoami)
    WinRM = (Get-Service WinRM).Status.ToString()
    LocalAccountTokenFilterPolicy = Get-ItemPropertyValue -Path $reg -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
  }
}
$result | Select-Object Computer,Identity,WinRM,LocalAccountTokenFilterPolicy | Format-List
if ($result.Computer -ine $name) { throw "Unexpected remote host: $($result.Computer)" }
Write-Host "SUCCESS: remote execution on $destination"
