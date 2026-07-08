---
title: "feat: fkill --port/--app selectors with death verification"
type: feat
status: completed
date: 2026-07-08
origin: docs/brainstorms/2026-07-08-fkill-port-app-selectors-requirements.md
deepened: 2026-07-08
---

# feat: fkill --port/--app selectors with death verification

## Overview

Extend `bin/fkill` with two new selectors — `--port N` (kill the TCP listener on a port) and `--app NAME` (kill a whole responsible app bundle, root-first) — and make every kill honest by polling for actual death, with opt-in TERM→KILL escalation (`--escalate`). All new paths run through fkill's existing safety pipeline.

## Problem Frame

Half of real kill intents arrive as "whatever holds port 3000" or "all of Chrome", which today require lsof detours or error-prone fzf multi-select. Separately, fkill reports "killed" the moment `kill(2)` returns, even when the process ignores SIGTERM — a false success that matters most for whole-app kills where helpers linger or respawn. (See origin: docs/brainstorms/2026-07-08-fkill-port-app-selectors-requirements.md.)

## Requirements Trace

- R1. `--port N` kills TCP LISTEN owner(s), works with `-9`/`--list`, standard exit codes.
- R2. `--app NAME` kills every bundle member, root process first.
- R3. `--app` prints victim list (root flagged) + single y/N confirm; `--force` skips; `--list` previews; numeric >5 guard does not apply to `--app`.
- R4. Every kill verifies death (bounded poll ~5s); "killed" only when gone; survivor → "still running" + exit 2.
- R5. `--escalate` = TERM → wait → SIGKILL → re-verify. Never automatic.
- R6. All selectors pass through exclusions, PID-reuse re-verification, exit codes 0/1/2.
- R7. Selectors mutually exclusive (`--match` | `--port` | `--app` | interactive).
- R8. Help text, README, and smoke tests cover all new behavior.

## Scope Boundaries

(carried from origin)
- TCP LISTEN only — no UDP, established connections, or port ranges.
- No `--project` selector, kill-log, restart, or freeze.
- No config file; wait window is a flag, not a dotfile.
- No sudo: root-owned listeners are not killable; `--port` reports "no killable listener" for them.

## Context & Research

### Relevant Code and Patterns

- `bin/fkill` — the entire feature lands here. Key structures: arg loop (`bin/fkill:16-27`), `candidates()` with ENVIRON-passed regex (`bin/fkill:49-65`), `--list` short-circuit (`:67-70`), `--match` + blast-radius guard (`:72-80`), kill loop with PID-reuse guard and `FAILED` accounting (`:90-108`).
- `bin/memtop:52-64` — the `.app`-bundle grouping awk (first `.app` path segment = responsible app). `--app` mirrors this logic inverted (name → PIDs) rather than sharing code; the shapes differ and the repo favors duplication over a lib file.
- `test/smoke.sh` — `poll` helper, PID-unique detached dummies via `python3 ... start_new_session=True`, identity-checked cleanup trap. New tests follow these patterns exactly.
- Regex-into-awk must go via `ENVIRON`, not `-v` (BSD awk backslash mangling) — established in this repo.

### Institutional Learnings

From `docs/solutions/security-issues/destructive-shell-cli-safety-patterns.md`:
- Match against source data, not formatted output; every destructive mode gets a dry-run; zero matches on a destructive selector exits nonzero; blast radius bounded structurally; tests never signal processes they didn't spawn; blast-radius assertions (other PIDs still alive), bounded polls not fixed sleeps; piped `while` loses flags — use `<<<`/herestrings for exit-code accounting.

### External References

None needed — `lsof -nP -iTCP:N -sTCP:LISTEN` and signal/poll semantics are stock macOS; no new dependencies.

## Key Technical Decisions

- **Verification is a change to the shared kill loop, not a selector feature** (R4): implement it once in the existing loop (`bin/fkill:90-108`) so interactive, `--match`, `--port`, and `--app` all inherit it. This is why Unit 1 comes first.
- **"Dead" = process gone or zombie** *(empirically validated on this machine)*: the death poll checks `ps -p PID -o state=` — nonzero exit / empty output means gone; output *starting with* `Z` means zombie (dead-enough: `kill -0` still succeeds on zombies, so it is the wrong liveness test). Strip the trailing padding macOS ps emits and suppress ps stderr (out-of-range PIDs print noise but exit 1, same "gone" branch).
- **--app root identification = "main binary" path shape, not segment counting** *(validated against live process families — segment counting is WRONG)*: every Electron app also runs one-`.app`-segment non-roots (crashpad handlers, `Contents/Resources` binaries), so "exactly one `.app` segment" is ambiguous. The validated rule: the root is the member whose argv[0] path is `…/<Name>.app/Contents/MacOS/<binary>` — i.e. `Contents/MacOS/` immediately follows the *first* `.app/` segment. This uniquely identified the root in every family observed (Chrome, Brave, Cursor, Loom, Spotify, Wispr Flow, Claude, Finder). Fallback when no member matches (families can be all-orphaned-helpers, observed with Cursor): oldest member by `etime` *normalized to seconds* (formats mix `MM:SS`/`HH:MM:SS`/`DD-HH:MM:SS`; string sort is wrong) — or no root phase at all if resolution is ambiguous. No fixed sleep between root and sweep — the root goes through the death poll, then remaining members are swept. Helpers are usually children of the root, so root-death often reaps them naturally.
- **--app membership = anchored first-`.app`-segment match + transitive children**: membership regex anchors at the start of the command (argv[0] path), requiring `(^|/)<NAME>\.app/` at the *first* `.app` occurrence — never "anywhere in line" (real command lines carry `.app` paths in *arguments*, which would create false membership) and never bare `.app` without the trailing slash (`.appex`/`.xpc` must not match). After path-matching, add transitive children (by PPID) of matched members to the victim list: some helpers rewrite their command line entirely (VS Code/Cursor extension hosts show no path at all) and are invisible to path matching.
- **--app name matching = case-insensitive exact whole-basename match**: this machine has `Google Chrome.app` vs `Google Chrome Dev.app`, `Notion.app` vs `Notion Calendar.app`, `Claude.app` vs `Claude Code URL Handler.app` — prefix/substring matching is dangerous. Match the literal bundle basename (spaces/parentheses allowed); do not anchor to `/Applications` (roots also live in `/System/Library/CoreServices/`, `~/Library/Application Support/…`).
- **Mirror memtop's grouping, don't extract a shared lib**: fkill needs the inverse mapping (name → PIDs) so the code shape differs anyway; a lib file adds coupling the repo deliberately avoids. Cross-reference comments in both files.
- **`--port` resolves PIDs then reuses the candidate pipeline**: lsof output is only used to get PIDs; display, exclusions, and the kill loop all go through `candidates()` filtered to those PIDs, so herdr/self exclusions still apply even if they somehow hold the port.
- **Non-TTY `--app` without `--force` refuses** with a clear message (consistent with existing no-TTY fzf degradation); the y/N prompt is TTY-only.
- **Exit-code contract sharpens, doesn't break**: 0 and 1 keep their meanings; exit 2 ("a kill failed") now also covers "process survived the wait window" — strictly more accurate, no new codes.

## Open Questions

### Resolved During Planning

- Root identification for `--app`: `Contents/MacOS/` immediately after the first `.app/` segment, with normalized-etime fallback — empirically validated against ~10 live app families; the original segment-counting heuristic was refuted (see Key Technical Decisions).
- Poll defaults: 0.1s × 50 (= 5s), tunable via `--wait SECS` (positive integer, validated like memtop's interval). Validated generous: a TERM'd process left ps in ~8ms; the first poll catches the common case.
- Sweep completeness for title-rewritten helpers: include transitive PPID-children of path-matched members (resolved from deepening research; previously an implicit gap).
- Code sharing with memtop: mirror, don't extract (see Key Technical Decisions).
- Multiple listeners on one port (SO_REUSEPORT/forked workers): kill all of them; they flow through the normal pipeline and its guards.
- Ignore-TERM smoke recipe: detached `bash -c 'trap "" TERM; while :; do sleep 5; done' perfmon-ignoreterm-<unique>` — the custom `$0` marker makes it uniquely matchable; spawned via the existing `start_new_session=True` python pattern.

### Deferred to Implementation

- Exact prompt wording, root-flag glyph in the `--app` victim list, and "dying… dead (1.8s)" interactive display details — cosmetic, decided in code.
- Whether the `--app` helper sweep needs one re-snapshot after root death (helpers may self-exit when the root dies; killing already-dying helpers is harmless but noisy) — observe during implementation.

## Implementation Units

- [x] **Unit 1: Death verification and --escalate in the shared kill loop**

**Goal:** Every kill polls for actual death; honest reporting; opt-in TERM→KILL escalation.

**Requirements:** R4, R5, R6 (exit codes)

**Dependencies:** None

**Files:**
- Modify: `bin/fkill`
- Test: `test/smoke.sh`

**Approach:**
- Add `--escalate` and `--wait SECS` flags (validate SECS like memtop's interval; `--escalate` implies waiting).
- After a successful `kill`, poll `ps -p PID -o state= 2>/dev/null` (0.1s steps, wait-window bound); nonzero-exit/empty output or stripped state starting with `Z` = dead → print `killed`; survivor → with `--escalate`, send SIGKILL and re-poll; else print `still running after SIG<X>` to stderr and set the failure flag (exit 2). (All state semantics empirically verified — see Key Technical Decisions.)
- `-9` upfront skips escalation (already KILL) but still verifies.
- Keep the `FAILED` accounting in the herestring loop (piped-while subshells lose flags — see learnings).

**Patterns to follow:** existing PID-reuse guard (`bin/fkill:94-99`) is the re-check idiom; smoke.sh's `poll` helper shape.

**Test scenarios:**
- Detached ignore-TERM dummy (`bash -c 'trap "" TERM; while :; do sleep 5; done' <unique-marker>` — verified: the marker appears as the trailing argument in the ps command column, matchable by `--match`; TERM is genuinely ignored; KILL works; the orphaned `sleep` child self-exits): `--match <marker>` → "still running", exit 2, process alive; then `--match <marker> --escalate` → dead, exit 0.
- Normal dummy still killed and reported exactly once; other-PID blast-radius snapshot untouched.
- `--wait 0` / non-numeric rejected with a clear message.

**Verification:** smoke passes; a TERM-ignoring process can no longer produce a false "killed"; existing tests (exact-PID assertion, exclusions) still green.

- [x] **Unit 2: --port selector**

**Goal:** `fkill --port 3000` kills the TCP listener(s) on the port through the safety pipeline.

**Requirements:** R1, R6, R7

**Dependencies:** Unit 1 (verification applies to port kills)

**Files:**
- Modify: `bin/fkill`
- Test: `test/smoke.sh`

**Approach:**
- Resolve PIDs with `lsof -nP -tiTCP:<port> -sTCP:LISTEN` (flag combination verified working as written; one PID per line). lsof exits 1 with empty output when nothing listens — treat that as "no killable listener on port N (or owned by another user)", exit 1, not as an error.
- Feed the PID set into `candidates()` as a PID filter (new optional filter alongside the regex — exclusions and formatting stay authoritative); result flows into the existing selection → guard → kill loop path.
- `--list --port N` previews the listener rows without killing. Mutual-exclusion check: `--port` with `--match`/`--app`/positional query is an argument error (start of R7 enforcement).
- Validate port is 1-65535.

**Patterns to follow:** `--list` short-circuit (`bin/fkill:67-70`); no-match exit-1 shape (`bin/fkill:74`).

**Test scenarios:**
- Spawn a detached listener on a random high port (`python3 -m http.server <port>` via the start_new_session pattern); `--list --port` shows it and kills nothing; `--port` kills it (verified dead, exit 0); freed port → rerun exits 1.
- Invalid port and `--port` + `--match` combos → clear error, exit 1.

**Verification:** the port-squatter workflow is one command; exit 0 implies the port's owner is dead; herdr/self exclusions still apply to port matches.

- [x] **Unit 3: --app selector with root-first ordering and confirmation**

**Goal:** `fkill --app "Brave Browser"` shows the full victim list, confirms once, kills root first with verification, then sweeps helpers.

**Requirements:** R2, R3, R6, R7

**Dependencies:** Unit 1 (root death is verified by polling, not a sleep)

**Files:**
- Modify: `bin/fkill`
- Test: `test/smoke.sh`

**Approach:**
- Resolve bundle members: processes whose argv[0] path contains `(^|/)<NAME>\.app/` at its *first* `.app` occurrence (case-insensitive exact basename match — see Key Technical Decisions for why prefix matching and anywhere-in-line matching are both unsafe); then add transitive PPID-children of matched members (catches title-rewritten helpers like extension hosts). Classify the root by the `Contents/MacOS/`-after-first-`.app/` rule, normalized-etime fallback; proceed sweep-only if no root resolves (all-orphan families exist).
- Print the victim list through the standard candidate formatting with the root row flagged; TTY → single y/N prompt; non-TTY without `--force` → refuse with message, exit 1; `--force` skips prompt; `--list --app` previews only.
- Bypass the numeric >5 guard for `--app` (the confirmation replaces it — origin Key Decision); kill order: root (verified via Unit 1 poll) → remaining members; helpers that already exited during the sweep are skipped silently by the PID-reuse guard.
- No match → "no processes for app: NAME", exit 1.

**Patterns to follow:** memtop's bundle-splitting awk (mirrored, cross-referenced comment); existing guard/refusal output shape (`bin/fkill:76-80`).

**Test scenarios:**
- `--list --app Finder` (safe, real bundle): ≥1 row, nothing killed, exit 0.
- Non-TTY `--app Finder` without `--force`: refuses, exit 1, nothing killed.
- Fake-bundle dummy: detached process whose argv[0] is `<Tmp>/SmokeApp.app/Contents/MacOS/SmokeApp-<unique>` (via `executable=` override in the python spawn — argv[0] is what ps shows; no real bundle needed) → `--app SmokeApp --force` kills exactly it, root-classification exercised. A second dummy with argv[0] `<Tmp>/SmokeApp.app/Contents/Resources/helper-<unique>` verifies helper classification and root-first ordering.
- Name-precision check: `--list --app <partial name>` must NOT match a longer bundle name (e.g. fake `SmokeApp` must not match a `SmokeApp Two.app` dummy).
- Unknown app name → exit 1.

**Verification:** whole-app kill is list → one confirm → root-first verified kills; no false success while members survive (Unit 1 guarantees).

- [x] **Unit 4: Help, README, and cross-cutting smoke coherence**

**Goal:** The new surface is discoverable and the full contract is regression-tested.

**Requirements:** R7, R8

**Dependencies:** Units 1-3

**Files:**
- Modify: `bin/fkill` (header usage lines + `sed -n` help range), `README.md` (command table rows for `--port`, `--app`, `--escalate`/`--wait`, exit codes)
- Test: `test/smoke.sh`

**Approach:**
- Header usage documents all selectors, mutual exclusivity, wait/escalate semantics, and the 0/1/2 exit contract; keep the `sed` range in sync (this repo has been burned by drift before).
- Final R7 sweep: every illegal selector combination errors consistently.
- Smoke run count check: full suite passes twice consecutively (flake check, established practice).

**Test scenarios:**
- `fkill --help` lists every flag; each pairwise illegal combo (`--match`+`--port`, `--port`+`--app`, `--app`+query) exits 1 with a message.

**Verification:** README table matches actual behavior; smoke suite (now ~25+ checks) passes twice.

## System-Wide Impact

- **Interaction graph:** `bin/perfmon` and `perfmon.zsh` don't invoke fkill — no workspace impact. The cheat sheet in `perfmon --cheats` mentions fkill usage; update its two fkill lines in Unit 4.
- **Error propagation:** exit 2 now covers "survived the wait window" — any script checking `!= 0` behaves identically; scripts checking `== 2` get strictly better information.
- **State lifecycle risks:** the death poll adds up to `--wait` seconds of runtime per surviving PID; interactive multi-select of N stubborn processes could wait serially — acceptable for a personal tool, noted in help.
- **API surface parity:** `--list` must preview all three selectors identically (match/port/app) — covered in Units 2-3.
- **Integration coverage:** the ignore-TERM + escalate path and the port-free-after-kill assertion are the two cross-layer scenarios unit-style checks alone wouldn't prove; both are in smoke.

## Risks & Dependencies

- **Helper respawn (Electron):** killing root first is the mitigation; a helper respawned *by launchd* after root death would survive the sweep — acceptable, reported honestly by verification (exit 2) rather than hidden.
- **XPC/appex workers are out of `--app`'s reach by design:** Safari's WebContent workers and other apps' `.xpc`/`.appex` services carry no `<App>.app/` path — document that `--app` covers bundle-pathed processes and their children only (Safari is effectively not sweepable this way).
- **System apps:** Finder/Dock/ControlCenter match the rules and are auto-restarted by launchd; warn (not refuse) when the resolved root lives under `/System/`.
- **lsof latency:** `lsof -i` on a single port is fast (<100ms); no `-d cwd` full scans anywhere in this plan.
- **Zombie handling:** treating state-starts-with-`Z` as dead is deliberate and verified (`kill -0` succeeds on zombies; an unreaped target would otherwise fail the "gone" check forever); document in a code comment.
- **`--app` name matching breadth:** exact whole-basename match (case-insensitive) — verified necessary on this machine (`Google Chrome` vs `Google Chrome Dev`, `Notion` vs `Notion Calendar`, `Claude` vs `Claude Code URL Handler`); users can preview resolution via `--list --app`. Nested same-name bundles (observed: `Wispr Flow.app` inside `Wispr Flow.app`) are handled by anchoring on the *first* `.app` segment only.

## Documentation / Operational Notes

- README command table + exit-code note; `perfmon --cheats` fkill lines (Unit 4). No rollout/monitoring concerns — local tool.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-08-fkill-port-app-selectors-requirements.md](../brainstorms/2026-07-08-fkill-port-app-selectors-requirements.md)
- Ideation: [docs/ideation/2026-07-08-perfmon-capabilities-ideation.md](../ideation/2026-07-08-perfmon-capabilities-ideation.md) (ideas #1, #2)
- Safety patterns: [docs/solutions/security-issues/destructive-shell-cli-safety-patterns.md](../solutions/security-issues/destructive-shell-cli-safety-patterns.md)
- Related code: `bin/fkill`, `bin/memtop:52-64`, `test/smoke.sh`
