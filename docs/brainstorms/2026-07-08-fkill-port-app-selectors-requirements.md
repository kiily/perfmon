---
date: 2026-07-08
topic: fkill-port-app-selectors
---

# fkill --port / --app selectors with death verification

## Problem Frame

fkill's only selectors are the interactive fzf picker and `--match REGEX` — but half of real kill intents arrive as different knowledge: "whatever is squatting on port 3000" or "all of Chrome". Today both require detours (hand-rolled `lsof`, or fzf multi-select hoping every helper was caught). Additionally, fkill currently reports success the moment `kill` returns, even when the process ignores SIGTERM — so "killed" can be a lie, which matters most for whole-app kills where Electron helpers respawn or linger.

Source: docs/ideation/2026-07-08-perfmon-capabilities-ideation.md, ideas #1 and #2 (bundled by decision).

## Requirements

- R1. `fkill --port N` kills the process(es) listening on TCP port N (resolved via `lsof`, LISTEN state only). Works with `-9`, `--list` (show, don't kill), and the standard exit-code contract.
- R2. `fkill --app NAME` kills every process belonging to the responsible app bundle NAME (same grouping notion as memtop: helpers roll up to their .app), root process first.
- R3. `--app` always prints the full victim list (root flagged) and asks a single y/N confirmation. `--force` skips the prompt (for scripts); `--list` previews without killing. The numeric >5 blast-radius guard does not apply to `--app` — the confirmation replaces it.
- R4. Every kill (all selectors, including existing `--match` and interactive) verifies death: poll the signaled PID (bounded, ~5s) and report honestly — "killed" only when the process is gone; "still running after SIGTERM" with exit 2 otherwise.
- R5. `--escalate` opts into TERM→wait→KILL: if the process survives the wait window, send SIGKILL and verify again. Never automatic.
- R6. All new selectors run through the existing safety pipeline: self/ancestry/herdr exclusions, PID-reuse re-verification before each signal, exit codes (0 success, 1 nothing matched/refused, 2 kill failed or survivor remains).
- R7. Selectors are mutually exclusive per invocation (`--match` | `--port` | `--app` | interactive); combining them is an argument error.
- R8. Help text, README command table, and smoke tests cover the new selectors and verification behavior.

## Success Criteria

- "Port squatter" workflow is one command with no lsof knowledge: `fkill --port 3000` kills the vite/next leftover and exits 0 only if the port's owner is actually dead.
- `fkill --app "Brave Browser"` presents the full helper list, one confirmation, kills root-first, and does not report success while helpers survive.
- A process that ignores SIGTERM produces "still running" + exit 2 (or dies via `--escalate`), never a silent false success.
- Existing behavior unchanged for scripts: `--match` semantics, exclusions, and exit codes 0/1 keep their meaning; exit 2 becomes strictly more accurate.
- Smoke suite covers: port kill (self-spawned listener), app-grouping resolution, confirmation/--force paths, ignore-TERM → exit 2, and --escalate.

## Scope Boundaries

- TCP LISTEN sockets only for `--port` — no UDP, no established connections, no port ranges.
- No `--project`/cwd-based selector (separate ideation idea #6).
- No kill-log, no restart/bounce, no freeze — all explicitly rejected in ideation.
- No config file; the wait window may be a flag (planning decides) but not a dotfile setting.
- Root-owned/system listeners: out of scope to kill (no sudo); listing/labeling them in `--list` output is fine.

## Key Decisions

- **Bundle --wait/escalation with the selectors** (rather than selectors-only): `--app` is unreliable without root-first ordering plus death verification — shipping them together makes one coherent, honest change.
- **--app safety = list + single y/N confirm** (not the >5 --force guard, not frictionless): a whole app is inherently many processes, so the count guard is wrong; a visible victim list with one confirmation keeps the safety property the guard was providing.
- **Verification on by default, escalation opt-in**: honest reporting should not be optional; SIGKILL should never happen without the user asking (`--escalate` or `-9`).
- **--port = TCP LISTEN via lsof**: matches the actual "address already in use" pain; anything broader is speculative.

## Dependencies / Assumptions

- `lsof` is stock macOS (no new dependency).
- memtop's .app-bundle grouping logic will be shared or mirrored in fkill for `--app` resolution (planning decides how — shared function vs. duplicated awk).
- Confirmation prompt requires a TTY; non-TTY `--app` without `--force` should refuse with a clear message (consistent with existing no-TTY degradation).

## Outstanding Questions

### Resolve Before Planning

(none)

### Deferred to Planning

- [Affects R2][Technical] How to identify the app "root" process reliably (oldest PID in the bundle? the one whose binary is `.app/Contents/MacOS/<Name>`?) and what ordering delay, if any, between root kill and helper sweep.
- [Affects R4][Technical] Poll interval/timeout defaults (e.g. 0.1s × 50) and whether the wait window is tunable via `--wait=SECS`.
- [Affects R2][Technical] Whether `--app` resolution shares code with memtop (extract a helper) or duplicates the small awk — weigh against the repo's minimalism preference.
- [Affects R1][Technical] Multiple PIDs on one port (SO_REUSEPORT, forked workers): kill all listeners or list-and-confirm when more than one.
- [Affects R8][Technical] Safe smoke-test recipe for the ignore-TERM case (e.g. a self-spawned `trap '' TERM` bash dummy) following the PID-unique blast-radius patterns in docs/solutions/.

## Next Steps

→ `/ce:plan` for structured implementation planning
