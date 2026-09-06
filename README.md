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
| `fkill --match REGEX` | Non-interactive: kill everything whose **command** matches the regex (case-insensitive, never matches PID/MEM columns; still respects safety exclusions). More than 5 matches requires `--force`. |
| `fkill --port N` | Kill whatever is listening on TCP port N (the "address already in use" fix). Exits 1 if nothing killable listens. |
| `fkill --app NAME` | Kill a whole app bundle — root process first, then all helpers and their children. Shows the victim list and asks once; `--force` skips the prompt. Exact bundle name ("Google Chrome", not "chrome"). |
| `fkill --list [--match RE \| --port N \| --app NAME \| query]` | Preview the candidate list without killing anything. |
| `fkill --escalate` / `--wait SECS` | Every kill is verified — "killed" is printed only when the process is actually gone (poll window default 5s). A TERM-ignoring survivor exits 2; `--escalate` follows up with SIGKILL. |
| `perfsession` | Build (or attach to) the dedicated `perf` herdr session: **⚡ COMMANDS**, **📊 VISUALS** and **🌐 SERVERS** spaces. Idempotent — running it again just attaches. |
| `perfmon` | Build the PERF MONITORING layout in the current herdr tab, or focus it if it exists. |
| `perfmon --hog` | The single worst CPU process and the single worst memory process, each with a copy-ready `kill -9 PID`. On a terminal it then offers one key: `c` cpu, `m` mem, `b` both, enter for nothing. |
| `perfweb` | Little localhost dashboard (`http://127.0.0.1:7777`) — live CPU/memory hogs, click to kill. `--port N`, `--no-open`. Opens your browser by default. |
| `perfmon --ensure` | Idempotent build, never steals focus (used by auto-launch). |
| `perfmon --doctor` | Check dependencies (btop, fzf, herdr, python3). |
| `perfmon --cheats` | Print the command cheat sheet. |
| `perfmon --servers [secs]` | Every localhost TCP listener with its PID and working directory — which dev server is still up, and from which repo. With `secs`, refreshes in place. |
| `perfmon --guide` | Practical how-to guide organized by situation ("port busy", "app gone feral", "it won't die"). |

`fkill` never offers itself, your current shell and its ancestors, or the herdr
server as targets. Exit codes: 0 = killed and verified dead, 1 = nothing
matched/refused/aborted, 2 = a kill failed or the process survived the wait
window.

`perfweb` binds 127.0.0.1 only and mints a fresh token per run (it is in the URL
it prints/opens); requests without it get 403, and the kill endpoint also needs
a custom header so no other page in your browser can reach it. It refuses to
kill itself or its ancestors, and reports a kill only once the process is gone.

**Keys (any zsh prompt, once `perfmon.zsh` is sourced):** `^G` opens/focuses the
dashboard, `^O` runs `perfmon --hog`.

## The perf session

`perfsession` starts the named herdr session `perf` (headless server + attach)
and builds three spaces:

- **⚡ COMMANDS** — two plain shells side by side, the cheat sheet printed in the
  left one. This is where you type `fkill`, `memtop`, `perfweb`.
- **📊 VISUALS** — `btop` (left) beside `memtop --watch 5`, `vm_stat 10` and the
  memory-pressure/swap watch. Nothing to type here.
- **🌐 SERVERS** — `perfmon --servers 10`: every localhost listener, its port,
  PID and project directory. Pair it with `fkill --port N`.

Switch spaces with herdr's workspace keys. All three spaces are created with
`PERFMON_NO_AUTO=1`, so the zsh auto-launch hook leaves this layout alone.

Run it again any time — it only builds spaces that are missing, otherwise it
attaches. Run from a plain terminal (from inside herdr it builds and prints the
attach command instead of nesting).

## The PERF MONITORING tab

`perfmon` builds its layout **in the tab you run it from** (renamed to
`PERF MONITORING`) instead of creating a new workspace. One tab:

- `btop` on the left (memory-sorted; click a process, then `t`/`k` to
  terminate/kill).
- Right column: the command cheat sheet, `memtop --watch`, and `vm_stat 10`
  beside a memory-pressure/swap watch.

The auto-launch hook (perf herdr session only) builds it in the session's
first tab.

## Monitoring across every herdr space

There is **one** `PERF MONITORING` tab, not one per space. Jump to it with
`perfmon` (which prints `focused …` so you know it worked — it switches you
to the existing tab rather than adding anything to your current one).

**Don't clone the full workspace into every space.** The heavy pane is `btop`:
it re-samples all ~1200 processes every 2s, continuously. One is cheap; five —
one per space — is five full-machine samplers running at once, which is
redundant and mildly self-defeating for a performance tool.

For an at-a-glance readout in each space (quorum, flown, default, …), use the
cheap gauge instead of the cockpit: add a tab running

```sh
memtop --watch 10
```

That's a `ps` every 10s (effectively free) showing free RAM %, swap, and the
top apps. Keep `btop` in the one dedicated workspace; put `memtop --watch` where
you want the glance.

## Install

```sh
brew install btop fzf
echo 'source "$HOME/Documents/devtools/perfmon/perfmon.zsh"' >> ~/.zshrc
perfmon --doctor
```

The zshrc hook adds `perfmon/bin` to PATH and, inside herdr (`HERDR_ENV=1`),
runs `perfmon --ensure` in the background. It is lock-guarded, so many panes
starting at once still build exactly one PERF MONITORING tab. Set
`PERFMON_NO_AUTO=1` to disable auto-launch.

## Uninstall

Remove the `perfmon` lines from `~/.zshrc` and delete this directory.

## Tests

```sh
bash test/smoke.sh
```

Verifies memtop output shape, fkill kill/exclusion behavior, and (inside
herdr, when the tab exists) build idempotence.

## Notes

- macOS only (`vm_stat`, `memory_pressure`, `sysctl` are Darwin-specific).
- `perfmon` writes a minimal `~/.config/btop/btop.conf` (memory sorting) only
  if you don't already have one.
- herdr workspace/tab/pane ids are session-scoped; `perfmon` always re-finds
  the tab by its label, never by cached id.
