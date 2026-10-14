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
  $session = $null
  $phase = 'Login'
  try {
    $session = New-PSSession -ComputerName $destination -Credential $credential -ErrorAction Stop
    $phase = 'Operation'
    $response = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    $outputText = ($response | Out-String).Trim()
    Write-Host ("  OK: {0}" -f $name) -ForegroundColor Green
    if ($outputText) { Write-Host $outputText }
    [pscustomobject]@{ Computer=$name; Status='OK'; Output=$outputText }
  } catch {
    $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
    Write-Host ("  {0}: {1}: {2}" -f $status, $name, $_.Exception.Message) -ForegroundColor Red
    [pscustomobject]@{ Computer=$name; Status=$status; Output=$_.Exception.Message }
  } finally {
    if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
  }
}
Write-Host "Completed. Summary:"
# Return structured results once for display or export.
$report
