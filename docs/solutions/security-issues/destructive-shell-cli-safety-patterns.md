---
title: Destructive shell CLI safety — match scope, lock takeover atomicity, and error-swallowing helpers
category: security-issues
date: 2026-07-08
tags: [bash, shell, fkill, process-kill, mkdir-lock, toctou, set-e, error-handling, code-review]
components: [bin/fkill, bin/perfmon, test/smoke.sh]
problem_type: security_issue
severity: p1-p2
status: documented
source: /ce:review multi-agent code review (security-sentinel, correctness-reviewer, code-simplicity-reviewer, agent-native-reviewer)
related_todos:
  - .context/compound-engineering/todos/001-pending-p1-fkill-match-overbroad-kill.md
  - .context/compound-engineering/todos/003-pending-p2-perfmon-stale-lock-takeover-race.md
  - .context/compound-engineering/todos/004-pending-p2-perfmon-json-error-swallowing.md
---

# Destructive shell CLI safety patterns (perfmon review learnings)

Three defect classes surfaced by an exhaustive multi-agent review of this repo's bash CLIs. None had caused a visible incident yet — all three are latent, which is exactly when they're cheapest to fix. Fixes are tracked as todos 001, 003, and 004; this doc captures the root causes and the generalizable patterns.

## Problem 1: Kill regex matched formatted output, not the command

**Symptom (latent):** `fkill --match 1234` can kill by PID or memory value; `fkill --match .` kills every user-owned process; regexes with multiple spaces silently never match.

**Root cause:** `candidates()` (`bin/fkill:37-46`) emits formatted `"MEM(MB)  PID  COMMAND"` lines and `grep -Ei -- "$MATCH"` (`bin/fkill:49`) runs against the *whole line*. Additionally, awk's field-reassignment trick (`$1=""; $2=""; $3=""`) forces `$0` to be rebuilt with single-space OFS, collapsing whitespace inside commands — so the displayed/matched command differs from the real one.

**Fix pattern:** apply the user regex to the command field only, extracted from the original line so spacing is preserved:

```bash
candidates() {
  local re="${1:-}"
  ps -axo rss=,pgid=,pid=,command= | sort -rn | \
    awk -v excl="$(echo "$EXCLUDE" | tr '\n' ' ')" -v mypgid="$MY_PGID" -v re="$re" '
    BEGIN { n=split(excl, arr, " "); for (i=1;i<=n;i++) skip[arr[i]]=1 }
    {
      rss=$1; pgid=$2; pid=$3
      line=$0   # strip first three fields from the ORIGINAL text — spacing intact
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      if (pid in skip || pgid == mypgid) next
      if (re != "" && tolower(line) !~ tolower(re)) next   # match COMMAND only
      printf "%8.0f  %-6s %s\n", rss/1024, pid, line
    }'
}
```

Pair with: a `--list`/`--dry-run` mode, a blast-radius cap (refuse >N matches without `--force`), and nonzero exit when a destructive selector matches nothing (todo 002).

## Problem 2: mkdir-lock stale takeover is a TOCTOU

**Symptom (latent):** two concurrent `perfmon --ensure` runs that both see a stale lock can both become builders → duplicate "PERF MONITORING" workspaces; the unguarded `trap 'rmdir "$LOCK"' EXIT` then deletes the *other* instance's live lock.

**Root cause:** staleness check (`find -mmin +2`) + `rmdir` + `mkdir` (`bin/perfmon:79-81`) is three non-atomic steps; instance B's rmdir can remove instance A's freshly re-acquired lock because B decided staleness before A recreated it. The EXIT trap (`bin/perfmon:93`) is not owner-guarded.

**Fix pattern:** atomic rename for takeover (exactly one contender wins the `mv`; `mkdir` stays the sole acquisition arbiter) plus an ownership flag for the trap:

```bash
LOCK_OWNED=0
trap '[ "$LOCK_OWNED" = 1 ] && rmdir "$LOCK" 2>/dev/null' EXIT

acquire_lock() {
  mkdir "$LOCK" 2>/dev/null && { LOCK_OWNED=1; return 0; }
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then   # atomic: one winner
      rmdir "$LOCK.stale.$$" 2>/dev/null || true
    fi
    mkdir "$LOCK" 2>/dev/null && { LOCK_OWNED=1; return 0; }
  fi
  return 1
}
```

Also scope the lock path per-user (`${TMPDIR:-/tmp}` falls back to world-writable `/tmp` under launchd/`env -i`; another user can pre-create the dir and silently DoS `--ensure`).

## Problem 3: Error-swallowing helper defeats retry logic under `set -eu`

**Symptom (latent):** one transient `herdr workspace list` hiccup aborts `perfmon` silently on retry-iteration 1 (the 10-iteration wait loop is dead code for its main failure mode); a JSON shape change mid-build leaves a half-built workspace with zero diagnostics.

**Root cause:** `json() { python3 -c "..." 2>/dev/null; }` (`bin/perfmon:66`) discards all stderr but still exits nonzero; under `set -eu` a plain `WS_ID=$(find_workspace)` assignment then kills the script with no message. Compounding: the create response is parsed by three separate python invocations, tripling the silent failure points.

**Fix pattern:** never combine a fallible helper with blanket `2>/dev/null` under errexit. Let errors reach stderr, tolerate failure *explicitly* where retry is intended, and parse once:

```bash
json() { python3 -c "import sys,json;$1"; }        # errors now visible

WS_ID=$(find_workspace) || WS_ID=""                # retry loop actually retries

{ read -r WS_ID; read -r TAB1; read -r PANE1; } < <(printf '%s' "$CREATE" | python3 -c '
import sys, json
r = json.load(sys.stdin)["result"]
i = lambda v, k: v[k] if isinstance(v, dict) else v
print(i(r["workspace"], "workspace_id")); print(i(r["tab"], "tab_id")); print(i(r["root_pane"], "pane_id"))
')
[ -n "$WS_ID" ] && [ -n "$PANE1" ] || { echo "perfmon: bad create response: $CREATE" >&2; exit 1; }
```

Related latent traps in the same family: shell variables interpolated into python *source text* (`w.get('label')=='$LABEL'` — pass data via env/argv instead), and fully-silenced backgrounded startup hooks (`>/dev/null 2>&1 &` in `perfmon.zsh` hides "command not found" forever).

## Prevention checklist

1. Match against source data, not formatted output — apply user patterns to one semantic field, never to a display line containing PIDs/memory/padding.
2. Every destructive non-interactive mode gets a dry-run (`--list`/`--dry-run`), and the act path prints what the dry-run would have shown.
3. Bound blast radius structurally: cap targets without `--force`, exclude own PID/pgid/ancestors, refuse catch-all patterns.
4. Zero matches on a destructive selector is an error (exit nonzero), not success.
5. Never recover a stale mkdir lock with rmdir+mkdir — use an atomic takeover (`mv` aside) and keep `mkdir` the sole arbiter.
6. Guard trap cleanup by ownership: verify `$$` still owns the resource before removing it.
7. Under `set -e`, never combine a helper with blanket `2>/dev/null` — return a checked status or log stderr somewhere.
8. Pass data to embedded interpreters via argv/env, never by splicing shell variables into program text.
9. Backgrounded startup hooks must leave a trace (log file, or `command -v` check before backgrounding).
10. Retry loops must be able to observe failure — assert a forced failure produces N attempts plus a diagnostic.

## Test strategies

- **PID-unique dummy targets:** spawn the kill target with a unique marker (`sleep 600$$`-style), detached stdio, own process group — so exclusion logic is exercised, not bypassed, and the match can only hit your own process. (The 10-value `RANDOM % 10` tag in `test/smoke.sh:25` can match strangers' sleeps — todo 005.)
- **Blast-radius assertions:** after the kill, assert the dummy died AND a pre-run snapshot of other PIDs is still alive. "Target died" passes even when everything died.
- **Adversarial-selector tests:** dry-run `--match <PID>` and `--match <memory value>` and assert zero matches — direct regression tests for the match-scope class.
- **Concurrent lock tests, not sequential:** sequential idempotency checks (like `smoke.sh:47-51`) cannot exercise takeover races. Create a stale lock, launch two contenders with `&` + `wait`, assert exactly one wins; verify a loser's EXIT trap leaves the winner's lock intact.
- **Failure injection for helpers:** shadow the interpreter with a PATH wrapper that fails the first N calls; assert the script retried N times with a diagnostic.
- **Bounded polls, not fixed sleeps:** poll the condition every ~100ms to a deadline; dump state (ps, lock contents) on timeout.

## Review heuristics (smells that predict these bugs)

1. `2>/dev/null` inside a function body in a `set -eu` script, especially called from a retry loop or command substitution.
2. A user regex applied to formatted/columnar output rather than one extracted field.
3. A destructive verb with no dry-run flag, or "0 matches" sharing an exit code with success.
4. `rmdir`/`rm` of a lock followed by re-acquisition, or any `trap '... rm ...' EXIT` whose path isn't provably owned by `$$`.
5. Shell variables spliced into `-c` program text for another interpreter; `>/dev/null 2>&1 &` on anything run at startup.

## Historical context

Commit `c1926c4` (2026-07-08) previously fixed a related, *solved* problem in `test/smoke.sh:26`: the dummy kill target was spawned with `start_new_session=True` (fkill deliberately refuses its own process group, so a same-shell background job would be invisible to it) but inherited the test's stdout/stderr, keeping the `$(...)` PID-capture pipe open until the sleeper died. Adding `stdout=DEVNULL, stderr=DEVNULL` fully detached it. The pgid-exclusion logic itself is sound and unrelated to the match-scope defect above.
