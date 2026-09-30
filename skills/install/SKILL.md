---
name: install
description: Install or update the usage statusline — copies the statusline script to a stable location under ~/.claude and wires statusLine in settings.json. Use when the user asks to install, set up, enable or update the usage statusline (the 5-hour / 7-day / Fable plan-limit bars), says the statusline is not showing at all, has just updated the plugin and wants the installed copy refreshed, or wants the statusLine command to work from a devcontainer or another account that shares ~/.claude.
---

# Install the usage statusline

Plugins cannot set `statusLine` themselves, and the plugin's own directory moves on every version update, so this skill copies the script somewhere stable and points settings at that copy. Idempotent: safe to re-run after a plugin update.

This is the interim release: the original bash script, before the port described in `docs/plans/01-plan-limit-fitting.md`. It has no `--doctor`, no config files and no knobs yet.

## Steps

1. **Check the platform.** The script runs on Linux, WSL and Git Bash on Windows. On macOS (`uname` prints `Darwin`), stop: tell the user macOS is not supported in this release (the script uses GNU `stat -c`, and the Fable bar reads a credentials file that macOS keeps in the Keychain instead) and that support comes with the port. Do not install it there.

2. **Check the tools.** Run `command -v jq curl git awk`. `jq` is required (nothing renders without it); `curl` feeds the Fable bar; `git` feeds the location row. If one is missing, name it with the install command for this platform (`sudo apt install jq`, `sudo dnf install jq`, or `winget install jqlang.jq` for Git Bash) and stop until it is installed.

3. **Copy to the stable location.** Resolve the config dir as `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`; call it `$CFG` below.
   ```bash
   CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   mkdir -p "$CFG/statusline"
   cp "${CLAUDE_PLUGIN_ROOT}/statusline/usage-statusline.sh" "$CFG/statusline/"
   chmod +x "$CFG/statusline/usage-statusline.sh"
   ```
   The script is refreshed every time; there is no user config to preserve.

4. **Wire settings.** Read `$CFG/settings.json`. Show the user the exact change before making it, then set `statusLine.command` to this text **exactly as written**, with the shell expression left unexpanded:
   ```json
   "statusLine": { "type": "command", "command": "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/usage-statusline.sh\"" }
   ```
   Claude Code runs the command through a shell, so each machine resolves the path for itself: the same settings file then works when `~/.claude` is shared with a devcontainer or another user account whose home directory differs. Write it with a JSON tool (`jq --arg`) or check the result with `jq -r .statusLine.command`, which must print `bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/usage-statusline.sh"`.
   - **Updating an earlier install** whose command names the script by an absolute path (`bash /home/<user>/.claude/statusline/usage-statusline.sh`): that is this plugin's own command, so replace it with the form above without asking, keeping anything in front of `bash`.
   - **A different statusline** already set (a command naming another script, including the spend statusline's `spend-statusline.sh`): say so and ask before replacing it; the two cannot both be active.
   - Never touch any other key.

5. **Smoke-test the installed copy** and show the output:
   ```bash
   echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'"$PWD"'"}}' | bash "$CFG/statusline/usage-statusline.sh"
   ```
   It should print a model segment and the location row. A blank output or an error means the install failed; show the error.

6. **Tell the user** the statusline appears on the next refresh, no restart needed (Claude Code picks up the settings change live). Then say what to expect:
   - The 5-hour and 7-day bars come from Claude Code's own status input, which carries them only for Pro and Max subscribers signed in with their Claude account. An API-key session shows no rate bars.
   - The Fable bar and the `credits:` line come from the account's usage endpoint, read with the OAuth token in the config dir's `.credentials.json` and refreshed in the background every 60 seconds, so they appear a render or two after install. They hide themselves when the account has no Fable window or no overage spend.
   - Reset countdowns appear on a bar once it reaches 70%.
   - Point them at the plugin's `README.md` for more.

## Do not

- Do not point `statusLine` at the plugin directory — it changes on update.
- Do not install on macOS in this release.
- Do not expand `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` or write an absolute path into the command; the literal form is what lets a shared settings file work everywhere.
- Do not edit settings without showing the change first.
