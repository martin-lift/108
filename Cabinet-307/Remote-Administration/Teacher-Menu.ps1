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
            default { Write-Host 'Choose a number from 0 to 10.' }
        }
    } catch { Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Read-Host 'Press Enter to return to the menu' | Out-Null
}



