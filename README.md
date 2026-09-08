# claude-code-notify

> **Know which Claude Code session just finished — or is waiting on you — by name, even with a dozen running.**

A **notifier** for [Claude Code](https://claude.com/claude-code). When a session **finishes a turn** — or **pauses to ask for your permission/input** — it tells you **which** session it was, by name, and draws your eye to the right window. Built for the reality of running **many Claude Code sessions at once**.

## Demo

<!-- Record a ~10s clip and drop it at docs/demo.gif, then replace this line with:  ![claude-code-notify demo](docs/demo.gif) -->
> 📹 *Demo coming.* One clip: three Claude Code sessions open; one finishes → **its** taskbar button flashes and a toast names that exact session.

On each of those moments it:

- 🔔 **plays a chime** and speaks the project name (debounced, so a burst doesn't echo);
- 🪟 **shows a desktop notification whose title is the session's own name** (its Claude-generated tab title), with a headline of **"task complete"** or **"needs your input"** so you know at a glance which session, and why;
- 🟧 **flashes that session's own taskbar button** — not whichever window happens to be active — so the highlight points at the session that actually needs you;
- 🖱️ **(Windows, optional) makes the notification click-to-raise** that session's window.

**Two triggers:** the `Stop` hook (a turn finished) and the `Notification` hook (Claude is waiting on your permission or input). The waiting-on-you notifications can be turned off with `CLAUDE_NOTIFY_NO_INPUT=1` if your workflow prompts often.

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

Windows is the most complete. macOS and Linux paths are functional — the Linux path is verified on Ubuntu 26.04 / KDE / X11 (all six test cases plus a live run) — but less battle-tested elsewhere; issues/PRs welcome.

### Linux dependencies

Every dependency below is **optional** — if it's missing, that piece is skipped as a silent no-op (a missing tool never breaks the hook). But for the full experience:

| Feature | Needs (any one) | Notes |
|---|---|---|
| Desktop notification | `libnotify` (`notify-send`) | Present on most desktops. |
| Sound | `paplay` or `aplay` | PulseAudio/PipeWire or ALSA. |
| Spoken project name | `spd-say` (speech-dispatcher) **or** `espeak` | Kubuntu ships `spd-say` but **not** `espeak`; other distros vary — one is usually present. |
| Click-to-raise the finished window (X11) | `xdotool` (to locate the window) | Click the notification body to raise. |
| Taskbar highlight of the finished window (X11) — parity with the Windows flash | `xdotool` **and** `wmctrl` | Sets the EWMH _demands-attention_ hint so the right session's taskbar entry lights up even when sessions share one icon. How it surfaces (a steady glow, a badge, or a flash) depends on your desktop and its taskbar settings — GNOME and KDE Plasma each render and configure it differently. |

> **Heads-up on stock desktops:** Ubuntu GNOME and Kubuntu/KDE ship **neither `xdotool` nor `wmctrl`** (nor `paplay`/`espeak`). So out of the box on Linux you get the **named notification + sound** (via the `aplay`/`spd-say` fallbacks) — which already tells you *which* session finished — but **not** click-to-raise or the taskbar highlight. To enable those on **X11**: `sudo apt install xdotool wmctrl`. On **Wayland**, raising/highlighting a window from another app is blocked by the compositor, so those stay off by design regardless.

**You won't have to remember that.** The first time it runs on X11 without those tools, the plugin shows a **one-time** notification naming what's missing and the exact command for your package manager (apt/dnf/pacman/zypper) — e.g. *"Missing: xdotool wmctrl — run: `sudo apt install xdotool wmctrl`"*. It only **displays** the command; it never runs a package manager or asks for sudo (a hook that ran privileged installs would be a trust problem). Shown once per missing-tool-set; silence it entirely with `CLAUDE_NOTIFY_NO_DEP_HINT=1`.

On **Wayland**, compositors block one app from raising another's window, so the raise step is skipped by design and you get the notification without the flash.

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
| `CLAUDE_NOTIFY_NO_INPUT` | _(unset)_ | Set to `1` to suppress the **waiting-on-you** notifications (the `Notification` hook), keeping only task-complete. Useful if your sessions prompt for permission frequently. |
| `CLAUDE_NOTIFY_NO_DEP_HINT` | _(unset)_ | Set to `1` to suppress the Linux one-time "install `xdotool`/`wmctrl` to enable click-to-raise + taskbar highlight" advisory. |

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
