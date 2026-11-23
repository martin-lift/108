# Exact browser process names. No arbitrary process names or command lines accepted.
function Get-ClassroomBrowserStopCommand {
    {
        param([string]$ExpectedName, [string]$TeacherName)
        $ErrorActionPreference = 'Stop'
        if ([string]::IsNullOrWhiteSpace($ExpectedName) -or
            $env:COMPUTERNAME -ine $ExpectedName -or $env:COMPUTERNAME -ieq $TeacherName) {
            throw "Unexpected remote identity: $env:COMPUTERNAME (expected $ExpectedName)."
        }
        $names = @('chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi')
        $before = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in $names })
        $stopped = 0
        $notes = @()
        foreach ($process in $before) {
            try {
                # Hold the OS process handle, so PID reuse cannot target a different app.
                $null = $process.Handle
                if ($process.HasExited) { continue }
                if ($process.ProcessName -notin $names -or $process.Id -eq $PID) { continue }
                $process.Kill()
                if ($process.WaitForExit(1000)) { $stopped++ }
                else { $notes += "Exit not confirmed for $($process.ProcessName), PID $($process.Id)." }
            } catch {
                $notes += "PID $($process.Id): $($_.Exception.Message)"
            } finally { $process.Dispose() }
        }
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in $names })
        foreach ($process in $remaining) {
            $notes += "Remaining: $($process.ProcessName), PID $($process.Id)."
            $process.Dispose()
        }
        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            Status = $(if ($remaining.Count -eq 0) { 'BROWSERS_STOPPED' } else { 'BROWSERS_REMAINING' })
            Stopped = $stopped; Remaining = $remaining.Count; Diagnostics = ($notes -join "`n")
        }
    }
}
