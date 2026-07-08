---
status: complete
priority: p3
issue_id: "005"
tags: [code-review, testing, shell]
dependencies: ["001"]
---

# smoke.sh: dummy-process match can kill unrelated real processes; fixed sleeps are racy

The fkill test tag has only 10 possible values and matches system-wide, so `bash test/smoke.sh` can SIGTERM a stranger's `sleep 600X`; fixed 0.3s sleeps make the test flaky under load.

## Problem Statement

`test/smoke.sh:25-28` — `TAG=$((RANDOM % 10))` yields `sleep 6000`..`sleep 6009`, all plausible real commands (10-minute sleeps in scripts, cron retry loops). `fkill --match "sleep 600$TAG$"` kills ALL matches, not just the dummy. Two concurrent smoke runs collide with probability 1/10. The 0.3s sleeps (lines 27/29) can false-FAIL: under load the ps snapshot may predate the dummy, or the TERM'd process may not be reaped yet (`kill -0` still succeeds).

## Findings

- Flagged independently by security-sentinel and correctness-reviewer.
- Fix should land after issue 001 (match semantics change what patterns work — with command-only matching, matching on the PID column stops being an option; a unique duration remains valid).

## Proposed Solutions

### Option 1: Unique tag + verify PID + poll (recommended)

**Approach:** `TAG=$$` → `sleep 600$$` (PID-unique duration). After the kill, assert the reported killed PID equals `$DUMMY`. Replace fixed sleeps with a bounded poll loop (e.g. up to 3s checking process appearance/disappearance).

**Pros:** Eliminates collateral kills, cross-run collisions, and load flakiness.
**Cons:** Slightly longer test.
**Effort:** ~20 min.
**Risk:** Low

### Option 2: Match by PID column

**Approach:** `fkill --match "^\s*[0-9.]+\s+$DUMMY\s"`.

**Pros:** Exact targeting.
**Cons:** Only works with whole-line matching — conflicts with the issue-001 fix; couples test to list formatting.
**Effort:** 10 min.
**Risk:** Medium (breaks when 001 lands)

## Recommended Action

Option 1 implemented, adapted to the post-001/002 fkill (command-column-only matching, `--list`, exit codes). `TAG=$$` makes the dummy `sleep 600$$` PID-unique (e.g. `sleep 60097123`), matched with the anchored command regex `sleep 600$$\$` — no stranger's process can match and concurrent runs cannot collide. After the kill, the test extracts the reported killed PID(s) from fkill's output and asserts they equal `$DUMMY` exactly. Fixed `sleep 0.3`s replaced by a `poll` helper (up to 3s, 0.1s steps) for both dummy appearance in `fkill --list --match ...` and disappearance after the kill. A cleanup trap reaps the dummy on exit, but only after re-verifying its command is still `sleep 600$TAG` (the test applies the same PID-reuse guard as fkill itself). Regression checks added for the new tool behavior: `--list` dry run (rows printed, dummy survives), `--match` no-match exit 1, PID-valued regex matches zero candidates, `memtop --watch 0` and `memtop -n` (missing value) rejected. Self- and herdr-exclusion checks rewritten for command-only matching using `--list` (the old herdr check used `--match herdr`, which under the new semantics would actually try to kill a running herdr).

## Technical Details

**Affected files:**
- `test/smoke.sh:22-43`

## Acceptance Criteria

- [x] Test cannot signal any process it did not spawn
- [x] Concurrent smoke runs do not interfere
- [x] No fixed sleeps; bounded polls instead
- [x] Killed-PID assertion checks the exact dummy PID

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — security-sentinel + correctness-reviewer)

**Actions:**
- Enumerated the 10-value tag space and cross-run collision odds; identified the two timing windows.

**Learnings:**
- Tests that exercise a kill-all tool need the same blast-radius thinking as the tool itself.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- Rewrote `test/smoke.sh` fkill section: PID-unique dummy (`sleep 600$$`), anchored command regex, exact killed-PID assertion, bounded `poll` helper replacing all fixed sleeps, identity-checked cleanup trap.
- Added regression checks for the issue-001/002/007 behavior: `--list` dry run, no-match exit 1, PID-column immunity, `memtop --watch 0` / `memtop -n` rejection.
- Rewrote self-/herdr-exclusion checks to use `--list` (safe under new `--match` kill semantics).

**Verification:**
- `bash test/smoke.sh` run twice back-to-back inside herdr: 18/18 checks ok both times, including the perfmon workspace idempotence check. No flakiness observed.
