# Teacher menu

Download `Start-Teacher.cmd`, `Teacher-Menu.ps1`, `Credential-Helper.ps1`, and the current `Manage-Classroom.ps1` into the same folder, for example `C:\307`. Save the actual files using Raw / Download raw file, not the GitHub HTML page. Double-click `Start-Teacher.cmd` and approve the Windows administrator prompt. The launcher uses Windows PowerShell 5.1 and ExecutionPolicy Bypass for this process only; organization policy still takes precedence. Passwords are requested interactively and are not saved.

## Actions

Groups are separated by a blank line. The current numbering is:

```text
1. Shut down student computers (all or selected)
2. Restart student computers (all or selected)

3. Restrict All computers 01-27 to school Wi-Fi (default: Students)
4. Remove restrictions on other Wi-Fi networks for all computers

5. Restrict selected computers to school Wi-Fi (default: Students)
6. Remove restrictions on other Wi-Fi networks for selected computers
7. Show Wi-Fi connection and filters on a selected computer
8. Check Wi-Fi restrictions on selected computers (Students)

9. List processes on a selected computer and save a report (all or filtered)
10. Stop processes on a selected computer by exact name or substring

11. Send a file to a student computer
12. Receive a file from a student computer

13. Start WinRM and check the teacher computer
14. Check the names of all 27 student computers

15. Use teacher DNS on students' computers (Wi-Fi IPv4)
16. Restore DNS on students' computers (saved settings or automatic)
17. Start AdGuard Home on the teacher computer
18. Open AdGuard Home control panel
19. Clear Windows DNS cache on student computers (all or selected)
20. Open school website on student computers (all or selected)

0. Exit
```

## Open the school website (menu action 20)

Opens `https://martin-lift.github.io/108/` in the default browser of the user logged on at each selected student computer's physical console. Choose A for all 27 students, S to enter selected numbers (one number is allowed), or Enter to cancel. The shared 108SU administrator password is requested once for WinRM. No student user password is requested or saved.

Because WinRM does not run on the student's desktop, the remote command uses a unique, demand-only Windows task with the existing console user's interactive token and least privilege. It explicitly selects that console session, verifies the user again before launching, and checks the session and user SID in the launcher. The hidden PowerShell launcher opens the fixed URL through the user's normal browser association. The temporary task is removed after the attempt; queued attempts are cancelled. No startup/login trigger is created. If cleanup fails, its unique task name is reported for administrator review.

Results: `LAUNCH_REQUESTED` means the launcher completed successfully in the user session; it does not prove that the page loaded. `NO_USER` means no console user is logged on. `SESSION_CHANGED` skips a computer whose console user changed during preparation. `ERROR` reports a launcher failure; `UNKNOWN` means completion could not be confirmed, so check before retrying. Login/connection failures are shown per computer and do not stop remaining targets. A locked session may show the browser after the user unlocks it; the menu does not unlock Windows. Windows Task Scheduler, the default browser association and remoting must be available.

Validation uses simulated console sessions, Task Scheduler and WinRM, including task cleanup and failures. A real student desktop/browser trial is still required; the tests do not open browsers on student computers.

## File transfers

Choose computer 1-27 and enter an absolute source file path, such as `C:\307\task.pdf`. For receiving, the source path is on the student computer. Enter an existing destination folder, a full destination file path, or accept the default. When a folder is selected, the source file name is appended automatically in either transfer direction. The destination folder must already exist. Enter the selected computer's local 108SU password. An existing destination file requires the exact confirmation REPLACE. Copies are verified with SHA-256, and the remote session is closed even on failure. A failed copy can leave a partial destination file; there is no automatic rollback of an overwritten file.

The student computer must be reachable by its `307-Student-XX.local` name, with WinRM configured and the teacher TrustedHosts entry present. The menu verifies the remote computer name before file transfer. It does not show student screens.

## Windows DNS cache (menu action 19)

Choose A for all 27 student computers, S to enter selected numbers, or Enter to cancel. The shared administrator password is requested once. Each student is checked by name before `Clear-DnsClientCache` runs through WinRM. A result table shows success or the reason for failure for every target; an unavailable computer does not stop the others. Missing confirmation or a lost connection is reported as UNKNOWN. Sessions are closed after each attempt.

This clears the Windows DNS resolver cache for the whole student computer, without changing DNS servers, IP settings, recovery backups, browser history, cookies or passwords. It does not close browsers or existing connections. AdGuard Home does not need to be running for this action, and no restart is required.

Actions 15 and 16 also clear the Windows DNS cache after a successful DNS change. Their result notes explicitly confirm cache clearing or report a cache-clearing failure while retaining the successfully applied DNS settings. See [DNS and AdGuard](DNS-AdGuard.md).

## Validation

PowerShell syntax was checked. File sending, receiving, overwrite cancellation, hash comparison, and session cleanup were exercised using simulated remoting; real classroom file transfer still requires a trial on one student computer.

## Read-only Wi-Fi restriction audit (menu action 8)

Download `Check-WifiRestrictions.ps1` into the same folder as `Teacher-Menu.ps1`. Action 8 checks the selected computers for the expected SSID `Students`, without changing remote network settings. It reads the four WLAN filter lists through [WlanGetFilterList](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlangetfilterlist), avoiding localized netsh text and Wi-Fi scan/location permissions. A native read may still fail due to permissions, unavailable WLAN services, or application-control policy; these failures are reported.

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

## Process review (menu action 9)

Select one student computer (1-27), then choose a report type. Enter or F selects interesting processes only (the default); A selects a complete inventory; 0 cancels. The menu reads its process snapshot, displays names and PIDs, and saves a UTF-8 TXT report under `Reports` beside the menu. The report includes available file description, company, executable path, start time, session ID, parent PID and parent name. Parent names are resolved within the snapshot; an absent or newer parent PID has no name.

For a filtered review, the teacher computer downloads [Uninteresting-Processes.json](../Uninteresting-Processes.json) from this repository's public `main` branch, validates it, and stores a local copy beside the menu. The download has a ten-second timeout. If GitHub is unavailable, it uses a valid local copy; if neither is usable, it explicitly warns and produces a complete inventory. Downloading the JSON manually alongside the menu also enables offline use. The JSON is data only and is never executed.

The shared list contains 66 exact process names, matched without case sensitivity, with a reason for each classification. It covers reviewed Windows background processes, security components, hardware/audio services, update services and OneDrive. It is a reporting filter, not a security allowlist. Names outside the list always remain for review. Browser and WebView2 processes remain visible because their executable names do not tell us which content is open. The list was derived from a classroom process report; the original report, PIDs and collected process data are not published in this repository.

In the default filtered mode, both the console and TXT report omit matching process records. A retained process's parent name is redacted if it is in the excluded list. The header records total, excluded and reported counts plus the filter revision and source, without listing the excluded names. A report with zero remaining processes is still saved. Edit the JSON and increment `Revision` to change the shared filter for all scripts that use it.

The existing name, path, description, company, session and time fields are enough for initial classroom classification. The parent name adds context for helper processes. For unresolved cases, inspect the specific process's owner, signature or command line separately; bulk collection of command lines is not part of this report. Company and description are unverified file metadata, and browser game activity cannot be established from this process inventory alone.


A full inventory skips the background filter and its download, includes all process names and parent names, and records `Full inventory` in the report header. Each use asks again, with the filtered view selected by pressing Enter.

## Stop processes (menu action 10)

Select one student computer, choose E for an exact name or S for a literal substring, and enter the search text. Matching is case-insensitive. Exact mode accepts `msedge` and `msedge.exe`; substring `edge` matches any executable name containing that text. Substrings are not regular expressions or wildcards. An empty computer, match mode or search text cancels.

The menu searches all processes independently of the report exclusion list and displays every match with its name, PID, session, path, eligibility and any blocking reason. It then states how many eligible processes will be forcibly terminated on the named computer. Enter cancels; only the exact text `STOP` confirms. Unsaved work in the targeted applications can be lost. System/service processes in session 0, the management host and essential Windows desktop/session processes cannot be stopped through this action.

Confirmation applies only to the displayed eligible process instances. The stop command rechecks the remote computer and each process's name, session and start time while holding its OS process handle. Reused PIDs are skipped, and newly started matching instances are not added. Only the approved processes are terminated; there is no automatic tree termination, repeat scan or retry.

Per-process results distinguish `STOPPED`, `ALREADY_EXITED`, `SKIPPED_CHANGED`, `BLOCKED`, `ERROR` and `UNKNOWN`. `STOPPED` requires the process exit to be confirmed. A timeout or lost connection can leave the result unknown; inspect the computer before retrying. Sessions are closed on success, cancellation and failure.

Validation: Windows PowerShell 5.1 tests cover literal/exact matching, case differences, preview cancellation, protected processes, stale identities, newly started processes, denied termination, unconfirmed exits, lost connections and cleanup using fake process objects. Process-report tests cover the default filtered mode and optional full inventory. Real classroom process termination still requires a trial on one selected application.
