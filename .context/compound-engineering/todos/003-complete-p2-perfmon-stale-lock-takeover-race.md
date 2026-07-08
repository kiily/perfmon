---
status: complete
priority: p2
issue_id: "003"
tags: [code-review, correctness, concurrency, shell]
dependencies: []
---

# perfmon: stale-lock takeover is not atomic — duplicate workspaces possible

The stale-lock recovery path in `bin/perfmon:77-93` is a TOCTOU race: two instances can both "take over" a stale lock, both become builders, and create duplicate PERF MONITORING workspaces — the exact thing the lock exists to prevent.

## Problem Statement

`rmdir "$LOCK" || true; mkdir "$LOCK" || exit 0` (bin/perfmon:80-81) is three non-atomic steps after the staleness check (line 79). Interleaving for instances A and B that both observe a stale lock: A rmdir+mkdir succeeds (A owns a FRESH lock) → B's rmdir then removes A's brand-new lock (B decided staleness before A recreated it) → B mkdir succeeds. Both build. Whichever finishes first also runs `trap 'rmdir "$LOCK"' EXIT` (line 93) and deletes the other still-running instance's lock, opening the door to a third builder.

Stale locks are not exotic: `perfmon --ensure` is auto-launched from every pane shell at herdr attach (`perfmon.zsh:11`), and a lock goes stale whenever an instance dies without cleanup (SIGKILL, or crash between mkdir at line 77 and trap installation at line 93). A legitimately slow builder (>120s) also gets its lock stolen — same outcome.

Secondary: `LOCK="${TMPDIR:-/tmp}/perfmon.lock.d"` (line 76) falls back to world-writable `/tmp` when TMPDIR is unset (launchd, `env -i`, ssh); another user can pre-create the dir (sticky bit prevents rmdir) and silently DoS `--ensure` forever.

## Findings

- correctness-reviewer (P2, confidence 0.85): full interleaving verified against code; noted the early exits at lines 81/83/90 do NOT trigger the trap (installed later) — cross-removal only happens via the steal race.
- security-sentinel (P3): /tmp fallback multi-user DoS; mkdir-on-symlink fails so symlink attacks don't apply.
- The lock itself is justified (concurrent pane shells at attach are real, smoke-tested at `test/smoke.sh:47-51`) — only the takeover protocol is broken. Note smoke's sequential idempotency check cannot exercise this race.

## Proposed Solutions

### Option 1: Atomic takeover via rename (recommended)

**Approach:** Replace rmdir+mkdir with `mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rmdir "$LOCK.stale.$$"`, then attempt the normal `mkdir "$LOCK" || exit 0`. Only the instance whose `mv` succeeded retries; mkdir stays the single arbiter. Also scope the path per-user: `${TMPDIR:-/tmp}/perfmon.$UID.lock.d`.

**Pros:** Minimal diff; rename is atomic; fixes DoS fallback with one path change.
**Cons:** Leaves a rare orphan `*.stale.*` dir if the winner dies mid-cleanup (harmless).
**Effort:** ~30 min.
**Risk:** Low

### Option 2: PID-owned lock with liveness check

**Approach:** Store `$$` in `$LOCK/pid`; staleness = owner not alive (`kill -0`) instead of mtime; EXIT trap removes the lock only if `$LOCK/pid` still equals `$$`.

**Pros:** Eliminates both the steal race and the trap-removes-other's-lock hazard; no arbitrary 120s heuristic.
**Cons:** More lines; PID reuse can rarely mistake a lock as live (self-heals next run via mtime fallback if kept).
**Effort:** ~1 h.
**Risk:** Low

### Option 3: Give up the lock; make creation idempotent at the herdr layer

**Approach:** After create, re-list workspaces; if >1 with the label, delete the newer one.

**Pros:** No lock protocol at all.
**Cons:** Visible flicker; relies on herdr delete semantics; racier than it sounds.
**Effort:** ~1 h.
**Risk:** Medium

## Recommended Action

Implement Option 1: atomic stale-lock takeover via `mv "$LOCK" "$LOCK.stale.$$" && rmdir`, with `mkdir` remaining the sole acquisition arbiter, an owner-guarded EXIT trap (`LOCK_OWNED` flag installed before acquisition), and a per-user lock path `${TMPDIR:-/tmp}/perfmon.$UID.lock.d`. Implemented 2026-07-08 in `bin/perfmon` (new `acquire_lock()` function).

## Technical Details

**Affected files:**
- `bin/perfmon:76-93` — lock acquisition, stale takeover, trap
- At minimum, make the EXIT trap owner-guarded regardless of chosen option.

## Acceptance Criteria

- [x] Two concurrent instances observing a stale lock cannot both become builders (6-contender concurrent test: exactly 1 winner)
- [x] The EXIT trap can never remove a lock the exiting process does not own (owner-guarded via LOCK_OWNED; tested)
- [x] Lock path is per-user even when TMPDIR is unset (`perfmon.$UID.lock.d`)
- [x] Sequential `--ensure` idempotency smoke check still passes (verified by logic review — acquire/find/exit-0 flow unchanged for the sequential case; smoke.sh not executed because it creates real herdr workspaces, prohibited for this run)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — correctness-reviewer + security-sentinel)

**Actions:**
- Traced the full interleaving; confirmed trap installation ordering; identified /tmp fallback exposure.

**Learnings:**
- mkdir-as-lock is fine; it's stale-lock *recovery* that needs atomicity (rename), and traps must be owner-guarded.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- Rewrote lock acquisition in `bin/perfmon` as `acquire_lock()`: `mkdir` first, then on a stale (>120s) lock an atomic `mv "$LOCK" "$LOCK.stale.$$"` (exactly one winner) followed by `rmdir` of the renamed dir and a fresh `mkdir` — mkdir stays the sole arbiter; losers fall through to the existing ensure-exit / focus-wait paths.
- Installed the EXIT trap *before* acquisition, guarded by `LOCK_OWNED=1` set only on successful mkdir, so a non-owner exit can never remove another instance's lock (also closes the crash-between-mkdir-and-trap window).
- Lock path now `${TMPDIR:-/tmp}/perfmon.$UID.lock.d` — per-user even under launchd/`env -i` /tmp fallback.
- Verified with an isolated scratch harness (fresh acquire, fresh-foreign-lock refusal, stale takeover, 6 concurrent contenders → exactly 1 winner, non-owner trap leaves foreign lock intact, owner trap cleans up with exit status preserved): all passed. `bash -n` clean; `--doctor` ok.

**Learnings:**
- Install owner-guarded traps before acquisition, not after — it removes an entire crash-window class for free.
