# Manage-Classroom.ps1 — run on teacher PC. Commands can change remote systems!
# Examples:
# .\Manage-Classroom.ps1 -Numbers 24 -ScriptBlock { hostname }
# .\Manage-Classroom.ps1 -All -ScriptBlock { hostname }
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [Parameter(ParameterSetName='Selected',Mandatory=$true)]
  [ValidateRange(1,27)][int[]]$Numbers,
  [Parameter(ParameterSetName='All',Mandatory=$true)][switch]$All,
  [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
)
$ErrorActionPreference = 'Stop'
if ($All) { $Numbers = @(1..27) }
$credentialInput = Get-Credential -UserName '108SU' -Message 'Shared LOCAL admin password for classroom'
$report = foreach ($number in $Numbers) {
  $name = '307-Student-{0:D2}' -f $number
  $destination = "$name.local"
  if (-not $PSCmdlet.ShouldProcess($destination,'Execute supplied remote script block')) {
    [pscustomobject]@{ Computer=$name; Status='Skipped'; Output='' }
    continue
  }
  $credential = [pscredential]::new("$name\108SU",$credentialInput.Password)
  try {
    $response = Invoke-Command -ComputerName $destination -Credential $credential -ScriptBlock $ScriptBlock -ErrorAction Stop
    [pscustomobject]@{ Computer=$name; Status='OK'; Output=($response | Out-String).Trim() }
  } catch {
    [pscustomobject]@{ Computer=$name; Status='ERROR'; Output=$_.Exception.Message }
  }
}
$report | Format-Table -AutoSize -Wrap
# Keep report available to callers in addition to the console display.
$report
