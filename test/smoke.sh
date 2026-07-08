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
fails() { ! "$@"; }        # succeeds when the command exits nonzero
poll()  { # poll <cmd...> — retry up to ~3s (0.1s steps) until cmd succeeds
  local i; for ((i = 0; i < 30; i++)); do "$@" && return 0; sleep 0.1; done; return 1
}

# --- memtop ---------------------------------------------------------------
OUT=$(memtop -n 5)
check "memtop runs"            test -n "$OUT"
check "memtop header"          grep -q "MEM(GB)" <<<"$OUT"
check "memtop swap line"       grep -q "swap:" <<<"$OUT"
check "memtop has rows"        test "$(grep -cE '^\s+[0-9]+\.[0-9]+' <<<"$OUT")" -ge 3
OUT_RAW=$(memtop --raw -n 5)
check "memtop --raw has PIDs"  grep -qE '^\s+[0-9.]+\s+[0-9.]+%\s+[0-9]+' <<<"$OUT_RAW"
check "memtop --watch 0 rejected"    fails memtop --watch 0
check "memtop -n missing value"      fails memtop -n

# --- fkill ----------------------------------------------------------------
# Dummy target must live in its own process group (fkill rightly refuses to
# target its own group, which a same-shell background job would share).
# TAG=$$ makes the sleep duration PID-unique: no collateral kills of a
# stranger's "sleep 600X" and no cross-run collisions.
TAG=$$
DUMMY=$(python3 -c "import subprocess as s; print(s.Popen(['sleep','600$TAG'], start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
# Safety net: never leave the dummy behind, but only signal it if it is
# still *our* dummy (PID-reuse guard for the test itself).
cleanup() {
  [ -n "${DUMMY:-}" ] || return 0
  ps -p "$DUMMY" -o command= 2>/dev/null | grep -q "sleep 600$TAG" && kill "$DUMMY" 2>/dev/null
  return 0
}
trap cleanup EXIT

dummy_listed() { fkill --list --match "sleep 600$TAG\$" | grep -qE "^\s*[0-9]+\s+$DUMMY\s"; }
dummy_gone()   { ! kill -0 "$DUMMY" 2>/dev/null; }

check "fkill --list shows dummy"     poll dummy_listed

# --list is a dry run: prints rows, never kills
LIST_ALL=$(fkill --list 2>&1)
check "fkill --list has rows"        test "$(grep -cE '^\s*[0-9]+\s+[0-9]+\s' <<<"$LIST_ALL")" -ge 3
check "fkill --list kills nothing"   kill -0 "$DUMMY"

# command-column-only matching: a PID-valued regex must match zero candidates
PID_MATCH=$(fkill --list --match "^$DUMMY\$" 2>&1)
check "fkill ignores PID column"     test -z "$PID_MATCH"

# --match with zero matches exits 1
check "fkill no-match exits 1"       fails fkill --match "no-such-command-$$-xyzzy"

# the kill itself: exact-PID victim, bounded poll for disappearance
KILL_OUT=$(fkill --match "sleep 600$TAG\$" 2>&1)
KILLED_PIDS=$(grep -oE 'killed \(SIGTERM\) [0-9]+' <<<"$KILL_OUT" | awk '{print $3}')
check "fkill kills matched process"  poll dummy_gone
check "fkill killed exactly dummy"   test "$KILLED_PIDS" = "$DUMMY"

# self-exclusion: fkill's candidate list must not contain this shell's PID
check "fkill excludes own shell"     fails grep -qE "^\s*[0-9]+\s+$$\s" <<<"$LIST_ALL"

# herdr exclusion: never offers the herdr server
HERDR_LISTED=$(fkill --list --match "herdr" 2>&1)
check "fkill excludes herdr"         test -z "$HERDR_LISTED"

# --- fkill: death verification + --escalate --------------------------------
# A TERM-ignoring target must produce "still running" + exit 2, then die
# under --escalate. Marker makes it uniquely matchable and PID-unique.
IGN="perfmon-ignoreterm-$$"
IGNPID=$(python3 -c "import subprocess as s; print(s.Popen(['bash','-c','trap \"\" TERM; while :; do sleep 5; done','$IGN'], start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
cleanup_ign() { kill -9 "$IGNPID" 2>/dev/null; return 0; }
ign_listed() { fkill --list --match "$IGN" | grep -q "$IGN"; }
poll ign_listed >/dev/null
check "fkill survivor exits 2"       bash -c "fkill --wait 1 --match '$IGN'; [ \$? -eq 2 ]"
check "fkill survivor still alive"   kill -0 "$IGNPID"
check "fkill --escalate kills it"    fkill --wait 1 --escalate --match "$IGN"
check "fkill escalated target dead"  poll bash -c "! kill -0 $IGNPID 2>/dev/null"
cleanup_ign
check "fkill --wait 0 rejected"      fails fkill --wait 0 --list
check "fkill --wait missing value"   fails fkill --wait

# --- fkill: --port ----------------------------------------------------------
TPORT=$((20000 + $$ % 20000))
check "fkill --port free exits 1"    fails fkill --port "$TPORT"
LPID=$(python3 -c "import subprocess as s; print(s.Popen(['python3','-m','http.server','$TPORT','--bind','127.0.0.1'], start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
cleanup_l() { kill -9 "$LPID" 2>/dev/null; return 0; }
port_listed() { fkill --list --port "$TPORT" | grep -qE "^\s*[0-9]+\s+$LPID\s"; }
check "fkill --port list shows it"   poll port_listed
check "fkill --port list kills nothing" kill -0 "$LPID"
check "fkill --port kills listener"  fkill --port "$TPORT"
check "fkill --port target dead"     poll bash -c "! kill -0 $LPID 2>/dev/null"
cleanup_l
check "fkill --port range check"     fails fkill --port 99999
check "fkill selector exclusivity"   fails fkill --port "$TPORT" --match x

# --- fkill: --app -----------------------------------------------------------
# Fake bundle: argv[0] carries the bundle path (executable= override), so the
# resolver sees a root (Contents/MacOS), a helper (Resources), and a pathless
# child that only the transitive-PPID sweep can find.
BAPP="Smoke $$ App"    # spaces on purpose — bundle names have them
BDIR="${TMPDIR:-/tmp}/perfmon-smoke-$$/$BAPP.app/Contents"
mkdir -p "$BDIR/MacOS" "$BDIR/Resources"
BROOT=$(python3 -c "import subprocess as s; print(s.Popen(['$BDIR/MacOS/SmokeRoot','-c','sleep 600 & wait'], executable='/bin/bash', start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
BHELP=$(python3 -c "import subprocess as s; print(s.Popen(['$BDIR/Resources/smokehelper','600'], executable='/bin/sleep', start_new_session=True, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)")
cleanup_b() { kill -9 "$BROOT" "$BHELP" 2>/dev/null; rm -rf "${TMPDIR:-/tmp}/perfmon-smoke-$$"; return 0; }
app_resolved() { [ "$(fkill --list --app "$BAPP" | wc -l | tr -d ' ')" -ge 3 ]; }
check "fkill --app resolves 3 procs"  poll app_resolved   # root + helper + pathless child
check "fkill --app root listed first" bash -c "fkill --list --app '$BAPP' | head -1 | grep -qE '^\s*[0-9]+\s+$BROOT\s'"
check "fkill --app partial no match"  fails bash -c "fkill --list --app 'Smoke $$' | grep -q ."
check "fkill --app non-tty refuses"   fails bash -c "fkill --app '$BAPP' </dev/null"
check "fkill --app refusal kills nothing" kill -0 "$BROOT"
BCHILD=$(pgrep -P "$BROOT" || true)
check "fkill --app --force kills all" fkill --app "$BAPP" --force
check "fkill --app root dead"         poll bash -c "! kill -0 $BROOT 2>/dev/null"
check "fkill --app helper dead"       poll bash -c "! kill -0 $BHELP 2>/dev/null"
[ -n "$BCHILD" ] && check "fkill --app child swept" poll bash -c "! kill -0 $BCHILD 2>/dev/null"
check "fkill --app unknown exits 1"   fails fkill --app "no-such-app-$$" --force
cleanup_b

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
