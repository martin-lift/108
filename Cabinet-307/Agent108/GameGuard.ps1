# Game enforcement is independent of the Wi-Fi and browser policies and has a fixed expiry.
$script:GameReg = 'HKLM:\SOFTWARE\Agent108'
$script:GameTaskName = 'Agent108-GameGuard'

function Read-GamePolicy {
    $item = Get-ItemProperty -LiteralPath $script:GameReg -Name GamePolicy -ErrorAction SilentlyContinue
    if ($item -and $item.GamePolicy) { return ($item.GamePolicy | ConvertFrom-Json) }
    [pscustomobject]@{ Enabled=$false; Seconds=6; ExpiresUtc=''; Computer=$env:COMPUTERNAME; Token='' }
}

function Test-GamePolicyActive($Policy, [datetime]$Now = [datetime]::UtcNow) {
    if ($Policy.Enabled -ne $true -or $Policy.Seconds -ne 6 -or
        $Policy.Computer -ine $env:COMPUTERNAME -or [string]::IsNullOrWhiteSpace($Policy.Token)) { return $false }
    $expiry = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Policy.ExpiresUtc, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiry)) { return $false }
    return $expiry.ToUniversalTime() -gt $Now.ToUniversalTime()
}

function Get-OwnedGameTask {
    $path = Join-Path $env:ProgramFiles 'Agent108\Agent108.exe'
    $tasks = @(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $script:GameTaskName)
    if ($tasks.Count -gt 1) { throw 'Ambiguous game task.' }
    if ($tasks.Count -eq 1 -and ($tasks[0].Description -cne 'Agent108 game guard' -or
        @($tasks[0].Actions).Count -ne 1 -or $tasks[0].Actions.Execute -ine $path -or
        $tasks[0].Actions.Arguments -cne 'games-watch')) { throw 'Unexpected game task ownership.' }
    if ($tasks.Count -eq 1) { return $tasks[0] }
}

function Start-GameTask {
    $task = Get-OwnedGameTask
    if (-not $task) {
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:ProgramFiles 'Agent108\Agent108.exe') -Argument 'games-watch'
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $script:GameTaskName -Description 'Agent108 game guard' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
    }
    Start-ScheduledTask -TaskName $script:GameTaskName
}

function Set-GameGuard([bool]$Enabled, [int]$Minutes = 40, [int]$Seconds = 6) {
    if ($Seconds -ne 6 -or $Minutes -lt 1 -or $Minutes -gt 240) { throw 'Game guard requires 6 seconds and 1-240 minutes.' }
    $mutex = [Threading.Mutex]::new($false, 'Global\Agent108.GamePolicy')
    $locked = $false
    try {
        try { $locked=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another game policy change is in progress.' }
        $old = Get-OwnedGameTask
        # Invalidate the previous worker before stopping its task or issuing a new token.
        if (-not (Test-Path -LiteralPath $script:GameReg)) { New-Item -Path $script:GameReg | Out-Null }
        Set-ItemProperty -LiteralPath $script:GameReg -Name GamePolicy -Value (@{
            Enabled=$false; Seconds=6; ExpiresUtc=''; Computer=$env:COMPUTERNAME; Token=''
        } | ConvertTo-Json -Compress)
        if ($old) {
            Stop-ScheduledTask -InputObject $old
            Unregister-ScheduledTask -InputObject $old -Confirm:$false
        }
        if ($Enabled) {
            $policy = @{ Enabled=$true; Seconds=6; Computer=$env:COMPUTERNAME;
                ExpiresUtc=[datetime]::UtcNow.AddMinutes($Minutes).ToString('o'); Token=[guid]::NewGuid().ToString('N') }
            Set-ItemProperty -LiteralPath $script:GameReg -Name GamePolicy -Value ($policy | ConvertTo-Json -Compress)
            try { Start-GameTask } catch {
                $policy.Enabled=$false
                Set-ItemProperty -LiteralPath $script:GameReg -Name GamePolicy -Value ($policy | ConvertTo-Json -Compress)
                throw
            }
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-GameGuard {
    $initial = Read-GamePolicy
    if (-not (Test-GamePolicyActive $initial)) { return }
    $token = $initial.Token
    while ($true) {
        $policy = Read-GamePolicy
        if ($policy.Token -cne $token -or -not (Test-GamePolicyActive $policy)) { return }
        $tick = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = & (Get-ClassroomGameStopCommand) $env:COMPUTERNAME '' -Patterns @(Read-GamePatterns)
            $status = @{ Computer=$env:COMPUTERNAME; Token=$token; CheckedUtc=[datetime]::UtcNow.ToString('o');
                Stopped=$result.Stopped; Remaining=$result.Remaining; Error=$result.Diagnostics }
        } catch {
            $status = @{ Computer=$env:COMPUTERNAME; Token=$token; CheckedUtc=[datetime]::UtcNow.ToString('o'); Error=$_.Exception.Message }
        }
        try { Set-ItemProperty -LiteralPath $script:GameReg -Name GameStatus -Value ($status | ConvertTo-Json -Compress) } catch { }
        Start-Sleep -Milliseconds ([int][Math]::Max(100, 6000 - $tick.ElapsedMilliseconds))
    }
}

function Restore-GameGuard {
    if (Test-GamePolicyActive (Read-GamePolicy)) { Start-GameTask }
}
