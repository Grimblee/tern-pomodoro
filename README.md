# tern-pomodoro

Pomodoro timer plugin for [Tern](https://stencil.so) (tested on Tern 0.9.16; written in Luau against the Tern Plugin SDK).

25 min work, 5 min short break, 15 min long break after every fourth finished work session. The next phase starts by itself when one ends. The status line shows the clock; a desktop notification and a sound mark each phase end.

## Install

```sh
tern plugin install github.com/Grimblee/tern-pomodoro   # or: tern plugin link <checkout>
```

## Status line

| Shows | Meaning |
|---|---|
| `🍅 24:13` | work phase, time left |
| `break 04:59` / `long break 14:59` | break phase |
| `⏸ …` (muted) | paused |
| nothing | idle |

Clicking the segment pauses or resumes. It is hidden when idle, so start with the chord or the palette.

## Commands and chords

Palette group "Pomodoro"; each is also the action `plugin.pomodoro.<id>`.

| Command | Id | Effect |
|---|---|---|
| Pomodoro: Start | `start` | Starts a work phase when idle |
| Pomodoro: Pause / resume | `pause` | Toggles pause; nothing when idle |
| Pomodoro: Start / pause / resume | `toggle` | Chord and status-click action |
| Pomodoro: Reset | `reset` | Back to idle, completed count to 0 |
| Pomodoro: Skip to next phase | `skip` | Ends the phase now; a skipped work session is not counted |
| Pomodoro: Set work-end sound | `set_work_sound` | Picker over every sound file found; plays the choice once as a preview |
| Pomodoro: Set break-end sound | `set_break_sound` | Same, for the end of a break |

Chord: `Ctrl+Alt+Shift+M` (`Cmd+Alt+Shift+M` on macOS) runs `toggle`. It does not clash with Tern's default keymap. Rebind in Tern's keybinds, or run commands from a shell: `tern ctl plugins run plugin.pomodoro.skip`.

## Change durations, sounds, players

Edit the constants at the top of `common.luau`, then `tern plugin reload pomodoro`: `DURATION` (seconds per phase), `LONG_BREAK_EVERY`, `SOUND` (default sounds) and `PLAYERS`.

## Notifications and sound

Only the host half (in Tern's session daemon) notifies, so a phase end fires once however many windows are open.

- Notification: `notify-send`. If it is missing, the plugin logs a warning and carries on.
- Sound: played with `pw-play`, falling back to `paplay`, as a background process; the timer never waits on it. If no player or file works, the plugin logs a warning. The sound is separate from the terminal bell.
- Defaults (`SOUND` in `common.luau`, freedesktop sound theme): `alarm-clock-elapsed.oga` when a work session ends, `complete.oga` when a break ends.

### Choosing a sound

Tern has no sound API and ships no sound files, so the choice is any sound file (`.oga .ogg .wav .flac .mp3 .opus`, up to 4 levels deep) under `$XDG_DATA_HOME/sounds` (default `~/.local/share/sounds`) and `<dir>/sounds` for each dir in `$XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`). Rows read `theme/name` with the sub-folder as detail (`~` marks your own folder), the first row is "None (no sound)" and the current choice has a check. The folders are scanned when the command runs.

The picker has no preview-on-highlight, so the chosen sound plays once after you pick it.

The choice is stored in kv `settings` as `{work_sound, break_sound}` (a file path, or `"none"`), in `<state>/plugin-data/pomodoro/kv.json`. A missing, malformed or deleted file falls back to the `SOUND` default. Set a default to `common.NONE` to silence it for good.

Plugin warnings go to Tern's daemon log (`~/.local/state/tern/logs/tern-daemon.log`).

## How it works

State survives reloads and daemon restarts because it holds the wall-clock end time (`os.time()`), not a countdown. If the daemon was down past the end of a phase, the next phase starts when it returns (no catching up).

kv keys (`<state>/plugin-data/pomodoro/kv.json`), one writer each:

| Key | Writer | Value |
|---|---|---|
| `state` | host | `{phase, end_epoch?, paused_remaining?, completed, handled}`; `handled` lists the request ids the host has seen |
| `requests` | windows | list of `{op, id, at}`, oldest first; op is `start`, `pause`, `toggle`, `reset` or `skip` |
| `settings` | windows | `{work_sound, break_sound}`, read by the host at each phase end |

Each tick (once a second) the host first ends a phase whose time has passed, then runs the requests it has not seen (ignoring ones older than 10 s), and writes `state` once. A command sent in the last second of a phase therefore acts on the next phase. Two commands within a second both run, in order, and a command's toast already counts the ones before it. Every window polls `state` once a second: it redraws the status line each second while a phase counts down and otherwise only when the state changed, so a start from another window shows up everywhere.

One race remains: `tern.kv` keeps the last write when two VMs write at the same instant. That can drop a request when two windows send at the same moment. It can also lose a `state` write that lands with a window's `requests` write; the host then redoes it on the next tick (`handled` was not saved), which can repeat that phase end's notification and sound. The completed count stays correct.

No history beyond the completed count.

## Development

```sh
tern plugin link .
tern plugin types .    # writes tern.d.luau (git-ignored) for luau-lsp
luau-lsp analyze --definitions=tern.d.luau common.luau sound.luau host.luau window.luau
```
