# Teacher menu

Download `Start-Teacher.cmd`, `Teacher-Menu.ps1`, `Credential-Helper.ps1`, and the current `Manage-Classroom.ps1` into the same folder, for example `C:\307`. Save the actual files using Raw / Download raw file, not the GitHub HTML page. Double-click `Start-Teacher.cmd` and approve the Windows administrator prompt. The launcher uses Windows PowerShell 5.1 and ExecutionPolicy Bypass for this process only; organization policy still takes precedence. Passwords are requested interactively and are not saved.

## Actions

1. Start WinRM and display the teacher service and TrustedHosts.
2. Read computer names from all 27 targets, with immediate per-computer progress. Unreachable computers can still delay the sequence.
3. Show Wi-Fi interfaces and filters on a selected computer.
4. Allow the entered school SSID (default: Students), then deny other infrastructure and ad hoc networks. Check the displayed current connection first. Other existing Allow entries remain allowed. Type YES to confirm. This does not block USB tethering or provide strong network authentication by SSID.
5. Remove the infrastructure and ad hoc deny-all filters after confirmation. Allow entries remain. If remote access is lost, run the removal commands locally as administrator.
6. Send one file to a student computer. Default destination: its public desktop, visible to all users.
7. Receive one file from a student computer. Default destination: the menu folder, with the computer name prefixed to the file name.
0. Exit.

## File transfers

Choose computer 1-27 and enter an absolute source file path, such as `C:\307\task.pdf`. For receiving, the source path is on the student computer. Enter an existing destination folder, a full destination file path, or accept the default. When a folder is selected, the source file name is appended automatically in either transfer direction. The destination folder must already exist. Enter the selected computer's local 108SU password. An existing destination file requires the exact confirmation REPLACE. Copies are verified with SHA-256, and the remote session is closed even on failure. A failed copy can leave a partial destination file; there is no automatic rollback of an overwritten file.

The student computer must be reachable by its `307-Student-XX.local` name, with WinRM configured and the teacher TrustedHosts entry present. The menu verifies the remote computer name before file transfer. It does not show student screens.

## Validation

PowerShell syntax was checked. File sending, receiving, overwrite cancellation, hash comparison, and session cleanup were exercised using simulated remoting; real classroom file transfer still requires a trial on one student computer.

## Read-only Wi-Fi restriction audit (menu action 10)

Download `Check-WifiRestrictions.ps1` into the same folder as `Teacher-Menu.ps1`. Action 10 checks all 27 computers for the expected SSID `Students`, without changing remote network settings. It reads the four WLAN filter lists through [WlanGetFilterList](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlangetfilterlist), avoiding localized netsh text and Wi-Fi scan/location permissions. A native read may still fail due to permissions, unavailable WLAN services, or application-control policy; these failures are reported.

- RESTRICTED: the local filters allow only the expected infrastructure SSID and contain deny-all rules for infrastructure and ad hoc networks.
- UNRESTRICTED: no deny filters are present. An allow entry by itself does not restrict other networks.
- PARTIAL: a required filter is missing, an additional network is allowed, the school SSID is blocked, or Group Policy filters require separate evaluation.
- LOGIN_ERROR: the session-opening error indicates refused authentication/access. This does not prove that only the password is wrong; account state and access rights can also cause refusal.
- ERROR: other connection, hostname verification, or filter-reading failures. Access denied during the filter read is ERROR, because the session has already opened.

All targets are attempted even after LOGIN_ERROR. There are no Yes/All confirmation prompts. A single credential prompt is preceded by an English keyboard-layout reminder. Each target gets one status line; the final table shows all results other than RESTRICTED with reasons. USB tethering and SSID impersonation are outside this filter audit.

Standalone examples:

```powershell
.\Check-WifiRestrictions.ps1 -All
.\Check-WifiRestrictions.ps1 -Numbers 9
.\Check-WifiRestrictions.ps1 -Numbers 1,9,11 -SchoolSSID Students
```

Standalone calls also return structured results for export; action 10 suppresses the duplicate object display. The native reader compiles in memory in the remote session and does not install files or change WLAN policy. Syntax, native helper compilation, restriction classifications, continued processing after login/network failures, and session cleanup were checked locally with simulated remoting. Real classroom execution still requires a trial.

## Shared credential helper

Keep `Credential-Helper.ps1` in the same folder as the menu and the standalone scripts. Each remote operation uses it to validate the entered password locally before connecting. Rejected credentials stop the operation; account and policy errors have separate explanations. After the local check passes, failures on individual remote targets continue to be reported without stopping the remaining targets. Local actions do not require this check. The helper does not save passwords.
