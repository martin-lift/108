# Setup-Student.ps1

**Цел:** еднократна локална подготовка на ученически Windows 11 Education PC за отдалечено управление.

**Параметри:** задължителен `-Number` от 1 до 27; опционален **рисков** `-AllowFullRemoteToken`; поддържа `-WhatIf` и потвърждения.

**Пример (проверка):** `.\Setup-Student.ps1 -Number 1 -WhatIf`

**Пример (реално):** `.\Setup-Student.ps1 -Number 1` от локален PowerShell като администратор.

**Действия:** проверява наличие и административна група на `108SU` или `108 SU`; отказва при двата акаунта или липса на двата; преименува `108 SU` на `108SU` (не променя SID, парола, профилна папка); активира WinRM с `-SkipNetworkProfileCheck` при Public профил; задава име `307-Student-XX`, с необходим рестарт. Запазва ограничено начално състояние при първото стартиране.

**Внимание:** `Enable-PSRemoting` може само да промени `LocalAccountTokenFilterPolicy` и firewall правила според конкретната среда; затова проверете реалното състояние след изпълнение. Опционалният флаг `-AllowFullRemoteToken` изрично задава LATFP=1, което намалява UAC защитата за всички локални администратори. Не се препоръчва като безусловен стандарт за 27 PC.

**Проверка след рестарт:** локално `hostname`, `Get-Service WinRM`, `Get-NetConnectionProfile`, `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy`; дистанционно — `Test-Student.ps1`.

**Възстановяване:** snapshot в `C:\ProgramData\Cabinet307\Student-before-setup.json` съдържа начално име, стар административен username, стар status/start type на WinRM и началната стойност/наличие на LATFP. Това е **информация за ръчно възстановяване, не автоматичен rollback**. Името и WinRM firewall правилата не се възстановяват автоматично.

**Предварително условие:** системата трябва да има действително зададена парола за `108SU`; не добавяйте паролата към скрипта или GitHub.
