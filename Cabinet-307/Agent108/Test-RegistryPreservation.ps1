$ErrorActionPreference='Stop'
. "$PSScriptRoot\Main.ps1"
. "$PSScriptRoot\BrowserGuard.ps1"
. "$PSScriptRoot\GameGuard.ps1"
$testKey='HKCU:\Software\Agent108-Test-'+[guid]::NewGuid().ToString('N')
$reg=$testKey;$script:BrowserReg=$testKey;$script:GameReg=$testKey
function Invoke-Network { }
function Get-ScheduledTask { @() }
function Start-BrowserTask { }
$worker='param($Profile,[switch]$CheckOnly); 1'
try {
    New-Item -Path $testKey | Out-Null
    $browser='{"Enabled":false,"Seconds":6,"Token":"preserved","ExpiresUtc":""}'
    Set-ItemProperty -LiteralPath $testKey -Name BrowserPolicy -Value $browser
    $game=' {"Enabled":false,"Seconds":6,"Token":"game-preserved","ExpiresUtc":""}'
    Set-ItemProperty -LiteralPath $testKey -Name GamePolicy -Value $game
    Configure All 0
    if ((Get-ItemProperty $testKey).BrowserPolicy -cne $browser) {throw 'Configure erased browser policy'}
    if ((Get-ItemProperty $testKey).GamePolicy -cne $game) {throw 'Configure erased game policy'}
    $wifi=(Get-ItemProperty $testKey).Policy
    Set-BrowserGuard $false
    if ((Get-ItemProperty $testKey).Policy -cne $wifi) {throw 'Browser guard erased Wi-Fi policy'}
    Set-ItemProperty -LiteralPath $testKey -Name BrowserPolicy -Value $browser
    Set-GameGuard $false
    if ((Get-ItemProperty $testKey).Policy -cne $wifi -or (Get-ItemProperty $testKey).BrowserPolicy -cne $browser) {throw 'Game guard erased independent policies'}
    Set-ItemProperty -LiteralPath $testKey -Name GamePolicy -Value $game
    Remove-ItemProperty -LiteralPath $testKey -Name Policy
    Set-ItemProperty -LiteralPath $testKey -Name BrowserPolicy -Value $browser
    Invoke-Agent install All 0
    if ((Get-ItemProperty $testKey).BrowserPolicy -cne $browser) {throw 'Repair erased browser policy'}
    if ((Get-ItemProperty $testKey).GamePolicy -cne $game) {throw 'Repair erased game policy'}
    if ((Read-Config).Mode -ne 'All') {throw 'Repair did not restore Wi-Fi policy'}
    'PASS: real registry preservation and missing-policy repair; no network/task changes'
} finally { if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse } }
