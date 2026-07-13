# usage-menubar

Claude(subscription) and GPT(codex/ChatGPT) usage limits, live in your macOS menu bar.

Shows `C{claude weekly %} G{gpt weekly %}`, color-coded by severity (green &lt;70, orange ≥70, red ≥90).
Click it for the full breakdown: session / weekly / scoped limits and reset countdowns.

No API keys. It reads the OAuth tokens your local Claude Code and Codex CLIs already have.

```
 C95 G11        ← menu bar
 ┌───────────────────────────┐
 │ CLAUDE · max              │
 │   세션 5h      15%         │
 │   주간 전체    95%  ↺ 3시간 │
 │   Fable        87%  ↺ 3시간 │
 │ ───────────────────────── │
 │ GPT(sol) · team           │
 │   5시간         1%  ↺ 3시간 │
 │   주간         11%  ↺ 6일   │
 │ ───────────────────────── │
 │ 갱신 16:48:17             │
 │ 지금 갱신             ⌘R   │
 │ 종료                  ⌘Q   │
 └───────────────────────────┘
```

## How it gets the data

- **Claude** — reads the `Claude Code-credentials` OAuth token from the macOS keychain and calls
  `GET https://api.anthropic.com/api/oauth/usage`. Free. The response's `limits[]` carries session,
  weekly-all, and weekly-scoped (Fable) percentages.
- **GPT** — reads the ChatGPT OAuth access token from `~/.codex/auth.json` and sends a tiny request to
  `POST https://chatgpt.com/backend-api/codex/responses`. The usage comes back in response **headers**
  (`x-codex-{primary,secondary}-used-percent`). Codex flips which bucket is "primary" vs "secondary",
  so each is classified by its `*-window-minutes` instead (~300min → 5h, ~10080min → weekly). The model
  name is auto-detected from `~/.codex/config.toml`. Because that request consumes a sliver of quota, it
  is cached and only re-fetched every 5 minutes.

The codex access token expires hourly; `fetch.py` refreshes it via the OAuth endpoint before expiry and
rewrites `auth.json` atomically.

## Requirements

- macOS with a Swift toolchain (`swiftc` — comes with Xcode / Command Line Tools)
- [Claude Code](https://claude.com/claude-code) logged in (for the Claude numbers)
- [Codex CLI](https://github.com/openai/codex) logged in with a ChatGPT account (for the GPT numbers)

Either side degrades gracefully: if one CLI isn't logged in, that half shows `–`.

## Install

```bash
git clone https://github.com/bugbug9999/usage-menubar.git
cd usage-menubar
./install.sh
```

It compiles a tiny `.app`, installs a LaunchAgent (auto-start at login, auto-restart if it dies), and
verifies the menu bar item rendered.

## Uninstall

```bash
./uninstall.sh
```

## Notes / gotchas

- **You launched it but nothing shows?** If you're in a fullscreen app, macOS auto-hides the menu bar
  (the app is still running). Exit fullscreen or hover the top edge.
- **It must be started via `launchctl bootstrap gui/$UID`** (the installer does this). A menu-bar
  (`NSStatusItem`) app started from a non-GUI shell session stays alive but never attaches to the visible
  menu bar. That's why there's a LaunchAgent rather than a plain `open`.
- Everything lives in `~/usage-bar/`. Logs: `~/usage-bar/fetch.log`.

## Files

| file | what |
|------|------|
| `UsageBar.swift` | the menu-bar app (NSStatusItem, colored title, dropdown, 90s poll) |
| `fetch.py` | fetches Claude + GPT usage, refreshes codex token, emits JSON |
| `com.bug.usage-bar.plist` | LaunchAgent template (`__HOME__` is substituted at install) |
| `install.sh` / `uninstall.sh` | setup / teardown |

MIT.
