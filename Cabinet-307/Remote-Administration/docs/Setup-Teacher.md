# Setup-Teacher.ps1

**Цел:** настройва Windows PowerShell Remoting **клиента** на `307-Teacher`.

**Действия:** проверява права на администратор; стартира локалната услуга WinRM; запазва стария списък TrustedHosts само при първото изпълнение; добавя конкретните 27 имена `307-Student-XX.local`, без да изтрива съществуващите. При повторно стартиране не дублира имена.

**Употреба:** От повишен Windows PowerShell: `.\Setup-Teacher.ps1`.

**Не прави:** не включва входящ PowerShell Remoting, не променя Windows Firewall или UAC, не съхранява парола, не създава потребители, не преименува учителския компютър.

**Проверка:** `Get-Item WSMan:\localhost\Client\TrustedHosts`, след това `Test-NetConnection 307-Student-24.local -Port 5985`.

**Възстановяване:** запазената стара стойност е в `C:\ProgramData\Cabinet307\TrustedHosts-before-setup.txt`. Администратор може да я върне с `Set-Item WSMan:\localhost\Client\TrustedHosts -Value (Get-Content 'C:\ProgramData\Cabinet307\TrustedHosts-before-setup.txt' -Raw).Trim() -Force`. Проверете стойността преди връщане, ако междувременно има легитимни промени.

**Риск:** TrustedHosts не потвърждава, че срещу нас действително стои довереният компютър; .local разпознаването зависи от мрежата.
