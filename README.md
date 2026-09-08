# claude-code-notify

A **task-complete notifier** for [Claude Code](https://claude.com/claude-code). When a session finishes a turn, it tells you **which** session it was — by name — and draws your eye to the right window. Built for the reality of running **many Claude Code sessions at once**.

On a turn end it:

- 🔔 **plays a chime** and speaks the project name (debounced, so a burst of sessions finishing doesn't echo);
- 🪟 **shows a desktop notification whose title is the session's own name** (its Claude-generated tab title), so you can see at a glance which of your sessions is done;
- 🟧 **flashes that session's own taskbar button** — not whichever window happens to be active — so the highlight points at the session that actually finished;
- 🖱️ **(Windows, optional) makes the notification click-to-raise** the finishing session's window.

It is **project-agnostic**: it identifies the project from the nearest `CLAUDE.md`/`package.json` and the session from the Stop hook's transcript, so it works in any repo with no configuration.

## Install

```
/plugin marketplace add rafik24/claude-code-notify
/plugin install claude-code-notify
```

That's it — the `Stop` hook is active immediately. Verify with `/plugin`.

> If you previously wired this notifier by hand (e.g. a `Stop` hook in `.claude/settings.local.json`), remove that entry after installing the plugin, or you'll get **two** notifications per turn.

## Platform support

| Platform | Chime + speech | Named notification | Taskbar flash of the finished window | Click-to-raise |
|---|---|---|---|---|
| **Windows 10/11** | ✅ | ✅ (toast) | ✅ (per-window) | ✅ (after one-time setup, below) |
| **macOS** | ✅ | — | — | — |
| **Linux (X11)** | ✅ | ✅ (`notify-send`) | ✅ (via `xdotool`/`wmctrl`) | ✅ (click action) |
| **Linux (Wayland)** | ✅ | ✅ | — (compositors block foreign raising) | — |

Windows is the most complete. macOS and Linux paths are functional but less battle-tested — issues/PRs welcome. Linux needs `libnotify` (`notify-send`) and, for raising, `xdotool` or `wmctrl`.

## Windows: enable click-to-raise (one-time, optional)

Clicking the toast can bring the finishing session's window to the front, but that needs a tiny helper and a URI-scheme registration (per user, **no admin**). Run once:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\plugins\<...>\claude-code-notify\scripts\task-complete-setup.ps1"
```

(`/plugin` shows the installed path.) Until you run it, the toast is display-only and the flashing taskbar button is the way to find the window. The setup compiles a small windowless `claude-raise.exe` into `%LOCALAPPDATA%\claude-notify` and registers a `claude-raise:` URI scheme — both outside the plugin dir, so they survive plugin updates. It writes nothing else and needs no admin.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDE_NOTIFY_DEBOUNCE_SECS` | `30` | Minimum seconds between **audible** notifications (machine-wide). The named toast and taskbar flash still fire **per session** — only the sound is coalesced, so a burst of finishes doesn't echo. |

## How it identifies the session

A Claude Code `Stop` hook runs detached from the terminal's console, so it can't read the tab title directly. Instead the hook reads the session's **`ai-title`** (the name Claude shows on the tab) from the session transcript that the Stop payload points at, preferring the entry that matches the current session id — so a resumed/forked session is never named after another one. It then flashes the top-level terminal window whose title contains that name (restricted to terminal window classes so a notification banner is never matched), and never falls back to a different window — a wrong flash is worse than none.

## Troubleshooting

The hook writes an end-to-end trace, one line per phase, to `claude-notify-trace.log` in your temp dir (`%TEMP%` on Windows, `$TMPDIR`/`/tmp` elsewhere):

```
ev=stop  sid=.. proj=.. src=transcript audible=.. label='..'
ev=flash sid=.. flashed=[hwnds] matched=N foregroundIsTarget=..
ev=toast sid=.. ok=0|1
ev=sound sid=.. played=..
```

Watch it live on Windows with:

```powershell
Get-Content -Wait -Tail 20 "$env:TEMP\claude-notify-trace.log"
```

Notes:
- `matched=0` means no live window matched the session name (e.g. the window was renamed or closed) — the toast still names the session.
- `foregroundIsTarget=True` is a correct no-op: you can't flash the window you're already looking at.

## Tests

The session-identification logic has a unit suite (`scripts/task-complete.test.sh`, plain `bash` + `node`):

```
bash scripts/task-complete.test.sh
```

## License

MIT — see [LICENSE](LICENSE).
