#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) -ErrorAction Stop
    } catch {
        Write-Host 'Administrator permission was not granted.'
        Read-Host 'Press Enter to close' | Out-Null
    }
    exit
}
Set-Location -LiteralPath $PSScriptRoot
$manager = Join-Path $PSScriptRoot 'Manage-Classroom.ps1'
if (-not (Test-Path -LiteralPath $manager)) {
    Write-Host 'Manage-Classroom.ps1 is missing. Place it in the same folder.'
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
$credentialHelper = Join-Path $PSScriptRoot 'Credential-Helper.ps1'
if (-not (Test-Path -LiteralPath $credentialHelper -PathType Leaf)) {
    throw 'Credential-Helper.ps1 is missing. Download it into the same folder as this script.'
}
. $credentialHelper

function Get-StudentNumber {
    while ($true) {
        $answer = Read-Host 'Student computer number (1-27; Enter = cancel)'
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le 27) { return $number }
        Write-Host 'Enter a number from 1 to 27.'
    }
}
function Get-StudentNumbers {
    while ($true) {
        $answer = Read-Host 'Student computer numbers (1-27; separated by commas or spaces; Enter = cancel)'
        if ([string]::IsNullOrWhiteSpace($answer)) { return }
        $parts = @($answer.Trim() -split '[,\s]+' | Where-Object { $_ })
        $valid = $parts.Count -gt 0
        $numbers = New-Object 'System.Collections.Generic.List[int]'
        foreach ($part in $parts) {
            $number = 0
            if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 1 -or $number -gt 27) {
                $valid = $false
                break
            }
            if (-not $numbers.Contains($number)) { $numbers.Add($number) }
        }
        if ($valid) { return $numbers.ToArray() }
        Write-Host 'Enter numbers from 1 to 27, separated by commas or spaces (for example: 1, 3, 5).'
    }
}
function Test-ClassroomComputers {
    Start-Service WinRM -ErrorAction Stop
    $credentialInput = Get-ClassroomCredential
    if ($null -eq $credentialInput) { return }
    $failures = @()
    $sessionOption = New-PSSessionOption -OpenTimeout 15000
    foreach ($number in 1..27) {
        $name = '307-Student-{0:D2}' -f $number
        $destination = "$name.local"
        Write-Host ("[{0}/27] Checking {1}... " -f $number, $destination) -NoNewline
        $session = $null
        $phase = 'Login'
        try {
            $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
            $session = New-PSSession -ComputerName $destination -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
            $phase = 'Operation'
            $phase = 'Operation'
        $actualName = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ([string]$actualName -ine $name) { throw "Unexpected remote computer name: $actualName (expected $name)." }
            Write-Host 'OK' -ForegroundColor Green
        } catch {
            $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
            Write-Host $status -ForegroundColor Red
            $reason = ($_.Exception.Message -replace '\s+', ' ').Trim()
            $failures += [pscustomobject]@{ Computer = $name; Status = $status; Reason = $reason }
        } finally {
            if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }
    if ($failures.Count -gt 0) {
        Write-Host ''
        $failures | Format-Table Computer, Status, Reason -AutoSize -Wrap | Out-Host
    }
}
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
function Set-AllClassroomWifi {
    Start-Service WinRM -ErrorAction Stop
    $ssid = Read-Host 'Exact school Wi-Fi name (Enter = Students)'
    if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'Students' }
    if ($ssid.Contains('"') -or $ssid.Contains("`r") -or $ssid.Contains("`n")) { throw 'Invalid network name.' }
    $credentialInput = Get-ClassroomCredential
    if ($null -eq $credentialInput) { return }
    $failures = @()
    $sessionOption = New-PSSessionOption -OpenTimeout 15000
    $command = {
        param([string]$AllowedSSID, [string]$ExpectedName)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $ExpectedName) { throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)." }
        $details = netsh wlan add filter permission=allow "ssid=$AllowedSSID" networktype=infrastructure 2>&1
        if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Allow filter failed; no deny filters were added. " + ($details | Out-String).Trim()) }
        $details = netsh wlan add filter permission=denyall networktype=infrastructure 2>&1
        if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Infrastructure restriction failed; the Allow filter may already be active. " + ($details | Out-String).Trim()) }
        $details = netsh wlan add filter permission=denyall networktype=adhoc 2>&1
        if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Ad hoc restriction failed; infrastructure restriction may already be active. " + ($details | Out-String).Trim()) }
    }
    foreach ($number in 1..27) {
        $name = '307-Student-{0:D2}' -f $number
        $destination = "$name.local"
        Write-Host ("[{0}/27] Restricting {1}... " -f $number, $destination) -NoNewline
        $session = $null
        $phase = 'Login'
        try {
            $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
            $session = New-PSSession -ComputerName $destination -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
            $phase = 'Operation'
            Invoke-Command -Session $session -ScriptBlock $command -ArgumentList $ssid, $name -ErrorAction Stop | Out-Null
            Write-Host 'OK' -ForegroundColor Green
        } catch {
            $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
            Write-Host $status -ForegroundColor Red
            $failures += [pscustomobject]@{ Computer = $name; Status = $status; Reason = ($_.Exception.Message -replace '\s+', ' ').Trim() }
        } finally {
            if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }
    if ($failures.Count -gt 0) {
        Write-Host ''
        $failures | Format-Table Computer, Status, Reason -AutoSize -Wrap | Out-Host
    }
}
function Remove-ClassroomWifiRestrictions {
    param([switch]$All)
    if ($All) {
        $numbers = @(1..27)
    } else {
        $numbers = @(Get-StudentNumbers)
        if ($numbers.Count -eq 0) { return }
    }
    Start-Service WinRM -ErrorAction Stop
    $credentialInput = Get-ClassroomCredential
    if ($null -eq $credentialInput) { return }
    $failures = @()
    $sessionOption = New-PSSessionOption -OpenTimeout 15000
    $command = {
        param([string]$ExpectedName)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $ExpectedName) { throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)." }
        $infrastructureDetails = netsh wlan delete filter permission=denyall networktype=infrastructure 2>&1
        $infrastructureResult = $LASTEXITCODE
        $adhocDetails = netsh wlan delete filter permission=denyall networktype=adhoc 2>&1
        $adhocResult = $LASTEXITCODE
        if ($infrastructureResult -ne 0 -or $adhocResult -ne 0) {
            throw ("Some deny-all filters could not be removed or were not present. Infrastructure: " + ($infrastructureDetails | Out-String).Trim() + " Ad hoc: " + ($adhocDetails | Out-String).Trim())
        }
    }
    $current = 0
    foreach ($number in $numbers) {
        $current++
        $name = '307-Student-{0:D2}' -f $number
        $destination = "$name.local"
        Write-Host ("[{0}/{1}] Removing restrictions on {2}... " -f $current, $numbers.Count, $destination) -NoNewline
        $session = $null
        $phase = 'Login'
        try {
            $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
            $session = New-PSSession -ComputerName $destination -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
            $phase = 'Operation'
            Invoke-Command -Session $session -ScriptBlock $command -ArgumentList $name -ErrorAction Stop | Out-Null
            Write-Host 'OK' -ForegroundColor Green
        } catch {
            $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
            Write-Host $status -ForegroundColor Red
            $failures += [pscustomobject]@{ Computer = $name; Status = $status; Reason = ($_.Exception.Message -replace '\s+', ' ').Trim() }
        } finally {
            if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }
    if ($failures.Count -gt 0) {
        Write-Host ''
        $failures | Format-Table Computer, Status, Reason -AutoSize -Wrap | Out-Host
    }
}
function Get-ClassroomPowerJobResult {
    param($Item, [string]$Action, [switch]$Expired)
    $receiveErrors = @()
    try {
        $response = @(Receive-Job -Job $Item.Job -ErrorAction SilentlyContinue -ErrorVariable receiveErrors)
    } catch {
        return [pscustomobject]@{ Computer=$Item.Name; Status='UNKNOWN'; Reason=("Unable to read the {0} confirmation. Check the computer before retrying. {1}" -f $Action.ToLowerInvariant(), $_.Exception.Message) }
    }
    $messages = @($response | Where-Object { $_.Computer -ceq $Item.Name -and $_.Action -ceq $Action })
    $accepted = @($messages | Where-Object { $_.Kind -ceq 'Accepted' })
    $rejected = @($messages | Where-Object { $_.Kind -ceq 'Rejected' })
    $verified = @($messages | Where-Object { $_.Kind -ceq 'Verified' })
    if ($accepted.Count -eq 1) {
        return [pscustomobject]@{ Computer=$Item.Name; Status='REQUESTED'; Reason='Windows accepted the request.' }
    }
    if ($rejected.Count -gt 0) {
        return [pscustomobject]@{ Computer=$Item.Name; Status='OPERATION_ERROR'; Reason=($rejected[0].Reason -replace '\s+', ' ').Trim() }
    }
    if (-not $Expired -and $verified.Count -eq 0 -and $receiveErrors.Count -gt 0) {
        $record = $receiveErrors[0]
        $status = Get-ClassroomErrorStatus -Record $record -Phase 'Login'
        $reason = ($record.Exception.Message -replace '\s+', ' ').Trim()
        if ($status -in 'NAME_ERROR','LOGIN_ERROR') {
            return [pscustomobject]@{ Computer=$Item.Name; Status=$status; Reason=$reason }
        }
        # A lost connection can also mean the requested power action has already begun.
        return [pscustomobject]@{ Computer=$Item.Name; Status='UNKNOWN'; Reason=("No reliable power-action confirmation was received. Check the computer before retrying. " + $reason) }
    }
    $reason = if ($Expired) { 'No confirmation arrived within the shared 10-second wait.' } else { 'The remote command ended without confirming acceptance.' }
    [pscustomobject]@{ Computer=$Item.Name; Status='UNKNOWN'; Reason=("$reason The computer may already be processing the request; check it before retrying.") }
}
function Write-ClassroomPowerResult {
    param($Result, [int]$Position, [int]$Total)
    $color = if ($Result.Status -eq 'REQUESTED') { 'Green' } elseif ($Result.Status -eq 'UNKNOWN') { 'Yellow' } else { 'Red' }
    Write-Host ("[{0}/{1}] {2}... {3}" -f $Position, $Total, $Result.Computer, $Result.Status) -ForegroundColor $color
}
function Invoke-ClassroomPowerAction {
    param([Parameter(Mandatory=$true)][ValidateSet('Restart','Shutdown')][string]$Action)
    $verb = if ($Action -eq 'Restart') { 'restart' } else { 'shut down' }
    while ($true) {
        $choice = Read-Host ("Do you want to {0} all student computers? (A = all, S = selected, Enter = cancel)" -f $verb)
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        $choice = $choice.Trim().ToUpperInvariant()
        if ($choice -eq 'A') { $numbers = @(1..27); break }
        if ($choice -eq 'S') {
            $numbers = @(Get-StudentNumbers)
            if ($numbers.Count -eq 0) { return }
            break
        }
        Write-Host 'Enter A for all computers, S to select computers, or press Enter to cancel.'
    }
    Write-Host ("{0} targets: {1}" -f $Action, ($numbers -join ', '))
    Write-Host ("Save student work before continuing. Open applications may delay or block {0}." -f $Action.ToLowerInvariant())
    Start-Service WinRM -ErrorAction Stop
    $credentialInput = Get-ClassroomCredential
    if ($null -eq $credentialInput) { return }
    $sessionOption = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 10000
    $teacherName = $env:COMPUTERNAME
    $command = {
        param([string]$ExpectedName, [string]$TeacherName, [ValidateSet('Restart','Shutdown')][string]$Action)
        $ErrorActionPreference = 'Stop'
        try {
            if ($env:COMPUTERNAME -ieq $TeacherName) { throw 'Refusing to restart or shut down the teacher computer.' }
            if ($env:COMPUTERNAME -ine $ExpectedName) {
                throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName). No power action was requested."
            }
            [pscustomobject]@{ Kind='Verified'; Computer=$ExpectedName; Action=$Action }
            $operation = if ($Action -eq 'Restart') { '/r' } else { '/s' }
            # A positive /t implicitly forces applications to close; use /t 0 without /f.
            $details = & "$env:SystemRoot\System32\shutdown.exe" $operation /t 0 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("Windows rejected the {0} request (exit code {1}): {2}" -f $Action.ToLowerInvariant(), $LASTEXITCODE, ($details | Out-String).Trim())
            }
            [pscustomobject]@{ Kind='Accepted'; Computer=$ExpectedName; Action=$Action }
        } catch {
            [pscustomobject]@{ Kind='Rejected'; Computer=$ExpectedName; Action=$Action; Reason=$_.Exception.Message }
        }
    }
    $submitted = New-Object 'System.Collections.Generic.List[object]'
    $report = New-Object 'System.Collections.Generic.List[object]'
    Write-Host ("Sending {0} requests in parallel..." -f $Action.ToLowerInvariant())
    try {
        foreach ($number in $numbers) {
            $name = '307-Student-{0:D2}' -f $number
            try {
                $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
                # AsJob opens each connection in the background; no per-target wait here.
                $job = Invoke-Command -ComputerName "$name.local" -Credential $credential -SessionOption $sessionOption -ScriptBlock $command -ArgumentList $name, $teacherName, $Action -AsJob -ErrorAction Stop
                $submitted.Add([pscustomobject]@{ Name=$name; Job=$job })
            } catch {
                $row = [pscustomobject]@{ Computer=$name; Status=(Get-ClassroomErrorStatus -Record $_ -Phase 'Login'); Reason=($_.Exception.Message -replace '\s+', ' ').Trim() }
                $report.Add($row)
                Write-ClassroomPowerResult -Result $row -Position $report.Count -Total $numbers.Count
            }
        }
        $pending = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $submitted) { $pending.Add($item) }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0 -and $timer.Elapsed.TotalSeconds -lt 10) {
            foreach ($item in @($pending.ToArray())) {
                if ($item.Job.State -in 'Completed','Failed','Stopped') {
                    $row = Get-ClassroomPowerJobResult -Item $item -Action $Action
                    $report.Add($row)
                    Write-ClassroomPowerResult -Result $row -Position $report.Count -Total $numbers.Count
                    $null = $pending.Remove($item)
                }
            }
            if ($pending.Count -gt 0 -and $timer.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
        }
        foreach ($item in $pending) {
            $expired = $item.Job.State -notin 'Completed','Failed','Stopped'
            $row = Get-ClassroomPowerJobResult -Item $item -Action $Action -Expired:$expired
            $report.Add($row)
            Write-ClassroomPowerResult -Result $row -Position $report.Count -Total $numbers.Count
        }
    } finally {
        $jobs = @($submitted | ForEach-Object { $_.Job })
        $activeJobs = @($jobs | Where-Object { $_.State -notin 'Completed','Failed','Stopped' })
        if ($activeJobs.Count -gt 0) { Stop-Job -Job $activeJobs -ErrorAction SilentlyContinue }
        if ($jobs.Count -gt 0) { Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue }
    }
    $acceptedCount = @($report | Where-Object { $_.Status -eq 'REQUESTED' }).Count
    Write-Host ("{0} requests accepted: {1}/{2}." -f $Action, $acceptedCount, $numbers.Count)
    Write-Host 'REQUESTED means Windows accepted the request; it does not confirm that the computer has finished restarting or shutting down.'
    $problems = @($report | Where-Object { $_.Status -ne 'REQUESTED' })
    if ($problems.Count -gt 0) {
        $problems | Format-Table Computer, Status, Reason -AutoSize -Wrap | Out-Host
    }
}
function Copy-ClassroomFile {
    param([ValidateSet('Send','Receive')][string]$Direction)
    $number = Get-StudentNumber
    if ($null -eq $number) { return }
    $name = '307-Student-{0:D2}' -f $number
    $source = (Read-Host 'Full source file path (Enter = cancel)').Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($source)) { return }
    if ($source -notmatch '^[A-Za-z]:\\') { throw 'Enter an absolute Windows file path, such as C:\307\task.pdf.' }
    $fileName = [IO.Path]::GetFileName($source)
    if (-not $fileName) { throw 'Specify a file, not a folder.' }
    if ($Direction -eq 'Send') {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'The source file does not exist on the teacher computer.' }
        $defaultDestination = 'C:\Users\Public\Desktop\' + $fileName
    } else {
        $defaultDestination = Join-Path $PSScriptRoot ($name + '-' + $fileName)
    }
    Write-Host ("Default destination: {0}" -f $defaultDestination)
    $destination = (Read-Host 'Destination folder or full file path (Enter = default)').Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($destination)) { $destination = $defaultDestination }
    if ($destination -notmatch '^[A-Za-z]:\\') {
        throw 'Specify an absolute destination folder or file path.'
    }
    Write-Host ("{0}: {1} -> {2} ({3})" -f $Direction, $source, $destination, $name)
    Start-Service WinRM -ErrorAction Stop
    $credential = Get-ClassroomCredential -UserName "$name\108SU"
    if ($null -eq $credential) { return }
    $session = $null
    $inspectFile = {
        param([string]$Path)
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Source file not found: $Path" }
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    $inspectDestination = {
        param([string]$Path, [string]$SourceFileName)
        $ErrorActionPreference = 'Stop'
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $Path = Join-Path -Path $Path -ChildPath $SourceFileName
        }
        $parent = [IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Destination folder does not exist: $parent" }
        if (Test-Path -LiteralPath $Path -PathType Container) { throw 'A subfolder has the same name as the source file. Choose another destination.' }
        [pscustomobject]@{ Path = $Path; Exists = (Test-Path -LiteralPath $Path) }
    }
    $phase = 'Login'
    try {
        Write-Host ("Connecting to {0}..." -f $name)
        $session = New-PSSession -ComputerName "$name.local" -Credential $credential -SessionOption (New-PSSessionOption -OpenTimeout 15000) -ErrorAction Stop
        $actualName = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME }
        if ($actualName -ine $name) { throw "Unexpected remote computer: $actualName" }
        if ($Direction -eq 'Send') {
            $sourceHash = & $inspectFile $source
            $destinationInfo = Invoke-Command -Session $session -ScriptBlock $inspectDestination -ArgumentList $destination, $fileName
        } else {
            $sourceHash = Invoke-Command -Session $session -ScriptBlock $inspectFile -ArgumentList $source
            $destinationInfo = & $inspectDestination $destination $fileName
        }
        $destination = $destinationInfo.Path
        Write-Host ("Destination file: {0}" -f $destination)
        if ($destinationInfo.Exists -and (Read-Host 'Destination file already exists. Type REPLACE to overwrite it') -cne 'REPLACE') {
            Write-Host 'Copy cancelled. The existing file was not replaced.'
            return
        }
        Write-Host 'Copying file...'
        if ($Direction -eq 'Send') {
            Copy-Item -LiteralPath $source -Destination $destination -ToSession $session -ErrorAction Stop
            $destinationHash = Invoke-Command -Session $session -ScriptBlock $inspectFile -ArgumentList $destination
        } else {
            Copy-Item -LiteralPath $source -Destination $destination -FromSession $session -ErrorAction Stop
            $destinationHash = & $inspectFile $destination
        }
        if ($sourceHash -ne $destinationHash) { throw 'File verification failed. The destination content differs from the source.' }
        Write-Host ("SUCCESS: File copied and verified: {0}" -f $destination) -ForegroundColor Green
    } catch {
        $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
        Write-Host ("{0}: {1}: {2}" -f $status, $name, $_.Exception.Message) -ForegroundColor Red
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
}
function ConvertFrom-ClassroomProcessFilter {
    param([string]$Json)
    $config = $Json | ConvertFrom-Json -ErrorAction Stop
    if ($config.SchemaVersion -ne 1 -or $null -eq $config.UninterestingProcesses -or
        $config.UninterestingProcesses -isnot [array] -or [string]::IsNullOrWhiteSpace([string]$config.Revision)) {
        throw 'Unsupported or incomplete process filter.'
    }
    $names = @{}
    foreach ($entry in $config.UninterestingProcesses) {
        if ($entry.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Name) -or
            $entry.Name.Length -gt 260 -or $entry.Name -match '[\x00-\x1f*?\[\]\\/]' -or
            $entry.Name -cne $entry.Name.Trim() -or $names.ContainsKey($entry.Name)) {
            throw 'The process filter contains an invalid or duplicate exact name.'
        }
        $names[$entry.Name] = $true
    }
    [pscustomobject]@{ Names = $names; Revision = [string]$config.Revision; Source = '' }
}
function Get-ClassroomProcessFilter {
    $cachePath = Join-Path $PSScriptRoot 'Uninteresting-Processes.json'
    $url = 'https://raw.githubusercontent.com/martin-lift/108/main/Cabinet-307/Remote-Administration/Uninteresting-Processes.json'
    try {
        # Only JSON data is downloaded. No downloaded scripts or expressions are executed.
        $download = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $filter = ConvertFrom-ClassroomProcessFilter -Json ([string]$download.Content)
        $filter.Source = 'GitHub'
        try {
            [string]$download.Content | Set-Content -LiteralPath $cachePath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host 'FILTER_WARNING: The current GitHub filter is in use, but its local cache could not be saved.' -ForegroundColor Yellow
        }
        return $filter
    } catch {
        Write-Host 'FILTER_WARNING: The current GitHub filter could not be downloaded or validated. Trying the local copy.' -ForegroundColor Yellow
    }
    try {
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $filter = ConvertFrom-ClassroomProcessFilter -Json (Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop)
            $filter.Source = 'Local copy (GitHub unavailable)'
            return $filter
        }
    } catch {
        Write-Host 'FILTER_WARNING: The local process filter is invalid or unreadable.' -ForegroundColor Yellow
    }
    Write-Host 'FILTER_WARNING: No usable filter is available. All processes will be included in this report.' -ForegroundColor Yellow
    [pscustomobject]@{ Names = @{}; Revision = 'none'; Source = 'None - complete inventory' }
}
function Show-ClassroomProcesses {
    $number = Get-StudentNumber
    if ($null -eq $number) { return }
    $name = '307-Student-{0:D2}' -f $number
    Start-Service WinRM -ErrorAction Stop
    $credential = Get-ClassroomCredential -UserName "$name\108SU"
    if ($null -eq $credential) { return }
    $session = $null
    $phase = 'Login'
    $readProcesses = {
        param([string]$ExpectedName)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $ExpectedName) {
            throw "Unexpected remote computer: $env:COMPUTERNAME (expected $ExpectedName)."
        }
        $capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        # Capture every PID before reading optional file metadata. Do not collect command lines.
        $processes = @(Get-CimInstance -ClassName Win32_Process -Property Name,ProcessId,ParentProcessId,SessionId,ExecutablePath,CreationDate -ErrorAction Stop)
        if ($processes.Count -eq 0) { throw 'Windows returned an empty process inventory.' }
        $parentNames = @{}
        foreach ($item in $processes) { $parentNames[[uint32]$item.ProcessId] = $item }
        $fileDetails = @{}
        foreach ($process in $processes) {
            $path = [string]$process.ExecutablePath
            $description = ''
            $company = ''
            $metadataStatus = 'Path unavailable (protected process or insufficient access)'
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                if (-not $fileDetails.ContainsKey($path)) {
                    $details = [pscustomobject]@{ Description = ''; Company = ''; Status = 'Metadata unavailable' }
                    if ($path -match '^[A-Za-z]:\\') {
                        try {
                            $version = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo
                            $details.Description = [string]$version.FileDescription
                            $details.Company = [string]$version.CompanyName
                            $details.Status = if ($details.Description -or $details.Company) { 'Read from file (not signature-verified)' } else { 'File has no description/company metadata' }
                        } catch {
                            $details.Status = 'File metadata unavailable (access denied or file no longer present)'
                        }
                    } else {
                        $details.Status = 'File metadata not read for a non-local path'
                    }
                    $fileDetails[$path] = $details
                }
                $description = $fileDetails[$path].Description
                $company = $fileDetails[$path].Company
                $metadataStatus = $fileDetails[$path].Status
            }
            $startedAtUtc = ''
            if ($null -ne $process.CreationDate) {
                try { $startedAtUtc = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o') } catch { }
            }
            $parentName = ''
            $parent = $parentNames[[uint32]$process.ParentProcessId]
            # A parent PID may already have been reused by a newer process.
            if ($null -ne $parent -and $process.ParentProcessId -ne $process.ProcessId -and
                $null -ne $parent.CreationDate -and $null -ne $process.CreationDate -and
                $parent.CreationDate -le $process.CreationDate) {
                $parentName = [string]$parent.Name
            }
            [pscustomobject]@{
                Computer = $env:COMPUTERNAME
                CapturedAtUtc = $capturedAtUtc
                Name = [string]$process.Name
                PID = [uint32]$process.ProcessId
                ParentPID = [uint32]$process.ParentProcessId
                ParentName = $parentName
                SessionId = [uint32]$process.SessionId
                StartedAtUtc = $startedAtUtc
                Description = $description
                Company = $company
                ExecutablePath = $path
                MetadataStatus = $metadataStatus
            }
        }
    }
    try {
        Write-Host ("Reading all processes on {0}..." -f $name)
        $session = New-PSSession -ComputerName "$name.local" -Credential $credential -SessionOption (New-PSSessionOption -OpenTimeout 15000) -ErrorAction Stop
        $phase = 'Operation'
        $processes = @(Invoke-Command -Session $session -ScriptBlock $readProcesses -ArgumentList $name -ErrorAction Stop | Sort-Object Name, PID)
        if ($processes.Count -eq 0) { throw 'No process inventory was received.' }
    } catch {
        $status = Get-ClassroomErrorStatus -Record $_ -Phase $phase
        Write-Host ("{0}: {1}: {2}" -f $status, $name, $_.Exception.Message) -ForegroundColor Red
        return
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    $totalCount = $processes.Count
    $capturedAtUtc = $processes[0].CapturedAtUtc
    $filter = Get-ClassroomProcessFilter
    $processes = @($processes | Where-Object { -not $filter.Names.ContainsKey([string]$_.Name) })
    $excludedCount = $totalCount - $processes.Count
    foreach ($process in $processes) {
        if ($filter.Names.ContainsKey([string]$process.ParentName)) {
            $process.ParentName = '[excluded background process]'
        }
    }
    Write-Host ("`n{0}: {1} processes for review; {2} background processes excluded; {3} total." -f $name, $processes.Count, $excludedCount, $totalCount) -ForegroundColor Cyan
    if ($processes.Count -gt 0) {
        $processes | Format-Table Name, PID -AutoSize -Wrap | Out-Host
    } else {
        Write-Host 'No processes remain for review after applying the background-process filter.'
    }
    # Write the report only on the teacher computer, after closing the remote session.
    try {
        $reportDirectory = Join-Path $PSScriptRoot 'Reports'
        New-Item -ItemType Directory -Path $reportDirectory -Force -ErrorAction Stop | Out-Null
        $reportName = 'Processes-{0}-{1}-{2}.txt' -f $name, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8))
        $reportPath = Join-Path $reportDirectory $reportName
        $reportLines = @(
            'CLASSROOM 307 - PROCESS REVIEW REPORT'
            ('Computer: {0}' -f $name)
            ('Captured at (UTC): {0}' -f $capturedAtUtc)
            ('Total process count: {0}' -f $totalCount)
            ('Excluded background process count: {0}' -f $excludedCount)
            ('Reported process count: {0}' -f $processes.Count)
            ('Filter revision: {0}' -f $filter.Revision)
            ('Filter source: {0}' -f $filter.Source)
            'Reviewed background process names are omitted. All other names are retained, even when optional metadata is unavailable.'
            'Remaining processes require review; their presence does not establish that a game is running.'
            'Parent names are from this snapshot; unavailable/exited parents have no name. Excluded parent names are redacted.'
            'Company/description are file metadata, not verified publisher identities.'
            'PIDs are a snapshot and can change or be reused after a process exits.'
            ''
            'NAME / PID'
            foreach ($process in $processes) { '{0} | PID {1}' -f $process.Name, $process.PID }
            ''
            'DETAILS FOR REVIEW'
            foreach ($process in $processes) {
                ''
                'Name: {0}' -f $process.Name
                'PID: {0}' -f $process.PID
                'Parent PID: {0}' -f $process.ParentPID
                'Parent name: {0}' -f $process.ParentName
                'Session ID: {0}' -f $process.SessionId
                'Started at (UTC): {0}' -f $process.StartedAtUtc
                'Description: {0}' -f $process.Description
                'Company: {0}' -f $process.Company
                'Path: {0}' -f $process.ExecutablePath
                'Metadata: {0}' -f $process.MetadataStatus
            }
        )
        $reportLines | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
        Write-Host ("Report saved: {0}" -f $reportPath) -ForegroundColor Green
        Write-Host 'Attach this TXT report in the chat for analysis.'
    } catch {
        Write-Host ("REPORT_ERROR: The process list was read and displayed, but the report could not be saved: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}
while ($true) {
    Write-Host "`nCLASSROOM 307 - TEACHER MENU" -ForegroundColor Cyan
    Write-Host '1. Start WinRM and check the teacher computer'
    Write-Host '2. Check the names of all 27 student computers'
    Write-Host '3. Show Wi-Fi connection and filters on a selected computer'
    Write-Host '4. Restrict selected computers to school Wi-Fi (default: Students)'
    Write-Host '5. Restrict All computers 01-27 to school Wi-Fi (default: Students)'
    Write-Host '6. Remove restrictions on other Wi-Fi networks for all computers'
    Write-Host '7. Remove restrictions on other Wi-Fi networks for selected computers'
    Write-Host '8. Send a file to a student computer'
    Write-Host '9. Receive a file from a student computer'
    Write-Host '10. Check Wi-Fi restrictions on selected computers (Students)'
    Write-Host '11. Restart student computers (all or selected)'
    Write-Host '12. Shut down student computers (all or selected)'
    Write-Host '13. Review processes on a selected computer (hide reviewed background processes)'
    Write-Host '0. Exit'
    $choice = Read-Host 'Choose an action'
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' {
                Start-Service WinRM -ErrorAction Stop
                Get-Service WinRM | Format-Table Status, Name, DisplayName | Out-Host
                Get-Item WSMan:\localhost\Client\TrustedHosts | Format-List Name, Value | Out-Host
            }
            '2' { Test-ClassroomComputers }
            '3' {
                $number = Get-StudentNumber
                if ($null -ne $number) {
                    Start-Service WinRM -ErrorAction Stop
                    & $manager -Numbers $number -Confirm:$false -ScriptBlock {
                        Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity | Format-Table -AutoSize | Out-String
                        Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String
                        $wlanDetails = netsh wlan show interfaces 2>&1
                        $wlanExitCode = $LASTEXITCODE
                        $wlanDetails | Out-String
                        if ($wlanExitCode -ne 0) {
                            'Wi-Fi details are unavailable. Windows may require location permission. Network profiles and IP addresses are shown above; the profile name is not guaranteed to be the SSID. Filter checks will continue.'
                        }
                        netsh wlan show filters
                        if ($LASTEXITCODE -ne 0) { throw 'Wi-Fi filter check failed.' }
                    } | Format-Table -AutoSize -Wrap | Out-Host
                }
            }
            '4' {
                $numbers = @(Get-StudentNumbers)
                if ($numbers.Count -gt 0) {
                    try {
                        Start-Service WinRM -ErrorAction Stop
                        $ssid = Read-Host 'Exact school Wi-Fi name (Enter = Students)'
                        if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'Students' }
                        if ($ssid.Contains('"') -or $ssid.Contains("`r") -or $ssid.Contains("`n")) { throw 'Invalid network name.' }
                        Write-Host ("Applying Wi-Fi filters on computers {0} for '{1}'..." -f ($numbers -join ', '), $ssid)
                        Write-Host 'Other existing Allow entries remain allowed. USB internet connections are not blocked.'
                        $command = {
                            param([string]$AllowedSSID)
                            $ErrorActionPreference = 'Stop'
                            $details = netsh wlan add filter permission=allow "ssid=$AllowedSSID" networktype=infrastructure 2>&1
                            if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Allow filter failed; no deny filters were added. " + ($details | Out-String).Trim()) }
                            $details = netsh wlan add filter permission=denyall networktype=infrastructure 2>&1
                            if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Infrastructure restriction failed; the Allow filter may already be active. " + ($details | Out-String).Trim()) }
                            $details = netsh wlan add filter permission=denyall networktype=adhoc 2>&1
                            if ($LASTEXITCODE -ne 0 -and (($details | Out-String) -notmatch 'This filter already exists in the same list on the system\.')) { throw ("Ad hoc restriction failed; infrastructure restriction may already be active. " + ($details | Out-String).Trim()) }
                            netsh wlan show filters
                            if ($LASTEXITCODE -ne 0) { throw 'Filters were applied, but reading the resulting filter list failed.' }
                        }
                        $results = @(& $manager -Numbers $numbers -ScriptBlock $command -ArgumentList @($ssid) -Confirm:$false)
                        if ($results.Count -eq 0) {
                            Write-Host 'Operation cancelled. No computer results were returned.'
                        }
                        foreach ($result in $results) {
                            if ($result.Status -eq 'OK') {
                                Write-Host ("SUCCESS: Wi-Fi filters applied on {0} for '{1}'." -f $result.Computer, $ssid) -ForegroundColor Green
                            } else {
                                $reason = $result.Output
                                if (-not $reason) { $reason = 'The operation did not return a successful result.' }
                                Write-Host ("{0}: {1}: {2}" -f $result.Status, $result.Computer, $reason) -ForegroundColor Red
                            }
                        }
                    } catch {
                        Write-Host ("ERROR: Selected computers {0}: {1}" -f ($numbers -join ', '), $_.Exception.Message) -ForegroundColor Red
                    }
                }
            }
            '5' { Set-AllClassroomWifi }
            '6' { Remove-ClassroomWifiRestrictions -All }
            '7' { Remove-ClassroomWifiRestrictions }
            '8' { Copy-ClassroomFile -Direction Send }
            '9' { Copy-ClassroomFile -Direction Receive }
            '10' {
                $numbers = @(Get-StudentNumbers)
                if ($numbers.Count -gt 0) {
                    $checker = Join-Path $PSScriptRoot 'Check-WifiRestrictions.ps1'
                    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) { throw 'Check-WifiRestrictions.ps1 is missing. Download it into the same folder as the menu.' }
                    & $checker -Numbers $numbers -SchoolSSID 'Students' | Out-Null
                }
            }
            '11' { Invoke-ClassroomPowerAction -Action Restart }
            '12' { Invoke-ClassroomPowerAction -Action Shutdown }
            '13' { Show-ClassroomProcesses }
            default { Write-Host 'Choose a number from 0 to 13.' }
        }
    } catch { Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Read-Host 'Press Enter to return to the menu' | Out-Null
}
