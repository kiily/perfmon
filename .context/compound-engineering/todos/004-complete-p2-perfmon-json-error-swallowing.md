---
status: complete
priority: p2
issue_id: "004"
tags: [code-review, correctness, simplification, shell]
dependencies: []
---

# perfmon: json() swallows all errors and JSON extraction is triplicated

`json() { python3 -c "import sys,json;$1" 2>/dev/null; }` (`bin/perfmon:66`) hides every parse/API failure, which under `set -eu` turns herdr hiccups into silent aborts — including killing the focus-wait retry loop on its first iteration. Separately, the create-response is parsed by three near-identical python invocations.

## Problem Statement

- **Retry loop is dead code for its main failure mode:** at `bin/perfmon:85-89`, one transient `herdr workspace list` failure makes `json` exit nonzero, and `set -e` kills the waiter on iteration 1 instead of retrying for 10 seconds as designed.
- **Half-built workspaces with zero diagnostics:** at `bin/perfmon:113-115`, if herdr's create output shape changes, the workspace is created but WS_ID/TAB1/PANE1 extraction dies silently — created workspace, no tabs/panes, nothing on stderr.
- **Triplication + YAGNI:** lines 113-115 spawn three interpreters over the same `$CREATE` JSON, each repeating a defensive `isinstance(x,dict)` dance for a dict-or-string shape herdr presumably only returns one of.

## Findings

- correctness-reviewer (P3, confidence 0.8) and code-simplicity-reviewer (P2 ×2) converged on the same lines independently.
- Suggested single extraction: one python call printing all three IDs, read via `{ read WS_ID; read TAB1; read PANE1; } <<<"$(...)"`.

## Proposed Solutions

### Option 1: Unify extraction + stop swallowing errors (recommended)

**Approach:** One python call extracts all three IDs from `$CREATE`. Drop `2>/dev/null` from `json()` (keep it only inside `find_workspace`, where empty-on-error is intentional, and make the wait loop tolerate failure with `WS_ID=$(find_workspace || true)`). Verify herdr's actual response shape and delete the isinstance fallback.

**Pros:** Fixes the dead retry loop, makes build failures diagnosable, removes two interpreter spawns and the dual-shape YAGNI in one pass.
**Cons:** Requires checking herdr's real output shape once.
**Effort:** ~30-45 min.
**Risk:** Low

### Option 2: Minimal correctness-only fix

**Approach:** Keep three calls; just add `|| true` in the wait loop and remove `2>/dev/null` at the build-phase call sites.

**Pros:** Tiny diff.
**Cons:** Leaves the triplication and dual-shape handling.
**Effort:** 10 min.
**Risk:** Low

## Recommended Action

Implement Option 1: drop the blanket `2>/dev/null` from `json()`; keep suppression only inside `find_workspace` (empty-on-error is intentional there) and make both `find_workspace` call sites tolerate failure with `|| WS_ID=""` so the focus-wait loop actually retries; replace the three create-response python calls with a single invocation consumed by three `read`s; add an explicit `[ -n "$WS_ID" ] && [ -n "$PANE1" ]` guard with a loud error. Herdr's real response shape was not verified (no mutating commands allowed), so the dict-or-string fallback is kept — folded into one lambda inside the single python call. Implemented 2026-07-08 in `bin/perfmon`.

## Technical Details

**Affected files:**
- `bin/perfmon:66` — json() helper
- `bin/perfmon:85-89` — focus-mode wait loop
- `bin/perfmon:113-117, 127` — create/tab extraction call sites

## Acceptance Criteria

- [x] A transient `herdr workspace list` failure does not abort the wait loop (`WS_ID=$(find_workspace) || WS_ID=""` at both call sites)
- [x] A JSON shape mismatch during build produces a visible error message (json() no longer suppresses stderr; explicit `[ -n "$WS_ID" ] && [ -n "$PANE1" ]` guard prints the raw response and exits 1)
- [x] `$CREATE` is parsed by a single python invocation (three `read`s from one process substitution)
- [x] The isinstance dict-or-string fallback is either justified (herdr really returns both) or deleted — kept as a single lambda: herdr's actual shape could not be verified without running a mutating `workspace create`, which was out of scope for this run; both shapes tested against the extractor

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — correctness-reviewer + code-simplicity-reviewer)

**Actions:**
- Both agents independently flagged json()'s stderr suppression; correctness agent traced the set -e interaction that defeats the retry loop.

**Learnings:**
- `helper 2>/dev/null` + `set -eu` is a compounding pattern: the helper converts diagnosable failures into silent script death.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- `json()` is now loud: `python3 -c "import sys,json,os;$1"` with no stderr suppression; suppression survives only inside `find_workspace` (both on the herdr call and the parse), where empty-on-error is the contract.
- Wait loop and the pre-build lookup both use `WS_ID=$(find_workspace) || WS_ID=""` — a transient list failure now retries instead of killing the script under `set -e`.
- Unified lines 113-115 into one python call (`{ read -r WS_ID; read -r TAB1; read -r PANE1; } < <(...)`) with the dict-or-string handling reduced to one lambda; added `[ -n "$WS_ID" ] && [ -n "$PANE1" ]` guard that echoes the raw `$CREATE` to stderr and exits 1.
- Verified: `bash -n` clean; extractor tested against both dict-shaped and string-shaped fake responses in a scratch harness; `--doctor`/`--cheats`/`-h` all pass.

**Learnings:**
- When you can't verify an external API's response shape, keep the defensive branch but collapse it to its cheapest form (one lambda) rather than triplicating it.
