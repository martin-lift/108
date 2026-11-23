$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try{
New-Item dist -ItemType Directory -Force | Out-Null
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /win32icon:assets\agent108.ico /out:dist\Agent108.exe /resource:Network.ps1,Network.ps1 /resource:Reconnect.ps1,Reconnect.ps1 /resource:BrowserProcesses.ps1,BrowserProcesses.ps1 /resource:BrowserGuard.ps1,BrowserGuard.ps1 /resource:GameProcesses.ps1,GameProcesses.ps1 /resource:GameGuard.ps1,GameGuard.ps1 /resource:Main.ps1,Main.ps1 Program.cs
if($LASTEXITCODE){throw 'Compiler failed'}
& $env:ISCC setup.iss
if($LASTEXITCODE){throw 'Setup build failed'}
}finally{Pop-Location}
