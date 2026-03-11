# Claude Code Powerline Statusline

A rich, two-row statusline for [Claude Code](https://claude.com/claude-code) with Powerline-style segments, real-time usage tracking, and smart API caching.

## What it looks like

```
 dir   main ⇡1 ?3   Opus 4   user   12m   45%
 5h 24%  10s   reset 18:00   7d 56%
```

**Row 1** — Project context (left to right):

| Segment | Content | Color |
|---------|---------|-------|
| Directory | Current folder name | Dark violet bg, light lavender text |
| Git | Branch + ahead/behind/staged/modified/untracked | Lavender bg, dark text |
| Model | Active Claude model | Peach bg, dark text |
| Account | Logged-in email prefix | Mint bg, dark text |
| Duration | Session time in minutes | Mid-peach bg |
| Context | Context window usage % | Rose-peach bg |

**Row 2** — Usage tracking (left to right):

| Segment | Content | Color |
|---------|---------|-------|
| **5h** | 5-hour rolling window utilization % + data age | Deep slate bg, light blue text |
| **reset** | When the 5-hour window resets (local time) | Teal-mint bg, dark text |
| **7d** | 7-day rolling window utilization % | Indigo bg, light purple text |

## Design System

### Color Palette (RGB)

**Row 1 — Warm gradient:**
```
Dark violet:   bg(58,52,72)    text(178,170,214)
Lavender:      bg(178,170,214) text(55,48,68)
Peach:         bg(230,210,186) text(72,58,48)
Mid-peach:     bg(224,200,177)
Rose-peach:    bg(226,196,196)
Mint:          bg(176,213,196) text(38,70,55)
```

**Row 2 — Cool tones:**
```
Deep slate:    bg(42,52,72)    text(160,178,214)  highlight(200,210,240)
Teal-mint:     bg(152,210,200) text(32,62,55)
Indigo:        bg(48,42,72)    text(170,160,214)  highlight(210,200,240)
```

### Segment Separators
- **Row 1**: Powerline arrow `` (U+E0B0) between segments
- **Row 2**: Full block `█` (U+2588) between segments — the foreground color of the block matches the previous segment's background, creating a clean visual break

### Nerd Font Icons
Row 1: `` (dir), `` (git), `󰚩` (model), `󱎫` (timer), `󰧠` (brain/context)
Row 2: `󰧒` (5h usage), `󰔟` (reset clock), `󰔠` (7d calendar)

> Requires a [Nerd Font](https://www.nerdfonts.com/) installed in your terminal. Any Nerd Font works — the icons are in the private-use Unicode range shared across all Nerd Font variants.

### Stale Data Indicator
When cached data is older than 2 minutes, a `~` prefix is added: `~24%` means "approximately 24%, data may be outdated."

## Usage Tracking — How It Works

The statusline calls Anthropic's internal OAuth usage API:

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer <accessToken>
  anthropic-beta: oauth-2025-04-20
  User-Agent: claude-code/<version>
```

The `User-Agent` header is **critical** — Anthropic uses it to select a more generous rate-limit bucket. Without it, you'll get HTTP 429 after ~5 requests.

### Response Format
```json
{
  "five_hour": { "utilization": 24.0, "resets_at": "2026-03-11T16:00:00+00:00" },
  "seven_day": { "utilization": 56.0, "resets_at": "2026-03-14T21:00:00+00:00" }
}
```

### Smart Caching Strategy

The statusline runs on every Claude Code render (every few seconds). Hitting the API every time would trigger rate limits. The caching strategy:

```
                0s          120s            900s
FRESH ──────────|── STALE ──|── EXPIRED ────|
  show as "24%" |  show "~24%" |  re-fetch from API
                |  serve from  |
                |  cache       |
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `FRESH_TTL` | 120s (2 min) | Data shown as-is. The 5h window changes slowly. |
| `STALE_TTL` | 900s (15 min) | Data shown with `~` prefix, served from cache. |
| `BACKOFF_TTL` | 300s (5 min) | After a failed fetch (429/timeout), don't retry for 5 minutes. |

**Backoff on failure**: When a fetch fails, a backoff marker file is created. While it exists (5 min), the script serves stale cache without hitting the API. This prevents "retry storms" where every render hammers a rate-limited endpoint.

### Retrieving the OAuth Token

The token is stored in the OS credential store by Claude Code:

| OS | Method |
|----|--------|
| **macOS** | `security find-generic-password -s "Claude Code-credentials" -w` |
| **Linux** | `secret-tool lookup service "Claude Code-credentials"` or check `~/.config/claude-code/credentials.json` |
| **Windows** | Windows Credential Manager under `Claude Code-credentials`, or `%APPDATA%\claude-code\credentials.json` |

The raw value is a JSON object. Extract the token:
```
json.get('claudeAiOauth', {}).get('accessToken', '')
```

## Git Status Indicators

The git segment shows compact indicators:

| Symbol | Meaning |
|--------|---------|
| `⇡N` | N commits ahead of upstream |
| `⇣N` | N commits behind upstream |
| `+N` | N staged files |
| `!N` | N modified files |
| `?N` | N untracked files |

## Setup

### Prerequisites
- [Claude Code](https://claude.com/claude-code) installed
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal
- `jq`, `curl`, `python3` available in PATH
- Terminal with true-color (24-bit) support

### Quick Start

1. Create the statusline script at `~/.claude/statusline.sh` (or any path)
2. Make it executable: `chmod +x ~/.claude/statusline.sh`
3. Configure Claude Code settings (`~/.claude/settings.json`):

```json
{
  "statusline": {
    "enabled": true,
    "script": "~/.claude/statusline.sh"
  }
}
```

4. Restart Claude Code. The statusline appears above the input prompt.

### How the Script Works

Claude Code pipes a JSON blob to your script via stdin on every render:
```json
{
  "workspace": { "current_dir": "/Users/you/project" },
  "model": { "display_name": "Opus 4" },
  "cost": { "total_duration_ms": 720000 },
  "context_window": { "used_percentage": 45 }
}
```

Your script reads this JSON, combines it with git/usage data, and prints ANSI-colored lines to stdout. Each line becomes a row in the statusline. Lines with only `\u200b` (zero-width space) act as spacing between rows.

### OS-Specific Notes

**macOS**: The reference script uses `stat -f %m` for file modification time. This is the BSD variant.

**Linux**: Replace `stat -f %m` with `stat -c %Y`. Also replace the `security find-generic-password` Keychain call with `secret-tool lookup` or read from `~/.config/claude-code/credentials.json`.

**Windows (WSL/Git Bash)**: Use `stat -c %Y`. Credentials may be in `%APPDATA%\claude-code\credentials.json`. The `curl`/`python3` commands work the same.

## Reference Implementation

See [`statusline.sh`](./statusline.sh) for the complete macOS implementation.

## Known Limitations

- **Usage % can be misleading**: Anthropic enforces 3 separate limits (quota, throughput, server pacing) but the API only reports quota utilization. You can get rate-limited at 70% if throughput or pacing limits are hit. See [this research](https://github.com/anthropics/claude-code/issues/22441).
- **Nerd Font required**: Without it, icons render as missing-glyph boxes.
- **True-color terminal required**: 256-color terminals will show incorrect colors. Most modern terminals (iTerm2, Kitty, Alacritty, Windows Terminal, Ghostty) support true-color.

## License

MIT
