# perfmon shell integration — sourced from ~/.zshrc
# Adds memtop/fkill/perfmon to PATH and auto-launches the PERF MONITORING
# herdr workspace when a shell starts inside herdr.

export PATH="$HOME/Documents/devtools/perfmon/bin:$PATH"

# Auto-launch on herdr attach. Backgrounded + silenced so shell startup stays
# instant; perfmon --ensure is lock-guarded so concurrent pane shells are safe.
# Set PERFMON_NO_AUTO=1 to disable.
if [[ "${HERDR_ENV:-}" == "1" && -z "${PERFMON_NO_AUTO:-}" ]]; then
  ( "$HOME/Documents/devtools/perfmon/bin/perfmon" --ensure >/dev/null 2>&1 & ) 2>/dev/null
fi
