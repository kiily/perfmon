---
status: complete
priority: p2
issue_id: "002"
tags: [code-review, agent-native, ux, shell]
dependencies: ["001"]
---

# fkill: add --list/dry-run mode and meaningful exit codes for --match

There is no non-interactive way to *see* fkill's candidate list before killing, and `--match` with zero matches exits 0 — scripts and agents can't verify before or after a destructive action.

## Problem Statement

- The human workflow is "look at the fzf list, then decide"; the non-interactive workflow is "write a regex blind and hope." The exclusion logic (shell ancestry, herdr, own pgid) lives only inside `candidates()` (`bin/fkill:37-46`), so an external `ps` cannot accurately preview what fkill would target.
- `bin/fkill:58` — "nothing selected" exits 0 in `--match` mode, so "killed the target" and "regex matched nothing" are indistinguishable without parsing stdout. The kill loop (`bin/fkill:60-66`) also exits 0 even when some `kill` calls fail.

## Findings

- agent-native-reviewer: rated this the one real parity gap (7/8 capabilities agent-accessible). `--list` is a ~4-line change since `candidates()` already exists.
- Interactive no-TTY degradation is already safe (fzf fails → `|| true` → "nothing selected") — good; keep that path exiting 0.

## Proposed Solutions

### Option 1: `--list` flag + mode-aware exit codes (recommended)

**Approach:** `--list` prints `candidates` (filtered by `--match`/query if given) and exits 0. In `--match` kill mode: exit 1 when nothing matched, exit 2 if any kill failed; interactive cancel stays exit 0. Document in header comment.

**Pros:** Enables list → confirm → kill for agents/scripts; trivially testable in smoke.sh.
**Cons:** None meaningful.
**Effort:** ~30 min including README + smoke test.
**Risk:** Low

### Option 2: `--dry-run` modifier instead of `--list`

**Approach:** `fkill --match RE --dry-run` prints would-be victims without signalling.

**Pros:** Exercises the exact kill-selection code path.
**Cons:** Slightly less discoverable than `--list` for the "just show me the list" case; could do both.
**Effort:** ~20 min.
**Risk:** Low

## Recommended Action

Option 1 implemented. Added `--list`: prints `candidates` filtered by `--match` regex (or the positional query when no `--match`) and exits 0 without ever reaching the kill path. Exit codes in `--match` kill mode: 1 when nothing matched ("fkill: no candidates match: RE" on stderr) and 1 when the blast-radius guard refuses (todo 001); 2 when any `kill` call failed (kill loop rewritten from a piped subshell to a `while ... done <<< "$SELECTED"` loop so the FAILED flag survives). Interactive fzf cancel still prints "fkill: nothing selected" and exits 0. Header usage comment now documents `--list`, `--force`, and the exit codes across lines 2-7, and `-h/--help` extraction widened from `sed -n '2,4p'` to `sed -n '2,7p'`. README updated (new `--list` row, exit codes on the `--match` row).

## Technical Details

**Affected files:**
- `bin/fkill` — arg loop (11-18), post-selection exit (58), kill loop (60-66)
- `README.md` command table
- `test/smoke.sh` — add list-mode and exit-code checks

Depends on 001 so the listed/matched surface is the corrected command-only one.

## Acceptance Criteria

- [x] `fkill --list [--match RE]` prints candidates without signalling and never kills (verified; `exit 0` before any kill code)
- [x] `fkill --match RE` exits nonzero when nothing matched (verified: `--match zzz-no-such-proc` → exit 1)
- [x] Partial kill failures are reflected in the exit code (kill loop sets FAILED → exit 2)
- [x] Interactive fzf cancel still exits 0 (path unchanged: `|| true` + "nothing selected" + exit 0)
- [x] Header help and README document the above

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — agent-native-reviewer)

**Actions:**
- Capability-parity mapping of all commands; identified missing preview affordance and ambiguous exit semantics.

**Learnings:**
- `test/smoke.sh` doubles as the agent-parity regression suite here; new non-interactive affordances should land with a smoke check.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- Implemented `--list` (filtered by `--match` or query), exit 1 on zero `--match` matches, exit 2 on any kill failure; interactive cancel stays exit 0. Header usage + `sed -n '2,7p'` help range; README updated.

**Verification:**
- `bin/fkill --list` printed the memory-sorted candidate list; `--list --match mds_stores` printed exactly the one match; nothing was signalled.
- `bin/fkill --match zzz-no-such-proc` → stderr message, exit 1.
- `bin/fkill --help` prints the full 6-line usage block.
- Smoke-test updates deferred to the test-owning agent.
