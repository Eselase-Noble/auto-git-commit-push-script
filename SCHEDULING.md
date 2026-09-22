# Scheduling `agent_pipeline.sh` per OS

The script itself is cross-platform (bash). Only the *scheduler* differs by OS.
It writes logs to an OS-appropriate directory automatically:

- **macOS:** `~/Library/Logs/auto-git/`
- **Linux / WSL:** `${XDG_STATE_HOME:-~/.local/state}/auto-git/`
- Override anywhere with `AUTOGIT_LOG_DIR=/path`.

Requirements on every OS: `git`, `gh` (authenticated: `gh auth login`), `claude`, `jq`.

---

## macOS — launchd

```sh
cp LaunchAgents/com.eselase.autogit.agent.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.eselase.autogit.agent.plist
# to stop:
launchctl unload ~/Library/LaunchAgents/com.eselase.autogit.agent.plist
```

Runs hourly at :15 (edit `StartCalendarInterval` in the plist to change).

---

## Linux — cron

```sh
crontab -e
```

Add (runs hourly at :15):

```cron
15 * * * * /bin/bash /path/to/auto-git-commit-push-script/agent_pipeline.sh
```

## Linux — systemd (alternative to cron)

`~/.config/systemd/user/autogit-agent.service`:

```ini
[Unit]
Description=Agent git pipeline

[Service]
Type=oneshot
ExecStart=/bin/bash /path/to/auto-git-commit-push-script/agent_pipeline.sh
```

`~/.config/systemd/user/autogit-agent.timer`:

```ini
[Unit]
Description=Run agent git pipeline hourly

[Timer]
OnCalendar=*-*-* *:15:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:

```sh
systemctl --user daemon-reload
systemctl --user enable --now autogit-agent.timer
```

---

## Windows

Bash scripts don't run natively on Windows. Two supported paths:

### Recommended: WSL (Windows Subsystem for Linux)

Install WSL, then treat it exactly like Linux above (use **cron** or **systemd**).
Install `git`, `gh`, `jq`, and `claude` *inside* the WSL distro.

### Native: Task Scheduler + Git Bash

If you have Git for Windows (which ships Git Bash), you can schedule the script
without WSL:

1. Open **Task Scheduler** → *Create Task*.
2. **Trigger:** Daily/hourly as desired.
3. **Action:** *Start a program*
   - Program: `C:\Program Files\Git\bin\bash.exe`
   - Arguments: `-lc "/c/path/to/auto-git-commit-push-script/agent_pipeline.sh"`
4. Ensure `gh`, `jq`, and `claude` are on the PATH seen by Git Bash.

> A fully native PowerShell rewrite is possible but is a separate port — WSL is
> the low-effort route to identical behavior on Windows.
