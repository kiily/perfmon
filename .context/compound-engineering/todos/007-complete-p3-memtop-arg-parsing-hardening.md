---
status: complete
priority: p3
issue_id: "007"
tags: [code-review, correctness, quality, shell]
dependencies: []
---

# memtop/fkill: argument-parsing hardening (interval 0 busy loop, missing-value errors, readability)

Small parsing gaps: `memtop --watch 0` busy-loops a snapshot pipeline at full tilt; `memtop -n` / `fkill --match` with no value die with bash's raw "unbound variable"; the `--watch` optional-arg one-liner reads like a set -e trap even though it's correct.

## Problem Statement

- `bin/memtop:15` — interval regex `^[0-9]+$` accepts 0 → `sleep 0` loop continuously forking ps/awk/sort/sysctl/memory_pressure. Ironic for a performance tool.
- `bin/memtop:13` and `bin/fkill:14` — `$2` under `set -u` with no value aborts with an unintelligible error instead of "missing value for -n".
- `bin/memtop:15` — the `[ ... ] && [[ ... ]] && { ...; shift; }; shift` chain was verified correct under set -e (non-final && members are errexit-exempt) but an explicit `if` is the same length and obvious.

## Findings

- correctness-reviewer (P3, confidence 0.9 — behavior verified empirically: `--watch` as last arg and `--watch foo` both behave acceptably today).
- code-simplicity-reviewer independently suggested the `if` rewrite (2 min).

## Proposed Solutions

### Option 1: Fix all three in one pass (recommended)

**Approach:** Interval regex → `^[1-9][0-9]*$`; guard value-taking flags with `[ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }`; rewrite the optional-arg chain as an explicit `if`.

**Pros:** One small PR; all under 15 lines total.
**Effort:** ~20 min.
**Risk:** Low

### Option 2: Interval fix only

**Approach:** Just the `^[1-9][0-9]*$` change.

**Pros:** Fixes the only runtime-harmful case.
**Cons:** Leaves the ugly errors and the readability nit.
**Effort:** 2 min.
**Risk:** Low

## Recommended Action

Option 1 implemented. In `bin/memtop`: interval regex tightened to `^[1-9][0-9]*$` with a dedicated error ("--watch interval must be a positive integer") for numeric-but-invalid values like 0; `-n` guarded with `[ $# -ge 2 ]` and a clear "missing value for -n" message; the `--watch` optional-arg `&&` chain rewritten as an explicit `if` block. The `bin/fkill` `--match` guard was handled separately by the fkill agent.

## Technical Details

**Affected files:**
- `bin/memtop:11-19`
- `bin/fkill:11-18`

## Acceptance Criteria

- [x] `memtop --watch 0` is rejected with a clear message ("--watch interval must be a positive integer", exit 1)
- [x] `memtop -n` (no value) prints "missing value" and exits 1 (`fkill --match` handled by the fkill agent)
- [x] `memtop --watch` (no interval) still defaults to 5s
- [x] Smoke test passes (`bash test/smoke.sh` → ALL OK)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — correctness-reviewer + code-simplicity-reviewer)

**Learnings:**
- The optional-arg && chain is *correct* but costs every future reader a set -e analysis; explicit `if` is free.

### 2026-07-08 - Resolution (memtop)

**By:** pr-comment-resolver

**Changes:**
- `bin/memtop`: `-n` guarded with `[ $# -ge 2 ]` → "memtop: missing value for -n" (exit 1); `--watch` chain rewritten as explicit `if`; interval regex now `^[1-9][0-9]*$`, with a dedicated `elif` rejecting numeric-but-invalid values (e.g. `--watch 0`) with "memtop: --watch interval must be a positive integer" (exit 1).

**Verification:** `bash -n bin/memtop` clean; `memtop -n 5` works; `memtop -n` and `memtop --watch 0` error clearly with exit 1; `--watch` (no arg) and `--watch 7` both run (killed after 1s); `test/smoke.sh` ALL OK.

**Note:** `bin/fkill` `--match` guard resolved by the fkill agent in a parallel task.

### 2026-07-08 - Resolution (fkill portion)

**By:** pr-comment-resolver

**Changes:**
- `bin/fkill`: `--match` now guarded with `[ $# -ge 2 ] || { echo "fkill: missing value for --match" >&2; exit 1; }` (landed as part of the fkill rework for todos 001/002/006).

**Verification:** `fkill --match` (no value) prints "fkill: missing value for --match" and exits 1.
