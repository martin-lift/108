# Manage-Classroom.ps1 — run on teacher PC. Commands can change remote systems!
# Examples:
# .\Manage-Classroom.ps1 -Numbers 24 -ScriptBlock { hostname }
# .\Manage-Classroom.ps1 -All -ScriptBlock { hostname }
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High', DefaultParameterSetName='Selected')]
param(
  [Parameter(ParameterSetName='Selected')]
  [ValidateRange(1,27)][int[]]$Numbers,
  [Parameter(ParameterSetName='All',Mandatory=$true)][switch]$All,
  [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
  [object[]]$ArgumentList = @()
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
$current = 0
$report = foreach ($number in $Numbers) {
  $name = '307-Student-{0:D2}' -f $number
  $destination = "$name.local"
  $current++
  Write-Host ("[{0}/{1}] Checking {2}..." -f $current, $Numbers.Count, $destination)
  if (-not $PSCmdlet.ShouldProcess($destination,'Execute supplied remote script block')) {
    Write-Host ("  SKIPPED: {0}" -f $name)
    [pscustomobject]@{ Computer=$name; Status='Skipped'; Output='' }
    continue
  }
  $credential = [pscredential]::new("$name\108SU",$credentialInput.Password)
  try {
    $response = Invoke-Command -ComputerName $destination -Credential $credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    $outputText = ($response | Out-String).Trim()
    Write-Host ("  OK: {0}" -f $name) -ForegroundColor Green
    if ($outputText) { Write-Host $outputText }
    [pscustomobject]@{ Computer=$name; Status='OK'; Output=$outputText }
  } catch {
    Write-Host ("  ERROR: {0}: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
    [pscustomobject]@{ Computer=$name; Status='ERROR'; Output=$_.Exception.Message }
  }
}
Write-Host "Completed. Summary:"
# Return structured results once for display or export.
$report
