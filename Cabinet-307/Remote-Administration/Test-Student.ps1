# Test-Student.ps1 - run on teacher PC. Read-only diagnostics.
[CmdletBinding()]
param(
  [ValidateRange(1,27)][int]$Number,
  [ValidateRange(1,60)][int]$NetworkTimeoutSeconds = 5,
  [ValidateRange(1,120)][int]$OpenTimeoutSeconds = 15
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('Number')) {
  do {
    $inputNumber = Read-Host 'Enter student computer number'
    $parsedNumber = 0
    $validNumber = [int]::TryParse($inputNumber, [ref]$parsedNumber) -and
      $parsedNumber -ge 1 -and $parsedNumber -le 27
    if (-not $validNumber) { Write-Warning 'Invalid student computer number. Please try again.' }
  } until ($validNumber)
  $Number = $parsedNumber
}
$name = '307-Student-{0:D2}' -f $Number
$destination = "$name.local"
$step = 0
$session = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
function Start-Step([int]$Number, [string]$Description) {
  Set-Variable -Name step -Value $Number -Scope 1
  $timer.Restart()
  Write-Host ("[{0}/7] START: {1}" -f $Number, $Description)
}
function Show-Result([string]$Status, [string]$Message) {
  Write-Host ("[{0}/7] {1}: {2} ({3:N1}s)" -f $step, $Status, $Message, $timer.Elapsed.TotalSeconds)
}
Write-Host "Target: $destination. No configuration changes will be made."
try {
  Start-Step 1 'Check local WinRM client and TrustedHosts'
  $service = Get-Service WinRM
  Write-Host ("  Local WinRM: {0}" -f $service.Status)
  $trusted = [string](Get-Item WSMan:\localhost\Client\TrustedHosts).Value
  $entries = @($trusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $matching = @($entries | Where-Object { $destination -like $_ })
  Write-Host ("  Matching TrustedHosts entries: {0}" -f ($matching -join ', '))
  if ($service.Status -ne 'Running') { throw 'Local WinRM is not running. Run Setup-Teacher.ps1 as administrator.' }
  if (-not $matching.Count) { throw 'The destination is not in TrustedHosts. Run Setup-Teacher.ps1 as administrator.' }
  Show-Result 'PASS' 'Local client prerequisites are present; TrustedHosts does not authenticate the remote host.'

  Start-Step 2 'Resolve the destination name'
  $lookup = [Net.Dns]::GetHostAddressesAsync($destination)
  if (-not $lookup.Wait($NetworkTimeoutSeconds * 1000)) { throw 'Name resolution timed out.' }
  $addresses = @($lookup.Result)
  if (-not $addresses.Count) { throw 'Name resolution returned no addresses.' }
  foreach ($address in $addresses) { Write-Host ("  Resolved address: {0}" -f $address) }
  Show-Result 'PASS' 'Compare these addresses with the student computer if the wrong host is suspected.'

  Start-Step 3 'Check TCP port 5985 on the resolved addresses'
  $reachable = 0
  foreach ($address in $addresses) {
    $client = New-Object Net.Sockets.TcpClient($address.AddressFamily)
    $pending = $null
    try {
      $pending = $client.BeginConnect($address, 5985, $null, $null)
      if (-not $pending.AsyncWaitHandle.WaitOne($NetworkTimeoutSeconds * 1000)) {
        throw 'TCP connection timed out.'
      }
      $client.EndConnect($pending)
      $reachable++
      Write-Host ("  PASS: {0}:5985; source: {1}" -f $address, $client.Client.LocalEndPoint)
    } catch {
      Write-Host ("  FAIL: {0}:5985 - {1}" -f $address, $_.Exception.Message)
    } finally {
      $client.Close()
      if ($null -ne $pending) { $pending.AsyncWaitHandle.Close() }
    }
  }
  if (-not $reachable) { throw 'Port 5985 is unreachable on all resolved addresses. Check the student PC, network and firewall.' }
  Show-Result 'PASS' 'At least one address accepts TCP; this alone does not prove WinRM works.'

  Start-Step 4 'Query WinRM without credentials (this may take longer)'
  try {
    $wsman = Test-WSMan -ComputerName $destination -ErrorAction Stop
    Write-Host ("  Protocol: {0}; Product: {1}" -f $wsman.ProtocolVersion, $wsman.ProductVersion)
    Show-Result 'PASS' 'The WinRM identification endpoint responded.'
  } catch {
    Show-Result 'WARN' 'The unauthenticated WinRM query failed; the authenticated session will still be checked.'
    Write-Warning $_.Exception.Message
  }

  Start-Step 5 'Request credentials and open a PowerShell session'
  $credential = Get-Credential -UserName "$name\108SU" -Message "Local administrator of $name"
  if ($null -eq $credential) { throw 'Credential entry was cancelled.' }
  $options = New-PSSessionOption -OpenTimeout ($OpenTimeoutSeconds * 1000)
  $session = New-PSSession -ComputerName $destination -Credential $credential -Authentication Negotiate -SessionOption $options -ErrorAction Stop
  Show-Result 'PASS' 'Authenticated PowerShell session opened.'

  Start-Step 6 'Verify the remote computer name and account'
  $identity = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Identity = (whoami) }
  }
  Write-Host ("  Computer: {0}; Identity: {1}" -f $identity.Computer, $identity.Identity)
  if ($identity.Computer -ine $name) { throw "Unexpected remote host: $($identity.Computer). Expected: $name." }
  Show-Result 'PASS' 'The remote computer reports the expected name.'

  Start-Step 7 'Read remote WinRM service and UAC policy'
  $details = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $properties = Get-ItemProperty -Path $reg
    $policy = $properties.PSObject.Properties['LocalAccountTokenFilterPolicy']
    [pscustomobject]@{
      WinRM = (Get-Service WinRM).Status.ToString()
      LocalAccountTokenFilterPolicy = if ($policy) { $policy.Value } else { 0 }
      PolicyValuePresent = ($null -ne $policy)
    }
  }
  $details | Format-List WinRM,LocalAccountTokenFilterPolicy,PolicyValuePresent | Out-Host
  Show-Result 'PASS' 'Remote configuration was read successfully.'
  Write-Host "SUCCESS: remote execution on $destination"
} catch {
  Show-Result 'FAIL' $_.Exception.Message
  for ($remaining = $step + 1; $remaining -le 7; $remaining++) {
    Write-Host ("[{0}/7] SKIPPED: a required earlier step failed." -f $remaining)
  }
  throw
} finally {
  if ($null -ne $session) {
    try { Remove-PSSession -Session $session -ErrorAction Stop }
    catch { Write-Warning 'Unable to close the diagnostic PowerShell session.' }
  }
  $credential = $null
}
