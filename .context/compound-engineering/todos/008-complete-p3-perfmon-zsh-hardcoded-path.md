---
status: complete
priority: p3
issue_id: "008"
tags: [code-review, portability, shell]
dependencies: []
---

# perfmon.zsh: hardcoded install path with fully-silenced auto-launch failure

Both the PATH export and the auto-launch hardcode `$HOME/Documents/devtools/perfmon`; if the repo is cloned elsewhere, commands vanish from PATH and the workspace silently stops auto-launching (everything is redirected to /dev/null and backgrounded).

## Problem Statement

`perfmon.zsh:5,11` — works today because the path matches this machine, but on a move/second machine the failure mode is invisible: line 11's `>/dev/null 2>&1 &` in a subshell swallows "command not found" entirely.

## Findings

- correctness-reviewer (P3, confidence 0.9) and code-simplicity-reviewer (the path literal is also duplicated) converged.

## Proposed Solutions

### Option 1: Derive path from the sourced file (recommended)

**Approach:** `PERFMON_DIR="${0:A:h}"` (zsh) at the top; use it for both the PATH prepend and the auto-launch binary. Optionally `command -v perfmon >/dev/null || print -u2 "perfmon: bin not found"` once.

**Pros:** Repo becomes relocatable; removes the duplication; README install line stays unchanged.
**Cons:** `${0:A:h}` semantics under `source` need a quick sanity check on the zsh version in use.
**Effort:** ~10 min.
**Risk:** Low

### Option 2: Keep hardcoded but add a guard

**Approach:** `[[ -d $PERFMON_DIR/bin ]] || return` with a one-time warning.

**Pros:** Trivial.
**Cons:** Still breaks on relocation, just audibly.
**Effort:** 5 min.
**Risk:** Low

## Recommended Action

Implement Option 1. Note: `${0:A:h}` is unreliable under `source` (depends on FUNCTION_ARGZERO/POSIX_ARGZERO); use the prompt-expansion idiom `PERFMON_DIR="${${(%):-%N}:A:h}"` instead, which always yields the currently-sourced file. Use `$PERFMON_DIR` for both the PATH prepend and the auto-launch binary, add a one-time non-fatal `print -u2` warning when `$PERFMON_DIR/bin` is missing, and guard the auto-launch with `-x "$PERFMON_DIR/bin/perfmon"` so the backgrounded/silenced launch only runs when the binary exists.

## Technical Details

**Affected files:**
- `perfmon.zsh:5,11`
- `README.md:40` — install snippet references the same path (fine; it's the user's chosen clone location)

## Acceptance Criteria

- [x] Sourcing perfmon.zsh from any clone location puts bin/ on PATH
- [x] Auto-launch failure is not fully silent (at least detectable once)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — correctness-reviewer + code-simplicity-reviewer)

**Learnings:**
- Backgrounded-and-silenced startup hooks need at least one detectable failure signal.

### 2026-07-08 - Resolution (Option 1 implemented)

**By:** pr-comment-resolver

**Changes:**
- `perfmon.zsh`: derive `PERFMON_DIR="${${(%):-%N}:A:h}"` from the sourced file; use it for the PATH prepend and the auto-launch binary; one-time `print -u2` warning if `$PERFMON_DIR/bin` is missing; auto-launch additionally guarded by `-x` on the binary (launch itself stays backgrounded/silenced).

**Verification:**
- `zsh -n perfmon.zsh` — clean.
- Sourcing a scratch copy from an unrelated directory: `PERFMON_DIR` resolved to the copy's directory and the missing-bin warning printed once to stderr (non-fatal).
- `zsh -c 'source perfmon.zsh; command -v memtop'` from the repo resolved to `/Users/kiily/Documents/devtools/perfmon/bin/memtop`.

**Learnings:**
- Tested empirically: both `${0:A:h}` and `${${(%):-%N}:A:h}` resolved correctly under `zsh -c 'source …'` here, but `$0` under `source` depends on FUNCTION_ARGZERO/POSIX_ARGZERO, so the prompt-expansion `%N` idiom is the robust choice for "directory of the currently-sourced file".
