[CmdletBinding()]
param([ValidateRange(1,27)][int[]]$Numbers=(1..27),[switch]$Apply)
$ErrorActionPreference='Stop'
. 'C:\307\Credential-Helper.ps1'
$cleanup={
    param($expected,$teacher,$apply)
    $ErrorActionPreference='Stop'
    if($env:COMPUTERNAME -ine $expected -or $expected -ieq $teacher -or $expected -notmatch '^307-Student-(0[1-9]|1[0-9]|2[0-7])$'){throw 'Unexpected computer identity.'}
    $programs=[Environment]::GetFolderPath('ProgramFiles')
    $agent=Join-Path $programs 'Classroom108-WifiReconnect'
    $recovery=Join-Path $programs 'RestoreStudentNetwork'
    $link=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'RestoreStudentNetwork.lnk'
    $worker=Join-Path $agent 'Reconnect.ps1'
    $config=Join-Path $agent 'Settings.json'
    $payload=Join-Path $recovery 'RestoreStudentNetwork.ps1'
    foreach($path in @($agent,$recovery,$worker,$config,$payload,$link)){
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Redirected path: $path"}
        }
    }
    $tasks=@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Classroom108-WifiReconnect')
    if($tasks.Count -gt 1 -or ($tasks.Count -and ($tasks[0].Description -cne 'Classroom108 Wi-Fi recovery v1' -or $tasks[0].Actions.Arguments -notlike "*$worker*"))){throw 'Unrecognized scheduled task.'}
    if(Test-Path -LiteralPath $link){
        $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($link)
        if($shortcut.TargetPath -ine (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -or $shortcut.Arguments -ine ('-NoProfile -ExecutionPolicy Bypass -File "'+$payload+'" -Elevated')){throw 'Unrecognized Start menu shortcut.'}
    }
    if((Test-Path -LiteralPath $payload) -and -not (Select-String -LiteralPath $payload -SimpleMatch 'function Suspend-LocalAgent' -Quiet)){throw 'Unrecognized recovery script.'}
    if((Test-Path -LiteralPath $worker) -and -not (Select-String -LiteralPath $worker -SimpleMatch 'Classroom108.Wifi' -Quiet)){throw 'Unrecognized reconnect script.'}
    if(Test-Path -LiteralPath $config){$settings=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json; if($null -eq $settings.interval_minutes -or -not $settings.profile){throw 'Unrecognized agent settings.'}}
    $files=@(@($worker,$config,$payload,$link) | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
    if($apply){
        if($tasks.Count){
            Disable-ScheduledTask -InputObject $tasks[0] | Out-Null
            Stop-ScheduledTask -InputObject $tasks[0]
            Unregister-ScheduledTask -InputObject $tasks[0] -Confirm:$false
        }
        foreach($file in $files){Remove-Item -LiteralPath $file -Force}
        foreach($dir in @($agent,$recovery)){if((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0){[IO.Directory]::Delete($dir)}}
        if(@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Classroom108-WifiReconnect').Count){throw 'Old task still present.'}
        foreach($file in @($worker,$config,$payload,$link)){if(Test-Path -LiteralPath $file){throw "Still installed: $file"}}
    }
    [pscustomobject]@{Computer=$expected;Status=$(if($apply){'Verified absent'}else{'Inventory'});TaskFound=$tasks.Count;FilesFound=$files.Count}
}
$credential=Get-ClassroomCredential
if(-not $credential){throw 'Login cancelled.'}
$report=foreach($number in ($Numbers|Sort-Object -Unique)){
    $name='307-Student-{0:D2}' -f $number
    try {Invoke-Command -ComputerName "$name.local" -Credential ([pscredential]::new("$name\108SU",$credential.Password)) -SessionOption (New-PSSessionOption -OpenTimeout 6000 -OperationTimeout 30000) -ScriptBlock $cleanup -ArgumentList $name,$env:COMPUTERNAME,([bool]$Apply) -ErrorAction Stop}
    catch{[pscustomobject]@{Computer=$name;Status=$_.Exception.Message}}
}
$report | Select-Object Computer,Status,TaskFound,FilesFound
