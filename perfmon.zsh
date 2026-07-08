# perfmon shell integration — sourced from ~/.zshrc
# Adds memtop/fkill/perfmon to PATH and auto-launches the PERF MONITORING
# herdr workspace when a shell starts inside herdr.

# Derive the install dir from this file's location so the repo is relocatable.
# ${(%):-%N} is the currently-sourced file (robust under source, unlike $0,
# whose value depends on FUNCTION_ARGZERO/POSIX_ARGZERO); :A resolves symlinks,
# :h takes the directory.
PERFMON_DIR="${${(%):-%N}:A:h}"

# One-time, non-fatal warning if the bin dir is missing (e.g. broken clone).
[[ -d "$PERFMON_DIR/bin" ]] || print -u2 "perfmon: bin not found at $PERFMON_DIR/bin"

export PATH="$PERFMON_DIR/bin:$PATH"

# Auto-launch on herdr attach. Backgrounded + silenced so shell startup stays
# instant; perfmon --ensure is lock-guarded so concurrent pane shells are safe.
# Set PERFMON_NO_AUTO=1 to disable.
if [[ "${HERDR_ENV:-}" == "1" && -z "${PERFMON_NO_AUTO:-}" && -x "$PERFMON_DIR/bin/perfmon" ]]; then
  ( "$PERFMON_DIR/bin/perfmon" --ensure >/dev/null 2>&1 & ) 2>/dev/null
fi
