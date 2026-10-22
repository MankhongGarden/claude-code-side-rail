# claude-code-side-rail

**A narrow, always-on PowerShell panel that sits next to Claude Code in Windows Terminal and shows, at a glance, which of your sessions needs you, how much of your 5-hour and 7-day usage is left, and whether the prompt cache is about to expire.**

> [!WARNING]
> **Experimental.** Built and used by one person on one Windows 11 machine since June 2026. Tested on Windows 11 with PowerShell 7.6.6 and Windows Terminal (2026-10-22). The usage bars call an **undocumented** endpoint and the cache timer reads Claude Code's transcript files, whose format is not a public API (see [Limitations](#limitations)). Expect breakage after Claude Code updates.

A frame of the rail (text copy, example values):

```text
 SIDE RAIL ───────────────────────────
 ◆ web-app  ⎇ main
 ─────────────────────────────────────
 ▸ frontend-design 4s  ● 1 need you
 ─────────────────────────────────────
 5h ▓▓▓░░░░  41%  ↻16:00
 7d ▓▓░░░░░  27%  ↻Mon 09:00
 mode ● plan only
 cache 1m/5m ok
 ─────────────────────────────────────
 ◆ Opus 5.5  eff:high
 recent frontend-design
 sess · 3 live
 ‼ api NEEDS YOU 3m
 ● web frontend-design 0m
 ⏸ docs idle 12m
 ─────────────────────────────────────
 PROJECTS
 web    main    *1
 api    main    ✓ ↑2
 ─────────────────────────────────────
 hook ●  usage ●
 ⟳ 12:46:38
 [1]web [2]api
 [+]new  [r]refresh  [q]quit
```

**TL;DR**
- With several Claude Code sessions open in different terminals, it is easy to miss the one that has been waiting for a permission answer for ten minutes, to hit the 5-hour limit by surprise, or to come back after the prompt cache expired.
- `side-rail.ps1` is a ~550-line PowerShell 7 TUI you put in a narrow left pane. It re-draws in place (no flicker) and stays quiet: green and grey normally, yellow/red and blinking only when something needs you.
- A tiny hook (`rail-hook.ps1`) appends one JSON line per Claude Code event (`PreToolUse:Skill`, `Notification`, `Stop`, `SessionEnd`) to a local file. The rail reads it to build a live roster of **all** sessions on the machine, with a red "NEEDS YOU" row for any session that raised a notification.
- It also shows: current project and git branch, active model and effort level, recently used skills, git status of your configured projects (dirty files, unpushed commits), and number keys to start Claude Code in another project.
- Optional: a "wrong Vercel account" guard for projects linked with `vercel link`, and a "recently changed" alert for any file you choose to watch.

---

## The problem

Claude Code's own status line shows the current session. What I kept missing was everything **around** it:

1. **Sessions waiting on me in another tab.** A `Notification` event (permission prompt, idle input) in a background terminal is invisible until I switch to it.
2. **Usage limits.** `/usage` tells you, but only when you ask. I wanted the 5-hour and 7-day bars always in view, plus a clear marker when extra (paid) usage is switched on.
3. **Prompt cache expiry.** After a break longer than the cache TTL (5 minutes or 1 hour), the next message re-writes the whole context to the cache. A timer showing "4m/5m soon" or "EXPIRED" helps decide whether to send now or `/compact` first.
4. **Which project am I in, and is it clean?** With several repos, a one-line git summary per project catches forgotten unpushed work.

The rail answers these without spending tokens: everything except the usage bars is read from local files.

## Install

Requirements: Windows 10/11, PowerShell 7 (`pwsh`), Windows Terminal (for side-by-side panes), `git` on `PATH`, Claude Code.

```powershell
git clone https://github.com/MankhongGarden/claude-code-side-rail
cd claude-code-side-rail
Copy-Item rail.config.example.json rail.config.json
notepad rail.config.json                 # add your projects
pwsh -NoProfile -File .\install-hook.ps1  # adds the event hook to your user settings.json
```

`install-hook.ps1`:
- edits `settings.json` in `claudeHome` (from the config; else `CLAUDE_CONFIG_DIR`; else `~\.claude`);
- writes a backup to `settings.json.railbak` first, re-reads the result, and restores the backup if `statusLine` or `permissions` went missing;
- is idempotent (re-running replaces its own entries), and only touches hook entries whose command contains `rail-hook.ps1`;
- `-Uninstall` removes exactly those entries.

Restart your Claude Code sessions afterwards. Without the hook the rail still runs and shows "(hook not set)" for the session parts.

### Running it

- **Side by side, automatically:** `pwsh -File .\start-rail.ps1 -Project web-app` opens a new Windows Terminal window with the rail on the left (28%) and Claude Code on the right, in that project's folder.
- **By hand:** in Windows Terminal, split a pane (Alt+Shift+-/+), and run `pwsh -NoProfile -File <path>\side-rail.ps1`. Without `-Project` it follows the session you used most recently.
- `-Once` prints one frame and exits (handy for testing your config).

Keys: `1`-`9` start Claude Code in that project in a new window · `+` start one in the current project · `r` refresh now · `q` quit.

## Configuration

`rail.config.json` (falls back to `rail.config.example.json`). Paths accept `%ENV_VARS%` and a leading `~`.

| Key | Default | Meaning |
|---|---|---|
| `projects` | `[]` | `{ key, name, short, path, vercel? }` per project. `key` is the hotkey, `short` the label (≤ 7 chars fits), `vercel` the expected Vercel account (see below). |
| `claudeHome` | `CLAUDE_CONFIG_DIR`, else `~\.claude` | Claude Code config folder (transcripts, credentials, settings). |
| `launchCmd` | `claude` | Command `claude-w.ps1` runs to start a session, e.g. `claude -w` to start each one in a new git worktree. |
| `usageRefreshSec` | `180` | Seconds between usage requests (shared by all open rails through `usage-cache.json`). Polling faster tends to get HTTP 429. |
| `liveWindowMin` | `30` | A session with no event for this long drops off the roster (a session that ends normally is removed at once via `SessionEnd`). |
| `widthTarget` | `38` | Width used when the console width cannot be read. |
| `watchFile` / `watchLabel` / `infraRecencyMin` | off / `watch` / `15` | Show "▸ NEW WATCH 3m" plus the file's last line for 15 minutes after the file changes. I use it for a shared log of newly created API keys and services, so a parallel session does not create a duplicate. |
| `vercelAccountsFile` | off | Enables the Vercel guard (below). |

### Optional: Vercel account guard

If you deploy projects from several Vercel accounts, a folder linked to the wrong team is easy to miss. Create a JSON file and point `vercelAccountsFile` at it:

```json
{ "primary": "my-personal", "teams": { "team_xxxxxxxx": { "account": "my-personal" }, "team_yyyyyyyy": { "account": "client-co" } } }
```

For the current project the rail reads `.vercel\project.json`, maps its `orgId` to an account, and compares it with the project's `vercel` value: green when it matches your primary account, yellow when the project belongs to another account, and a blinking red block when the folder is linked to a different account than expected.

## How it works

| Part | Source | Refresh |
|---|---|---|
| Session roster, "needs you", current skill, effort | `rail-events.jsonl` written by `rail-hook.ps1` (last 200 lines) | 1.5 s |
| Current project | newest live session's folder; else `-Project` / `-Cwd`; else the newest transcript | 1.5 s |
| Model and cache timer | last assistant message in the newest transcripts under `<claudeHome>\projects` (`message.model`, `message.usage.cache_creation` to tell 5-minute from 1-hour cache) | 6 s |
| Project git status | `git rev-parse`, `git status --porcelain` (ignoring `.claude\`), `git rev-list @{u}..HEAD` | 20 s |
| Usage bars | `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token from `<claudeHome>\.credentials.json` (`five_hour`, `seven_day`, `extra_usage`) | `usageRefreshSec`, cached in `usage-cache.json` |

- The hook always exits 0 and never blocks Claude Code. It retries the append 3 times if another session is writing, and rotates `rail-events.jsonl` to `.1` past 5 MB.
- The screen is redrawn with cursor-home + clear-to-end-of-line, so it does not flicker; it only redraws when data changed, the window was resized, or something is blinking.
- `claude-w.ps1` clears the ReadOnly attribute on `.claude` and `.claude\worktrees` before starting Claude Code. Inside some cloud-synced folders (Google Drive for desktop in my case) those folders end up ReadOnly and `claude -w` then fails with `EEXIST`. Elsewhere it is a no-op.

## Limitations

- **Undocumented usage endpoint.** `/api/oauth/usage` is what Claude Code's `/usage` screen uses; it is not a public API. The rail sends the same headers Claude Code does (`anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<your installed version>`). It may change, rate-limit (429) or disappear; the rail then keeps showing the last cached values or "· …". It reads your OAuth access token from `.credentials.json` and sends it only to `api.anthropic.com`. Requires a Claude subscription login (not an API key). Checked on 2026-10-22: the response still carries `five_hour`, `seven_day` and `extra_usage` (alongside a newer `limits` array the rail does not use yet).
- **Transcript format is internal.** The model and cache timer parse `projects\*\*.jsonl`, which can change in any Claude Code release.
- **Cache timer is an estimate.** It measures time since the last assistant message; it cannot see cache hits from other tools.
- **Roster liveness is heuristic.** Sessions killed without a `SessionEnd` event stay listed until `liveWindowMin` passes.
- Projects whose folder does not exist show as clean (`✓`).
- Windows only (Windows Terminal, `attrib`, `wt`). Needs a font with box-drawing and block characters (Cascadia Mono works).

## License

MIT, see [LICENSE](LICENSE).
