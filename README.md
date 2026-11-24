# Quota Bar

A native macOS menu bar app for the seven-day quotas of Claude, Codex, and Google Antigravity.

The menu bar shows three quota rings in order: clay for Claude, blue for Codex, and green for Antigravity. Hover for exact percentages or click for progress bars, reset dates, live countdowns, and manual refresh. The Antigravity ring and panel show its Gemini weekly quota. A dimmed arc marks a reading retained after a refresh failed.

## Run locally

Requires macOS 14 or later, Swift 5.9 or later, and the current CodexBar quota helper.

```sh
brew install --cask codexbar antigravity-cli
./build.sh
open "dist/Quota Bar.app"
```

Quota Bar polls the [CodexBar CLI](https://github.com/steipete/CodexBar/blob/main/docs/cli.md) every five minutes using the existing provider sign-ins. CodexBar's menu bar UI can stay closed. Quota Bar keeps the percentages and timestamps in memory. It does not read browser cookies itself, run a local server, or send AI prompts.

- **Claude** - CodexBar can use the Claude Code sign-in or an available browser session. If needed, run `claude` in Terminal and sign in.
- **Codex** - CodexBar can use the existing Codex sign-in. If needed, run `codex login` in Terminal and sign in with ChatGPT.
- **Antigravity** - The signed-in `agy` CLI supports background usage while the desktop app is closed. Run `agy` once and sign in if the existing session is unavailable.

For setup details, see the CodexBar guides for [Claude](https://github.com/steipete/CodexBar/blob/main/docs/claude.md), [Codex](https://github.com/steipete/CodexBar/blob/main/docs/codex.md), and [Antigravity](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md).
