---
date: 2026-07-08
topic: perfmon-capabilities
focus: What other features/capabilities could the perfmon project have?
---

# Ideation: What else could perfmon have?

## Codebase Context

perfmon is a ~430-line bash toolset for macOS + herdr: `memtop` (memory consumers grouped by responsible .app bundle, --raw/--watch, RAM/swap/pressure headline), `fkill` (fzf fuzzy process killer with command-column `--match`, `--list` dry-run, blast-radius guard, exit codes, PID-reuse guard, self/herdr exclusions), `perfmon` (idempotent herdr workspace builder with atomic locking, --doctor, --cheats), zshrc auto-launch, 18-check smoke suite. Deps: btop, fzf, python3, herdr. Recently hardened via multi-agent review (see docs/solutions/security-issues/destructive-shell-cli-safety-patterns.md).

Key gaps at ideation time: memory-only (no CPU/disk/network), point-in-time only (no history/deltas), no configuration, no notifications, human-oriented output. Identity to preserve: "run it, read it, done" — no daemons, no sudo, no stability contracts.

Process: 5 parallel ideation agents (frames: pain/friction, missing capability, inversion/automation, assumption-breaking, leverage/power-user) → 41 raw ideas → deduped to 19 candidates → adversarial skeptic pass → 7 survivors.

## Ranked Ideas

### 1. fkill --port and --app selectors
**Description:** `fkill --port 3000` resolves the listener via `lsof -iTCP:3000 -sTCP:LISTEN` and kills it through fkill's existing safety pipeline; `fkill --app NAME` kills a whole responsible app (all helpers at once) by reusing memtop's .app-bundle grouping logic. Both honor exclusions, `--list`, PID re-verification, and exit codes.
**Rationale:** Highest daily value per line. "Address already in use" and "kill all of Chrome" are the two most common real kill intents; both currently require detours (hand-rolled lsof, or fzf multi-select hoping you got every helper). The safety machinery all kill features need already exists.
**Downsides:** `--app` needs an explicit blast-radius carve-out (a whole app is intentionally >5 processes); Electron helpers respawn unless the root process dies first — kill ordering matters.
**Confidence:** 85%
**Complexity:** Low-Medium
**Status:** Explored

### 2. fkill --wait with TERM→KILL escalation
**Description:** `--wait[=SECS]` (default ~5s) polls each signaled PID for actual death; still-alive at timeout → report (exit 2) or, with `--escalate`, send SIGKILL. Interactive mode shows "dying… dead (1.8s)" per process.
**Rationale:** Closes fkill's one remaining correctness gap — a TERM that gets ignored is a daily event and today fkill reports success. ~15 lines, reusing the PID-reuse guard's existing `ps -p PID -o command=` re-check. `--app` (idea 1) benefits directly.
**Downsides:** Default wait behavior for `--match` scripting needs a decision (opt-in vs default).
**Confidence:** 90%
**Complexity:** Low
**Status:** Unexplored

### 3. zombies — orphaned dev-process sweeper
**Description:** Lists developer detritus: orphaned node/vite/webpack/jest workers and stale language servers (PPID 1, TTY `??`, name allowlist), with age, RSS, and total reclaimable memory. `--reap` pipes the set through fkill's machinery. Defaults to listing, never auto-reaps.
**Rationale:** Gigabytes accumulate weekly in processes no window owns; users never search fkill for processes they don't know exist. Inverts the flow: names the processes you forgot. Cheap, sudo-free `ps` heuristics.
**Downsides:** Heuristic can flag legitimate launchd-reparented daemons; allowlist needs occasional tending.
**Confidence:** 80%
**Complexity:** Medium
**Status:** Unexplored

### 4. perfmon report — one-shot diagnostic for LLM/bug-report pasting
**Description:** Captures memtop (grouped + raw top 10), memory_pressure, vm_stat, swap, uptime, top-CPU ps into a single fenced-markdown block on stdout; `--copy` pipes to pbcopy. No thermal data (would need sudo powermetrics).
**Rationale:** Pure composition of what exists — no daemon, no sudo, no state. "Paste machine state into a Claude conversation" is the maintainer's actual daily workflow, and every future metric added anywhere shows up in reports for free.
**Downsides:** None structural; scope discipline needed (resist adding sudo-gated sections).
**Confidence:** 85%
**Complexity:** Low
**Status:** Unexplored

### 5. memtop --snap / --diff — on-demand memory deltas
**Description:** `memtop --snap` writes the current grouped table to ~/.local/state/perfmon/; `memtop --diff` shows per-app RSS deltas since the snapshot ("Chrome +3.1 GB since 09:14"). No sampler, no daemon.
**Rationale:** The ~20 lines of the full "history layer" idea that answer 80% of the leak question ("what GREW, not what's big"). Makes future features history-aware without any resident component.
**Downsides:** Only answers "since I snapped" — no passive overnight recording (that variant was rejected with the launchd stack).
**Confidence:** 80%
**Complexity:** Low
**Status:** Unexplored

### 6. memtop --project — what is this repo's dev stack costing me
**Description:** Filters to processes whose cwd (via `lsof -d cwd`) is under the current repo: dev servers, test watchers, docker helpers otherwise hidden inside generic "node" rows. Natural companion: `fkill --project` teardown.
**Rationale:** The most differentiated idea on the list for a herdr + Claude Code workflow; nothing else (including btop) answers it.
**Downsides:** `lsof` over all PIDs is slow; cwd is misleading for daemons launched elsewhere.
**Confidence:** 70%
**Complexity:** Medium
**Status:** Unexplored

### 7. memtop --status — one-line vitals for the herdr status bar
**Description:** Emits `mem 62%  swp 1.2G  ⚠` (free%, swap, pressure glyph). Presentation (colors, flashing, placement) is herdr's job — perfmon just prints the string.
**Rationale:** ~10 lines; ambient visibility with zero resident component.
**Downsides:** Value depends on herdr status-bar integration.
**Confidence:** 75%
**Complexity:** Low
**Status:** Unexplored

**Build order:** 1 → 2 → 3 (fkill's safety pipeline is the shared asset), then 4/5/6 (read-only views that compose), 7 anytime.

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Pressure sentinel / swap-death warning daemon | Resident polling daemon with hooks, in bash, duplicating macOS's own out-of-memory alert; burns CPU forever to say what btop shows |
| 2 | Background history sampler + `perfmon blame` | Requires launchd supervision stack; trimmed to on-demand --snap/--diff (survivor 5) |
| 3 | fkill --restart (bounce) | Faithful relaunch unsolvable (env, cwd, version managers, quoting); wrong bounce worse than none |
| 4 | fkill --freeze (SIGSTOP/SIGCONT) | macOS watchdogs kill/beachball stopped GUI apps; frozen processes still hold all RSS |
| 5 | fkill kill-log / --last / --revive | Flight recorder for a single user who was watching; --revive is `history \| grep` with a maintenance burden |
| 6 | perfmon MCP server | Claude already runs the CLIs via Bash; MCP wrapper = second interface, strictly less capability |
| 7 | --json stable schemas everywhere | Permanent compatibility contract on a 79-line script; defer until a concrete consumer exists |
| 8 | cputop + nettop/disktop/powertop family | btop (one pane over) is the CPU answer; family is a product roadmap, sudo/entitlement walls |
| 9 | Electron tab-title attribution (x-ray) | AppleScript hits TCC prompts, most Electron apps have no scripting dictionary, CDP needs debug ports, Chromium multiplexes tabs per renderer; the free part (--type un-grouping) can ride along later |
| 10 | ~/.perfmonrc config + auto-kill policy enforcer | Config surface for a user base of one; a policy daemon that kills by rule is how you lose unsaved work to your own tooling |
| 11 | Panic button / perfmon rescue | Real scenario, but `purge` needs sudo (password prompt during memory emergency); trim to a --fast no-deps path someday |
| 12 | Generic declarative herdr workspace builder (YAML) | Framework extracted from one example; if a second workspace appears, copy the 150 lines |
| 13 | launchd agent home (install-agent) | Exists only to host the rejected sampler/sentinel; KeepAlive/log-rotation/stale-version burden |
| 14 | Homebrew tap + dynamic completions | Release ceremony for a single-installer tool; dynamic completion forks python3 per keystroke (static completions still worthwhile someday) |
| 15 | Agent-session process grouping | PPID-tree reconstruction breaks on daemonize/reparent; agent-orphan debris folds into zombies' allowlist instead |
| 16 | Pressure-triggered workspace summon + triage banner | Depends on rejected sentinel; attention-grabbing resident behavior |

## Session Log
- 2026-07-08: Initial ideation — 41 raw ideas from 5 framed agents, 19 after dedupe, 7 survived adversarial filtering. Idea 1 (fkill --port/--app) selected for brainstorm; marked Explored.
