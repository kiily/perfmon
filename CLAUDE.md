# CLAUDE.md

Guidance for AI coding agents working in this repo. Based on Andrej Karpathy's
[viral CLAUDE.md 4 rules](https://lucaberton.com/blog/karpathy-claude-md-llm-coding-principles-2026/)
(Jan 2026).

## The 4 rules

1. **Think before coding.** State your assumptions and surface anything unclear
   *before* you edit. If the request is ambiguous, ask — don't guess and build.

2. **Simplicity first.** No feature, abstraction, config knob, or dependency
   beyond what was asked. Reach for the shell builtin / stdlib / an existing
   helper before writing new code. The best code is the code never written.

3. **Surgical changes.** Touch only what the request requires. Match the
   surrounding style. A small diff in the wrong place is a second bug — read the
   whole flow first, then make the minimal change.

4. **Goal-driven execution.** Work toward the success criterion, not a fixed
   script of steps. Verify the outcome (run it, check exit codes) rather than
   assuming it worked.

## This repo specifically

- Pure `bash` + macOS tools (`ps`, `vm_stat`, `memory_pressure`, `sysctl`) and
  the `herdr` CLI. No package manager, no build step. Keep it that way.
- Exception: `app/` is the native menu bar app (SwiftUI + Charts, three Swift
  files). Built by `app/build.sh` with plain `swiftc` + `actool` — no Xcode
  project, no SwiftPM, no third-party packages. Releases: `app/release.sh`. Read metrics via Mach/sysctl/libproc/IOKit, never
  by shelling out. `Perfmon --selftest` holds its checks.
- Scripts live in `bin/` and must stay runnable standalone from any shell.
- Non-trivial logic gets a check in `test/smoke.sh`. Run `bash test/smoke.sh`
  before you call a change done.
- `perfmon` re-finds its herdr tab by **label**, never by cached id
  (ids are session-scoped). Don't reintroduce id caching.
