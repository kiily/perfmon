#!/bin/bash
# smoke.sh — sanity checks for perfmon tooling. Run: bash test/smoke.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$DIR/bin:$PATH"
FAIL=0

check() { # check <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; FAIL=1; fi
}

# --- memtop ---------------------------------------------------------------
OUT=$(memtop -n 5)
check "memtop runs"            test -n "$OUT"
check "memtop header"          grep -q "MEM(GB)" <<<"$OUT"
check "memtop swap line"       grep -q "swap:" <<<"$OUT"
check "memtop has rows"        test "$(grep -cE '^\s+[0-9]+\.[0-9]+' <<<"$OUT")" -ge 3
OUT_RAW=$(memtop --raw -n 5)
check "memtop --raw has PIDs"  grep -qE '^\s+[0-9.]+\s+[0-9.]+%\s+[0-9]+' <<<"$OUT_RAW"

# --- fkill ----------------------------------------------------------------
# Dummy target must live in its own process group (fkill rightly refuses to
# target its own group, which a same-shell background job would share).
TAG=$((RANDOM % 10))
DUMMY=$(python3 -c "import subprocess as s; print(s.Popen(['sleep','600$TAG'], start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
sleep 0.3
KILL_OUT=$(fkill --match "sleep 600$TAG$" 2>&1)
sleep 0.3
if kill -0 "$DUMMY" 2>/dev/null; then
  echo "FAIL fkill kills matched process"; kill "$DUMMY" 2>/dev/null; FAIL=1
else
  echo "ok   fkill kills matched process"
fi
check "fkill reports the kill"  grep -q "killed (SIGTERM) $DUMMY" <<<"$KILL_OUT"

# self-exclusion: fkill's candidate list must not contain this shell's PID
LISTED=$(fkill --match "^\s*[0-9]+\s+$$\s" 2>&1)
check "fkill excludes own shell" grep -q "nothing selected" <<<"$LISTED"

# herdr exclusion: never offers the herdr server
HERDR_LISTED=$(fkill --match "herdr" 2>&1)
check "fkill excludes herdr"     grep -q "nothing selected" <<<"$HERDR_LISTED"

# --- perfmon --------------------------------------------------------------
check "perfmon --doctor"       perfmon --doctor
if [ "${HERDR_ENV:-}" = "1" ]; then
  perfmon --ensure >/dev/null 2>&1
  perfmon --ensure >/dev/null 2>&1
  N=$(herdr workspace list | python3 -c 'import sys,json; ws=json.load(sys.stdin)["result"]["workspaces"]; print(sum(1 for w in ws if w.get("label")=="PERF MONITORING"))' 2>/dev/null || echo "?")
  if [ "$N" = "1" ]; then echo "ok   perfmon idempotent (1 workspace)"; else echo "FAIL perfmon idempotent (count=$N)"; FAIL=1; fi
else
  echo "skip perfmon workspace checks (not inside herdr)"
fi

echo ""
[ "$FAIL" = 0 ] && echo "smoke: ALL OK" || echo "smoke: FAILURES"
exit "$FAIL"
