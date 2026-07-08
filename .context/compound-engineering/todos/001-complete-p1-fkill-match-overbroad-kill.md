---
status: complete
priority: p1
issue_id: "001"
tags: [code-review, security, correctness, shell]
dependencies: []
---

# fkill --match matches the whole formatted line, not the command — over-broad, destructive

`fkill --match REGEX` is kill-on-sight and the regex is applied case-insensitively to the entire formatted candidate line (`MEM  PID  COMMAND args...`), not just the command. A slightly-wrong regex non-interactively SIGTERM/SIGKILLs far more than intended.

## Problem Statement

`bin/fkill:48-49` — `SELECTED=$(candidates | grep -Ei -- "$MATCH" || true)` runs against lines that include the memory and PID columns and the full argv:

- `fkill --match 1234` kills any process whose **PID or RSS value** contains `1234`, not just commands mentioning it.
- The match includes **arguments**: `fkill --match vite` kills an editor with `vite.config.ts` open on its command line, a `tail -f vite.log`, a Chrome renderer with "vite" in a URL arg.
- Degenerate regexes are catastrophic: `fkill --match .` or `--match ' '` selects every candidate and signals everything the user owns — effectively logs you out (exclusions only cover fkill's ancestry, its pgid, and herdr).
- Additionally, awk's field-reassignment (`bin/fkill:42`) rebuilds `$0` with single-space OFS, so runs of whitespace inside the original command are collapsed — a regex written against real command spacing silently matches nothing.

## Findings

- security-sentinel (P2): whole-line, case-insensitive, argument-inclusive matching; kill-all on degenerate regex. Concrete: `fkill -9 --match node` kills VS Code, Cursor, and any script with "node" in argv.
- correctness-reviewer (P3, verified): grep sees MEM/PID columns → numeric regexes kill by memory size or PID; whitespace collapse verified empirically.
- The exclusion machinery itself (ancestry walk + pgid, `bin/fkill:21-32`) is sound and smoke-tested — the gap is only match scope.

## Proposed Solutions

### Option 1: Match against the command column only (recommended core fix)

**Approach:** Apply the regex to the command field inside awk (pass regex via `-v` and test `cmd ~ re`), or grep on `substr($0, 18)`. Preserve original command spacing via substr on the raw ps line instead of field reassignment.

**Pros:** Fixes PID/MEM false matches and the whitespace-collapse bug in one place; small diff.
**Cons:** awk `-v` regex escaping needs care (backslashes).
**Effort:** ~30 min including smoke-test updates.
**Risk:** Low

### Option 2: Option 1 + blast-radius guard

**Approach:** In `--match` mode, if matches exceed N (e.g. 5) require `--force`; always print the victim list and count before signalling.

**Pros:** Makes degenerate regexes non-catastrophic; pairs naturally with the `--list` mode in issue 002.
**Cons:** Slightly more ceremony for a personal tool.
**Effort:** +20 min on top of Option 1.
**Risk:** Low

### Option 3: Require full-token match on process name only

**Approach:** Match against `comm` (executable name) rather than full argv.

**Pros:** Safest semantics.
**Cons:** Loses legitimate use of matching args (e.g. `--match 'npm run dev'`); changes documented behavior.
**Effort:** ~20 min.
**Risk:** Medium (behavior change)

## Recommended Action

Option 2 implemented (command-column-only matching + blast-radius guard). `candidates()` now takes an optional regex and applies it inside awk to the COMMAND field only, extracted from the ORIGINAL ps line via `sub()` on the three leading numeric columns — spacing preserved (verified: a regex with a double space matches a command containing one). The regex is passed via environment (`MATCH_RE="$re" awk ... ENVIRON["MATCH_RE"]`) instead of `awk -v` to avoid BSD awk backslash mangling (verified: `--match 'time\.sleep\(9999\)'` works). Matching stays case-insensitive (`tolower(line) ~ tolower(re)`). In `--match` mode, if more than 5 processes match, fkill prints the count and full victim list to stderr and exits 1 unless `--force` is given. Degenerate regexes (`.`) therefore refuse without `--force`. README `--match` row updated.

## Technical Details

**Affected files:**
- `bin/fkill:37-49` — candidates() and the --match grep
- `test/smoke.sh:25-43` — match patterns assume whole-line semantics (see issue 005)
- `README.md:19` — document command-only matching

## Acceptance Criteria

- [x] `fkill --match <regex>` matches only the COMMAND column
- [x] Numeric regexes cannot select by PID or MEM value (verified: `--list --match '^<live PID>$'` → 0 matches)
- [x] Original command whitespace is preserved in matching (verified with a double-space command)
- [x] Degenerate regex (`.`) refuses without `--force` via the >5-matches blast-radius guard (exit 1, victim list printed)
- [x] Smoke test updated and passing (done in issue 005 resolution — 2026-07-08, pr-comment-resolver)

## Work Log

### 2026-07-08 - Initial Discovery

**By:** Claude Code (/ce:review — security-sentinel + correctness-reviewer)

**Actions:**
- Whole-repo review; both agents independently flagged match-scope; correctness agent verified whitespace collapse and PID-column matching empirically.

**Learnings:**
- The dangerous part of fkill is not the interactive path (fzf shows you the list) but the non-interactive `--match`, which inherits list formatting as its match surface.

### 2026-07-08 - Resolution

**By:** pr-comment-resolver

**Actions:**
- Rewrote `candidates()` per docs/solutions/security-issues/destructive-shell-cli-safety-patterns.md (Problem 1): regex applied inside awk to the COMMAND column only, extracted with original spacing intact; regex passed via ENVIRON (not `-v`) so backslashes survive BSD awk.
- Added blast-radius guard: >5 matches in `--match` mode prints count + victim list and exits 1 unless `--force`.
- Updated README `fkill --match` row; header usage comment updated (help sed range widened to 2,7p).

**Verification:**
- `--list --match '^<live PID>$'` → 0 matches (PID column unmatchable).
- `--match 'Brave Browser'` (57 matches) refused, exit 1, nothing signalled.
- Detached dummy `sleep 12345` killed by `--match 'sleep 12345$'`; a second dummy `sleep 54321` survived.
- Double-space regex matched a command containing a double space; killed only that dummy.
