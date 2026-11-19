SHINYSLACK V16 — 20-SECOND README

1. Extract the ZIP. Do NOT run from inside the ZIP.
2. In Slack, select Knock Brush and receive one REAL notification once.
3. Run Start-ShinySlack.cmd.
4. Drop an MP3 -> Apply Sound.
5. Green cards = good. Watcher should say WATCHING.

Activity is newest-first. The watcher writes a heartbeat every ~15s.
If Watcher says Not watching, Activity now shows watcher.trace/stderr/stdout diagnostics automatically.
Repair Now intentionally restarts Slack; the background watcher never force-closes a running Slack session.

Logs: %LOCALAPPDATA%\ShinySlack\

UPGRADES: Opening a newer extracted build automatically updates/restarts only the installed watcher/runtime. It does not restart Slack or repatch the sound just to upgrade the agent.
