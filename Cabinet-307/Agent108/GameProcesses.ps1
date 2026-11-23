# Literal, case-insensitive fragments; never interpreted as wildcards or code.
function ConvertTo-GamePatterns($Values) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Values)) {
        if ($value -isnot [string]) { throw 'Process fragments must be strings.' }
        $fragment = $value.Trim()
        if ($fragment.Length -lt 3) { continue }
        if ($fragment.Length -gt 260 -or $fragment.Contains("`n") -or $fragment.Contains("`r")) { throw 'Invalid process fragment.' }
        if ($seen.Add($fragment)) { $fragment }
    }
}
function Read-GamePatterns {
    $item = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Agent108' -Name GamePatterns -ErrorAction SilentlyContinue
    if ($null -eq $item -or $null -eq $item.GamePatterns) { return @('RobloxPlayerBeta', 'RobloxPlayer') }
    ConvertTo-GamePatterns ($item.GamePatterns | ConvertFrom-Json)
}
function Set-GamePatterns([string]$Hex) {
    if ($Hex.Length -gt 24000 -or $Hex -notmatch '\A(?:[0-9a-fA-F]{2})+\z') { throw 'Invalid process list encoding.' }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i]=[Convert]::ToByte($Hex.Substring($i*2,2),16) }
    $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if (-not $json.TrimStart().StartsWith('[')) { throw 'Process list must be a JSON array.' }
    $patterns = @(ConvertTo-GamePatterns ($json | ConvertFrom-Json))
    $key='HKLM:\SOFTWARE\Agent108'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key | Out-Null }
    Set-ItemProperty -LiteralPath $key -Name GamePatterns -Value (ConvertTo-Json -InputObject $patterns -Compress)
}
function Get-ClassroomGameStopCommand {
    {
        param([string]$ExpectedName, [string]$TeacherName, [string[]]$Patterns = @('RobloxPlayerBeta', 'RobloxPlayer'))
        $ErrorActionPreference = 'Stop'
        if ([string]::IsNullOrWhiteSpace($ExpectedName) -or
            $env:COMPUTERNAME -ine $ExpectedName -or $env:COMPUTERNAME -ieq $TeacherName) {
            throw "Unexpected remote identity: $env:COMPUTERNAME (expected $ExpectedName)."
        }
        $names = @($Patterns | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 3 })
        function Matches-GameProcess($process) {
            if ($process.Id -eq $PID -or $process.Id -le 4 -or $process.ProcessName -in @('Agent108','powershell','pwsh','wininit','winlogon','csrss','lsass','services','svchost','smss','System','Registry')) { return $false }
            foreach ($fragment in $names) {
                if ($process.ProcessName.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
            return $false
        }
        $before = @(Get-Process -ErrorAction Stop | Where-Object { Matches-GameProcess $_ })
        $stopped = 0
        $notes = @()
        foreach ($process in $before) {
            try {
                # Hold the OS process handle, so PID reuse cannot target a different app.
                $null = $process.Handle
                if ($process.HasExited) { continue }
                if (-not (Matches-GameProcess $process)) { continue }
                $process.Kill()
                if ($process.WaitForExit(1000)) { $stopped++ }
                else { $notes += "Exit not confirmed for $($process.ProcessName), PID $($process.Id)." }
            } catch {
                $notes += "PID $($process.Id): $($_.Exception.Message)"
            } finally { $process.Dispose() }
        }
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-Process -ErrorAction Stop | Where-Object { Matches-GameProcess $_ })
        foreach ($process in $remaining) {
            $notes += "Remaining: $($process.ProcessName), PID $($process.Id)."
            $process.Dispose()
        }
        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            Status = $(if ($remaining.Count -eq 0) { 'GAMES_STOPPED' } else { 'GAMES_REMAINING' })
            Stopped = $stopped; Remaining = $remaining.Count; Diagnostics = ($notes -join "`n")
        }
    }
}
