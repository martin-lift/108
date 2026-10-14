# Test-Student.ps1 - run on teacher PC. Read-only diagnostics.
[CmdletBinding()]
param(
  [ValidateRange(1,27)][int]$Number,
  [ValidateRange(1,60)][int]$NetworkTimeoutSeconds = 5,
  [ValidateRange(1,120)][int]$OpenTimeoutSeconds = 15
)
function Test-WifiLoginError {
    param([System.Management.Automation.ErrorRecord]$Record)
    # Used only for errors while opening the session, never for a remote read error.
    $exception = $Record.Exception
    while ($null -ne $exception) {
        foreach ($property in @('ErrorCode','HResult')) {
            if ($exception.PSObject.Properties[$property]) {
                $code = [int64]$exception.$property -band 4294967295L
                if ($code -in 5,1326,1909,1331,1330,1385,2147942405L,2147943726L,2147944309L,2147943731L,2147943730L,2147943785L,2148074252L) { return $true }
            }
        }
        $exception = $exception.InnerException
    }
    if ($Record.FullyQualifiedErrorId -match 'AccessDenied|LogonFailure|AuthenticationFailed|InvalidCredential') { return $true }
    $Record.Exception.Message -match 'Access is denied|user name or password is incorrect|logon failure|authentication failed|account.*(locked|disabled)|\u041e\u0442\u043a\u0430\u0437\u0430\u043d \u0434\u043e\u0441\u0442\u044a\u043f|\u0414\u043e\u0441\u0442\u044a\u043f\u044a\u0442 \u0435 \u043e\u0442\u043a\u0430\u0437\u0430\u043d|\u043d\u0435\u043f\u0440\u0430\u0432\u0438\u043b\u043d\u0430.*\u043f\u0430\u0440\u043e\u043b\u0430'
}
function Get-ClassroomErrorStatus {
    param([System.Management.Automation.ErrorRecord]$Record, [string]$Phase)
    if ($Phase -eq 'Login') {
        if (Test-WifiLoginError -Record $Record) { return 'LOGIN_ERROR' }
        $message = $Record.Exception.Message
        $exception = $Record.Exception
        while ($null -ne $exception) {
            if ($exception -is [Net.Sockets.SocketException]) {
                if ($exception.SocketErrorCode -in 'HostNotFound','NoData','TryAgain') { return 'NAME_ERROR' }
                if ($exception.SocketErrorCode -in 'TimedOut','ConnectionRefused','NetworkUnreachable','HostUnreachable','ConnectionReset') { return 'CONNECTION_ERROR' }
            }
            $exception = $exception.InnerException
        }
        if ($message -match 'name cannot be resolved|could not be resolved|No such host|host.*not found|Name resolution|DNS.*(fail|error)|resolve.*(fail|error)') { return 'NAME_ERROR' }
        if ($message -match 'timed out|timeout|cannot connect|could not connect|connection.*(failed|refused|closed)|unreachable|WinRM cannot complete the operation|client cannot connect') { return 'CONNECTION_ERROR' }
        return 'ERROR'
    }
    if ($Phase -eq 'Operation') { return 'OPERATION_ERROR' }
    'ERROR'
}
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
  $phase = 'Operation'
  if ($step -eq 2 -or $step -eq 3 -or $step -eq 5) { $phase = 'Login' }
  if ($step -eq 1) { $phase = 'Local' }
  $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
  Show-Result $status $_.Exception.Message
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
