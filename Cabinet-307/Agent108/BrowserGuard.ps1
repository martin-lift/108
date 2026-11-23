# Browser enforcement is independent of the Wi-Fi policy and has a fixed expiry.
$script:BrowserReg = 'HKLM:\SOFTWARE\Agent108'
$script:BrowserTaskName = 'Agent108-BrowserGuard'

function Read-BrowserPolicy {
    $item = Get-ItemProperty -LiteralPath $script:BrowserReg -Name BrowserPolicy -ErrorAction SilentlyContinue
    if ($item -and $item.BrowserPolicy) { return ($item.BrowserPolicy | ConvertFrom-Json) }
    [pscustomobject]@{ Enabled=$false; Seconds=6; ExpiresUtc=''; Computer=$env:COMPUTERNAME; Token='' }
}

function Test-BrowserPolicyActive($Policy, [datetime]$Now = [datetime]::UtcNow) {
    if ($Policy.Enabled -ne $true -or $Policy.Seconds -ne 6 -or
        $Policy.Computer -ine $env:COMPUTERNAME -or [string]::IsNullOrWhiteSpace($Policy.Token)) { return $false }
    $expiry = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Policy.ExpiresUtc, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiry)) { return $false }
    return $expiry.ToUniversalTime() -gt $Now.ToUniversalTime()
}

function Get-OwnedBrowserTask {
    $path = Join-Path $env:ProgramFiles 'Agent108\Agent108.exe'
    $tasks = @(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $script:BrowserTaskName)
    if ($tasks.Count -gt 1) { throw 'Ambiguous browser task.' }
    if ($tasks.Count -eq 1 -and ($tasks[0].Description -cne 'Agent108 browser guard' -or
        @($tasks[0].Actions).Count -ne 1 -or $tasks[0].Actions.Execute -ine $path -or
        $tasks[0].Actions.Arguments -cne 'browsers-watch')) { throw 'Unexpected browser task ownership.' }
    if ($tasks.Count -eq 1) { return $tasks[0] }
}

function Start-BrowserTask {
    $task = Get-OwnedBrowserTask
    if (-not $task) {
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:ProgramFiles 'Agent108\Agent108.exe') -Argument 'browsers-watch'
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $script:BrowserTaskName -Description 'Agent108 browser guard' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
    }
    Start-ScheduledTask -TaskName $script:BrowserTaskName
}

function Set-BrowserGuard([bool]$Enabled, [int]$Minutes = 40, [int]$Seconds = 6) {
    if ($Seconds -ne 6 -or $Minutes -lt 1 -or $Minutes -gt 240) { throw 'Browser guard requires 6 seconds and 1-240 minutes.' }
    $mutex = [Threading.Mutex]::new($false, 'Global\Agent108.BrowserPolicy')
    $locked = $false
    try {
        try { $locked=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another browser policy change is in progress.' }
        $old = Get-OwnedBrowserTask
        # Invalidate the previous worker before stopping its task or issuing a new token.
        if (-not (Test-Path -LiteralPath $script:BrowserReg)) { New-Item -Path $script:BrowserReg | Out-Null }
        Set-ItemProperty -LiteralPath $script:BrowserReg -Name BrowserPolicy -Value (@{
            Enabled=$false; Seconds=6; ExpiresUtc=''; Computer=$env:COMPUTERNAME; Token=''
        } | ConvertTo-Json -Compress)
        if ($old) {
            Stop-ScheduledTask -InputObject $old
            Unregister-ScheduledTask -InputObject $old -Confirm:$false
        }
        if ($Enabled) {
            $policy = @{ Enabled=$true; Seconds=6; Computer=$env:COMPUTERNAME;
                ExpiresUtc=[datetime]::UtcNow.AddMinutes($Minutes).ToString('o'); Token=[guid]::NewGuid().ToString('N') }
            Set-ItemProperty -LiteralPath $script:BrowserReg -Name BrowserPolicy -Value ($policy | ConvertTo-Json -Compress)
            try { Start-BrowserTask } catch {
                $policy.Enabled=$false
                Set-ItemProperty -LiteralPath $script:BrowserReg -Name BrowserPolicy -Value ($policy | ConvertTo-Json -Compress)
                throw
            }
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-BrowserGuard {
    $initial = Read-BrowserPolicy
    if (-not (Test-BrowserPolicyActive $initial)) { return }
    $token = $initial.Token
    while ($true) {
        $policy = Read-BrowserPolicy
        if ($policy.Token -cne $token -or -not (Test-BrowserPolicyActive $policy)) { return }
        $tick = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = & (Get-ClassroomBrowserStopCommand) $env:COMPUTERNAME ''
            $status = @{ Computer=$env:COMPUTERNAME; Token=$token; CheckedUtc=[datetime]::UtcNow.ToString('o');
                Stopped=$result.Stopped; Remaining=$result.Remaining; Error=$result.Diagnostics }
        } catch {
            $status = @{ Computer=$env:COMPUTERNAME; Token=$token; CheckedUtc=[datetime]::UtcNow.ToString('o'); Error=$_.Exception.Message }
        }
        try { Set-ItemProperty -LiteralPath $script:BrowserReg -Name BrowserStatus -Value ($status | ConvertTo-Json -Compress) } catch { }
        Start-Sleep -Milliseconds ([int][Math]::Max(100, 6000 - $tick.ElapsedMilliseconds))
    }
}

function Restore-BrowserGuard {
    if (Test-BrowserPolicyActive (Read-BrowserPolicy)) { Start-BrowserTask }
}
