# Teacher menu

Download `Start-Teacher.cmd`, `Teacher-Menu.ps1`, and the current `Manage-Classroom.ps1` into the same folder, for example `C:\307`. Save the actual files using Raw / Download raw file, not the GitHub HTML page. Double-click `Start-Teacher.cmd` and approve the Windows administrator prompt. The launcher uses Windows PowerShell 5.1 and ExecutionPolicy Bypass for this process only; organization policy still takes precedence. Passwords are requested interactively and are not saved.

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
