# Manage-Classroom.ps1 — run on teacher PC. Commands can change remote systems!
# Examples:
# .\Manage-Classroom.ps1 -Numbers 24 -ScriptBlock { hostname }
# .\Manage-Classroom.ps1 -All -ScriptBlock { hostname }
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High', DefaultParameterSetName='Selected')]
param(
  [Parameter(ParameterSetName='Selected')]
  [ValidateRange(1,27)][int[]]$Numbers,
  [Parameter(ParameterSetName='All',Mandatory=$true)][switch]$All,
  [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
)
$ErrorActionPreference = 'Stop'
if ($All) { $Numbers = @(1..27) }
elseif (-not $PSBoundParameters.ContainsKey('Numbers')) {
  do {
    $inputNumbers = Read-Host 'Enter student computer numbers (separated by commas or spaces)'
    $parts = @($inputNumbers.Trim() -split '[,\s]+' | Where-Object { $_ })
    $validNumbers = $parts.Count -gt 0
    $selectedNumbers = New-Object 'System.Collections.Generic.List[int]'
    foreach ($part in $parts) {
      $parsedNumber = 0
      if (-not [int]::TryParse($part, [ref]$parsedNumber) -or
          $parsedNumber -lt 1 -or $parsedNumber -gt 27) {
        $validNumbers = $false
        break
      }
      $selectedNumbers.Add($parsedNumber)
    }
    if (-not $validNumbers) { Write-Warning 'Invalid student computer numbers. Please try again.' }
  } until ($validNumbers)
  $Numbers = @($selectedNumbers.ToArray() | Select-Object -Unique)
}
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
