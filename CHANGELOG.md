# Changelog

Versions follow the `version` field in `.claude-plugin/plugin.json`; Claude
Code offers a plugin update when that field changes. Each version is a git
tag (`v0.1.0`) and a GitHub release with this section as its notes.

## 0.1.0 — 2026-09-30

- **Interim release** of the author's home statusline script, packaged as the
  `usage-statusline` plugin ahead of the port described in
  `docs/plans/01-plan-limit-fitting.md`.
- Shows model, effort, context and session cost; 5-hour and 7-day usage bars
  from Claude Code's status input; the Fable weekly bar and an overage
  `credits:` line from the account's usage endpoint (cached, refreshed in the
  background every 60 seconds); reset countdowns on bars at 70% or more; and
  a git location row.
- `/usage-statusline:install` copies the script under `~/.claude` and wires
  `statusLine` in `settings.json`, showing the change first.
- Linux, WSL and Git Bash only: macOS is refused by the installer (GNU
  `stat -c`, and the credentials live in the Keychain there). No doctor, no
  config file, no knobs yet.
- Listed in the [claude-toolbox](https://github.com/MasonFlint44/claude-toolbox)
  marketplace.
