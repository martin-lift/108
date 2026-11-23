$reg='HKLM:\SOFTWARE\Agent108'
$exe=Join-Path $env:ProgramFiles 'Agent108\Agent108.exe'
function Read-Config {
    $item=Get-ItemProperty -LiteralPath $reg -Name Policy -ErrorAction SilentlyContinue
    if($item -and -not [string]::IsNullOrWhiteSpace([string]$item.Policy)){return ($item.Policy | ConvertFrom-Json)}
    [pscustomobject]@{Mode='All';Seconds=0}
}
function Invoke-Network($action){
    $r=& (Get-ClassroomInternetCommand) $env:COMPUTERNAME '' $action 'Students' ''
    if($r.status -notin 'NETWORK_OK','NETWORK_WARNING'){throw $r.diagnostics}
    $r.diagnostics
}
function Configure($mode,[int]$seconds){
    if($mode -notin 'Students','All' -or $seconds -lt 0 -or $seconds -gt 86400){throw 'Invalid policy'}
    $taskName='Agent108-Reconnect'
    $task=@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName)
    if($task.Count -and $task[0].Description -ne 'Agent108 reconnect worker'){throw 'Task name already occupied.'}
    if($mode -eq 'Students'){
        if((& ([scriptblock]::Create($worker)) -Profile Students -CheckOnly) -lt 1){throw 'Students requires a saved all-users Wi-Fi profile.'}
        Invoke-Network NetWifiRestrict | Out-Null
    }else{Invoke-Network NetWifiRemove | Out-Null}
    if (-not (Test-Path -LiteralPath $reg)) { New-Item $reg | Out-Null }
    Set-ItemProperty $reg Policy (@{Mode=$mode;Seconds=$seconds}|ConvertTo-Json -Compress)
    if($task.Count){Stop-ScheduledTask -InputObject $task[0];Unregister-ScheduledTask -InputObject $task[0] -Confirm:$false}
    if($mode -eq 'Students' -and $seconds -gt 0){
        $action=New-ScheduledTaskAction -Execute $exe -Argument 'watch'
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Description 'Agent108 reconnect worker' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
        Start-ScheduledTask -TaskName $taskName
    }
}
function Restore-AgentWorkers {
    $cfg=Read-Config
    if($cfg.Mode -notin 'Students','All' -or [int]$cfg.Seconds -lt 0 -or [int]$cfg.Seconds -gt 86400){throw 'Invalid saved Wi-Fi policy'}
    if($cfg.Mode -eq 'Students' -and [int]$cfg.Seconds -gt 0){
        $task=Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Agent108-Reconnect'
        if(-not $task -or $task.Description -cne 'Agent108 reconnect worker' -or @($task.Actions).Count -ne 1 -or
            $task.Actions.Execute -ine $exe -or $task.Actions.Arguments -cne 'watch'){throw 'Saved Wi-Fi task ownership not confirmed'}
        Start-ScheduledTask -TaskName 'Agent108-Reconnect'
    }
    Restore-BrowserGuard
    Restore-GameGuard
}
function Show-Agent {
    [void][Reflection.Assembly]::LoadFrom($exe)
    [Agent108Taskbar]::IdentifyWindowProcess()
    Add-Type -AssemblyName System.Windows.Forms
    $form=New-Object Windows.Forms.Form
    $form.Icon=[Drawing.Icon]::ExtractAssociatedIcon($exe)
    $form.Text='Agent108 — мрежа, браузери и игри';$form.ClientSize=New-Object Drawing.Size(490,810)
    $form.StartPosition='CenterScreen'
    function Control($type,$text,$x,$y,$width,$height){$c=New-Object "Windows.Forms.$type";$c.Text=$text;$c.SetBounds($x,$y,$width,$height);$form.Controls.Add($c);return $c}
    $cfg=Read-Config
    $null=Control Label 'Wi-Fi режим' 18 18 120 24
    $mode=Control ComboBox '' 158 15 300 30;$mode.DropDownStyle='DropDownList'
    $mode.Items.AddRange(@('Само Students','Всички мрежи разрешени'))
    $mode.SelectedIndex=[int]($cfg.Mode -ne 'Students')
    $null=Control Label 'Автоматично свързване към Students (през колко секунди)' 18 52 450 23
    $sec=Control NumericUpDown '' 18 77 90 28;$sec.Maximum=86400;$sec.Value=$cfg.Seconds
    $null=Control Label 'Ако Wi-Fi е прекъснат, Agent108 опитва да свърже компютъра към Students. Ако Wi-Fi е изключен от Windows, агентът първо го включва. При работеща връзка не предприема действие. Стойност 0 изключва автоматичните опити.' 18 108 450 68
    $sec.Enabled=$mode.SelectedIndex -eq 0
    $mode.add_SelectedIndexChanged({$sec.Enabled=$mode.SelectedIndex -eq 0})
    $save=Control Button 'Приложи настройките' 18 180 215 34
    $info=Control TextBox '' 18 232 450 115;$info.Multiline=$true;$info.ReadOnly=$true;$info.ScrollBars='Vertical'
    $automatic=Control Button 'Автоматичен DNS' 18 368 202 37
    $restore=Control Button 'Възстанови запазения DNS' 230 368 238 37
    $null=Control Label 'Спиране на браузерите през 6 секунди' 18 426 450 24
    $null=Control Label 'Продължителност (минути)' 18 460 260 24
    $guardMinutes=Control NumericUpDown '' 310 456 90 28;$guardMinutes.Minimum=1;$guardMinutes.Maximum=240;$guardMinutes.Value=40
    $guardOn=Control Button 'Включи спирането' 18 496 215 37
    $guardOff=Control Button 'Разреши браузерите' 243 496 225 37
    $guardInfo=Control Label '' 18 544 450 70
    $null=Control Label 'Спиране на процеси от списъка (през 6 секунди)' 18 618 450 24
    $null=Control Label 'Продължителност (минути)' 18 650 260 24
    $gameMinutes=Control NumericUpDown '' 310 646 90 28;$gameMinutes.Minimum=1;$gameMinutes.Maximum=240;$gameMinutes.Value=40
    $gameOn=Control Button 'Спиране на игрите' 18 686 240 37
    $gameOff=Control Button 'Разрешаване на игрите' 268 686 200 37
    $gameInfo=Control Label '' 18 734 450 65
    function Refresh-Info {
        $gamePolicy=Read-GamePolicy
        $gameInfo.Text=if(Test-GamePolicyActive $gamePolicy){'Спиране на игрите: включено до '+([datetime]$gamePolicy.ExpiresUtc).ToLocalTime().ToString('HH:mm')+'. Списъкът се управлява от Classroom108.'}else{'Спиране на игрите: изключено. Списъкът се управлява от Classroom108.'}

        $guardPolicy=Read-BrowserPolicy
        $guardInfo.Text=if(Test-BrowserPolicyActive $guardPolicy){'Включено през 6 секунди до '+([datetime]$guardPolicy.ExpiresUtc).ToLocalTime().ToString('HH:mm')+'. Незаписаната работа може да се загуби.'}else{'Периодичното спиране е изключено. Wi-Fi настройките са независими.'}
        $info.Text=(@(Get-NetAdapter -Physical | Where-Object {[int]$_.NdisPhysicalMedium -in 1,9} | ForEach-Object {
            $key='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'+([guid]$_.InterfaceGuid).ToString('B')
            $method=if((Get-ItemProperty $key).NameServer){'ръчно'}else{'автоматично'}
            "$($_.Name): $method — $((Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4).ServerAddresses -join ', ')"
        }) -join [Environment]::NewLine)
    }
    function Admin-Action($arguments){
        try{$p=Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -PassThru -Wait
            if($p.ExitCode){throw 'Операцията не завърши успешно.'}; Refresh-Info
        }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Agent108')|Out-Null}
    }
    $save.add_Click({$policy=if($mode.SelectedIndex -eq 0){'Students'}else{'All'};Admin-Action @('interactive','configure',$policy,[string]$sec.Value)})
    $automatic.add_Click({Admin-Action @('interactive','automatic')})
    $restore.add_Click({Admin-Action @('interactive','restore')})
    $guardOn.add_Click({if([Windows.Forms.MessageBox]::Show('Браузерите ще се затварят принудително. Незаписаната работа може да се загуби. Да включа ли режима?','Agent108','YesNo') -eq 'Yes'){Admin-Action @('interactive','browsers-on',[string]$guardMinutes.Value,'6')}})
    $guardOff.add_Click({Admin-Action @('interactive','browsers-off')})
    $gameOn.add_Click({if([Windows.Forms.MessageBox]::Show('Процесите от списъка ще се затварят принудително през 6 секунди. Напредъкът в играта може да се загуби. Да включа ли спирането на игрите?','Agent108','YesNo') -eq 'Yes'){Admin-Action @('interactive','games-on',[string]$gameMinutes.Value,'6')}})
    $gameOff.add_Click({Admin-Action @('interactive','games-off')})
    Refresh-Info
    [void]$form.ShowDialog()
}
function Invoke-Agent([string]$command,[string]$mode,[string]$seconds,[string]$extra){
    if($command -eq 'interactive'){
        try{
            if($mode -eq 'restore'){
                Add-Type -AssemblyName System.Windows.Forms
                $path=Join-Path $env:ProgramData 'Classroom108\DnsControl\PreviousDns.json'
                if(-not(Test-Path -LiteralPath $path)){throw 'Няма запазени DNS настройки за възстановяване.'}
                $saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $adapters=@(Get-NetAdapter -Physical | Where-Object {[int]$_.NdisPhysicalMedium -in 1,9 -and ([guid]$_.InterfaceGuid) -eq ([guid]$saved.AdapterGuid)})
                if($saved.Computer -ine $env:COMPUTERNAME -or $adapters.Count -ne 1){throw 'Записът е за друг компютър или адаптер.'}
                $preview=if($saved.Mode -eq 'Automatic'){'Автоматичен DNS'}else{$saved.Servers -join ', '}
                if([Windows.Forms.MessageBox]::Show("$($adapters[0].Name): $preview. Да възстановя ли тези настройки?",'Agent108','YesNo') -ne 'Yes'){return}
            }
            Invoke-Agent $mode $seconds $extra}catch{Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Agent108')|Out-Null;throw};return
    }
    switch ($command){
        'install'{Invoke-Network NetDnsSnapshot | Out-Null; Configure $mode ([int]$seconds); if (-not (Get-ItemProperty -LiteralPath $reg -Name BrowserPolicy -ErrorAction SilentlyContinue)) { Set-BrowserGuard $false }; Restore-BrowserGuard; if (-not (Get-ItemProperty -LiteralPath $reg -Name GamePolicy -ErrorAction SilentlyContinue)) { Set-GameGuard $false }; Restore-GameGuard}
        'upgrade'{Restore-AgentWorkers}
        'games-patterns'{Set-GamePatterns $mode}
        'games-on'{Set-GameGuard $true ([int]$mode) ([int]$seconds)}
        'games-off'{Set-GameGuard $false}
        'games-watch'{Invoke-GameGuard}
        'browsers-on'{Set-BrowserGuard $true ([int]$mode) ([int]$seconds)}
        'browsers-off'{Set-BrowserGuard $false}
        'browsers-watch'{Invoke-BrowserGuard}
        'configure'{Configure $mode ([int]$seconds)}
        'automatic'{Invoke-Network NetDnsAutomatic | Out-Null}
        'restore'{Invoke-Network NetDnsRestore | Out-Null}
        'watch'{$check=[scriptblock]::Create($worker);while($true){$cfg=Read-Config;if($cfg.Mode -ne 'Students' -or $cfg.Seconds -le 0){return};try{& $check -Profile Students}catch{Write-Warning $_.Exception.Message};Start-Sleep -Seconds $cfg.Seconds}}
        'selftest'{if((Read-Config).Seconds -lt 0){throw 'Invalid settings'};[void][scriptblock]::Create($worker)}
        ''{Show-Agent}
        default{throw 'Unknown action'}
    }
}
