---
status: complete
priority: p3
issue_id: "009"
tags: [code-review, security, quality, shell]
dependencies: []
---

# perfmon: preemptive hardening polish (label-as-data, %q path quoting, complete help)

Three small latent-issue fixes in `bin/perfmon`, none currently exploitable: the workspace label is interpolated into Python source, `$SELF`/`$BIN_DIR` are hand-quoted into pane commands, and `-h` omits two flags.

## Problem Statement

1. **Label into Python source** — `bin/perfmon:71` embeds `$LABEL` directly in `w.get('label')=='$LABEL'`. Safe today (hardcoded constant, line 8), but one refactor away from code injection if LABEL ever comes from a CLI arg or env var; a label with a single quote already breaks parsing (and `json()` would swallow the SyntaxError).
2. **Hand-placed single quotes around paths** — `bin/perfmon:123,130,132` build pane commands like `"clear; '$SELF' --cheats"`. An install path containing a `'` breaks quoting and executes the remainder as shell. Self-inflicted only.
3. **Incomplete help** — `-h` prints header lines 2-5 (`bin/perfmon:56`), omitting `--cheats` (the best capability index for the whole toolset) and `--pressure-watch`.

## Findings

- security-sentinel (P3 ×2) + agent-native-reviewer (help gap). All agreed: cheap, non-urgent, worth doing together.
- Optional extras from simplicity review, take-or-leave: collapse the focus-mode 10-iteration wait loop to a single attempt (`bin/perfmon:84-90`); compute %RAM in memtop's first awk pass (`bin/memtop:41-60`). Both explicitly judged optional.

## Proposed Solutions

### Option 1: All three core fixes (recommended)

**Approach:** Pass label as data (`LABEL="$LABEL" python3 -c "...os.environ['LABEL']..."` or sys.argv); use `printf -v CMD '%q' "$SELF"`-style quoting for pane commands; add `--cheats`/`--pressure-watch` to the header usage lines and widen the sed range (mark --pressure-watch "internal, loops forever").

**Pros:** Removes an injection *class* before it can exist; ~20 lines total.
**Effort:** ~30 min.
**Risk:** Low

### Option 2: Help fix only

**Approach:** Just the header/sed change.

**Pros:** 2 min.
**Cons:** Leaves both latent quoting traps.
**Risk:** Low

## Recommended Action

Implement Option 1 (the three core fixes; optional extras skipped): pass LABEL to python as data via `LABEL="$LABEL"` env prefix + `os.environ['LABEL']` in `find_workspace`; quote `$SELF`/`$BIN_DIR/memtop` with `printf -v ... '%q'` for the three `herdr pane run` command strings; add `--cheats` and `--pressure-watch` (marked internal/loops-forever) to the header usage lines and widen the help range to `sed -n '2,7p'`. Implemented 2026-07-08 in `bin/perfmon`.

## Technical Details

**Affected files:**
- `bin/perfmon:2-5,56` — header + help sed range
- `bin/perfmon:66-72` — json()/find_workspace label handling
- `bin/perfmon:123,130,132` — pane run command construction

## Acceptance Criteria

- [x] LABEL reaches Python as data, never as source text (env var + os.environ; tested with a label containing single quotes)
- [x] A repo path containing a single quote still produces working pane commands (`printf %q` roundtrip tested with `/tmp/we'ird path/perfmon`)
- [x] `perfmon -h` lists every user-facing flag (--ensure, --doctor, --cheats, --pressure-watch marked internal/loops forever)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — security-sentinel + agent-native-reviewer + code-simplicity-reviewer)

**Learnings:**
- "Not currently exploitable" injection patterns are cheapest to remove while the constant is still a constant.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- `find_workspace` now compares against `os.environ['LABEL']` (env prefix on the `json` call); `json()` imports `os`. No shell variable reaches python source text.
- Pane commands use `printf -v SELF_Q '%q' "$SELF"` / `printf -v MEMTOP_Q '%q' "$BIN_DIR/memtop"`; the three `herdr pane run` strings interpolate the %q-quoted forms.
- Header usage block now lists all five invocations; `-h` prints `sed -n '2,7p'`; `--pressure-watch` documented as internal/loops forever. README command table gained a `perfmon --cheats` row.
- Skipped the explicitly optional extras (wait-loop collapse, memtop awk change — memtop is owned by another agent anyway).
- Verified: `bash -n` clean; `-h` output shows all flags; %q roundtrip and quoted-label matching tested in a scratch harness.

**Learnings:**
- `printf -v VAR '%q'` is the cheapest way to make command-string interpolation quote-safe without restructuring how commands are passed.
