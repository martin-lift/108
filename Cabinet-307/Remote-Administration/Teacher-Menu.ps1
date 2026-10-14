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
function Get-StudentNumber {
    while ($true) {
        $answer = Read-Host 'Student computer number (1-27; Enter = cancel)'
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le 27) { return $number }
        Write-Host 'Enter a number from 1 to 27.'
    }
}
function Test-ClassroomComputers {
    Start-Service WinRM -ErrorAction Stop
    $credentialInput = Get-Credential -UserName '108SU' -Message 'Shared LOCAL admin password for classroom'
    if ($null -eq $credentialInput) { return }
    $failures = @()
    $sessionOption = New-PSSessionOption -OpenTimeout 15000
    foreach ($number in 1..27) {
        $name = '307-Student-{0:D2}' -f $number
        $destination = "$name.local"
        Write-Host ("[{0}/27] Checking {1}... " -f $number, $destination) -NoNewline
        try {
            $credential = [pscredential]::new("$name\108SU", $credentialInput.Password)
            $actualName = Invoke-Command -ComputerName $destination -Credential $credential -SessionOption $sessionOption -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ([string]$actualName -ine $name) { throw "Unexpected remote computer name: $actualName (expected $name)." }
            Write-Host 'OK' -ForegroundColor Green
        } catch {
            Write-Host 'ERROR' -ForegroundColor Red
            $reason = ($_.Exception.Message -replace '\s+', ' ').Trim()
            $failures += [pscustomobject]@{ Computer = $name; Reason = $reason }
        }
    }
    if ($failures.Count -gt 0) {
        Write-Host ''
        $failures | Format-Table Computer, Reason -AutoSize -Wrap | Out-Host
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
    $credential = Get-Credential -UserName "$name\108SU" -Message "Local administrator password for $name"
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
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session }
    }
}
while ($true) {
    Write-Host "`nCLASSROOM 307 - TEACHER MENU" -ForegroundColor Cyan
    Write-Host '1. Start WinRM and check the teacher computer'
    Write-Host '2. Check the names of all 27 student computers'
    Write-Host '3. Show Wi-Fi connection and filters on a selected computer'
    Write-Host '4. Restrict a selected computer to school Wi-Fi (default: Students)'
    Write-Host '5. Remove restrictions on other Wi-Fi networks'
    Write-Host '6. Send a file to a student computer'
    Write-Host '7. Receive a file from a student computer'
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
                    & $manager -Numbers $number -ScriptBlock {
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
                $number = Get-StudentNumber
                if ($null -ne $number) {
                    try {
                        Start-Service WinRM -ErrorAction Stop
                        $ssid = Read-Host 'Exact school Wi-Fi name (Enter = Students)'
                        if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'Students' }
                        if ($ssid.Contains('"') -or $ssid.Contains("`r") -or $ssid.Contains("`n")) { throw 'Invalid network name.' }
                        Write-Host ("Applying Wi-Fi filters on computer {0} for '{1}'..." -f $number, $ssid)
                        Write-Host 'Other existing Allow entries remain allowed. USB internet connections are not blocked.'
                        $command = {
                            param([string]$AllowedSSID)
                            $ErrorActionPreference = 'Stop'
                            $details = netsh wlan add filter permission=allow "ssid=$AllowedSSID" networktype=infrastructure 2>&1
                            if ($LASTEXITCODE -ne 0) { throw ("Allow filter failed; no deny filters were added. " + ($details | Out-String).Trim()) }
                            $details = netsh wlan add filter permission=denyall networktype=infrastructure 2>&1
                            if ($LASTEXITCODE -ne 0) { throw ("Infrastructure restriction failed; the Allow filter may already be active. " + ($details | Out-String).Trim()) }
                            $details = netsh wlan add filter permission=denyall networktype=adhoc 2>&1
                            if ($LASTEXITCODE -ne 0) { throw ("Ad hoc restriction failed; infrastructure restriction may already be active. " + ($details | Out-String).Trim()) }
                            netsh wlan show filters
                            if ($LASTEXITCODE -ne 0) { throw 'Filters were applied, but reading the resulting filter list failed.' }
                        }
                        $results = @(& $manager -Numbers $number -ScriptBlock $command -ArgumentList @($ssid) -Confirm:$false)
                        if ($results.Count -ne 1 -or $results[0].Status -ne 'OK') {
                            $reason = ($results | ForEach-Object { $_.Output }) -join '; '
                            if (-not $reason) { $reason = 'The operation did not return a successful result.' }
                            throw $reason
                        }
                        Write-Host ("SUCCESS: Wi-Fi filters applied on computer {0} for '{1}'." -f $number, $ssid) -ForegroundColor Green
                    } catch {
                        Write-Host ("FAILED: Computer {0}: {1}" -f $number, $_.Exception.Message) -ForegroundColor Red
                    }
                }
            }
            '5' {
                $number = Get-StudentNumber
                if ($null -ne $number) {
                    $confirmation = Read-Host ("Type YES to remove Wi-Fi restrictions on computer {0}" -f $number)
                    if ($confirmation -ieq 'YES') {
                        Start-Service WinRM -ErrorAction Stop
                        & $manager -Numbers $number -ScriptBlock {
                            netsh wlan delete filter permission=denyall networktype=infrastructure
                            $infrastructureResult = $LASTEXITCODE
                            netsh wlan delete filter permission=denyall networktype=adhoc
                            $adhocResult = $LASTEXITCODE
                            netsh wlan show filters
                            if ($infrastructureResult -ne 0 -or $adhocResult -ne 0) { throw 'Some deny filters could not be removed or were not present; review the displayed filters.' }
                        } | Format-Table -AutoSize -Wrap | Out-Host
                    }
                }
            }
            '6' { Copy-ClassroomFile -Direction Send }
            '7' { Copy-ClassroomFile -Direction Receive }
            default { Write-Host 'Choose a number from 0 to 7.' }
        }
    } catch { Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Read-Host 'Press Enter to return to the menu' | Out-Null
}



