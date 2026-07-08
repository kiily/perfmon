---
status: complete
priority: p3
issue_id: "006"
tags: [code-review, correctness, shell]
dependencies: []
---

# fkill: PID reuse race between snapshot and kill

The ps snapshot (`bin/fkill:38`) and the `kill` (`bin/fkill:61`) can be minutes apart in interactive mode (fzf open); a selected process may exit and macOS may reuse its PID — the signal then hits an innocent process, potentially with SIGKILL.

## Problem Statement

Interactive mode has an unbounded window while the user browses fzf; `--match` mode has a small one. The exclusion lists (`bin/fkill:31`) are also computed once before fzf, so herdr processes spawned during selection aren't protected.

## Findings

- security-sentinel (P3). Low probability on a personal machine, but the consequence (SIGKILL to a random process) is nasty, and the fix is cheap.

## Proposed Solutions

### Option 1: Re-verify identity before signalling (recommended)

**Approach:** In the kill loop, `NOW=$(ps -p "$pid" -o command= 2>/dev/null)`; signal only if `$NOW` prefix-matches the selected `cmd` (whitespace-normalized per issue 001's outcome); otherwise skip with a warning.

**Pros:** Closes the window to milliseconds; ~5 lines.
**Cons:** Prefix compare is heuristic (command lines can legitimately change via exec — acceptable).
**Effort:** ~20 min.
**Risk:** Low

### Option 2: Do nothing (document the window)

**Approach:** Note the race in the header comment.

**Pros:** Zero code.
**Cons:** SIGKILL-to-bystander remains possible.
**Effort:** 2 min.
**Risk:** Accepts the race

## Recommended Action

Option 1 implemented. In the kill loop, before each `kill`: `NOW=$(ps -p "$pid" -o command= 2>/dev/null) || NOW=""`, then `case "$NOW" in "$cmd"*) ;; *) skip ;; esac` — the freshly-read command must prefix-match the selected one (quoted case pattern, so regex/glob chars in the command are literal). On mismatch (or a gone PID) the process is skipped with `fkill: skipping PID — command changed since selection (now: ...)` on stderr and no signal is sent. The comparison is exact-prefix because todo 001's fix preserves original command spacing in the selection, so selected `cmd` and a fresh `ps` read agree byte-for-byte for an unchanged process. Skips are warnings, not kill failures — they do not trigger exit 2.

## Technical Details

**Affected files:**
- `bin/fkill:60-66` — kill loop

## Acceptance Criteria

- [x] A PID whose command no longer matches the selection is skipped with a warning
- [x] Smoke test still passes (done in issue 005 resolution — 2026-07-08, pr-comment-resolver)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — security-sentinel)

**Learnings:**
- Snapshot-then-act tools should re-validate identity at act time when the action is irreversible.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- Added the re-verify guard to the kill loop in `bin/fkill` (re-read `ps -p PID -o command=`, prefix-compare, skip with warning on mismatch).

**Verification:**
- Happy path: detached `sleep 12345` dummy still killed by `--match 'sleep 12345$'` (guard passes for an unchanged process); an unrelated `sleep 54321` dummy untouched. Mismatch path exercised implicitly by gone-PID handling (`NOW=""` never prefix-matches a non-empty cmd → skip).
