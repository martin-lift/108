#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ExpectedComputer,
    [string]$RunId = 'Logon'
)
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectedComputer -or $ExpectedComputer -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$') {
    throw "Unexpected computer: $env:COMPUTERNAME. No keyboard changes made."
}
$stateKey = 'HKCU:\Software\Cabinet307\KeyboardSetup'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($sid -in @('S-1-5-18','S-1-5-19','S-1-5-20')) { throw 'A real user profile is required.' }
New-Item -Path $stateKey -Force | Out-Null
try {
    $before = @((Get-WinUserLanguageList).GetEnumerator())
    if (-not (Get-ItemProperty -LiteralPath $stateKey -Name OriginalLanguages -ErrorAction SilentlyContinue)) {
        $snapshot = @($before | ForEach-Object {
            [pscustomobject]@{ LanguageTag=$_.LanguageTag; InputMethodTips=@($_.InputMethodTips) }
        }) | ConvertTo-Json -Depth 5 -Compress
        New-ItemProperty -Path $stateKey -Name OriginalLanguages -Value $snapshot -PropertyType String -Force | Out-Null
    }
    $current = @($before | ForEach-Object { $_.InputMethodTips })
    # Retain the relative order of English and Bulgarian when already present.
    $tags = @($before | Where-Object LanguageTag -in @('en-US','bg-BG') | ForEach-Object LanguageTag)
    $tags = @(@($tags) + @('en-US','bg-BG') | Select-Object -Unique)
    $languages = New-WinUserLanguageList -Language $tags[0]
    $languages.Add((New-WinUserLanguageList -Language $tags[1])[0])
    foreach ($language in $languages) { $language.InputMethodTips.Clear() }
    ($languages | Where-Object LanguageTag -eq 'en-US').InputMethodTips.Add('0409:00000409')
    $bulgarian = $languages | Where-Object LanguageTag -eq 'bg-BG'
    $bulgarian.InputMethodTips.Add('0402:00040402')
    $bulgarian.InputMethodTips.Add('0402:00000402')
    $expected = @('0409:00000409','0402:00040402','0402:00000402')
    if (@(Compare-Object $expected $current).Count -gt 0) {
        Set-WinUserLanguageList -LanguageList $languages -Force
    }
    Set-WinDefaultInputMethodOverride -InputTip '0409:00000409'
    $actual = @(Get-WinUserLanguageList | ForEach-Object { $_.InputMethodTips })
    if (@(Compare-Object $expected $actual).Count -gt 0) { throw "Keyboard verification failed: $($actual -join ', ')" }
    if ((Get-WinDefaultInputMethodOverride).InputMethodTip -ne '0409:00000409') { throw 'Default keyboard verification failed.' }
    New-ItemProperty -Path $stateKey -Name Status -Value 'OK' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name RunId -Value $RunId -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name AppliedUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null
} catch {
    New-ItemProperty -Path $stateKey -Name Status -Value $_.Exception.Message -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name RunId -Value $RunId -PropertyType String -Force | Out-Null
    throw
}
