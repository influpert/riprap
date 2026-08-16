#!/usr/bin/env bash
# Shared constant for the plan stress-test gate.
# Sourced by bin/hooks/riprap/claude/require-plan-stress-test.sh.
# See interaction-preferences.md's "Always stress-test a plan before presenting it" for
# the rule, and its "## Enforcement" subsection for what this mechanism does and does not
# verify.
#
# QUALIFYING_TOOL_NAMES does not live here. It names the subagent-dispatch tool for this
# harness — a fact about the runtime the hook is running under, not a project preference —
# and this file's .local.sh extension point below is exactly the mechanism that would let
# a mismatched name go silently unnoticed rather than surfaced and fixed upstream. It is a
# plain constant in the hook script itself instead.

# The floor: this many qualifying dispatches, since the last PASSING check, before
# ExitPlanMode is allowed. Five distinct-angle critics plus the mandatory devil's
# advocate, per interaction-preferences.md.
# shellcheck disable=SC2034  # consumed by require-plan-stress-test.sh
STRESS_TEST_MIN_DISPATCHES=6

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a value changed here is
# gone the next time. To raise or lower STRESS_TEST_MIN_DISPATCHES for this project, set
# it in bin/hooks/lib/stress-test-patterns.local.sh instead; riprap sources it if present
# and never overwrites it.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/stress-test-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
