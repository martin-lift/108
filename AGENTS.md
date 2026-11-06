# Persistent repository instructions

## GitHub workflow

- This repository is `martin-lift/108` on GitHub. For the Cabinet 307 scripts, the shared destination is `origin/main`.
- After each completed script change, run the checks appropriate to the change, create a Git commit, and push the completed changes to GitHub.
- The user explicitly authorizes ordinary commits and pushes to `main` in `martin-lift/108` in advance. Do not ask for this permission again for each change.
- Check the current remote state and preserve other people's work. Never use force push unless separately requested.
- If a tool or automatic approval review blocks publication, state the actual reason and what remains unpushed. Do not claim that publication succeeded.

## Avoid redundant backups of content in GitHub

- Do not make redundant backup copies of files or other content already recoverable from GitHub. Use Git history for those files instead of `.bak`, `.old`, timestamped copies, backup directories or archives.
- This rule does not prohibit saving settings or data that GitHub does not contain, including previous DNS settings needed for restoration. Automatic saving of such settings is allowed when it is part of the requested functionality.
- This does not authorize deleting existing files or backups. Preserve unrelated content.

## Cabinet 307 context

- The working teacher menu is `C:\307\Teacher-Menu.ps1`; its repository source is `Cabinet-307/Remote-Administration/Teacher-Menu.ps1`.
- Student computers are controlled through the existing WinRM scripts. Keep the existing credential prompt and remote identity checks.
- Files in a ChatGPT project mirror's `sources/` directory are read-only references.
- Communicate with the user in Bulgarian, briefly and directly.
