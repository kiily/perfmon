# perfmon

Machine performance monitoring for macOS + [herdr](https://herdr.dev). Answers
"what is eating my memory?" and lets you kill the offender from the terminal in
seconds.

## Commands

All available in every shell once installed:

| Command | What it does |
|---|---|
| `memtop` | Top memory consumers, **grouped by responsible app** (Chrome's 50 helpers → one "Google Chrome" row with the total). Shows RAM free %, swap usage. |
| `memtop --raw` | Ungrouped per-process view with PIDs. |
| `memtop --watch [secs]` | Live-refreshing view (default 5s). |
| `memtop -n N` | Show N rows (default 15). |
| `fkill [query]` | Memory-sorted process list in fzf. Type to filter, `tab` to multi-select, `enter` to SIGTERM. Optional query pre-fills the filter. |
| `fkill -9 [query]` | Same, but SIGKILL. |
| `fkill --match REGEX` | Non-interactive: kill everything matching the regex (still respects safety exclusions). |
| `perfmon` | Create the PERF MONITORING herdr workspace, or focus it if it exists. |
| `perfmon --ensure` | Idempotent create, never steals focus (used by auto-launch). |
| `perfmon --doctor` | Check dependencies (btop, fzf, herdr, python3). |

`fkill` never offers itself, your current shell and its ancestors, or the herdr
server as targets.

## The PERF MONITORING workspace

Auto-launches whenever you attach to herdr (via the zshrc hook). Two tabs:

- **Overview** — `btop` (memory-sorted; click a process, then `t`/`k` to
  terminate/kill) + a shell pane with the command cheat sheet.
- **Memory** — `memtop --watch` on top; `vm_stat 10` and a memory-pressure/swap
  watch below.

## Install

```sh
brew install btop fzf
echo 'source "$HOME/Documents/devtools/perfmon/perfmon.zsh"' >> ~/.zshrc
perfmon --doctor
```

The zshrc hook adds `perfmon/bin` to PATH and, inside herdr (`HERDR_ENV=1`),
runs `perfmon --ensure` in the background. It is lock-guarded, so many panes
starting at once still create exactly one workspace. Set `PERFMON_NO_AUTO=1`
to disable auto-launch.

## Uninstall

Remove the `perfmon` lines from `~/.zshrc` and delete this directory.

## Tests

```sh
bash test/smoke.sh
```

Verifies memtop output shape, fkill kill/exclusion behavior, and (inside
herdr) workspace idempotence.

## Notes

- macOS only (`vm_stat`, `memory_pressure`, `sysctl` are Darwin-specific).
- `perfmon` writes a minimal `~/.config/btop/btop.conf` (memory sorting) only
  if you don't already have one.
- herdr workspace/tab/pane ids are session-scoped; `perfmon` always re-finds
  the workspace by its label, never by cached id.
